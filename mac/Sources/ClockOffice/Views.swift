import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClockOfficeCore
import ClockOfficeUI

// The visual grammar, kept small on purpose:
// - Text is the interface. Two sizes (15 and 13), two colours (ink and quiet), one accent (pink = a question for you).
// - Things you can click are plain words in medium weight with the hand cursor. No boxes, no pills, and no
//   underline at rest: a hairline appears only under the word the pointer is on.
// - Hover never moves anything. Press dims. The only things that move are views changing place and the dial.

// MARK: Small parts

/// Motion in one place. Short, eased out, and only where it explains something:
/// where a view came from, that a press was heard, that a list grew.
enum Motion {
    /// Strong ease-out: starts at once, settles softly.
    static let push = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.24)
    static let quick = Animation.easeOut(duration: 0.1)
    /// With "reduce motion" on, views fade in place and nothing travels.
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static func enter(from edge: CGFloat) -> AnyTransition {
        // The arriving view travels in from its side once the leaving one is gone (80 ms), so two layers of
        // text never sit on top of each other. (With a 50 ms wait they did, for two frames: screen recording.)
        reduced ? .opacity : .asymmetric(
            insertion: .offset(x: edge).combined(with: .opacity).animation(push.delay(0.09)),
            removal: .opacity.animation(.easeOut(duration: 0.08)))
    }
}

/// A press is answered at once: the thing dims while held. Nothing moves.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}

extension View {
    /// The pointing-hand cursor over anything that can be clicked.
    @ViewBuilder func clickable() -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(.link)
        } else {
            self.onHover { inside in
                if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
        }
    }
}

/// A word you can click. Medium weight, no decoration at rest; a hairline appears under it on hover.
/// While ⌘ is held it shows its shortcut beside it.
struct LinkButton: View {
    let title: String
    var quiet = false
    var key: String?
    /// What the pointer resting on it says, when that is more than its shortcut.
    var tip: String?
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(Store.self) private var store
    @State private var hover = false

    init(_ title: String, quiet: Bool = false, key: String? = nil, tip: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.quiet = quiet; self.key = key; self.tip = tip; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .fontWeight(.medium)
                    .foregroundStyle(quiet && !hover ? theme.sub : theme.ink)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(theme.ink.opacity(0.5)).frame(height: 1).offset(y: 2).opacity(hover ? 1 : 0)
                    }
                if let key, store.commandHeld {
                    Text("⌘" + key).foregroundStyle(theme.sub).monospacedDigit().transition(.opacity)
                }
            }
            .font(Theme.small)
            .contentShape(Rectangle().inset(by: -6)) // a bigger target than the word itself
        }
        .buttonStyle(PressStyle())
        .clickable()
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .animation(Motion.quick, value: store.commandHeld)
        .help(tip ?? key.map { "⌘" + $0 } ?? "")
    }
}

private struct DialSpaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }
extension EnvironmentValues {
    /// The shared space in which a session's dial travels between the list and its conversation.
    var dialSpace: Namespace.ID? {
        get { self[DialSpaceKey.self] }
        set { self[DialSpaceKey.self] = newValue }
    }
}

/// Marks a session's dial so it flies from the row you clicked to the head of its conversation, and back:
/// the new view grows out of the thing you touched instead of appearing from nowhere.
struct TravellingDial: ViewModifier {
    let id: String
    @Environment(\.dialSpace) private var space
    func body(content: Content) -> some View {
        if let space, !Motion.reduced {
            content.matchedGeometryEffect(id: "dial-" + id, in: space)
        } else {
            content
        }
    }
}

/// The one moment of show: when the user's answer goes out, three sparkles twinkle across the dial, then it is quiet.
struct Glimmer: View {
    let since: Date
    let size: CGFloat
    private static let spots: [(x: CGFloat, y: CGFloat, s: CGFloat, delay: Double)] =
        [(0.72, 0.24, 0.30, 0), (0.22, 0.42, 0.20, 0.22), (0.62, 0.74, 0.24, 0.44)]

    var body: some View {
        // Only while it lasts (1.2 s): no clock keeps ticking behind a finished sparkle.
        if !Motion.reduced, Date().timeIntervalSince(since) < 1.3 {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: Date().timeIntervalSince(since) > 1.3)) { ctx in
                let t = ctx.date.timeIntervalSince(since)
                ZStack {
                    ForEach(0..<Self.spots.count, id: \.self) { i in
                        let spot = Self.spots[i]
                        let local = max(0, min(1, (t - spot.delay) / 0.7))
                        let pulse = sin(local * .pi)
                        Sparkle().fill(Color.white)
                            .frame(width: size * spot.s, height: size * spot.s)
                            .scaleEffect(0.4 + 0.6 * pulse)
                            .opacity(pulse)
                            .position(x: size * spot.x, y: size * spot.y)
                    }
                }
                .frame(width: size, height: size)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// Lays children out left to right and wraps to the next line (the option row).
struct Flow: Layout {
    var spacing: CGFloat = 20
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
            x += s.width + spacing
            line = max(line, s.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            line = max(line, s.height)
        }
    }
}

/// "34 min", kept current without redrawing anything else.
struct Age: View {
    let since: Date
    var suffix = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { ctx in
            // "now ago" is not a thing: under a minute it is "just now".
            let age = Words.age(since: since, now: ctx.date)
            Text(age == "now" && !suffix.isEmpty ? "just now" : age + suffix)
        }
    }
}

extension Session {
    var dialMode: DialView.Mode {
        switch state {
        case .asking: return .asking
        case .working: return .turning
        case .done: return .faded
        }
    }
    /// "Desktop/TEAM-HANDBOOK": the folder without the home prefix.
    var shortPath: String {
        let home = NSHomeDirectory()
        return cwd.hasPrefix(home + "/") ? String(cwd.dropFirst(home.count + 1)) : cwd
    }
}

// MARK: Reply

/// The message box, built like the one in common chat apps (ChatGPT's, measured 2026-11-16: a
/// rounded box as wide as the reading column, "+" on the left to attach, the text, a round arrow on the right to
/// send). Two earlier versions failed: a bordered field with a paperclip floating beside an invisible
/// send button, then a bare line with the word "Attach" (an icon is clearer).
/// Return sends too. A screenshot can be pasted, a file dropped on the box.
struct ReplyBox: View {
    let session: Session
    let placeholder: String
    /// Puts the caret in the line as soon as it shows (a session's own view), so it is plainly a place to type.
    var autofocus = false
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(SurfaceModel.self) private var surface
    @FocusState private var focused: Bool
    @State private var targeted = false

