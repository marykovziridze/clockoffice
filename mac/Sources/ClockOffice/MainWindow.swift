import AppKit
import SwiftUI
import ClockOfficeCore
import ClockOfficeUI

/// The app's own window (Dock icon, "Open ClockOffice"). The dropdown is for a glance and a quick answer;
/// this is for sitting with the sessions: all of them on the left, one conversation in full on the right with its
/// message box always at hand, and room to drag files in.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let store: Store
    let surface = SurfaceModel(kind: .window)
    private var window: NSWindow?

    init(store: Store) {
        self.store = store
        super.init()
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "ClockOffice"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 480)
            // The green button is real full screen.
            w.collectionBehavior = [.fullScreenPrimary]
            // First time: a comfortable size in the middle of the screen. After that: exactly the size and place the user
            // gave it. The window never resizes itself.
            if !w.setFrameUsingName("ClockOfficeWindow") { w.center() }
            w.setFrameAutosaveName("ClockOfficeWindow")
            w.delegate = self
            window = w
        }
        // A minimised window is still open: bringing it back must not reset it or count it twice.
        if window?.isVisible != true && window?.isMiniaturized != true {
            surface.reset()
            let host = NSHostingView(rootView: WindowRoot().environment(store).environment(surface))
            // Without this the content dictates the window's size, and the window jumped whenever a conversation
            // was longer or shorter.
            host.sizingOptions = []
            let frame = window?.frame
            window?.contentView = host
            if let frame { window?.setFrame(frame, display: true) }
            store.watching += 1
        }
        NSApp.activate(ignoringOtherApps: true)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    var isKey: Bool { window?.isKeyWindow == true }
    /// ⌘W.
    func close() { window?.performClose(nil) }
    /// Open where the user is: a window on another desktop or behind a full-screen app does not count, so the menu-bar
    /// icon still gives them the dropdown there.
    var isOpen: Bool { window?.isVisible == true && window?.isMiniaturized != true && window?.isOnActiveSpace == true }
    var exists: Bool { window?.isVisible == true || window?.isMiniaturized == true }

    /// Covered, minimised or on another desktop: the dials stop turning until it is seen again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        surface.hidden = window?.occlusionState.contains(.visible) != true
    }

    func windowWillClose(_ notification: Notification) {
        store.watching -= 1
        window?.contentView = nil // nothing animates while the window is closed
    }
}

struct WindowRoot: View {
    @Environment(SurfaceModel.self) private var surface
    var body: some View { Themed { WindowBody() }.environment(\.dialsPaused, surface.hidden) }
}

private struct WindowBody: View {
    static let sidebar: CGFloat = 300
    @Environment(Store.self) private var store
    @Environment(SurfaceModel.self) private var surface
    @Environment(\.theme) private var theme

    /// The last picture of the session on show, kept for the moments it is missing from a read.
    @State private var held: Session?
    @State private var goneSince: Date?

    /// The session the user picked (or the one first shown). A session that is missing from one read is not gone:
    /// its last picture stays up for ten seconds before the window moves on.
    private var shown: Session? {
        if let id = surface.detail {
            if let s = store.session(id) { return s }
            if let held, held.id == id { return held }
        }
        return first
    }

    /// The one that has waited longest, or simply the first.
    private var first: Session? {
        store.asking.first ?? store.justSent.first ?? store.working.first ?? store.done.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(theme.hair).frame(width: 1)
            if let s = shown {
                ConversationPane(session: s).id(s.id)
            } else {
                Text(store.loaded ? "No sessions are running." : "Looking for sessions…")
                    .font(Theme.body).foregroundStyle(theme.sub)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.panel)
        .ignoresSafeArea()
        // The session first shown becomes the selection. Without this the pane re-decided "whichever is first"
        // on every refresh and could switch session under their hands while they typed.
        .onAppear(perform: pin)
        .onChange(of: store.sessions.map(\.id)) { _, _ in pin() }
        .onChange(of: surface.detail) { _, _ in pin() }
    }

    private func pin() {
        guard let id = surface.detail else {
            goneSince = nil
            if let first { held = first; surface.show(first.id) }
            return
        }
        if let s = store.session(id) { held = s; goneSince = nil; return }
        // A session the user closed: nothing to hold on to, on to the next one at once (it stayed for ten
        // seconds with live buttons, as if the close had failed).
        if store.closed.contains(id) {
            goneSince = nil; held = nil
            if let first { held = first; surface.show(first.id) } else { surface.reset() }
            return
        }
        guard let since = goneSince else {
            goneSince = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { pin() }
            return
        }
        if Date().timeIntervalSince(since) >= 10 {
            goneSince = nil; held = nil
            if let first { held = first; surface.show(first.id) } else { surface.reset() }
        }
    }

