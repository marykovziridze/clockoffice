import AppKit
import SwiftUI
import Network
import Vision
import ClockOfficeCore
import ClockOfficeUI

// The test rig: the app's real screens and its real keyboard handling, driven with made-up sessions.
//   ClockOffice --rig <folder> [--port 48100]
// A test agent looks at a picture of the screen, then clicks, moves the pointer, types or presses
// keys, through plain web requests to 127.0.0.1. Nothing real is read and nothing is typed into any real session:
// the store is the same fixture the design renders use; a link that would open the real app is caught here; a menu
// item that would change real settings is shown but not carried out.
//
//   /look                 the current screen: a PNG and every piece of text on it with its place (read from the
//                         picture itself, as eyes would: what is not visible is not listed)
//   /open?surface=…       menubar (dropdown closed) | dropdown | menu (the icon's right-click menu) | window | widget
//   /click?x=…&y=…        a click at that point (points, from the top-left of the picture)
//   /rightclick?x=…&y=…   a right-click (on the menu-bar icon it opens the menu)
//   /hover?x=…&y=…        moves the pointer there without clicking
//   /press?n=…            clicks the middle of text n of the last list
//   /type?text=…          types into the field that has the caret (click a field first)
//   /key?name=…           return, escape, tab, up, down, cmd (hold), cmd-release, cmd+1 … cmd+9, cmd+o, cmd+w
//
// The rig's window sits on the screen but fully transparent and outside Mission Control. (It used to be parked
// 20,000 points off screen, and Mission Control shrank every window into a pile to fit that in.)

private final class RigWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class Rig {
    static let bar: CGFloat = 30   // the height of the drawn menu bar above the dropdown

    let dir: URL
    let store: Store
    private let menuBar: MenuBar
    private var surface = SurfaceModel(kind: .panel)
    private var kind = "menubar"
    private var films = 0
    private var window: RigWindow!
    private var menuRows: [(item: NSMenuItem, rect: NSRect)] = []
    private var texts: [NSRect] = []
    private var shots = 0
    private var listener: NWListener?
    private var scheduled: Set<String> = []
    private var outside: [String] = []
    private let started = Date()