    private var draft: String { store.drafts[session.id] ?? "" }
    private var ready: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(store.attachments[session.id] ?? []).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.attachments[session.id] ?? [], id: \.self) { path in
                Button { store.detach(session.id, path: path) } label: {
                    // The × says what a click does.
                    Text("Attached: \((path as NSString).lastPathComponent)  ×")
                        .font(Theme.small).foregroundStyle(theme.sub).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(PressStyle())
                .clickable()
                .help("Click to remove")
            }
            // The box grows with the text, up to six lines: a one-line box showed only the tail of a longer reply.
            // The + and the arrow stay at the foot.
            HStack(alignment: .bottom, spacing: 6) {
                Button(action: pick) {
                    Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(theme.ink)
                        .frame(width: 30, height: 30).contentShape(Circle())
                }
                .buttonStyle(PressStyle())
                .clickable()
                .help("Attach a file")
                .accessibilityLabel("Attach a file")
                TextField("", text: Binding(get: { store.drafts[session.id] ?? "" },
                                            set: { store.drafts[session.id] = $0; store.clearError(session.id) }),
                          prompt: Text(targeted ? "Drop to attach" : placeholder).font(Theme.body).foregroundStyle(theme.sub),
                          axis: .vertical)
                    .lineLimit(1...8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundStyle(theme.ink)
                    .focused($focused)
                    .onSubmit(send)
                    // 6 above and below an 18-high line makes the 30 of the buttons beside it: the text is centred
                    // on them when there is one line, and has the same room at the top and the bottom when there
                    // are several.
                    .padding(.vertical, 6)
                    .accessibilityLabel("Message to \(session.title)")
                // Always in its place, so nothing shifts: dim until there is something to send.
                Button(action: send) {
                    // 30 across with 6 around it: the circle sits in the middle of the box's round end (15 + 6 = the
                    // end's radius of 21), the same distance from the top, the bottom and the side. It was 28 in a
                    // 30-high row aligned to the bottom, so it sat low with unequal gaps.
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(theme.panel)
                        .frame(width: 30, height: 30).background(theme.ink, in: Circle())
                }
                .buttonStyle(PressStyle())
                .clickable()
                .opacity(ready ? 1 : 0.28)
                .disabled(!ready)
                .help("Send (Return)")
                .accessibilityLabel("Send")
            }
            .padding(6)
            .background(theme.composer, in: RoundedRectangle(cornerRadius: 21, style: .circular))
            .contentShape(RoundedRectangle(cornerRadius: 21, style: .circular))
            .onTapGesture { focused = true } // the whole box takes the click, not only the line of text
            .animation(Motion.quick, value: ready)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for p in providers {
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in store.attach(session.id, paths: [url.path]) }
                    }
                }
                return true
            }
            if let e = store.error(session) {
                Text(e).font(Theme.small).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: focused) { _, now in
            if now { surface.focusedReply = session.id } else if surface.focusedReply == session.id { surface.focusedReply = nil }
        }
        .onAppear {
            if autofocus && store.autofocus { focused = true }
            if surface.focusRequest == session.id { focused = true; surface.focusRequest = nil }
        }
        // Tab asks for the caret (see Keys).
        .onChange(of: surface.focusRequest) { _, id in
            if id == session.id { focused = true; surface.focusRequest = nil }
        }
    }

    private func send() {
        guard ready else { return }
        // The dropdown goes back to its list only once the message really went out; a failure stays in view.
        store.send(session, text: draft.trimmingCharacters(in: .whitespacesAndNewlines)) { ok in
            if ok { surface.afterSend(session.id) }
        }
    }

    private func pick() {
        guard !surface.holdOpen else { return } // one picker at a time
        surface.holdOpen = true
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        // Above the dropdown, so the dropdown never covers part of it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.begin { result in
            if result == .OK { store.attach(session.id, paths: panel.urls.map(\.path)) }
            surface.holdOpen = false
        }
    }
}

/// The one-click answers a question offers, as plain words. ⌘1, ⌘2… pick them from the keyboard.
struct OptionRow: View {
    let session: Session
    @Environment(Store.self) private var store
    @Environment(SurfaceModel.self) private var surface

    var body: some View {
        // The ⌘ numbers show only on the question they would answer (the row the arrow keys are on, else the one
        // that has waited longest): two questions both labelled ⌘1 did not say which.
        let mine = surface.target(store)?.id == session.id
        Flow(spacing: 8, lineSpacing: 8) {
            ForEach(Array(session.options.enumerated()), id: \.offset) { n, o in
                AnswerPill(title: o.label, key: mine && n < 9 ? String(n + 1) : nil,
                           chosen: store.waiting(session)?.contains { $0.send == o.send } ?? false) {
                    store.answer(session, o) { ok in if ok { surface.afterSend(session.id) } }
                }
            }
        }
    }
}

/// One answer you can press. As plain words they did not look pressable. Built like the suggestion buttons in
/// ChatGPT, measured on 2026-11-16: a fully round pill, a fill one shade off the panel, a semibold label with 14 of padding
/// either side. Hover deepens the fill; nothing moves. While ⌘ is held it shows its shortcut.
struct AnswerPill: View {
    let title: String
    var key: String?
    /// Clicked and waiting out its undo time: the pill is filled in ink.
    var chosen = false
    let action: () -> Void
    @Environment(\.theme) private var theme
    @Environment(Store.self) private var store
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).fontWeight(.semibold).foregroundStyle(chosen ? theme.panel : theme.ink).lineLimit(1)
                if let key, store.commandHeld {
                    Text("⌘" + key).foregroundStyle(chosen ? theme.panel.opacity(0.7) : theme.sub).monospacedDigit().transition(.opacity)
                }
            }
            .font(Theme.small)
            .padding(.horizontal, 14)
            .frame(height: 32)
            // Fill only: an outline on a fully round pill drew stray ticks at its sides.
            .background(chosen ? theme.ink.opacity(hover ? 0.8 : 0.92) : theme.ink.opacity(hover ? 0.18 : 0.10), in: Capsule())
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressStyle())
        .clickable()
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        .animation(Motion.quick, value: store.commandHeld)
        .help(key.map { "⌘" + $0 } ?? "")
        .accessibilityLabel("Answer: \(title)")
    }
}

/// How the user answers from here: the choices a question offers, and the message box. When this session cannot be
/// typed into from here, it says why in one line and what to do, never a dead end.
struct AnswerArea: View {
    let session: Session
    var compact = false
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        // While the session is being closed nothing can be sent to it: the box and the answers rest, and keep
        // what the user typed for an Undo.
        let closing = store.closing[session.id] != nil
        area.disabled(closing).opacity(closing ? 0.4 : 1)
    }

    @ViewBuilder private var area: some View {
        let asking = session.state == .asking
        VStack(alignment: .leading, spacing: 10) {
          if let chosen = store.waiting(session) {
            // A one-click answer on its way. The choices stay, the chosen ones filled in: a second click adds one
            // or drops one. The message box makes way for what is being sent and the way back. The card keeps
            // its place for these seconds, so nothing shifts under the pointer.
            OptionRow(session: session)
            // In the message box's own shape and place: same height, same edges, the words where the placeholder
            // stands and "Undo" where the send arrow stands. A bare line floating in that space had 26 above it
            // and 35 below.
            HStack(alignment: .center, spacing: 10) {
                Text("Sending " + chosen.map { "“\($0.label)”" }.joined(separator: " + ") + "…")
                    .font(Theme.small).foregroundStyle(theme.sub).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                LinkButton("Undo") { store.undo(session.id) }
                    .help("Take this answer back: nothing is sent")
            }
            .padding(.leading, 16).padding(.trailing, 16).padding(.vertical, 6)
            .frame(minHeight: 42)
            .background(theme.composer, in: RoundedRectangle(cornerRadius: 21, style: .circular))
            .transition(.opacity)
          } else {
            // A dialog's question is not in the conversation (it is written there only once answered), so the
            // session's own view says it here, above the answers.
            if !compact, asking, session.certain, let q = session.question, !q.isEmpty {
                Text(q).font(Theme.body).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
            }
            // A dialog (official "waiting") takes keys, not sentences: only its own numbered choices are safe to type.
            if store.canReply(session) && !session.options.isEmpty { OptionRow(session: session) }
            if store.canReply(session) && !session.certain {
                ReplyBox(session: session, placeholder: asking ? "Type a reply" : "Type a message", autofocus: !compact)
            } else {
                if !compact, let w = store.staleWindow(of: session) {
                    // The session's own window is one click away at the top of this view, so no link here.
                    ReloadNotice(windows: [w], links: false)
                } else if !compact, let why = store.whyNoReply(session) {
                    Text(why).font(Theme.small).lineSpacing(3).foregroundStyle(theme.sub).fixedSize(horizontal: false, vertical: true)
                }
                if compact && asking {
                    HStack(spacing: 20) {
                        if store.canShow(session) { LinkButton(store.goLabel(session), key: "O") { store.openWindow(session) } }
                        if session.remoteURL != nil { LinkButton("Open in Claude") { store.openRemote(session) } }
                    }
                }
                if let e = store.error(session) {
                    Text(e).font(Theme.small).foregroundStyle(theme.ink).fixedSize(horizontal: false, vertical: true)
                }
            }
          }
        }
        .animation(Motion.quick, value: store.waiting(session)?.map(\.label))
    }
}

