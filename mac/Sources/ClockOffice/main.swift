import AppKit
import WidgetKit
import ClockOfficeCore

// ClockOffice: one calm place for every coding session on this Mac.
//   ClockOffice                 the menu-bar app
//   ClockOffice --print         print what the reader sees and exit (for checks)
//   ClockOffice --render <dir>  draw every surface with sample sessions into PNG files and exit (for design review)
//   ClockOffice --rig <dir>     the test rig: the real screens with made-up sessions, driven over 127.0.0.1

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    var menuBar: MenuBar!
    var mainWindow: MainWindow!
    private var keys: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy only: a second launch just leaves.
        let me = NSRunningApplication.current
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != me }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.mainMenu = Self.editMenu()
        DockIcon.handIcon()
        mainWindow = MainWindow(store: store)
        menuBar = MenuBar(store: store)
        menuBar.openMainWindow = { [weak self] in self?.mainWindow.show() }
        menuBar.mainWindowOpen = { [weak self] in self?.mainWindow.isOpen ?? false }
        store.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let build = Bundle.main.object(forInfoDictionaryKey: "ClockOfficeCommit") as? String ?? "run from source"
            let text = "\(Date())\nbuild=\(build)\n\(self.menuBar.diagnostics)\nclaude=\(ClaudeBinary.locate() ?? "not found")\n"
            try? text.write(to: Store.supportDirectory.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        }

        keys = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        // A click in the widget that started the app: follow it once the menu-bar icon is in place.
        if let link = pendingLink {
            pendingLink = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.follow(link) }
        }
    }

    private var pendingLink: WidgetLink?
    private var lastLinkAt = Date.distantPast

    /// The surface the keyboard is in, if it is one of ours (not a file picker or an alert in front of them).
    private var keySurface: SurfaceModel? {
        if mainWindow.isKey { return mainWindow.surface }
        if menuBar.isKey { return menuBar.surface }
        return nil
    }

    /// Keyboard shortcuts, the same in the dropdown and in the window:
    /// ↑ ↓ move through the sessions · Return opens the selected one (or sends what is typed) · Esc goes back, then closes
    /// ⌘1…⌘9 pick a question's answer · ⌘O opens the session's window · ⌘W closes · ⌘V attaches a copied file or screenshot.
    /// Holding ⌘ shows the numbers next to the answers.
    private func handle(_ event: NSEvent) -> NSEvent? {
        Keys.handle(event, surface: keySurface, store: store, hidePanel: { [weak self] in self?.menuBar.hide() },
                    closeWindow: { [weak self] in self?.mainWindow.close() },
                    paste: { [weak self] in self?.pasteAttachment(into: $0) ?? false })
    }

    /// Coming to the app by ⌘-Tab with nothing showing opens its window (a Dock click already did).
    /// A click in the widget also brings the app forward, but says itself what to show: so this waits a moment
    /// for that link before deciding.
    func applicationDidBecomeActive(_ notification: Notification) {
        DockIcon.keep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, NSApp.isActive, Date().timeIntervalSince(self.lastLinkAt) > 2,
                  self.mainWindow != nil, !self.mainWindow.exists, !self.menuBar.isOpen,
                  !self.menuBar.surface.holdOpen, !self.menuBar.busy else { return }
            self.mainWindow.show()
        }
    }

    /// A click in the widget arrives here as a link (see WidgetLink).
    func application(_ application: NSApplication, open urls: [URL]) {
        DockIcon.keep()
        guard let link = urls.lazy.compactMap({ WidgetLink($0) }).first else { return }
        lastLinkAt = Date()
        // Clicked while the app was not running: nothing exists yet, so remember it for the end of launch.
        guard mainWindow != nil, menuBar != nil else { pendingLink = link; return }
        follow(link)
    }

    /// The widget follows the order of surfaces: a click gives the dropdown (on that session's conversation when
    /// a session was clicked), never the window. Only when the window is already open in front of the user does the
    /// click go there, because the dropdown never opens over the window.
    private func follow(_ link: WidgetLink) {
        lastLinkAt = Date()
        switch link {
        case .open: showFromWidget(nil)
        case .session(let id): showFromWidget(id)
        case .answer(let id, let n, let mark, let secret):
            store.answerFromWidget(session: id, option: n, mark: mark, secret: secret) { [weak self] ok in
                guard let self else { return }
                if ok {
                    // Answered. Nothing of ours was on screen, so step back to what the user was doing.
                    if !self.mainWindow.exists && !self.menuBar.isOpen { NSApp.hide(nil) }
                } else {
                    // The question changed, or it cannot be typed from here: show the session, answer nothing.
                    self.showFromWidget(id)
                }
            }
        }
    }

    private func showFromWidget(_ id: String?) {
        let known = id.flatMap { store.session($0) }?.id
        if mainWindow.isOpen {
            mainWindow.show()
            if let known { mainWindow.surface.show(known) }
            return
        }
        if !menuBar.isOpen { menuBar.show() }
        if let known { menuBar.surface.open(known) } else if menuBar.surface.detail != nil { menuBar.surface.back() }
    }

    /// Quitting: the widget is asked to refresh, so it says "not running" instead of keeping old questions up.
    func applicationWillTerminate(_ notification: Notification) {
        store.stopServing()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Closing the window leaves the app running: the menu bar and the widget still need it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockIcon.keep()
        menuBar?.hide() // one surface at a time: the Dock icon swaps the dropdown for the window
        mainWindow?.show()
        return false
    }

    /// ⌘V with a file or a screenshot on the clipboard attaches it to the reply being typed; plain text pastes as usual.
    private func pasteAttachment(into surface: SurfaceModel) -> Bool {
        guard let id = surface.focusedReply, store.session(id) != nil else { return false }
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            store.attach(id, paths: urls.map(\.path))
            return true
        }
        if pb.string(forType: .string) == nil, let image = NSImage(pasteboard: pb), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            store.attachImage(id, png: png)
            return true
        }
        return false
    }

    /// A menu-bar app has no visible menus, but text fields only get ⌘C ⌘V ⌘X ⌘A ⌘Z when these items exist.
    static func editMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit ClockOffice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.insertItem(appItem, at: 0)
        return main
    }
}