    init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sessions = Fixtures.sessions()
        // Session "f" (four days old) cannot be replied to from here, so the "why not" line is on show too.
        // One long conversation, as real sessions have: the view must open at its newest words.
        var turns = Fixtures.turns()
        turns["d"] = (1...7).flatMap { n in [
            Turn(id: "d-you-\(n)", who: .you, text: "Step \(n): go on with the next part of the history file, and tell me what you changed."),
            Turn(id: "d-claude-\(n)", who: .assistant, text: "Part \(n) is done.\n\nI rewrote the section on who pays for which tool, checked the three figures against the invoices in the folder, and moved the outdated paragraph to the archive note.\n\nNext is part \(n + 1): the list of open accounts. \(n == 7 ? "LAST WORDS: only the closing summary is left to write." : "I will carry on unless you say otherwise.")"),
        ] }
        store = Store(fixture: sessions, replyable: Set(sessions.map(\.id)).subtracting(["f"]), turns: turns,
                      usage: UsageLimits(sessionPercent: 62, sessionResets: Date().addingTimeInterval(2 * 3600 + 900),
                                         weekPercent: 24, weekResets: Date().addingTimeInterval(5 * 86400)),
                      models: ["a": "Opus 5.5", "c": "Fable 5.2"])
        // As on a real Mac: sessions run in an editor; the old one in a plain terminal, where the app cannot type.
        store.hostNames = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.id == "f" ? "Terminal" : "Visual Studio Code") })
        store.autofocus = true
        menuBar = MenuBar(store: store, visible: false)
        store.onOutside = { [weak self] note in self?.outside.append(note) }
        window = RigWindow(contentRect: NSRect(x: 0, y: 0, width: PanelRoot.width, height: 600),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        Self.hide(window)
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true
        show("menubar")
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// A window that works but cannot be seen, clicked by the real pointer, or picked up by Mission Control.
    static func hide(_ w: NSWindow) {
        w.alphaValue = 0
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.collectionBehavior = [.transient, .stationary, .ignoresCycle, .canJoinAllSpaces, .fullScreenAuxiliary]
        park(w)
    }

    /// Bottom-left corner of the screen. A resize keeps a window's top edge, so this is done again after each one:
    /// otherwise the window slid below the screen's edge.
    static func park(_ w: NSWindow) {
        let screen = NSScreen.main?.frame ?? .zero
        w.setFrameOrigin(NSPoint(x: screen.minX, y: screen.minY))
    }

    // MARK: The made-up world moves on

    /// A session the user answered starts working after a few seconds and reports back a little later, as a real one would.
    private func tick() {
        for s in store.justSent where !scheduled.contains(s.id) {
            scheduled.insert(s.id)
            let id = s.id, said = store.sentText(s) ?? ""
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, var now = self.store.session(id) else { return }
                now.state = .working; now.since = Date(); now.question = nil; now.headline = nil; now.options = []
                now.revision = "rig-working"
                self.store.rigReplace(now, adding: Turn(id: UUID().uuidString, who: .you, text: said))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in
                guard let self, var now = self.store.session(id) else { return }
                now.state = .done; now.since = Date(); now.revision = "rig-done"
                now.inShort = "Did what you asked (“\(Words.clip(said, 40))”) and reported back."
                self.store.rigReplace(now, adding: Turn(id: UUID().uuidString, who: .assistant,
                    text: "Done: I went ahead with “\(said)”. The result is in the project folder. Nothing else is needed from you."))
            }
        }
    }

    // MARK: Surfaces

    private var hasBar: Bool { ["menubar", "dropdown", "menu"].contains(kind) }

    private func show(_ name: String) {
        kind = name
        let size: NSSize
        let root: AnyView
        // A link that would open the real app (the widget's rows and answers) is followed inside the rig instead.
        let open = OpenURLAction { [weak self] url in
            Task { @MainActor in self?.follow(url) }
            return .handled
        }
        switch name {
        case "window":
            surface = SurfaceModel(kind: .window)
            size = NSSize(width: 1120, height: 760)
            root = AnyView(WindowRoot().environment(store).environment(surface))
        case "widget":
            size = NSSize(width: 345, height: 354)
            root = AnyView(RigWidget(store: store).environment(\.openURL, open))
        case "dropdown":
            surface = SurfaceModel(kind: .panel)
            surface.openMainWindow = { [weak self] in self?.show("window") }
            size = NSSize(width: PanelRoot.width, height: 600)
            root = AnyView(PanelRoot().environment(store).environment(surface))
        default:
            // "menubar" (nothing open) and "menu" (drawn by hand below): an empty desktop under the bar.
            kind = name == "menu" ? "menu" : "menubar"
            size = NSSize(width: PanelRoot.width, height: name == "menu" ? 330 : 90)
            root = AnyView(Color.clear)
        }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        window.setContentSize(size)
        Self.park(window)
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        window.orderFrontRegardless()
        window.makeKey()
    }

    private func follow(_ url: URL) {
        guard let link = WidgetLink(url) else { return }
        switch link {
        case .open: show("dropdown")
        case .session(let id): show("dropdown"); surface.show(id)
        case .answer(let id, let n, _, _):
            if let s = store.session(id), n < s.options.count { store.send(s, text: s.options[n].send, withAttachments: false) }
        }
    }

    /// The dropdown is as tall as its content, as the real one is.
    private func fit() {
        guard kind == "dropdown" else { return }
        surface.roomForContent = 900 - 12
        let h = min(max(surface.contentHeight + 12, 80), 900)
        if abs(window.frame.height - h) > 0.5 {
            window.setContentSize(NSSize(width: PanelRoot.width, height: h))
            Self.park(window)
        }
    }

    // MARK: Looking

    /// The menu-bar icon as the app shows it: the glyph, and the count of questions beside it.
    private func drawBar(width: CGFloat) {
        NSColor(white: 0.13, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: Self.bar).fill()
        if let glyph = Assets.menuGlyph() {
            let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                glyph.draw(in: rect); NSColor.white.set(); rect.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: NSRect(x: 14, y: 5, width: 20, height: 20))
        }
        let title = NSMutableAttributedString(attributedString: MenuBar.countTitle(store.asking.count))
        title.addAttribute(.foregroundColor, value: NSColor.white, range: NSRange(location: 0, length: title.length))
        title.draw(at: NSPoint(x: 35, y: 6))
    }

    /// The icon's right-click menu, drawn as a plain list from the app's real menu (titles, ticks, greyed items).
    private func drawMenu(in area: NSRect) {
        NSColor(white: 0.17, alpha: 1).setFill()
        NSBezierPath(roundedRect: area.insetBy(dx: 6, dy: 6), xRadius: 8, yRadius: 8).fill()
        menuRows = []
        var y = area.maxY - 16
        for item in menuBar.buildMenu().items {
            if item.isSeparatorItem {
                NSColor(white: 1, alpha: 0.12).setFill()
                NSRect(x: area.minX + 18, y: y - 5, width: area.width - 36, height: 1).fill()
                y -= 10
                continue
            }
            let row = NSRect(x: area.minX + 12, y: y - 22, width: area.width - 24, height: 22)
            let on = item.state == .on, dead = item.action == nil
            NSAttributedString(string: (on ? "✓ " : "    ") + item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: dead ? NSColor(white: 1, alpha: 0.4) : NSColor.white,
            ]).draw(at: NSPoint(x: row.minX + 6, y: row.minY + 3))
            menuRows.append((item, row))
            y -= 22
        }
    }

    private func look(note: String) -> [String: Any] {
        fit()
        window.contentView?.layoutSubtreeIfNeeded()
        shots += 1
        let name = String(format: "screen-%03d.png", shots)
        let content = window.frame.size
        let top = hasBar ? Self.bar : 0
        let full = NSSize(width: content.width, height: content.height + top)
        var cg: CGImage?
        if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
           let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(full.width * 2), pixelsHigh: Int(full.height * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            view.cacheDisplay(in: view.bounds, to: rep)
            out.size = full
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
            // The wallpaper behind everything, so a closed dropdown is an empty desktop and not a black hole.
            NSColor(srgbRed: 0.23, green: 0.165, blue: 0.19, alpha: 1).setFill()
            NSRect(origin: .zero, size: full).fill()
            rep.draw(in: NSRect(x: 0, y: 0, width: content.width, height: content.height))
            if kind == "menu" { drawMenu(in: NSRect(x: 0, y: 0, width: content.width, height: content.height)) }
            if hasBar {
                NSGraphicsContext.current?.cgContext.translateBy(x: 0, y: content.height)
                drawBar(width: content.width)
            }
            NSGraphicsContext.restoreGraphicsState()
            try? out.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            cg = out.cgImage
        }
        texts = []
        var list: [[String: Any]] = []
        if let cg {
            for (text, box) in Self.read(cg) {
                // Vision measures from the bottom-left in fractions; the list is in points from the top-left.
                let r = NSRect(x: box.minX * full.width, y: (1 - box.maxY) * full.height,
                               width: box.width * full.width, height: box.height * full.height)
                list.append(["n": texts.count, "says": text, "x": Int(r.minX.rounded()), "y": Int(r.minY.rounded()),
                             "w": Int(r.width.rounded()), "h": Int(r.height.rounded())])
                texts.append(r)
            }
        }
        let line = String(format: "%6.1fs  %@  → %@\n", Date().timeIntervalSince(started), note, name)
        if let h = try? FileHandle(forWritingTo: dir.appendingPathComponent("actions.log")) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: dir.appendingPathComponent("actions.log"), atomically: true, encoding: .utf8)
        }
        var answer: [String: Any] = [
            "ok": true, "surface": kind, "picture": dir.appendingPathComponent(name).path,
            "size_points": [Int(full.width), Int(full.height)],
            "note": "Picture pixels are 2 per point; x and y are in points from the top-left. The list holds the text visible in the picture; things without text (the menu-bar icon, the + and the round arrow of a message box, the dials) are only in the picture.",
            "texts": list,
        ]
        if !outside.isEmpty { answer["happened_outside_the_app"] = outside; outside = [] }
        return answer
    }

    /// Every piece of text in the picture, top to bottom, with its box (in fractions of the picture).
    private static func read(_ image: CGImage) -> [(String, CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US", "nl-NL"]
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { o in
            o.topCandidates(1).first.map { ($0.string, o.boundingBox) }
        }.sorted { $0.1.maxY > $1.1.maxY }
    }

    // MARK: Acting

    private func mouse(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    }

    /// A click in the picture: on the menu-bar icon it opens or closes the dropdown, in the drawn menu it picks an
    /// item, anywhere else it goes to the app's own views.
    private func click(x: CGFloat, y: CGFloat, right: Bool = false) {
        if hasBar && y < Self.bar {
            guard x >= 6, x <= 64 else { return }
            if right { show("menu") } else { show(kind == "dropdown" ? "menubar" : "dropdown") }
            return
        }
        let cy = y - (hasBar ? Self.bar : 0)
        if kind == "menu" {
            let p = NSPoint(x: x, y: window.frame.height - cy)
            guard let hit = menuRows.first(where: { $0.rect.contains(p) }) else { show("menubar"); return }
            pick(hit.item)
            return
        }
        guard !right else { return }
        let p = NSPoint(x: x, y: window.frame.height - cy)
        guard let down = mouse(.leftMouseDown, p), let up = mouse(.leftMouseUp, p) else { return }
        // The release goes into the queue first: a text field answers a press by waiting, inside the press itself,
        // for the release to arrive, and would wait for ever if it were only sent afterwards.
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
    }

    /// Scrolls the list or conversation under a point by `dy` points (positive: towards later content).
    private func scroll(x: CGFloat, y: CGFloat, dy: CGFloat) -> Bool {
        let cy = y - (hasBar ? Self.bar : 0)
        guard let content = window.contentView else { return false }
        let p = content.convert(NSPoint(x: x, y: window.frame.height - cy), from: nil)
        guard let sv = content.hitTest(p)?.enclosingScrollView ?? Self.firstScroll(in: content), let doc = sv.documentView else { return false }
        var o = sv.contentView.bounds.origin
        let room = max(0, doc.frame.height - sv.contentView.bounds.height)
        o.y = min(max(0, o.y + (doc.isFlipped ? dy : -dy)), room)
        sv.contentView.scroll(to: o)
        sv.reflectScrolledClipView(sv.contentView)
        return true
    }
    private static func firstScroll(in v: NSView) -> NSScrollView? {
        if let s = v as? NSScrollView { return s }
        for c in v.subviews { if let s = firstScroll(in: c) { return s } }
        return nil
    }

    /// A transition on film: one picture of the surface every `ms` milliseconds after a click, without reading
    /// the text, so motion can be looked at frame by frame (a still of the end state says nothing about a jump).
    private func film(x: CGFloat, y: CGFloat, frames: Int, ms: Int, done: @escaping ([String]) -> Void) {
        films += 1
        let n = films
        var names: [String] = []
        var i = 0
        func shoot() {
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let name = String(format: "film-%02d-%02d.png", n, i)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
                names.append(name)
            }
            i += 1
            if i < frames { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) { shoot() } } else { done(names) }
        }
        shoot()                 // the frame before the click
        click(x: x, y: y)
    }

    /// A menu item. Only what stays inside the app is carried out; anything that would change real settings, or
    /// quit, is described instead.
    private func pick(_ item: NSMenuItem) {
        if item.title == "Open ClockOffice" { show("window"); return }
        guard item.action != nil else { show("menubar"); return }
        let tip = item.toolTip.map { " Its tooltip says: “\($0)”" } ?? ""
        outside.append("The menu item “\(item.title)” (now \(item.state == .on ? "ticked" : "not ticked")) was clicked. In this test it is not carried out, because it would change real settings on the Mac.\(tip)")
        show("menubar")
    }

    /// Moves the pointer without clicking, so hover states can be looked at.
    private func hover(x: CGFloat, y: CGFloat) {
        guard !(hasBar && y < Self.bar), kind != "menu" else { return }
        let p = NSPoint(x: x, y: window.frame.height - (y - (hasBar ? Self.bar : 0)))
        // SwiftUI learns about the pointer from the tracking areas of its hosting view: each gets an "entered"
        // and a "moved" at the new place.
        guard let view = window.contentView else { return }
        var targets: [NSView] = [view]
        var i = 0
        while i < targets.count { targets.append(contentsOf: targets[i].subviews); i += 1 }
        for v in targets {
            for area in v.trackingAreas {
                if let enter = NSEvent.enterExitEvent(with: .mouseEntered, location: p, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, trackingNumber: area.hash, userData: nil) {
                    (area.owner as? NSResponder)?.mouseEntered(with: enter)
                }
            }
        }
        if let e = mouse(.mouseMoved, p) {
            window.sendEvent(e)
            for v in targets where !v.trackingAreas.isEmpty { v.mouseMoved(with: e) }
        }
    }

    private func type(_ text: String) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

    /// A key, sent through the app's own key handling first (the same code the real app runs), and on to the field
    /// that has the caret when the app does not take it.
    private func key(_ name: String) -> Bool {
        let n = name.lowercased().replacingOccurrences(of: " ", with: "+")
        let model: SurfaceModel? = (kind == "dropdown" || kind == "window") ? surface : nil
        func send(_ e: NSEvent?) {
            guard let e else { return }
            let passed = Keys.handle(e, surface: model, store: store,
                                     hidePanel: { [weak self] in self?.show("menubar") },
                                     closeWindow: { [weak self] in self?.show("menubar") }, paste: { _ in false })
            if let passed, passed.type == .keyDown { window.sendEvent(passed) }
        }
        func flags(_ f: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: 55)
        }
        if n == "cmd" || n == "cmd-hold" { send(flags(.command)); return true }
        if n == "cmd-release" { send(flags([])); return true }
        var mods: NSEvent.ModifierFlags = []
        var base = n
        if n.hasPrefix("cmd+") { mods = .command; base = String(n.dropFirst(4)) }
        let arrow = { (c: Int) in String(UnicodeScalar(c)!) }
        let codes: [String: (UInt16, String)] = [
            "return": (36, "\r"), "escape": (53, "\u{1b}"), "esc": (53, "\u{1b}"), "tab": (48, "\t"),
            "up": (126, arrow(0xF700)), "down": (125, arrow(0xF701)), "o": (31, "o"), "w": (13, "w"),
            "1": (18, "1"), "2": (19, "2"), "3": (20, "3"), "4": (21, "4"), "5": (23, "5"),
            "6": (22, "6"), "7": (26, "7"), "8": (28, "8"), "9": (25, "9"),
        ]
        guard let (code, chars) = codes[base] else { return false }
        if mods.contains(.command) { send(flags(.command)) }
        send(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                              windowNumber: window.windowNumber, context: nil, characters: chars,
                              charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code))
        if mods.contains(.command) { send(flags([])) }
        return true
    }

    /// One request: do the thing, give the screens a moment to settle, then answer with what is now on screen.
    func handle(_ path: String, _ q: [String: String], reply: @escaping ([String: Any]) -> Void) {
        let note = path + (q.isEmpty ? "" : " " + q.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        var problem: String?
        func point() -> (CGFloat, CGFloat)? {
            guard let x = q["x"].flatMap(Double.init), let y = q["y"].flatMap(Double.init) else { return nil }
            return (CGFloat(x), CGFloat(y))
        }
        switch path {
        case "/look": break
        case "/open":
            let s = q["surface"] ?? ""
            if ["menubar", "dropdown", "menu", "window", "widget"].contains(s) { show(s) }
            else { problem = "surface must be menubar, dropdown, menu, window or widget" }
        case "/click":
            if let (x, y) = point() { click(x: x, y: y) } else { problem = "give x and y in points" }
        case "/rightclick":
            if let (x, y) = point() { click(x: x, y: y, right: true) } else { problem = "give x and y in points" }
        case "/hover":
            if let (x, y) = point() { hover(x: x, y: y) } else { problem = "give x and y in points" }
        case "/press":
            if let n = q["n"].flatMap({ Int($0) }), n >= 0, n < texts.count { click(x: texts[n].midX, y: texts[n].midY) }
            else { problem = "no text with that number in the last list; /look again" }
        case "/type":
            if !type(q["text"] ?? "") { problem = "no field has the caret: click a field first" }
        case "/scroll":
            if let (x, y) = point(), let dy = q["dy"].flatMap(Double.init) {
                if !scroll(x: x, y: y, dy: CGFloat(dy)) { problem = "nothing scrolls there" }
            } else { problem = "give x, y and dy in points" }
        case "/film":
            guard let (x, y) = point() else { reply(["ok": false, "problem": "give x and y in points"]); return }
            let frames = min(max(q["frames"].flatMap { Int($0) } ?? 24, 2), 90), ms = min(max(q["ms"].flatMap { Int($0) } ?? 16, 8), 200)
            film(x: x, y: y, frames: frames, ms: ms) { [weak self] names in
                guard let self else { return }
                reply(["ok": true, "frames": names, "folder": self.dir.path, "every_ms": ms,
                       "note": "frame 00 is before the click; pictures are of the surface only (no menu bar strip), 2 pixels per point"])
            }
            return
        case "/key":
            if !key(q["name"] ?? "") { problem = "name must be return, escape, tab, up, down, cmd, cmd-release, cmd+1 … cmd+9, cmd+o or cmd+w" }
        default: problem = "unknown request; use /look /open /click /rightclick /hover /press /type /key /scroll /film"
        }
        if let problem {
            reply(["ok": false, "problem": problem])
            return
        }
        // The dropdown is resized to its content first, and only then given time to settle: a click that came
        // right after the window had been resized and moved was swallowed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.fit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                reply(self.look(note: note))
            }
        }
    }

    // MARK: The door

    func listen(port: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        // No port reuse (T-42): with it a rig started silently on a port another process held, and that process got
        // every request. A port in use now ends the rig with a message, as a failed start already did.
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state {
                print("rig: cannot listen on \(port): \(e)")
                exit(1)
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global(qos: .userInitiated))
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let head = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let c = URLComponents(string: "http://x" + target)
                var q: [String: String] = [:]
                for item in c?.queryItems ?? [] { q[item.name] = item.value ?? "" }
                let path = c?.path ?? "/"
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { conn.cancel(); return }
                        self.handle(path, q) { answer in
                            let body = (try? JSONSerialization.data(withJSONObject: answer, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
                            var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                            out.append(body)
                            conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
                        }
                    }
                }
            }
        }
        l.start(queue: .global(qos: .userInitiated))
        listener = l
    }
}

/// The large widget, fed from the rig's made-up sessions and kept current.
private struct RigWidget: View {
    let store: Store
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            Themed {
                WidgetCard(snapshot: Snapshot.from(store.sessions.filter { store.sentText($0) == nil }, now: ctx.date,
                                                   answerable: Set(store.sessions.map(\.id)).subtracting(["f"]), runSecret: "rig",
                                                   limited: store.outOfLimit),
                           now: ctx.date, size: .large)
                    .padding(16)
            }
            .background(Theme.dark.panel)
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
    }
}