/// "Reload this editor window once": the one thing only the user can do before replies work there. It used to be a grey
/// line inside a session's view, where they did not see it. Now it is said once at the top of the dropdown and of the
/// window's list, in full ink, and again where the message box would be. It goes by itself once the reload is done.
struct ReloadNotice: View {
    let windows: [StaleWindow]
    var links = true
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(ReloadHint.headline(windows)).fontWeight(.medium).foregroundStyle(theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            if links && windows.count > 1 {
                // Each name brings that window to the front.
                Flow(spacing: 16, lineSpacing: 6) {
                    ForEach(windows) { w in LinkButton(w.name) { store.show(w) }.help("Bring this window to the front") }
                }
                .padding(.vertical, 2)
            }
            Text(ReloadHint.steps(windows)).foregroundStyle(theme.sub)
                .fixedSize(horizontal: false, vertical: true)
            if links && windows.count == 1, let w = windows.first {
                LinkButton("Show that window") { store.show(w) }.padding(.top, 4)
            }
        }
        .font(Theme.small).lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The plan's limits, for the whole account: how full the 5-hour session window and the week are, and when the
/// session window starts again.
/// It is the least urgent thing on the surface, so it is one quiet line at the foot: two full sentences
/// were cluttered and fought the sessions above them. Only a percentage of 80 or more stands out, in full ink.
/// The full wording, with both reset times, is in the tooltip. Nothing is drawn until Claude Code has reported.
struct UsageLines: View {
    /// The window's list has room for the two windows on a line each; the dropdown keeps them on one.
    var stacked = false
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            if let u = store.usage {
                let now = ctx.date
                let session = part("Session", u.sessionPercent, u.sessionResets, now, withTime: true)
                let week = part("Week", u.weekPercent, u.weekResets, now, withTime: stacked)
                Group {
                    if stacked {
                        VStack(alignment: .leading, spacing: 2) { if let session { session }; if let week { week } }
                    } else if let session, let week {
                        Text("\(session) · \(week)")
                    } else if let one = session ?? week {
                        one
                    }
                }
                .font(Theme.small).foregroundStyle(theme.sub).monospacedDigit().lineLimit(1)
                .help(detail(u, now))
                .accessibilityLabel(detail(u, now))
            }
        }
    }

    /// "62% used · resets 19:50": what the number is and what the time is, in as few words as say it. A bare
    /// "62% · 19:34" did not say which was "used" and which "resets at".
    /// Quiet text; the number turns to ink once it is high.
    private func part(_ name: String, _ percent: Double?, _ resets: Date?, _ now: Date, withTime: Bool) -> Text? {
        guard let percent, resets.map({ $0 > now }) ?? true else { return nil }
        let number = Text("\(Int(percent.rounded()))%")
            .foregroundStyle(percent >= 99.5 ? theme.limitText : (UsageWords.isHigh(percent) ? theme.ink : theme.sub))
            .fontWeight(UsageWords.isHigh(percent) ? .medium : .regular)
        let time = withTime ? (resets.map { " · resets " + UsageWords.when($0, now: now) } ?? "") : ""
        // The dropdown's one line: "62% used · resets 19:50" then "week 24%". The window names both windows.
        if stacked { return Text("\(name) \(number) used\(time)") }
        return name == "Session" ? Text("\(number) used\(time)") : Text("week \(number)")
    }

    private func detail(_ u: UsageLimits, _ now: Date) -> String {
        [UsageWords.line("Session limit", percent: u.sessionPercent, resets: u.sessionResets, now: now),
         UsageWords.line("Weekly limit", percent: u.weekPercent, resets: u.weekResets, now: now),
         now.timeIntervalSince(u.at) > 300 ? "As of " + UsageWords.when(u.at, now: now) : nil]
            .compactMap { $0 }.joined(separator: ". ") + "."
    }
}

// MARK: Rows

/// A question in the dropdown: who asks, for how long, what, and the quickest way to answer.
struct QuestionRow: View {
    let session: Session
    let open: () -> Void
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(SurfaceModel.self) private var surface
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: open) {
                HStack(alignment: .center, spacing: 12) {
                    // One dial column for every row of the dropdown (32 wide): a question's dial fills it and glows,
                    // a quiet one is a little smaller on the same centre line, and all text starts on one edge.
                    // (A wider column left the small dials adrift, and a highlighted row with 20 of room on the
                    // left of its dial and 13 on the right of its state.)
                    DialView(.asking, size: 32).frame(width: 32, height: 40)
                        .modifier(TravellingDial(id: session.id))
                    VStack(alignment: .leading, spacing: 2) {
                        // Which folder and which session asks, then how long it has waited: a card that named only
                        // the folder could be answered for the wrong session.
                        HStack(spacing: 0) {
                            Text(store.folderPrefix(session) + session.title).foregroundStyle(hover ? theme.subHover : theme.sub)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 10)
                            if store.closing[session.id] != nil {
                                Text("closing…").foregroundStyle(theme.sub).fixedSize()
                            } else {
                                Age(since: session.since).foregroundStyle(theme.accent).fontWeight(.semibold).monospacedDigit()
                                    .fixedSize()
                            }
                        }
                        .font(Theme.small)
                        Text(session.headline ?? session.question ?? session.title)
                            .font(Theme.body).fontWeight(.medium).foregroundStyle(theme.ink)
                            .lineLimit(2).multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // The block fills the row, so the waiting time ends on the same right edge as the message
                    // box, the dividers and the rows' states (a spacer after it left the time 12 short).
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 12, leading: 12, bottom: 10, trailing: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .clickable()
            .onHover { hover = $0 }
            .animation(Motion.quick, value: hover)
            .help("See the conversation")
            .accessibilityLabel("Conversation: \(session.title)")

            AnswerArea(session: session, compact: true)
                .padding(.leading, 56).padding(.trailing, 12)
        }
        .padding(.bottom, 14)
        // The row the arrow keys are on: the band covers the whole card, answers and message box included
        // (a band behind the question's words alone was easy to miss).
        .background(surface.selected == session.id ? theme.select : (hover ? theme.select.opacity(0.55) : .clear),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .animation(Motion.quick, value: hover)
    }
}

/// A session in one quiet line: in the dropdown's quiet list, and every session in the window's sidebar.
struct QuietRow: View {
    let session: Session
    var sentText: String?
    var sentAt: Date?
    var selected = false
    /// How many lines the session's line may take: one in the dropdown, two in the window's sidebar, where a
    /// question cut off after four words told the user too little.
    var lines = 1
    /// How far the row sits in from its surface's edges (6 in the dropdown, 8 in the window's list): the band
    /// of the open row reaches out by that much.
    var bleed: CGFloat = 6
    /// The width of the column the dial sits in. In the dropdown it is the same 40 as the question rows', so every
    /// row's text starts on the same left edge as the questions, their answers and their message box.
    var dialColumn: CGFloat = 32
    /// Under a folder heading: the folder's name is said once above, so the row is the session's line and its age.
    var grouped = false
    /// The plan's limit is used up: a session that was working is shown as stopped by it.
    var limited = false
    let open: () -> Void
    @Environment(\.theme) private var theme
    @Environment(Store.self) private var store
    @State private var hover = false