    /// Every session, one line each: questions first (longest wait on top), then working, then finished.
    private var sidebar: some View {
        // Every session under its folder's name, in a fixed order: a row never moves when its state changes.
        // A question shows by its glowing dial and its pink waiting time, where it stands.
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !store.staleWindows.isEmpty {
                    ReloadNotice(windows: store.staleWindows)
                        .padding(EdgeInsets(top: 2, leading: 12, bottom: 14, trailing: 12))
                    Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 12).padding(.bottom, 8)
                }
                ForEach(store.folders(store.sessions)) { folder in
                    if store.manyFolders { FolderHeading(name: folder.name, edge: 12) } // 12 row padding; the 26 dial fills its 26 column
                    ForEach(folder.sessions) { s in
                        QuietRow(session: s, sentText: store.sentText(s), sentAt: store.sentAt(s), selected: s.id == shown?.id,
                                 lines: 2, bleed: 8, dialColumn: 26, grouped: true, limited: store.limited(s)) {
                            surface.open(s.id)
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.bottom, 12)
        }
        .padding(.top, 38) // clear of the window buttons
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The limits sit at the foot of the list, always in view.
            if store.usage != nil {
                VStack(alignment: .leading, spacing: 10) {
                    Rectangle().fill(theme.hair).frame(height: 1)
                    // The same single line as the dropdown's foot. Two lines of different length under each other
                    // ("Session 39% used · resets 22:10" over "Week 7% used · resets Sun 19:00") lined up with
                    // nothing. The week's reset time is in the tooltip.
                    UsageLines()
                }
                // On the dials' left edge (20), and on the same baseline as the foot of the conversation beside it.
                .padding(.horizontal, 20).padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.panel)
            }
        }
        .frame(width: Self.sidebar)
    }
}

/// One conversation in the window: who it is, what was said (scrolling, newest at the bottom), and the message
/// box fixed underneath, as in any messaging app. Everything sits in one reading column, centred in the pane, so
/// a wide or full-screen window does not leave the text stranded on the left.
private struct TalkHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ConversationPane: View {
    static let column: CGFloat = 760
    let session: Session
    /// How tall the conversation is now: taller than its room means it scrolls.
    @State private var talk: CGFloat = 0
    @Environment(Store.self) private var store
    @Environment(SurfaceModel.self) private var surface
    @Environment(\.theme) private var theme

    var body: some View {
        let sent = store.sentText(session) != nil
        VStack(alignment: .leading, spacing: 0) {
            column {
                // The link sits on the title's line, not between the title and the state under it.
                HStack(alignment: .firstTextBaseline) {
                    SessionHeader(session: session, folder: false)
                    if store.canShow(session) { LinkButton(store.goLabel(session), key: "O") { store.openWindow(session) } }
                }
            }
            .padding(.top, 30).padding(.bottom, 16)
            Rectangle().fill(theme.hair).frame(height: 1)
            // A short conversation starts at the top; a long one opens at its newest words.
            GeometryReader { area in
                ScrollView(.vertical) {
                    column { ConversationView(session: session, limit: 8, roomy: true, scrolls: talk + 44 > area.size.height) }
                        .background(GeometryReader { g in Color.clear.preference(key: TalkHeight.self, value: g.size.height) })
                        .onPreferenceChange(TalkHeight.self) { talk = $0 }
                        .padding(.vertical, 22)
                        .frame(minHeight: area.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
            }
            Rectangle().fill(theme.hair).frame(height: 1)
            column {
                VStack(alignment: .leading, spacing: 14) {
                    // The message box keeps its place while a message is on its way, dimmed and resting. It used
                    // to go the moment the user sent and come back when the session's record caught up: the
                    // conversation above grew and shrank by the box's height each time, and jumped in one frame
                    // (filmed in the rig, 2026-11-17, T-27).
                    AnswerArea(session: session)
                        .disabled(sent).opacity(sent ? 0.4 : 1)
                    SessionFooter(session: session)
                }
            }
            .padding(.top, 16).padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // A file dropped anywhere on the conversation is attached to the next message (T-32).
        .modifier(DropsAttachments(session: session, radius: 0))
        // The box dims and comes back on the app's own curve, not in a single frame.
        .animation(Motion.reduced ? nil : Motion.push, value: sent)
        // Resting took the caret out of the box; it comes back when the box does, so the next message can be typed
        // at once. (When the box was taken away and put back, putting it back gave the caret: verifier, T-27.)
        .onChange(of: sent) { _, now in
            if !now { surface.focusRequest = session.id }
        }
    }

    private func column<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: Self.column, alignment: .leading)
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
    }
}
