import AppKit
import SwiftUI
import ClockOfficeCore
import ClockOfficeUI

/// Draws each surface with sample sessions into PNG files, off screen. This is how the design is checked by eye
/// without installing anything: `ClockOffice --render <folder>`.
@MainActor
enum Renderer {
    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let all = Fixtures.sessions()
        let linkTurns: [Turn]? = linkTurns(dir)
        for dark in [true, false] {
            let tag = dark ? "dark" : "light"
            panel("panel-list-\(tag)", all, dark, dir) { _, _ in }
            panel("panel-detail-\(tag)", all, dark, dir) { _, surface in surface.show("a") }
            panel("panel-detail-done-\(tag)", all, dark, dir) { _, surface in surface.show("e") }
            panel("panel-quiet-\(tag)", all.filter { $0.state != .asking }, dark, dir) { _, _ in }
            // A real-life case: a long last message in a session that cannot be replied to from here.
            var long = all[2]; long.id = "long"; long.title = "Project review and improvement plan"
            panel("panel-long-\(tag)", [long] + all, dark, dir, replyable: []) { _, surface in surface.show("long") }
            panel("panel-noreply-\(tag)", all, dark, dir, replyable: []) { _, _ in }
            // A Codex conversation beside the Claude Code sessions: listed like any other, its own view names the
            // tool and says why it cannot be answered from here.
            let codex = Session(id: "x", tool: "Codex", pid: 0, cwd: NSHomeDirectory() + "/Code/web-shop", project: "Web shop",
                                title: "Add a discount field to the checkout", state: .asking, since: Date().addingTimeInterval(-7 * 60),
                                question: "I found 14 old migration files. Should I delete them, or move them to an archive folder?",
                                headline: "Delete 14 old migration files, or archive them?",
                                inShort: "Added the field; asks what to do with old migrations.")
            panel("panel-codex-\(tag)", all + [codex], dark, dir, replyable: Set(all.map(\.id))) { _, _ in }
            panel("panel-codex-detail-\(tag)", all + [codex], dark, dir, replyable: Set(all.map(\.id))) { _, surface in surface.show("x") }
            // A permission prompt held by the hook: Allow and Deny, also for a session in a plain terminal (no message
            // box there), since the answer goes back through Claude Code's hook and not through typing.
            let perm = Session(id: "p", tool: "Claude Code", pid: 0, cwd: NSHomeDirectory() + "/Projects/client-website",
                               project: "Client website", title: "Cleaning the build folder", state: .asking,
                               since: Date().addingTimeInterval(-3 * 60), certain: true, waitingFor: "permission prompt",
                               question: "Allow Bash: rm -rf dist && npm run build?", headline: "Allow Bash: rm -rf dist && npm run build?",
                               options: [ReplyOption(label: "Allow", send: Store.allowMark + "render"),
                                         ReplyOption(label: "Deny", send: Store.denyMark + "render")],
                               inShort: "Wants to clear the build folder and build again.")
            panel("panel-permission-\(tag)", [perm] + all, dark, dir, replyable: Set(all.map(\.id))) { _, _ in }
            panel("panel-permission-detail-\(tag)", [perm] + all, dark, dir, replyable: Set(all.map(\.id))) { _, surface in surface.show("p") }
            panel("panel-permission-sending-\(tag)", [perm] + all, dark, dir, replyable: Set(all.map(\.id))) { store, surface in
                surface.show("p"); store.answer(perm, perm.options[0])
            }
            // A command too long for the list's headline: the list offers no Allow; the session's view shows it whole.
            var longAsk = perm
            longAsk.question = "Allow Bash: find . -name '*.log' -mtime +30 -print0 | xargs -0 rm -f && rsync -av --delete ./dist/ deploy@staging:/var/www/site/?"
            longAsk.headline = Words.clip(longAsk.question!, 90)
            panel("panel-permission-long-\(tag)", [longAsk] + all, dark, dir, replyable: Set(all.map(\.id))) { _, _ in }
            panel("panel-permission-long-detail-\(tag)", [longAsk] + all, dark, dir, replyable: Set(all.map(\.id))) { _, surface in surface.show("p") }
            var noHook = perm; noHook.options = []
            panel("panel-permission-nohook-\(tag)", [noHook] + all, dark, dir, replyable: Set(all.map(\.id))) { _, surface in surface.show("p") }
            // Every session in one folder: its name is said nowhere.
            panel("panel-onefolder-\(tag)", all.map { var s = $0; s.project = "ClockOffice"; return s }, dark, dir) { _, _ in }
            // No question and one folder: the list opens on a plain row, with room above it.
            panel("panel-plain-\(tag)", all.filter { $0.state != .asking }.map { var s = $0; s.project = "ClockOffice"; return s }, dark, dir) { _, _ in }
            // With Claude Code's limits and models reported: the footer lines, and the model in a session's view.
            let limits = UsageLimits(sessionPercent: 85, sessionResets: Date().addingTimeInterval(3 * 3600),
                                     weekPercent: 24, weekResets: Date().addingTimeInterval(6 * 86400))
            usagePanel("panel-usage-\(tag)", all, dark, dir, limits) { _ in }
            // The plan's limit used up: working sessions stand still under a red shine until the reset.
            let spent = UsageLimits(sessionPercent: 100, sessionResets: Date().addingTimeInterval(2 * 3600),
                                    weekPercent: 41, weekResets: Date().addingTimeInterval(6 * 86400))
            usagePanel("panel-limit-\(tag)", all, dark, dir, spent) { _ in }
            usagePanel("panel-limit-detail-\(tag)", all, dark, dir, spent) { surface in surface.show("c") }
            usagePanel("panel-usage-detail-\(tag)", all, dark, dir, limits) { surface in surface.show("c") }
            usageWindow("window-usage-\(tag)", all, dark, dir, limits)
            // An editor window that needs one reload before it takes replies: one window, then two.
            panel("panel-reload-\(tag)", all, dark, dir, stale: ["c"]) { _, _ in }
            panel("panel-reload-two-\(tag)", all, dark, dir, stale: ["b", "c", "d"]) { _, _ in }
            panel("panel-reload-detail-\(tag)", all, dark, dir, stale: ["c"]) { _, surface in surface.show("c") }
            window("window-reload-\(tag)", all, dark, dir, detail: "c", stale: ["c"])
            panel("panel-sent-\(tag)", all, dark, dir) { store, _ in
                store.drafts["a"] = "deep scan, and attach the PPTX too"
                store.attachments["b"] = [NSHomeDirectory() + "/Desktop/brief.pdf"]
                store.send(all[1], text: "yes")
            }
            window("window-\(tag)", all, dark, dir)
            window("window-working-\(tag)", all, dark, dir, detail: "c")
            if let linkTurns { window("window-links-\(tag)", all, dark, dir, detail: "c", turns: ["c": linkTurns]) }
            window("window-fullscreen-\(tag)", all, dark, dir, wide: true)
            for family in [WidgetCard.Size.large, .medium] {
                let size = family == .large ? CGSize(width: 345, height: 354) : CGSize(width: 345, height: 162)
                shoot("widget-\(family == .large ? "large" : "medium")-\(tag)", dark, dir, size: size) {
                    // As on a Mac where the app can type into both asking sessions: their answers show.
                    Themed { WidgetCard(snapshot: Snapshot.from(all, answerable: ["a", "b"], runSecret: "render"), now: Date(), size: family).padding(16) }
                        .background(Theme.of(dark ? .dark : .light).panel)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                }
            }
            // The medium size with no questions, one session working and one done.
            shoot("widget-medium-quiet-\(tag)", dark, dir, size: CGSize(width: 345, height: 162)) {
                Themed { WidgetCard(snapshot: Snapshot.from([all[2], all[4]]), now: Date(), size: .medium).padding(16) }
                    .background(Theme.of(dark ? .dark : .light).panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            // The app cannot be reached; and data that is 29 minutes old.
            shoot("widget-offline-\(tag)", dark, dir, size: CGSize(width: 345, height: 162)) {
                Themed { WidgetCard(snapshot: Snapshot(asOf: Date(), asking: [], working: 0, done: 0, live: false), now: Date(), size: .medium).padding(16) }
                    .background(Theme.of(dark ? .dark : .light).panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            shoot("widget-old-\(tag)", dark, dir, size: CGSize(width: 345, height: 162)) {
                Themed { WidgetCard(snapshot: Snapshot.from(all, now: Date()), now: Date().addingTimeInterval(29 * 60), size: .medium).padding(16) }
                    .background(Theme.of(dark ? .dark : .light).panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            // The plan's limit used up, in the widget.
            shoot("widget-limit-\(tag)", dark, dir, size: CGSize(width: 345, height: 354)) {
                Themed { WidgetCard(snapshot: Snapshot.from(all, limited: true), now: Date(), size: .large).padding(16) }
                    .background(Theme.of(dark ? .dark : .light).panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
            shoot("widget-quiet-\(tag)", dark, dir, size: CGSize(width: 345, height: 354)) {
                Themed { WidgetCard(snapshot: Snapshot.from(all.filter { $0.state != .asking }), now: Date(), size: .large).padding(16) }
                    .background(Theme.of(dark ? .dark : .light).panel)
                    .clipShape(RoundedRectangle(cornerRadius: 22))
            }
        }
        // A double-click on a one-click answer must answer one question, not two.
        let guarded = Store(fixture: all, replyable: Set(all.map(\.id)))
        guarded.send(all[0], text: "standaard scan", withAttachments: false)
        guarded.send(all[1], text: "yes", withAttachments: false)
        print("double-click guard: \(guarded.justSent.map(\.id) == ["a"] ? "ok, one answer sent" : "FAILED, sent to \(guarded.justSent.map(\.id))")")
        motionFrames(all, dir)
        menuBarGlyph(dir)
        print("rendered into \(dir.path)")
    }

    static func panel(_ name: String, _ sessions: [Session], _ dark: Bool, _ dir: URL,
                      replyable: Set<String>? = nil, stale: Set<String> = [], setup: (Store, SurfaceModel) -> Void) {
        let store = Store(fixture: sessions, replyable: replyable ?? Set(sessions.map(\.id)), turns: Fixtures.turns(), stale: stale)
        let surface = SurfaceModel(kind: .panel)
        setup(store, surface)
        // Two passes: the first measures the content, the second draws at that height.
        var height: CGFloat = 400
        surface.onHeight = { height = $0 + 12 }
        for pass in 0..<2 {
            let view = PanelRoot().environment(store).environment(surface)
                .frame(width: PanelRoot.width, height: height).padding(16)
            shoot(name, dark, dir, size: CGSize(width: PanelRoot.width + 32, height: height + 32), write: pass == 1) { view }
        }
        // The height the dropdown opens at must be the height its content then reports, or it jumps after opening.
        if surface.detail == nil, dark {
            let fitted = PanelRoot.listHeight(store)
            print("open height \(name): measured before showing \(Int(fitted.rounded())), reported after \(Int((height - 12).rounded()))"
                  + (abs(fitted - (height - 12)) > 1 ? "  MISMATCH" : ""))
        }
    }

    static func usagePanel(_ name: String, _ sessions: [Session], _ dark: Bool, _ dir: URL, _ limits: UsageLimits,
                           setup: (SurfaceModel) -> Void) {
        let store = Store(fixture: sessions, replyable: Set(sessions.map(\.id)), turns: Fixtures.turns(),
                          usage: limits, models: ["c": "Fable 5.2", "a": "Opus 5.5"])
        let surface = SurfaceModel(kind: .panel)
        setup(surface)
        var height: CGFloat = 400
        surface.onHeight = { height = $0 + 12 }
        for pass in 0..<2 {
            let view = PanelRoot().environment(store).environment(surface)
                .frame(width: PanelRoot.width, height: height).padding(16)
            shoot(name, dark, dir, size: CGSize(width: PanelRoot.width + 32, height: height + 32), write: pass == 1) { view }
        }
    }

    static func usageWindow(_ name: String, _ sessions: [Session], _ dark: Bool, _ dir: URL, _ limits: UsageLimits) {
        let store = Store(fixture: sessions, replyable: Set(sessions.map(\.id)), turns: Fixtures.turns(),
                          usage: limits, models: ["c": "Fable 5.2", "a": "Opus 5.5"])
        let surface = SurfaceModel(kind: .window)
        surface.show("c")
        shoot(name, dark, dir, size: CGSize(width: 1120, height: 760)) {
            WindowRoot().environment(store).environment(surface)
        }
    }

    /// A conversation with a link to a file, a web address, and pictures: the user's above their words, Claude's under its.
    static func linkTurns(_ dir: URL) -> [Turn] {
        let shot = dir.appendingPathComponent("sample-screenshot.png").path
        let image = NSImage(size: NSSize(width: 640, height: 220), flipped: false) { rect in
            NSColor(srgbRed: 0.16, green: 0.15, blue: 0.17, alpha: 1).setFill(); rect.fill()
            let accent = Edition.current.accentDark ?? 0xFFA35C
            NSColor(srgbRed: CGFloat((accent >> 16) & 0xFF) / 255, green: CGFloat((accent >> 8) & 0xFF) / 255,
                    blue: CGFloat(accent & 0xFF) / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 80, width: 300, height: 60), xRadius: 30, yRadius: 30).fill()
            NSColor(white: 1, alpha: 0.25).setFill()
            NSRect(x: 360, y: 96, width: 240, height: 10).fill(); NSRect(x: 360, y: 118, width: 180, height: 10).fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: shot))
        }
        for longest in [720, 440] { Pictures.prime(shot, longest: longest) }
        return [
            Turn(id: "l1", who: .you, text: "[screenshot] why is this button cut off?", pictures: [shot]),
            Turn(id: "l2", who: .assistant, text: "The container has a fixed height. I changed it in `\(dir.path)/panel-list-dark.png` (a stand-in for a source file here) and described the rule at https://code.claude.com/docs/en/statusline.\n\nOpen \(shot) to see the result."),
        ]
    }

    static func window(_ name: String, _ sessions: [Session], _ dark: Bool, _ dir: URL, detail: String? = nil, wide: Bool = false,
                       stale: Set<String> = [], turns: [String: [Turn]]? = nil) {
        let store = Store(fixture: sessions, replyable: Set(sessions.map(\.id)), turns: turns ?? Fixtures.turns(), stale: stale)
        let surface = SurfaceModel(kind: .window)
        if let detail { surface.show(detail) }
        shoot(name, dark, dir, size: wide ? CGSize(width: 1710, height: 1000) : CGSize(width: 1120, height: 760)) {
            WindowRoot().environment(store).environment(surface)
        }
    }

    static func shoot<V: View>(_ name: String, _ dark: Bool, _ dir: URL, size: CGSize, write: Bool = true,
                               @ViewBuilder _ content: () -> V) {
        // On the screen but transparent and outside Mission Control: a window parked 20,000 points away made
        // Mission Control shrink every window into a pile.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        Rig.hide(window)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(srgbRed: 0.23, green: 0.165, blue: 0.19, alpha: 1)
                                      : NSColor(srgbRed: 0.89, green: 0.64, blue: 0.70, alpha: 1)
        let host = NSHostingView(rootView: content().frame(width: size.width, height: size.height, alignment: .top))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        // Let SwiftUI lay out, measure and load images.
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()
        if write, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
        window.orderOut(nil)
    }

    /// The push from list to details, caught at a few moments, to check nothing breaks mid-way.
    static func motionFrames(_ sessions: [Session], _ dir: URL) {
        let store = Store(fixture: sessions, replyable: Set(sessions.map(\.id)), turns: Fixtures.turns())
        let surface = SurfaceModel(kind: .panel)
        let size = CGSize(width: PanelRoot.width, height: 520)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        Rig.hide(window)
        window.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: PanelRoot().environment(store).environment(surface).frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        surface.open("a")
        for (i, wait) in [0.03, 0.05, 0.06, 0.3].enumerated() {
            RunLoop.current.run(until: Date().addingTimeInterval(wait))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("motion-\(i).png"))
            }
        }
        window.orderOut(nil)
    }

    /// The menu-bar glyph on a light and a dark bar, with the count beside it.
    static func menuBarGlyph(_ dir: URL) {
        let size = NSSize(width: 240, height: 28)
        let image = NSImage(size: NSSize(width: size.width, height: size.height * 2))
        image.lockFocus()
        for (row, dark) in [(0, true), (1, false)] {
            let y = CGFloat(row) * size.height
            (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.96, alpha: 1)).setFill()
            NSRect(x: 0, y: y, width: size.width, height: size.height).fill()
            if let glyph = Assets.menuGlyph() {
                let tinted = NSImage(size: glyph.size, flipped: false) { rect in
                    glyph.draw(in: rect)
                    (dark ? NSColor.white : NSColor.black).set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: 98, y: y + 4, width: 20, height: 20))
            }
            NSAttributedString(string: "2", attributes: [.foregroundColor: dark ? NSColor.white : NSColor.black, .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)])
                .draw(at: NSPoint(x: 122, y: y + 5))
        }
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("menubar.png"))
        }
    }
}