    var body: some View {
        let asks = session.state == .asking && sentText == nil
        Button(action: open) {
            // The dial is centred against the row's text, whether that is one line or two, and the row has the
            // same space above and below: the shape behind an open or hovered row then sits evenly around it
            // (it was 12 above and 5 below, and looked lopsided).
            HStack(alignment: grouped ? .center : (lines > 1 ? .top : .center), spacing: 12) {
                let size: CGFloat = grouped ? 26 : 28
                // Under a folder name the row is as tall as its text plus the room around it; the dial is centred
                // on it and does not make a one-line row taller than a two-line one's lines (the name then stood
                // 28 below its folder's name in one row and 20 in the next).
                DialView(sentText != nil ? .turning : (limited && session.state == .working ? .blocked : session.dialMode), size: size)
                    .frame(width: dialColumn, height: grouped ? 16 : size + 4)
                    .overlay { if let at = sentAt { Glimmer(since: at, size: size) } }
                    .modifier(TravellingDial(id: session.id))
                if grouped {
                  // One gap of 8 between the name and its state (a spacing of 8 on both sides of the spacer made 16).
                  HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // The session's own name, always: a row whose words changed from its title to "Sent …" to a
                    // summary could not be found again. Its state stands on the right, in a word: the dials
                    // alone were misread (grey as "off" or "failed").
                    // The name takes the room first, and may close up its letters a hair to stay on one line:
                    // "Password reset email" missed the line by five points and was then broken after its first
                    // word (the system evens out the two lines of a wrapped text).
                    Text(session.title).foregroundStyle(old ? theme.sub : theme.ink).fontWeight(asks ? .medium : .regular)
                        .lineLimit(lines).multilineTextAlignment(.leading).allowsTightening(true)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(Theme.small)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    Group {
                        if store.closing[session.id] != nil {
                            Text("closing…").foregroundStyle(theme.sub)
                        } else if sentText != nil {
                            Text("sent").foregroundStyle(theme.sub)
                        } else if asks {
                            Age(since: session.since).foregroundStyle(theme.accent).fontWeight(.semibold)
                        } else if session.state == .working {
                            Text(limited ? "out of limit" : "working").foregroundStyle(limited ? theme.limitText : theme.sub)
                        } else {
                            HStack(spacing: 0) { Text("done "); Age(since: session.since) }.foregroundStyle(theme.sub)
                        }
                    }
                    .font(Theme.small).monospacedDigit().fixedSize()
                    .help(session.state == .done ? (session.inShort ?? "") : "")
                  }
                } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 0) {
                        Text(session.project).foregroundStyle(hover ? theme.subHover : theme.sub).lineLimit(1)
                        Spacer(minLength: 8)
                        // A "Sent" row has no time: the only one at hand is the question's age, not when the user sent it.
                        if sentText == nil {
                            Age(since: session.since).monospacedDigit()
                                .foregroundStyle(asks ? theme.accent : theme.sub)
                                .fontWeight(asks ? .semibold : .regular)
                        }
                    }
                    Text(line).foregroundStyle(old ? theme.sub : theme.ink).fontWeight(asks ? .medium : .regular)
                        .lineLimit(lines).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.small)
                }
            }
            // Room inside the shape: 11 above and below (it was 7, and read as too tight).
            // The sides stay at 12, which keeps every row's text on the one left edge.
            .padding(.horizontal, 12).padding(.vertical, grouped ? 11 : 8)
            // The open row and the row under the pointer: a soft rounded shape set in from the surface's edges,
            // with the geometry of ChatGPT's sidebar rows (measured 2026-11-16: 10 round, 6 in from the edge).
            // An edge-to-edge band cut off at the borders; the first rounded slab was
            // heavier (8 round, stronger fill). Under the pointer it is half as strong. Nothing moves.
            .background(selected ? theme.select : (hover ? theme.select.opacity(0.55) : .clear),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .clickable()
        .onHover { hover = $0 }
        .animation(Motion.quick, value: hover)
        // A sliver between rows, so the shapes of two neighbours (one open, one under the pointer) never touch.
        .padding(.vertical, grouped ? 1.5 : 0)
    }

    /// A report older than a day steps back: its line drops to the quiet text colour (still readable: no fading).
    private var old: Bool { session.state == .done && Date().timeIntervalSince(session.since) > 86400 }

    private var line: String {
        if let sentText { return "Sent “\(sentText)”" }
        switch session.state {
        case .asking: return session.headline ?? session.question ?? session.title
        case .working: return session.title
        case .done: return session.inShort ?? session.title
        }
    }
}

// MARK: Folders

/// The sessions of one folder (two rows that both said "ClockOffice" told the user nothing).
struct FolderGroup: Identifiable {
    let name: String
    let sessions: [Session]
    var id: String { name }
}

extension Store {
    /// Sessions under their folder's name. Folders stand in alphabetical order and the sessions inside in a fixed
    /// order, so a row keeps its place when a session changes state: a list that reshuffled between looking and
    /// clicking could open the wrong session.
    /// True when the sessions come from more than one folder. With a single folder its name says nothing new, so
    /// it is left out everywhere.
    var manyFolders: Bool { Set(sessions.map(\.project)).count > 1 }

    /// The folder's name in front of a session's name, only where it adds something: several folders are in
    /// play and the session's name does not already carry it.
    func folderPrefix(_ s: Session) -> String {
        manyFolders && !s.title.localizedCaseInsensitiveContains(s.project) ? s.project + " · " : ""
    }