/// Whether ClockOffice has a Dock icon. Off: it lives in the menu bar only (no Dock icon, not in ⌘-Tab); the window
/// still opens from the dropdown and the right-click menu. Kept across restarts.
@MainActor
enum DockIcon {
    static var shown: Bool {
        get { UserDefaults.standard.object(forKey: "showInDock") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showInDock"); apply() }
    }
    static func apply() {
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
        if shown { handIcon() } // coming back to the Dock: the Dock would otherwise show its cached older icon
    }
    /// Opening the running app again (Spotlight, Finder, a widget link) makes macOS give it a Dock icon even when
    /// Show in Dock is off: put it back to the menu bar only. Nothing happens when the mode is already right.
    static func keep() {
        if !shown, NSApp.activationPolicy() != .accessory { NSApp.setActivationPolicy(.accessory) }
    }
    /// Hand the Dock our icon directly: it otherwise keeps showing a cached older one after the artwork changes.
    static func handIcon() {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let url = Bundle.main.url(forResource: name, withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
}

/// The keyboard, in one place for the app and for the test rig, so a test presses the very same code.
@MainActor
enum Keys {
    /// Returns the event when it is not one of ours (it then goes on to the field that has the caret).
    static func handle(_ event: NSEvent, surface: SurfaceModel?, store: Store, hidePanel: () -> Void,
                       closeWindow: () -> Void = {}, paste: (SurfaceModel) -> Bool) -> NSEvent? {
        if event.type == .flagsChanged {
            let held = event.modifierFlags.contains(.command) && surface != nil
            if store.commandHeld != held { store.commandHeld = held }
            return event
        }
        guard let surface else { return event }
        let command = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers ?? ""

        switch event.keyCode {
        case 53: // Esc: out of the conversation first, then out of the dropdown
            if surface.kind == .panel {
                if surface.detail != nil { surface.back() } else { hidePanel() }
                return nil
            }
            if surface.detail != nil { surface.reset(); return nil }
            return event
        case 125, 126: // ↓ ↑
            guard surface.kind == .window || surface.detail == nil else { return event }
            let list = surface.order(store)
            guard !list.isEmpty else { return nil }
            let current = (surface.kind == .window ? surface.detail : surface.selected) ?? (surface.kind == .window ? surface.target(store)?.id : nil)
            let at = current.flatMap { id in list.firstIndex { $0.id == id } }
            let next = event.keyCode == 125 ? min((at ?? -1) + 1, list.count - 1) : max((at ?? list.count) - 1, 0)
            if surface.kind == .window { surface.show(list[next].id) } else { surface.selected = list[next].id }
            return nil
        case 36, 76: // Return: with nothing typed, open the selected row
            // Shift+Return in a message box starts a new line where the caret is, as in common chat apps; Return
            // alone still sends. (It sent: T-31.)
            if event.modifierFlags.contains(.shift), !command {
                // Text an input method is still composing (Japanese, Chinese, an accent key) is the input method's:
                // the key goes on to it, which confirms that text. Taking it here deleted it (verifier, T-31).
                guard let field = (event.window ?? NSApp.keyWindow)?.firstResponder as? NSTextView,
                      surface.focusedReply != nil, !field.hasMarkedText() else {
                    // Shift+Return outside a message box does nothing (it opened the selected row, as Return does).
                    return surface.focusedReply == nil ? nil : event
                }
                field.insertNewlineIgnoringFieldEditor(nil)
                return nil
            }
            if surface.kind == .panel, surface.detail == nil, let id = surface.selected,
               (surface.focusedReply.map { (store.drafts[$0] ?? "").isEmpty } ?? true) {
                surface.open(id)
                return nil
            }
            return event
        case 48: // Tab: the caret goes to the message box of the session the keys are on
            guard !command, surface.focusedReply == nil, let s = surface.target(store),
                  store.canReply(s), !s.certain, store.sentText(s) == nil, store.pending[s.id] == nil,
                  surface.kind == .window || surface.detail != nil || s.state == .asking else { return event }
            surface.focusRequest = s.id
            return nil
        default: break
        }

        guard command else { return event }
        if chars == "v", paste(surface) { return nil }
        if chars == "w" { if surface.kind == .panel { hidePanel() } else { closeWindow() }; return nil }
        if chars == "o", let s = surface.target(store) { store.openWindow(s); return nil }
        if let n = Int(chars), (1...9).contains(n), let s = surface.target(store),
           store.canReply(s), !store.canDecide(s), n <= s.options.count {
            Undone.markIfTakingBack(s, s.options[n - 1], store: store)
            store.answer(s, s.options[n - 1]) { ok in if ok { surface.afterSend(s.id) } }
            return nil
        }
        return event
    }
}

let arguments = CommandLine.arguments
if arguments.contains("--print") {
    for s in ClaudeCodeSource().sessions() + CodexSource().sessions() {
        print("\(s.state.rawValue)\t\(s.certain ? "official" : "read")\t\(s.tool)\t\(s.project)\t\(s.title)\t\(s.headline ?? "-")\t\(s.options.map(\.label))")
    }
    exit(0)
}
// For checks: how one Codex conversation file is read (field lengths only, never its words).
if let i = arguments.firstIndex(of: "--codex-file"), i + 1 < arguments.count {
    let file = arguments[i + 1]
    var src = CodexSource()
    src.listedFor = .greatestFiniteMagnitude
    let changed = ((try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date) ?? Date()
    if let s = src.session(file: file, changed: changed, now: changed.addingTimeInterval(60), pid: 0) {
        print("state=\(s.state.rawValue) project=\(s.project) titleChars=\(s.title.count) lastTextChars=\(s.lastText?.count ?? 0) inShortChars=\(s.inShort?.count ?? 0) turns=\(CodexSource.parsed(file, changed: changed).record.turns.count) id=\(s.id.prefix(13))")
    } else {
        print("not a session (no folder or nothing said)")
    }
    exit(0)
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    if let i = arguments.firstIndex(of: "--render"), i + 1 < arguments.count {
        app.setActivationPolicy(.accessory)
        Renderer.run(into: URL(fileURLWithPath: arguments[i + 1]))
        exit(0)
    }
    if let i = arguments.firstIndex(of: "--rig"), i + 1 < arguments.count {
        // The test rig (see Rig.swift): real screens, made-up sessions, driven over 127.0.0.1.
        app.setActivationPolicy(.accessory)
        let port = arguments.firstIndex(of: "--port").flatMap { $0 + 1 < arguments.count ? UInt16(arguments[$0 + 1]) : nil } ?? 48100
        let rig = Rig(dir: URL(fileURLWithPath: arguments[i + 1]))
        do { try rig.listen(port: port) } catch { print("rig: cannot listen on \(port): \(error)"); exit(1) }
        print("rig: listening on http://127.0.0.1:\(port)  (pictures in \(arguments[i + 1]))")
        setvbuf(stdout, nil, _IONBF, 0)
        withExtendedLifetime(rig) { app.run() }
        exit(0)
    }
    // By default it lives in the Dock (click it for the window) as well as in the menu bar; "Show in Dock" in the
    // right-click menu turns the Dock icon off.
    DockIcon.apply()
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
