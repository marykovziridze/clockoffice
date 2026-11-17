import AppKit
import SwiftUI
import ServiceManagement
import ClockOfficeCore
import ClockOfficeUI

/// A borderless panel that can take typing without pulling the app in front of the one the user is working in.
final class DropdownPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The icon in the menu bar: a count when sessions ask, the dropdown on click, settings on right-click.
@MainActor
final class MenuBar: NSObject {
    let store: Store
    let surface = SurfaceModel(kind: .panel)
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var panel: DropdownPanel?
    private var outsideClicks: Any?
    private var ownClicks: Any?
    private var top: CGFloat = 0
    var openMainWindow: (() -> Void)?
    /// Whether the main window is open where the user is (not a file picker, not on another desktop).
    var mainWindowOpen: () -> Bool = { false }

    /// `visible: false` is for the test rig: the same object and the same menu, without a second icon in
    /// the real menu bar.
    init(store: Store, visible: Bool = true) {
        self.store = store
        super.init()
        item.isVisible = visible
        if let b = item.button {
            b.image = Assets.menuGlyph() ?? NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.setAccessibilityLabel("ClockOffice")
        }
        surface.openMainWindow = { [weak self] in self?.hide(); self?.openMainWindow?() }
        // Switching to another app (⌘-Tab, a Dock click) puts the dropdown away, like any menu.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self, self.isOpen, !self.surface.holdOpen, app != NSRunningApplication.current else { return }
                self.hide()
            }
        }
        surface.onHeight = { [weak self] h in self?.resize(to: h) }
        store.onCount = { [weak self] n in self?.setCount(n) }
    }

    /// The count as it stands beside the icon: nothing when no session asks.
    static func countTitle(_ n: Int) -> NSAttributedString {
        n > 0 ? NSAttributedString(string: " \(n)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold), .baselineOffset: -0.5])
              : NSAttributedString(string: "")
    }

    /// The number of questions, in the menu bar's own text colour so it reads on any wallpaper (pink on a pink
    /// wallpaper did not). Nothing when there are none. Pink stays the mark of a question inside the dropdown.
    func setCount(_ n: Int) {
        guard let b = item.button else { return }
        b.attributedTitle = Self.countTitle(n)
        b.setAccessibilityValue(n == 0 ? "No questions" : "\(n) question\(n == 1 ? "" : "s") for you")
        // The same number on the Dock icon.
        NSApp.dockTile.badgeLabel = n > 0 ? String(n) : nil
    }

    /// The menu-bar icon always gives the dropdown. The order of surfaces is: dropdown, then a session's
    /// conversation inside the dropdown, and only then the window (from "Open ClockOffice" or the Dock icon).
    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    /// Where the icon sits, for the diagnostics file (a hidden or off-screen icon is the first thing to rule out).
    var diagnostics: String {
        let b = item.button
        let frame = b?.window.map { NSStringFromRect($0.frame) } ?? "no window"
        let screen = b?.window?.screen.map { NSStringFromRect($0.frame) } ?? "no screen"
        return "status item visible=\(item.isVisible) frame=\(frame) screen=\(screen) image=\(b?.image != nil) occluded=\(b?.window?.occlusionState.contains(.visible) == false)"
    }

    // MARK: Dropdown

    var isOpen: Bool { panel?.isVisible == true && !closing }
    /// True when the dropdown is the window the keyboard is in (not a file picker or an alert in front of it).
    var isKey: Bool { isOpen && panel?.isKeyWindow == true }
    private var closing = false
    private var openedAt = Date.distantPast
    private var maxHeight: CGFloat = 600
    /// Where the icon is on screen; the window opens beneath it too.
    var iconFrame: NSRect? {
        guard let button = item.button, let bw = button.window else { return nil }
        return bw.convertToScreen(button.convert(button.bounds, to: nil))
    }

    func show() {
        guard let button = item.button, let bw = button.window, let anchor = iconFrame else { return }
        let visible = (bw.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        maxHeight = max(240, visible.height - 24)

        if panel == nil {
            let p = DropdownPanel(contentRect: NSRect(x: 0, y: 0, width: PanelRoot.width, height: 200),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.hidesOnDeactivate = false
            p.isMovable = false
            p.animationBehavior = .none // the open and close motion is ours, below
            panel = p
        }
        guard let panel else { return }
        closing = false
        surface.reset()
        let host = NSHostingView(rootView: PanelRoot().environment(store).environment(surface))
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = [] // this file sizes the dropdown; the content must not also try to
        panel.contentView = host
        // Lay the content out first, so the height used below is today's, not the last opening's.
        // Otherwise, after the list changed, the dropdown reopened at its old height and cut off a row.
        surface.roomForContent = maxHeight - 12
        panel.setContentSize(NSSize(width: PanelRoot.width, height: maxHeight))
        host.layoutSubtreeIfNeeded()
        // Today's height, known before anything is shown (see `PanelRoot.listHeight`).
        let fitted = PanelRoot.listHeight(store)
        if fitted > 20 { surface.contentHeight = fitted }
        let h = min(max(surface.contentHeight + 12, 60), maxHeight)
        // Like a native menu: the left edge sits under the icon, unless the screen edge is in the way.
        let x = min(max(anchor.minX - 10, visible.minX + 8), visible.maxX - PanelRoot.width - 8)
        top = anchor.minY - 6
        let final = NSRect(x: x, y: top - h, width: PanelRoot.width, height: h)
        openedAt = Date()
        // It drops out of the menu bar: 6 points of travel and a fade, 140 ms, eased out.
        panel.alphaValue = 0
        panel.setFrame(Motion.reduced ? final : final.offsetBy(dx: 0, dy: 6), display: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(final, display: true)
        }
        store.watching += 1
        DispatchQueue.main.async { [weak self] in
            button.highlight(true)
            // And once more after the first real frame, in case the measurement arrived late.
            if let self { self.resize(to: self.surface.contentHeight) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if let self { self.resize(to: self.surface.contentHeight) }
        }

        // Clicks in the app's own window do not reach the watcher below, so the dropdown stayed lying over the
        // window. A click anywhere but in the dropdown or on its icon closes it, as a menu does.
        if ownClicks == nil {
            ownClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if let self, self.isOpen, !self.surface.holdOpen, let w = event.window,
                   w !== self.panel, w !== self.item.button?.window, w.level == .normal { self.hide() }
                return event
            }
        }
        outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.surface.holdOpen else { return }
                self.hide()
            }
        }
    }

    func hide() {
        if let m = outsideClicks { NSEvent.removeMonitor(m); outsideClicks = nil }
        if let m = ownClicks { NSEvent.removeMonitor(m); ownClicks = nil }
        guard let panel, panel.isVisible, !closing else { return }
        closing = true
        store.watching -= 1
        item.button?.highlight(false)
        // Leaving is quicker than arriving.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.09
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.closing else { return }
                panel.orderOut(nil)
                panel.contentView = nil // stops the dial animations while nothing is on screen
                self.closing = false
            }
        })
    }

    /// The window follows its content: growing and shrinking from the top edge, in step with the push inside it.
    private func resize(to content: CGFloat) {
        guard let panel, panel.isVisible, !closing else { return }
        let height = min(max(content + 12, 60), maxHeight)
        var f = panel.frame
        guard abs(f.height - height) > 0.5 else { return }
        f.origin.y = top - height
        f.size.height = height
        if Motion.reduced || Date().timeIntervalSince(openedAt) < 0.3 {
            panel.setFrame(f, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                panel.animator().setFrame(f, display: true)
            }
        }
        panel.invalidateShadow()
    }

    // MARK: Settings menu

    private func showMenu() {
        hide() // the menu never opens on top of the dropdown
        let menu = buildMenu()
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// The right-click menu, built fresh each time so its ticks are current.
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open ClockOffice", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let s = menu.addItem(withTitle: "Summaries in plain words", action: #selector(toggleSummaries), keyEquivalent: "")
        s.target = self; s.state = store.summariesOn ? .on : .off
        s.toolTip = "Uses a small model through your own Claude Code, inside your plan. Off: wording rules only."
        let l = menu.addItem(withTitle: "Open at login", action: #selector(toggleLogin), keyEquivalent: "")
        l.target = self; l.state = SMAppService.mainApp.status == .enabled ? .on : .off
        let d = menu.addItem(withTitle: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "")
        d.target = self; d.state = DockIcon.shown ? .on : .off
        d.toolTip = "Off: ClockOffice lives in the menu bar only. Open ClockOffice above still opens the window."
        let h = menu.addItem(withTitle: "Show the words of Claude Code dialogs", action: #selector(toggleHooks), keyEquivalent: "")
        h.target = self; h.state = ClaudeHooks.isInstalled() ? .on : .off
        h.toolTip = "Adds two hook entries to ~/.claude/settings.json (a backup is kept). Off: a dialog shows as “has a question, in its window”."
        let u = menu.addItem(withTitle: "Show usage and model", action: #selector(toggleUsage), keyEquivalent: "")
        u.target = self; u.state = StatusLineRelay.isInstalled() ? .on : .off
        u.toolTip = "Puts a small relay in front of your Claude Code status line in ~/.claude/settings.json (a backup is kept). Your status line stays as it is. Off: no limits or model shown here."
        menu.addItem(.separator())
        let editors = Hosts.editors()
        if editors.isEmpty {
            menu.addItem(withTitle: "No editor found for replying in place", action: nil, keyEquivalent: "")
        }
        for (i, e) in editors.enumerated() {
            let it = menu.addItem(withTitle: "Set up replying in \(e.name)", action: #selector(installExtension(_:)), keyEquivalent: "")
            it.target = self; it.tag = i
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ClockOffice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openWindow() { hide(); openMainWindow?() }
    @objc private func toggleSummaries() { store.summariesOn.toggle() }

    @objc private func toggleDock() {
        let windowOpen = mainWindowOpen()
        DockIcon.shown.toggle()
        // Leaving the Dock sends the app to the back; an open window comes forward again.
        if windowOpen { DispatchQueue.main.async { [weak self] in self?.openMainWindow?() } }
    }

    @objc private func toggleHooks() {
        let on = !ClaudeHooks.isInstalled()
        do {
            try ClaudeHooks.set(on, backups: Store.supportDirectory.appendingPathComponent("settings-backups"))
            if on {
                alert("Dialog questions will show here",
                      "Two hook entries were added to ~/.claude/settings.json; the previous file is saved in ClockOffice's settings-backups folder. Sessions started from now on use it; running sessions pick it up when they next reload their settings.")
            }
        } catch {
            alert("Nothing was changed", error.localizedDescription)
        }
    }

    @objc private func toggleUsage() {
        let on = !StatusLineRelay.isInstalled()
        do {
            try StatusLineRelay.set(on, scriptDirectory: Store.supportDirectory,
                                    backups: Store.supportDirectory.appendingPathComponent("settings-backups"))
            if on {
                alert("Usage and model will show here",
                      "A relay was put in front of your status line command in ~/.claude/settings.json; the previous file is saved in ClockOffice's settings-backups folder. Your status line looks the same. The numbers appear once a running session next refreshes its status line.")
            }
        } catch {
            alert("Nothing was changed", error.localizedDescription)
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            alert("Couldn't change the login setting", "\(error.localizedDescription)")
        }
    }

    /// Installs the small extension that lets ClockOffice type a reply into the exact terminal of an editor window.
    @objc private func installExtension(_ sender: NSMenuItem) {
        let editors = Hosts.editors()
        guard sender.tag < editors.count, let vsix = Assets.url("clockoffice-terminal.vsix") else {
            alert("The extension file is missing from this build", "")
            return
        }
        let e = editors[sender.tag]
        DispatchQueue.global().async {
            let r = Shell.run(e.cli, ["--install-extension", vsix.path, "--force"], timeout: 90)
            DispatchQueue.main.async {
                if r.status == 0 {
                    self.alert("Replying is set up in \(e.name)",
                               "Windows that are already open start using it after a reload: press ⇧⌘P in the editor and choose “Developer: Reload Window”. Terminals keep running.")
                } else {
                    self.alert("Couldn't set it up in \(e.name)", String((r.stderr + r.stdout).prefix(400)))
                }
            }
        }
    }

    /// True while one of the menu's own alerts or the install is up, so nothing else opens under it.
    private(set) var busy = false

    private func alert(_ title: String, _ text: String) {
        hide()
        busy = true
        defer { busy = false }
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}