    func folders(_ list: [Session]) -> [FolderGroup] {
        Dictionary(grouping: list, by: \.project)
            .map { FolderGroup(name: $0.key, sessions: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// A folder's name above its sessions: quiet, on the same left edge as the rows' text.
struct FolderHeading: View {
    let name: String
    let edge: CGFloat
    @Environment(\.theme) private var theme
    var body: some View {
        Text(name).font(Theme.small).foregroundStyle(theme.sub).lineLimit(1)
            // Room below, so the shape of the first row (open or under the pointer) does not crowd the name.
            .padding(.leading, edge).padding(.trailing, 12).padding(.top, 14).padding(.bottom, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: The dropdown's list

/// The dropdown's first view: every session. Questions first, with their answers; then the ones that are working
/// or done, one line each. Nothing is folded away and nothing is said about what is not there.
/// (With no questions the user does not need a sentence telling them so: the absence of pink says it.)
struct SessionList: View {
    @Environment(Store.self) private var store
    @Environment(SurfaceModel.self) private var surface
    @Environment(\.theme) private var theme

    var body: some View {
        let asking = store.asking, sent = store.justSent
        let rest = store.working + store.done
        VStack(alignment: .leading, spacing: 0) {
            if !store.staleWindows.isEmpty {
                ReloadNotice(windows: store.staleWindows)
                    .padding(EdgeInsets(top: 12, leading: 12, bottom: 14, trailing: 12))
                Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 12).padding(.bottom, 4)
            }
            // Only when there is nothing at all to list.
            if store.sessions.isEmpty {
                Text(store.loaded ? "No sessions are running." : "Looking for sessions…")
                    .font(Theme.body).foregroundStyle(theme.sub)
                    .padding(.horizontal, 12).padding(.top, 16).padding(.bottom, 4)
            }
            // No extra room above a list that opens on a plain row: 8 points tried here were too much. What had looked like
            // missing padding was the list slipped up by 8 points (the scroll gap fixed in PanelBody).
            ForEach(asking) { s in
                VStack(spacing: 0) {
                    QuestionRow(session: s) { surface.open(s.id) }
                    // Clear of the card above and below by the same amount, so a highlighted card never touches it.
                    Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 12).padding(.vertical, 5)
                }
                .transition(.opacity)
            }
            // Everything that does not ask, under its folder's name.
            ForEach(store.folders(sent + rest)) { folder in
                if store.manyFolders { FolderHeading(name: folder.name, edge: 56) }
                ForEach(folder.sessions) { s in
                    QuietRow(session: s, sentText: store.sentText(s), sentAt: store.sentAt(s), selected: surface.selected == s.id,
                             grouped: true, limited: store.limited(s)) { surface.open(s.id) }
                        .transition(.opacity)
                }
            }
            // The foot: what is about the app, not about a session. A hairline sets it apart from the list
            // (questions already end on one).
            if asking.isEmpty || !(sent + rest).isEmpty {
                Rectangle().fill(theme.hair).frame(height: 1).padding(.horizontal, 12).padding(.top, 6)
            }
            HStack(alignment: .firstTextBaseline) {
                UsageLines()
                Spacer(minLength: 12)
                LinkButton("Open ClockOffice", quiet: true) { surface.openMainWindow?() }
            }
            // 10 above the line and (with the panel's own 6) 10 below it.
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        }
        .animation(Motion.push, value: asking.map(\.id))
        .animation(Motion.push, value: (sent + rest).map(\.id))
    }
}

/// Running text set for reading: paragraphs kept apart, lines given air, a line length the eye can follow.
private struct LinkFolderKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The folder of the session whose words are shown: a file named in them is looked for from there.
    var linkFolder: String? {
        get { self[LinkFolderKey.self] }
        set { self[LinkFolderKey.self] = newValue }
    }
}

struct Prose: View {
    let paragraphs: [String]
    var roomy = false
    var color: Color
    /// As wide as its words only (the user's messages, which stand on the right).
    var hug = false
    @Environment(\.linkFolder) private var folder

    var body: some View {
        VStack(alignment: .leading, spacing: roomy ? 15 : 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in
                Text(Self.styled(p, folder: folder))
                    .font(roomy ? Theme.body : Theme.small)
                    .lineSpacing(roomy ? 6 : 4)
                    .foregroundStyle(color)
                    .tint(color) // a link is the text's own colour, underlined: not a blue word in a calm page
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: hug ? nil : (roomy ? 680 : 600), alignment: .leading) // a line length the eye can follow
    }

    static func split(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private final class Kept { let value: AttributedString; let at = Date(); init(_ v: AttributedString) { value = v } }
    nonisolated(unsafe) private static let kept = NSCache<NSString, Kept>()

    /// Claude writes Markdown; bold and inline code are shown as such, the rest as plain text. With a session's
    /// folder given, web addresses and files that exist become links, as in common chat apps.
    static func styled(_ text: String, folder: String? = nil) -> AttributedString {
        let key = ((folder ?? "") + "\u{1}" + text) as NSString
        // Kept for a little while only: a file Claude is about to write does not exist yet.
        if let hit = kept.object(forKey: key), Date().timeIntervalSince(hit.at) < 20 { return hit.value }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        var a = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        if let folder { link(&a, folder: folder) }
        tame(&a)
        kept.setObject(Kept(a), forKey: key)
        return a
    }

    private static func link(_ a: inout AttributedString, folder: String) {
        let plain = String(a.characters)
        var spots: [(Range<AttributedString.Index>, URL)] = []
        for f in Linker.find(in: plain, cwd: folder) {
            let s = a.index(a.startIndex, offsetByCharacters: f.start)
            spots.append((s..<a.index(s, offsetByCharacters: f.length), f.url))
        }
        // A path in code type is tried whole: that is how one with spaces in it is written.
        for run in a.runs where run.inlinePresentationIntent?.contains(.code) == true {
            guard !spots.contains(where: { $0.0.overlaps(run.range) }),
                  let url = Linker.file(String(a.characters[run.range]), cwd: folder) else { continue }
            spots.append((run.range, url))
        }
        for (range, url) in spots where a[range].link == nil { a[range].link = Linker.inner(url) }
    }

    /// Every text, also one held short: a link is kept only when it is a web page or a file, and only when it
    /// goes where it says. "[https://good.example](https://evil.example)" shows one address and opens another:
    /// such a link is left as plain words.
    private static func tame(_ a: inout AttributedString) {
        // The links as the text came, before any of them is taken away: whether two links touch is a fact about
        // the text, not about which of them is still a link after the first check.
        let came = a.runs.map { (range: $0.range, link: $0.link) }
        // Two links that touch, with different targets, read as one underlined address whose second half goes
        // somewhere else ("https://good.example" followed at once by "/login" linked to another site): neither
        // stays a link. Characters that take no room (a zero-width space, a joiner, an accent that lands on the
        // letter before it) do not separate two links.
        var touching: [Range<AttributedString.Index>] = []
        var before: (range: Range<AttributedString.Index>, link: URL)?
        for run in came {
            guard let url = run.link else {
                if a.unicodeScalars[run.range].allSatisfy({ Linker.takesNoRoom($0) }) { continue }
                before = nil
                continue
            }
            if let b = before, b.link != url { touching.append(b.range); touching.append(run.range) }
            before = (run.range, url)
        }
        for run in came {
            guard let url = run.link else { continue }
            // The words of the whole link, not of this one run: emphasis inside a link splits it into several.
            var whole = run.range
            for other in came where other.link == url {
                if other.range.upperBound == whole.lowerBound { whole = other.range.lowerBound..<whole.upperBound }
                if other.range.lowerBound == whole.upperBound { whole = whole.lowerBound..<other.range.upperBound }
            }
            // Read letter by letter: read by whole characters, a link followed by an accent lost its last letter
            // (the accent joins it), and "https://good.example" was read as another address.
            var words = String.UnicodeScalarView()
            words.append(contentsOf: a.unicodeScalars[whole])
            let honest = Linker.followable(url) && Linker.click(url) != .nothing
                && Linker.honest(words: String(words), target: url)
            if honest {
                a[run.range].underlineStyle = .single
                // A file link the Markdown itself made travels under the app's own name too.
                if url.isFileURL { a[run.range].link = Linker.inner(url) }
            } else {
                a[run.range].link = nil
            }
        }
        for range in touching { a[range].link = nil; a[range].underlineStyle = nil }
    }
}

/// Pictures in a conversation: which of them are there to show, and small versions of them.
enum Pictures {
    private final class Kept { let paths: [String]; let at = Date(); init(_ p: [String]) { paths = p } }
    nonisolated(unsafe) private static let named = NSCache<NSString, Kept>()
    nonisolated(unsafe) private static let small = NSCache<NSString, NSImage>()
    private static let standIn = try! NSRegularExpression(pattern: #"\[(?:screenshot|image|Image #\d+)\]\s*"#)

    /// The ones whose file is still on this Mac (a screenshot's temporary file goes after a while).
    static func there(_ paths: [String]) -> [String] {
        paths.filter { p in
            // A file, not a folder that happens to be called "x.png" (it showed as an empty frame).
            var dir: ObjCBool = false
            return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue
        }
    }

    /// The picture files a message names, looked up at most every 20 seconds.
    static func named(in text: String, folder: String) -> [String] {
        guard text.contains("/") else { return [] }
        let key = (folder + "\u{1}" + text) as NSString
        if let hit = named.object(forKey: key), Date().timeIntervalSince(hit.at) < 20 { return hit.paths }
        let found = there(Linker.pictures(in: text, cwd: folder))
        named.setObject(Kept(found), forKey: key)
        return found
    }

    static func withoutStandIns(_ text: String) -> String {
        standIn.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A small version of a picture, made off the main thread and kept: a screenshot is megabytes, its place in a
    /// message a few hundred points.
    @MainActor static func small(_ path: String, longest: Int) async -> NSImage? {
        let key = "\(path)#\(longest)" as NSString
        if let hit = small.object(forKey: key) { return hit }
        let cg: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: longest] as CFDictionary)
        }.value
        guard let cg else { return nil }
        let made = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        small.setObject(made, forKey: key)
        return made
    }

    /// Still drawings cannot wait for a picture to be made small: there it is made beforehand (`prime`).
    @MainActor static func ready(_ path: String, longest: Int) -> NSImage? {
        small.object(forKey: "\(path)#\(longest)" as NSString)
    }
    @MainActor static func prime(_ path: String, longest: Int) {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longest] as CFDictionary) else { return }
        small.setObject(NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2)), forKey: "\(path)#\(longest)" as NSString)
    }
}

