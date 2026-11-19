import AppKit
import SwiftUI
import ClockOfficeCore

/// The text view of a paragraph with links. A click on a link opens it even while ClockOffice is in the background:
/// AppKit's text view ignores the click that brings its window forward, and that first click opened nothing
/// (verifier 1 of T-23), the very "click did nothing" this task began with.
final class LinkTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A paragraph with links, drawn by AppKit's own text view (T-23). Selectable SwiftUI text shows the text cursor over
/// its links, and every way of taking the cursor from it was seen to fail in the user's app (2026-11-18): set on each
/// move it flickered, AppKit cursor areas lost to it, and making the paragraph unselectable while on a link still
/// flickered. NSTextView shows a pointing hand over a link itself, and keeps selection, copy and the text cursor
/// elsewhere. Paragraphs without links stay SwiftUI text.
struct LinkText: NSViewRepresentable {
    let text: AttributedString
    let size: CGFloat
    let lineSpacing: CGFloat
    let color: Color

    final class Coordinator: NSObject, NSTextViewDelegate {
        var open: OpenURLAction?
        static func url(_ link: Any?) -> URL? { (link as? URL) ?? (link as? String).flatMap(URL.init(string:)) }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = Self.url(link), let open else { return true } // never handed to AppKit's own opener
            open(url)
            return true
        }

        /// The right-click menu holds Copy, and on a link Open Link and Copy Link, nothing else: AppKit's own menu
        /// offered "Open With" a browser and "Search With Google", which skip the app's link rules, and editing
        /// items for words no one can edit (verifier 1 of T-23).
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            let out = NSMenu()
            if view.selectedRange().length > 0 {
                out.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: ""))
            }
            if charIndex >= 0, charIndex < (view.textStorage?.length ?? 0),
               let url = Self.url(view.textStorage?.attribute(.link, at: charIndex, effectiveRange: nil)) {
                for (title, action) in [("Open Link", #selector(openLink(_:))), ("Copy Link", #selector(copyLink(_:)))] {
                    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    out.addItem(item)
                }
            }
            return out.items.isEmpty ? nil : out // no menu at all rather than an empty one
        }

        @objc func openLink(_ item: NSMenuItem) {
            if let url = item.representedObject as? URL, let open { open(url) }
        }

        @MainActor @objc func copyLink(_ item: NSMenuItem) {
            guard let url = item.representedObject as? URL else { return }
            Clip.board.clearContents()
            Clip.board.setString(Self.shown(url), forType: .string)
        }

        /// A link as a person reads it: a file's path, a web page's address (never the app's own inner name).
        static func shown(_ url: URL) -> String {
            let outer = Linker.outer(url) ?? url
            return outer.isFileURL ? outer.path : outer.absoluteString
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let v = LinkText.view()
        v.delegate = context.coordinator
        return v
    }

    static func view() -> NSTextView {
        let v = LinkTextView(usingTextLayoutManager: false)
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.isRichText = true
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = true
        v.isVerticallyResizable = false
        v.isHorizontallyResizable = false
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    func updateNSView(_ v: NSTextView, context: Context) {
        context.coordinator.open = context.environment.openURL
        let ink = NSColor(color)
        let s = LinkText.attributed(text, size: size, lineSpacing: lineSpacing, color: ink)
        if v.textStorage?.isEqual(to: s) != true { v.textStorage?.setAttributedString(s) }
        v.linkTextAttributes = LinkText.linkLook(ink)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView v: NSTextView, context: Context) -> CGSize? {
        LinkText.fit(v, width: proposal.width)
    }

    /// As wide as its words, at most the width offered: what SwiftUI text answers too (a user's message hugs them).
    /// Measured on a copy of the words: the text view's own layout reports every line as wide as the view.
    static func fit(_ v: NSTextView, width offered: CGFloat?) -> CGSize? {
        guard let words = v.textStorage else { return nil }
        let width = offered.flatMap { $0.isFinite ? $0 : nil } ?? 10_000
        let storage = NSTextStorage(attributedString: words), m = NSLayoutManager()
        let c = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        c.lineFragmentPadding = 0
        m.addTextContainer(c); storage.addLayoutManager(m); m.ensureLayout(for: c)
        var widest: CGFloat = 0
        m.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: m.numberOfGlyphs)) { _, used, _, _, _ in
            widest = max(widest, used.width)
        }
        return CGSize(width: min(width, ceil(widest) + 1), height: ceil(m.usedRect(for: c).height))
    }

    /// How a link looks: the text's own colour, underlined, with a pointing hand over it.
    static func linkLook(_ ink: NSColor) -> [NSAttributedString.Key: Any] {
        [.foregroundColor: ink, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    }

    /// The words as SwiftUI set them: the font of each run (bold, code, italic), the paragraph's line spacing,
    /// the colour, and each link.
    static func attributed(_ text: AttributedString, size: CGFloat, lineSpacing: CGFloat, color: NSColor = .labelColor) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        for run in text.runs {
            let intent = run.inlinePresentationIntent ?? []
            var font = intent.contains(.code) ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
            if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style, .foregroundColor: color]
            if let link = run.link { attrs[.link] = link }
            out.append(NSAttributedString(string: String(text.characters[run.range]), attributes: attrs))
        }
        return out
    }
}

/// Words that may hold links: SwiftUI text when they hold none, `LinkText` when they do. Applies the text selection
/// itself: callers do not add `.textSelection`.
struct LinkWords: ViewModifier {
    let text: AttributedString
    let size: CGFloat
    let lineSpacing: CGFloat
    let color: Color

    func body(content: Content) -> some View {
        if text.runs.contains(where: { $0.link != nil }) {
            LinkText(text: text, size: size, lineSpacing: lineSpacing, color: color)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            content.textSelection(.enabled)
        }
    }
}
