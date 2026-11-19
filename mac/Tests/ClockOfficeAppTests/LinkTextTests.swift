import AppKit
import SwiftUI
import Testing
@testable import ClockOffice

// T-23: a paragraph with links is drawn by AppKit's text view, which shows a pointing hand over a link.

private func linked(_ md: String) -> AttributedString {
    var a = try! AttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
    for run in a.runs where run.link != nil { a[run.range].underlineStyle = .single }
    return a
}

@MainActor private func shown(_ text: AttributedString, size: CGFloat, spacing: CGFloat, width: CGFloat) -> NSTextView {
    let v = LinkText.view()
    v.textStorage?.setAttributedString(LinkText.attributed(text, size: size, lineSpacing: spacing))
    v.linkTextAttributes = LinkText.linkLook(.labelColor)
    let fit = LinkText.fit(v, width: width)!
    v.frame = NSRect(origin: .zero, size: fit)
    return v
}

@MainActor @Test func aLinkIsTheTextsOwnColourUnderlinedWithAPointingHand() {
    let look = LinkText.linkLook(.red)
    #expect(look[.cursor] as? NSCursor == NSCursor.pointingHand)
    #expect(look[.foregroundColor] as? NSColor == .red)
    #expect(look[.underlineStyle] as? Int == NSUnderlineStyle.single.rawValue)
    let v = shown(linked("See [the page](https://example.com) now."), size: 15, spacing: 6, width: 600)
    #expect(v.isSelectable && !v.isEditable, "the words stay selectable, never editable")
    // The hand itself is AppKit's: it shows the `.cursor` of the letters under the pointer. Not measurable in a
    // test (a made-up cursor event stops AppKit); checked by hovering in the app.
}

@MainActor @Test func aClickOnALinkGoesToTheAppsOwnOpener() {
    var got: URL?
    let c = LinkText.Coordinator()
    c.open = OpenURLAction { url in got = url; return .handled }
    let v = LinkText.view()
    #expect(c.textView(v, clickedOnLink: URL(string: "https://example.com/a")!, at: 0), "handled here, not by AppKit")
    #expect(got == URL(string: "https://example.com/a"))
    // Without the app's opener a click does nothing rather than open by itself.
    let bare = LinkText.Coordinator()
    #expect(bare.textView(v, clickedOnLink: URL(string: "https://example.com/b")!, at: 0))
}

@MainActor @Test func theParagraphIsAsTallAsTheSwiftUITextWas() {
    for (size, spacing, width) in [(CGFloat(15), CGFloat(6), CGFloat(600)), (13, 4, 300)] {
        let text = linked(String(repeating: "A sentence with **bold**, `code` and a [link](https://example.com) in it. ", count: 5))
        let swiftUI = ImageRenderer(content: Text(text).font(.system(size: size)).lineSpacing(spacing)
            .frame(width: width, alignment: .leading).fixedSize(horizontal: false, vertical: true))
        let drawn = swiftUI.nsImage?.size.height ?? 0
        let fit = shown(text, size: size, spacing: spacing, width: width).frame.size
        #expect(drawn > 40)
        #expect(abs(drawn - fit.height) <= 4, "SwiftUI \(drawn) vs AppKit \(fit.height) at \(size) pt, width \(width)")
        #expect(fit.width <= width)
    }
}

@MainActor @Test func aShortParagraphIsAsWideAsItsWords() {
    let v = shown(linked("Open [it](https://example.com)."), size: 13, spacing: 4, width: 600)
    #expect(v.frame.width < 100, "a user's short message hugs its words: \(v.frame.width)")
    #expect(v.frame.height < 25)
}

@MainActor @Test func aLinkOpensOnTheClickThatBringsTheWindowForward() {
    #expect(LinkText.view().acceptsFirstMouse(for: nil))
}

@MainActor @Test func theRightClickMenuOffersOnlyCopyOpenAndCopyLink() {
    let v = shown(linked("See [the page](https://example.com/a) now."), size: 15, spacing: 6, width: 600)
    let c = LinkText.Coordinator()
    var got: URL?
    c.open = OpenURLAction { url in got = url; return .handled }
    let theirs = NSMenu()
    for t in ["Open With", "Search With Google", "Cut", "Paste", "Font", "Spelling and Grammar"] { theirs.addItem(withTitle: t, action: nil, keyEquivalent: "") }
    let e = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    let onLink = (v.string as NSString).range(of: "page").location
    v.setSelectedRange(NSRange(location: 0, length: 3))
    let menu = c.textView(v, menu: theirs, for: e, at: onLink)!
    #expect(menu.items.map(\.title) == ["Copy", "Open Link", "Copy Link"])
    let open = menu.items[1]
    _ = (open.target as AnyObject).perform(open.action, with: open)
    #expect(got == URL(string: "https://example.com/a"), "Open Link goes to the app's own opener")
    v.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(c.textView(v, menu: theirs, for: e, at: 0) == nil, "off a link, with nothing selected: no menu")
    #expect(LinkText.Coordinator.shown(URL(string: "https://example.com/a")!) == "https://example.com/a")
    #expect(LinkText.Coordinator.shown(URL(fileURLWithPath: "/tmp/a b.txt")) == "/tmp/a b.txt")
}

@MainActor @Test func aRightClickOnALinkIsLeftToTheLinkNotTheMessage() {
    // The window is never put on screen: nothing shows up on the user's desktop.
    let v = shown(linked("See [the page](https://example.com/a) now."), size: 15, spacing: 6, width: 600)
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 80), styleMask: .borderless,
                     backing: .buffered, defer: true)
    let box = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 80))
    box.addSubview(v)
    w.contentView = box
    func point(_ word: String) -> NSPoint {
        let r = (v.string as NSString).range(of: word)
        let g = v.layoutManager!.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = v.layoutManager!.boundingRect(forGlyphRange: g, in: v.textContainer!)
        rect.origin.x += v.textContainerOrigin.x
        rect.origin.y += v.textContainerOrigin.y
        return v.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
    }
    #expect(CopyMessageCatcher.link(at: point("page"), in: w), "on a link: the link's own menu")
    #expect(!CopyMessageCatcher.link(at: point("now"), in: w), "on plain words: Copy Message as before")
    #expect(!CopyMessageCatcher.link(at: NSPoint(x: 630, y: 75), in: w), "beside the words: Copy Message")
}