/// The pictures of one message, small, side by side. A click opens the picture itself.
struct PictureRow: View {
    let paths: [String]
    let session: Session
    var roomy = false
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(paths.prefix(4), id: \.self) { Picture(path: $0, session: session, height: roomy ? 150 : 96, width: roomy ? 360 : 220) }
        }
    }
}

private struct Picture: View {
    let path: String
    let session: Session
    let height: CGFloat
    let width: CGFloat
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var image: NSImage?

    var body: some View {
        Button { store.openLink(URL(fileURLWithPath: path), from: session) } label: {
            Group {
                if let image = image ?? Pictures.ready(path, longest: Int(max(width, height) * 2)) {
                    // The frame is the picture's own shape, as large as fits: no empty bands beside a tall one.
                    let scale = min(width / max(image.size.width, 1), height / max(image.size.height, 1), 1)
                    Image(nsImage: image).resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.bubble).frame(width: height * 1.5, height: height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.hair, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .clickable()
        .help("Open the picture")
        .accessibilityLabel("Picture: " + (path as NSString).lastPathComponent)
        .task(id: path) { image = await Pictures.small(path, longest: Int(max(width, height) * 2)) }
    }
}

/// The last few things said in a session. The newest message is the one to read, so it is set as running text in
/// full ink; what came before is context and stays to two quiet lines each. No bubbles, no boxes.
struct ConversationView: View {
    let session: Session
    let limit: Int
    /// The window has room for larger type and the whole last message; the dropdown shows its closing part first.
    var roomy = false
    /// The conversation is already taller than the room it has, so it scrolls. (A dropdown that can still grow, or
    /// a short conversation in the window, does not.) It decides how earlier messages come in.
    var scrolls = false
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @State private var expanded = false
    /// How many messages further back the user has asked to see.
    @State private var extra = 0
    /// Earlier messages the user clicked open in full.
    @State private var opened: Set<String> = []
    /// Messages that have just been brought in above and are still fading in.
    @State private var fresh: Set<String> = []
    /// The user asked for earlier messages and they are still being read: the message that was first on screen then.
    @State private var waitingAbove: String?

    private func key(_ turn: String) -> String { "turn-\(session.id)-\(turn)" }

    /// "Show earlier messages": the eight messages before the ones on screen come in directly above them, in one
    /// step, and the user ends up looking at the nearest of them with what they were reading just below. (They came in two
    /// steps as they were read, and a view that scrolls stayed at its top, on the oldest of the new ones.)
    /// - Where there is room to grow (the dropdown below its full height, a short conversation in the window), what
    ///   is on screen slides down and the earlier messages fade in above: the dropdown grows on the same curve.
    /// - Where the view scrolls, what the user was reading keeps its place and the view glides up to the nearest ones.
    private func earlier(_ all: [Turn], proxy: ScrollViewProxy) {
        let shown = all.suffix(limit + extra)
        guard let first = shown.first?.id else { return }
        if all.count > shown.count { reveal(all, above: first, proxy: proxy) } else { waitingAbove = first }
        // One batch further than the user will see now: the next click shows at once.
        store.wantTurns(session, limit + extra + 16)
    }

    private func reveal(_ all: [Turn], above first: String, proxy: ScrollViewProxy) {
        let before = Set(all.suffix(limit + extra).map(\.id))
        let new = all.suffix(limit + extra + 8).map(\.id).filter { !before.contains($0) }
        let rest = UnitPoint(x: 0, y: 0.55)   // where the message being read comes to rest when the view scrolls
        var still = Transaction()
        still.disablesAnimations = true
        guard scrolls, !Motion.reduced else {
            if Motion.reduced {
                withTransaction(still) { extra += 8 }
                DispatchQueue.main.async { withTransaction(still) { proxy.scrollTo(key(first), anchor: rest) } }
                return
            }
            withAnimation(Motion.push) { extra += 8 }
            // If it has outgrown its room meanwhile, the nearest earlier messages are brought into view.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(key(first), anchor: rest) }
            }
            return
        }
        withTransaction(still) { fresh = Set(new); extra += 8 }
        DispatchQueue.main.async {
            // The user's place first, without motion; then one glide up, while the new messages fade in.
            withTransaction(still) { proxy.scrollTo(key(first), anchor: .top) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                withAnimation(.easeInOut(duration: 0.38)) {
                    fresh = []
                    proxy.scrollTo(key(first), anchor: rest)
                }
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in content(proxy) }
    }

    @ViewBuilder private func content(_ proxy: ScrollViewProxy) -> some View {
        let all = store.turns[session.id] ?? []
        let turns = Array(all.suffix(limit + extra))
        // Measured against ChatGPT's conversation view on 2026-11-16 (16 px text on a 26 px line, about 17 px
        // between paragraphs, a 22 px-round bubble with 16 by 12 padding, at most 70% of the column wide, a clear
        // gap between speakers), scaled to this app's two text sizes.
        VStack(alignment: .leading, spacing: roomy ? 30 : 20) {
            if turns.isEmpty {
                Text(session.inShort ?? "Nothing said yet.").font(Theme.small).foregroundStyle(theme.sub)
            }
            // The way back: more of the conversation, eight messages at a time.
            if all.count > turns.count || (!turns.isEmpty && store.mayHaveEarlier(session)) {
                LinkButton("Show earlier messages", quiet: true) { earlier(all, proxy: proxy) }
            }
            ForEach(turns) { turn in
                let last = turn.id == turns.last?.id
                Group {
                if turn.who == .you {
                    // The user's own words: on the right, in one soft bubble, as in common chat apps.
                    // (Position alone was not enough: plain grey lines on the right read as scattered text.)
                    // Their pictures above their words, as in common chat apps; the word that stood in for
                    // a picture ("[screenshot]") goes when the picture itself is there.
                    let shown = Pictures.there(turn.pictures)
                    let words = shown.isEmpty ? turn : Turn(id: turn.id, who: .you, text: Pictures.withoutStandIns(turn.text), at: turn.at)
                    HStack(alignment: .top, spacing: 0) {
                        Spacer(minLength: roomy ? 200 : 64)
                        VStack(alignment: .trailing, spacing: 6) {
                            if !shown.isEmpty { PictureRow(paths: shown, session: session, roomy: roomy) }
                            if !words.text.isEmpty {
                                usersMessage(words, whole: roomy || opened.contains(turn.id), lines: last ? 8 : 3)
                                    .padding(.horizontal, roomy ? 16 : 12).padding(.vertical, roomy ? 10 : 7)
                                    .background(theme.bubble, in: RoundedRectangle(cornerRadius: roomy ? 20 : 16, style: .continuous))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("You said")
                } else {
                    // A picture Claude names by its path (a still it made, a screenshot it took) shows under its words.
                    let shown = Pictures.named(in: turn.text, folder: session.cwd)
                    VStack(alignment: .leading, spacing: 8) {
                        claudes(turn, last: last)
                        if !shown.isEmpty, roomy || last || opened.contains(turn.id) {
                            PictureRow(paths: shown, session: session, roomy: roomy)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Claude said")
                }
                }
                .opacity(fresh.contains(turn.id) ? 0 : 1)
                .id(key(turn.id))
            }
            // What the user just sent, at once and in their own bubble, until the session's record carries it: without it
            // the message box vanished and their words were nowhere.
            if let sent = store.sentText(session), !sent.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: roomy ? 200 : 64)
                    Prose(paragraphs: Prose.split(sent), roomy: roomy, color: theme.ink, hug: true)
                        .padding(.horizontal, roomy ? 16 : 12).padding(.vertical, roomy ? 10 : 7)
                        .background(theme.bubble, in: RoundedRectangle(cornerRadius: roomy ? 20 : 16, style: .continuous))
                }
                .accessibilityLabel("You sent")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.linkFolder, session.cwd)
        .environment(\.openURL, OpenURLAction { url in store.openLink(url, from: session); return .handled })
        .task(id: session.revision) { store.loadTurns(session) }
        .onChange(of: all.count) { _, count in
            // The earlier messages the user asked for have been read.
            guard let first = waitingAbove, count > turns.count else { return }
            waitingAbove = nil
            reveal(all, above: first, proxy: proxy)
        }
    }

    /// One of the user's messages. In the dropdown it is held to a few lines until they click it (three for an older
    /// one, eight for the newest), so one long message never pushes everything else out of view.
    @ViewBuilder private func usersMessage(_ turn: Turn, whole: Bool, lines: Int = 3) -> some View {
        if whole {
            Prose(paragraphs: Prose.split(turn.text), roomy: roomy, color: theme.ink, hug: true)
        } else {
            Button { withAnimation(Motion.push) { _ = opened.insert(turn.id) } } label: {
                Text(Prose.styled(turn.text))   // held short: a click opens the whole message, where its links are
                    .font(Theme.small).lineSpacing(4).foregroundStyle(theme.ink)
                    .lineLimit(lines).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .clickable()
            .help("Show the whole message")
        }
    }

    /// One of Claude's messages: plain text on the left, in full ink and one size. The window shows every message
    /// whole. The dropdown is small, so there the newest shows its closing part and an older one its last lines;
    /// a click gives the whole message.
    @ViewBuilder private func claudes(_ turn: Turn, last: Bool) -> some View {
        let all = Prose.split(turn.text)
        if roomy || opened.contains(turn.id) || (last && expanded) {
            Prose(paragraphs: all, roomy: roomy, color: theme.ink)
        } else if last {
            let shown = Self.closing(all)
            VStack(alignment: .leading, spacing: 5) {
                if shown.count < all.count {
                    // Three dots say there is more above; a click gives the whole message.
                    LinkButton("…", quiet: true) { withAnimation(Motion.push) { expanded = true } }
                        .help("Show the whole message")
                        .accessibilityLabel("Show the whole message")
                }
                Prose(paragraphs: shown, roomy: false, color: theme.ink)
            }
        } else {
            // What a message ended on says more than how it began ("Your remaining actions:" told nothing).
            Button { withAnimation(Motion.push) { _ = opened.insert(turn.id) } } label: {
                Text(Prose.styled(all.last ?? turn.text))
                    .font(Theme.small).lineSpacing(4).foregroundStyle(theme.ink)
                    .lineLimit(3).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 600, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .clickable()
            .help("Show the whole message")
        }
    }

    /// The closing paragraphs of a message, up to about 480 characters: a message ends on what it wants from the user.
    static func closing(_ paragraphs: [String]) -> [String] {
        var out: [String] = [], total = 0
        for p in paragraphs.reversed() {
            if !out.isEmpty && total + p.count > 480 { break }
            out.insert(p, at: 0); total += p.count
        }
        return out
    }
}

/// The head of a conversation: the dial, the title, where it stands. The dial's left edge is the text's left edge.
struct SessionHeader: View {
    let session: Session
    /// Whether the folder's name is said under the title. Not where it is already on screen: the window's list
    /// shows it as a heading beside this, and with one
    /// folder only it says nothing.
    var folder = true
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let sentText = store.sentText(session)
        // Which tool, when it is not Claude Code: "Website · Codex · working".
        let where_ = [folder ? session.project : nil, session.tool == "Claude Code" ? nil : session.tool]
            .compactMap { $0 }.joined(separator: " · ")
        // "ClockOffice · " before the state, or nothing.
        let lead = where_.isEmpty ? "" : where_ + " · "
        HStack(alignment: .center, spacing: 14) {
            let limited = store.limited(session) && sentText == nil
            DialView(sentText != nil ? .turning : (limited ? .blocked : session.dialMode), size: 44)
                .modifier(TravellingDial(id: session.id))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(Theme.body).fontWeight(.semibold).foregroundStyle(theme.ink).lineLimit(2)
                Group {
                    if sentText != nil {
                        Text(lead.isEmpty ? "Working on your reply" : "\(lead)working on your reply")
                    } else {
                        switch session.state {
                        case .asking:
                            HStack(spacing: 0) {
                                Text(lead)
                                HStack(spacing: 0) { Text(lead.isEmpty ? "Waiting " : "waiting "); Age(since: session.since) }.foregroundStyle(theme.accent)
                            }
                        case .working:
                            // The same words as its row: the limit stopped it.
                            if store.limited(session) {
                                HStack(spacing: 0) { Text(lead); Text(lead.isEmpty ? "Out of limit" : "out of limit").foregroundStyle(theme.limitText) }
                            } else {
                                Text(lead.isEmpty ? "Working" : "\(lead)working")
                            }
                        case .done: HStack(spacing: 0) { Text(lead.isEmpty ? "Done " : "\(lead)done "); Age(since: session.since, suffix: " ago") }
                        }
                    }
                }
                .font(Theme.small).foregroundStyle(theme.sub)
            }
            Spacer(minLength: 0)
        }
    }
}

/// The last line of a conversation view: where the session runs on the left, its page on claude.ai on the right.
/// (There was a "Hide" here. three clicks hid every session, with no way back. Removed.)
struct SessionFooter: View {
    let session: Session
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    /// "Visual Studio Code · Fable 5.2": the app it runs in and its model. Not the folder: the list beside it has it
    /// as a heading, and their sessions run in a folder called "ClockOffice", which read as the app's own name.
    /// The whole path is in the tooltip.
    private var place: String {
        // The model this session runs on, when Claude Code has reported it.
        let model = store.models[session.id].map { " · " + $0 } ?? ""
        return (store.host(of: session) ?? session.tool) + model
    }

    var body: some View {
        HStack(spacing: 20) {
            Text(place).font(Theme.small).foregroundStyle(theme.sub).lineLimit(1).truncationMode(.tail)
                .help(session.cwd)
            CloseLink(session: session)
            Spacer(minLength: 8)
            if session.remoteURL != nil { LinkButton("Open in Claude", quiet: true) { store.openRemote(session) } }
        }
    }
}

/// "Close session", the last thing in a session's view: one quiet word on the left, away from the links that take
/// the user somewhere and from the send arrow on the right (it sat 23 points under the arrow).
/// (Not in the top line of the dropdown: beside it "Show in Visual Studio Code" broke over two lines.) One click,
/// then "Closing…" with an Undo for a few seconds, the same as a one-click answer.
struct CloseLink: View {
    let session: Session
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 14) {
            if let asked = store.closing[session.id] {
                // As wide as the link it replaces, so "Undo" never lands under a second click meant for
                // "Close session" (it did).
                Text("Close session").fontWeight(.medium).hidden()
                    .overlay(alignment: .leading) { Text("Closing…").foregroundStyle(theme.sub).fixedSize() }
                    .font(Theme.small)
                if !asked { LinkButton("Undo") { store.undoClose(session.id) } }
            } else if store.canClose(session) {
                LinkButton("Close session", quiet: true,
                           tip: "It quits in its own terminal. The conversation is kept: “claude --resume” picks it up again.") {
                    store.close(session)
                }
            }
        }
    }
}

/// One session in the dropdown. Top line: back on the left, its window on the right. Then who it is, what was said,
/// the message box, and one quiet closing line.
struct SessionDetail: View {
    let session: Session
    @Environment(Store.self) private var store
    @Environment(SurfaceModel.self) private var surface
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LinkButton("‹ All sessions", quiet: true) { surface.back() }.help("Back (Esc)")
            SessionHeader(session: session, folder: store.manyFolders)
            Rectangle().fill(theme.hair).frame(height: 1)
            ConversationView(session: session, limit: 3, scrolls: surface.contentHeight >= surface.roomForContent - 1)
            if store.sentText(session) == nil { AnswerArea(session: session).padding(.top, 2) }
            // No closing line here: where the session runs, its model and its page on claude.ai are in the window.
            // (A closing line made this view cluttered.) Only the one word for closing the session is kept.
            // Under the message box: closing the session on the left, going to its own window on the right.
            if store.canClose(session) || store.closing[session.id] != nil || store.canShow(session) {
                HStack(spacing: 20) {
                    CloseLink(session: session)
                    Spacer(minLength: 8)
                    if store.canShow(session) { LinkButton(store.goLabel(session), quiet: true, key: "O") { store.openWindow(session) } }
                }
                .padding(.top, -4)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 12, trailing: 18))
    }
}

// MARK: Surfaces

/// State of one surface (the dropdown or the window): which session is open, whether the quiet list shows.
@MainActor
@Observable
final class SurfaceModel {
    enum Kind { case panel, window }
    let kind: Kind
    private(set) var detail: String?
    var contentHeight: CGFloat = 200
    /// How tall the content may get before its surface stops growing and scrolls (the dropdown's full height).
    @ObservationIgnored var roomForContent: CGFloat = .infinity
    /// The row the arrow keys are on.
    var selected: String?
    /// True while this surface cannot be seen (window covered or minimised): its animations pause.
    var hidden = false
    @ObservationIgnored var focusedReply: String?
    /// Set by Tab: the session whose message box should take the caret.
    var focusRequest: String?
    /// True while a file picker is up, so the dropdown does not close under it.
    @ObservationIgnored var holdOpen = false
    @ObservationIgnored var openMainWindow: (() -> Void)?
    /// Tells the dropdown's window how tall its content is.
    @ObservationIgnored var onHeight: ((CGFloat) -> Void)?
    init(kind: Kind) { self.kind = kind }

    /// In the dropdown the conversation slides in from the right; in the window it simply changes beside the list.
    func open(_ id: String) {
        if kind == .panel { withAnimation(Motion.push) { detail = id } } else { detail = id }
    }
    func back() { withAnimation(Motion.push) { detail = nil } }
    /// Without motion: when the surface itself appears.
    func reset() { detail = nil; selected = nil; focusedReply = nil }

    /// The sessions in the order this surface lists them: what ↑ and ↓ walk through.
    func order(_ store: Store) -> [Session] {
        // The same order the lists are drawn in: the window lists every session under its folder; the dropdown
        // puts the questions first and the rest under their folders.
        if kind == .window { return store.folders(store.sessions).flatMap(\.sessions) }
        return store.asking + store.folders(store.justSent + store.working + store.done).flatMap(\.sessions)
    }

    /// The session a shortcut acts on: the open conversation, else the selected row, else the longest-waiting question.
    func target(_ store: Store) -> Session? {
        if let id = detail, let s = store.session(id) { return s }
        if let id = selected, let s = store.session(id) { return s }
        return kind == .window ? order(store).first : store.asking.first
    }
    func show(_ id: String) { detail = id }
    /// After an answer the dropdown returns to the list, where the reply shows as sent. The window stays put.
    /// Only when the user is still looking at that session: an answer that went out four seconds later must not pull
    /// them out of another session they opened meanwhile.
    func afterSend(_ id: String) { if kind == .panel, detail == id { back() } }
}

private struct HeightsKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private extension View {
    /// Reports this view's height under a name, so a surface can size itself to the view that is arriving
    /// and ignore the one that is leaving.
    func measured(as name: String) -> some View {
        background(GeometryReader { g in Color.clear.preference(key: HeightsKey.self, value: [name: g.size.height]) })
    }
}

/// The dropdown's content: the list, or one conversation, with the push between them.
struct PanelContent: View {
    let width: CGFloat
    @Environment(Store.self) private var store
    @Environment(SurfaceModel.self) private var surface

    var body: some View {
        // The session's dial no longer flies from its row to the top of its view: it crossed the fading list on
        // its own and read as things shifting about. One motion is left: the view comes in from its side.
        ZStack(alignment: .topLeading) {
            if let id = surface.detail, let s = store.session(id) {
                SessionDetail(session: s)
                    .frame(width: width, alignment: .topLeading)
                    .measured(as: "detail")
                    .transition(Motion.enter(from: 28))
            } else {
                SessionList()
                    .frame(width: width, alignment: .topLeading)
                    .measured(as: "list")
                    .transition(Motion.enter(from: -28))
            }
        }
        .frame(width: width, alignment: .topLeading)
        .onPreferenceChange(HeightsKey.self) { heights in
            let showing = surface.detail != nil && store.session(surface.detail ?? "") != nil ? "detail" : "list"
            guard let h = heights[showing], abs(h - surface.contentHeight) > 0.5 else { return }
            surface.contentHeight = h
            surface.onHeight?(h)
        }
        .onChange(of: store.sessions.map(\.id)) { _, ids in
            // A session that ended while open: back to the list.
            if let id = surface.detail, !ids.contains(id) { surface.back() }
        }
    }
}

/// The menu-bar dropdown: 410 points wide, as tall as its content, scrolling only when the screen runs out.
/// It fills its window; the window itself grows and shrinks (see MenuBar.resize).
struct PanelRoot: View {
    static let width: CGFloat = 410
    var body: some View { Themed { PanelBody() } }

    /// How tall the list is right now, measured before the dropdown is on screen. The height the content reports
    /// arrives a moment after it is laid out, so the dropdown opened at the height of its LAST opening and then
    /// jumped to today's.
    @MainActor static func listHeight(_ store: Store) -> CGFloat {
        let probe = NSHostingController(rootView: PanelContent(width: width - 12)
            .environment(store).environment(SurfaceModel(kind: .panel)))
        return probe.sizeThatFits(in: NSSize(width: width - 12, height: 20_000)).height
    }
}

private struct PanelBody: View {
    @Environment(SurfaceModel.self) private var surface
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // A session's view opens at its newest words and its message box, however long the conversation above is;
        // the list opens at its top. (Opened at the top, a long conversation had to be scrolled all the way down.)
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // No gap between the content and the mark at its foot: left to itself the scroll view put 8 points
                // there, so content that fitted exactly could still slip up by 8 points, and stayed there once a
                // session's view had been scrolled to its foot (back from a session, the list sat
                // cut off at the top; measured in the rig: a list that fits moved from 53 to 45).
                VStack(spacing: 0) {
                    PanelContent(width: PanelRoot.width - 12).padding(6)
                    Color.clear.frame(height: 0).id("foot")
                }
            }
            .onChange(of: surface.detail) { _, id in
                guard id != nil else { return }
                // Only a view taller than the dropdown can get is scrolled to its end, and only once the list
                // has left: scrolled while both were still there, a short view was pushed up and dropped back.
                for delay in [0.1, 0.3, 0.6] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if surface.contentHeight > surface.roomForContent - 1 { proxy.scrollTo("foot", anchor: .bottom) }
                    }
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(theme.hair, lineWidth: 1))
        // Depth from a top highlight and a hairline, not from a heavy shadow.
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(
            LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.10 : 0.9), .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.12)),
            lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
