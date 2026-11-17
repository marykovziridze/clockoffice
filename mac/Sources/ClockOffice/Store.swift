import AppKit
import ClockOfficeCore
import Observation
import WidgetKit

/// The one live picture of every session, and the actions the user can take on them.
/// Closing the app changes nothing for the sessions: it only reads, and only types when the user replies.
@MainActor
@Observable
final class Store {
    private(set) var sessions: [Session] = []
    /// Sessions an editor window can type into (the reply box shows only for these).
    private(set) var replyable: Set<String> = []
    var drafts: [String: String] = [:]
    var attachments: [String: [String]] = [:]
    /// What the user just sent, shown until the session visibly moves on.
    private(set) var sent: [String: (text: String, stamp: String, at: Date)] = [:]
    private(set) var errors: [String: String] = [:]
    /// The last few things said per session, loaded when its conversation is opened.
    private(set) var turns: [String: [Turn]] = [:]
    /// How far back each conversation has been read; it grows when the user asks for earlier messages.
    private(set) var turnLimits: [String: Int] = [:]
    /// Sessions whose editor window answered with an old secret: it needs one reload before it takes replies.
    private(set) var stale: Set<String> = []
    /// The same, per editor window: what the "reload once" notice names.
    private(set) var staleWindows: [StaleWindow] = []
    private(set) var loaded = false
    /// The plan's limits as Claude Code last reported them (nil until the status line relay is on and has spoken).
    private(set) var usage: UsageLimits?
    /// True while the Claude plan's session or weekly limit is used up and has not reset yet. Kept as a value the
    /// screens watch, and brought up to date on every look, so a row loses its red shine when the limit resets
    /// without waiting for something else to redraw it.
    private(set) var outOfLimit = false

    private func limitNow() -> Bool { usage?.usedUp() ?? false }

    private func refreshLimit() {
        let now = limitNow()
        guard now != outOfLimit else { return }
        outOfLimit = now
        // What each session reports at the moment the limit is reached is not known yet (nothing recognisable in
        // the records so far): it goes into the diary, so the state can be drawn from facts next time.
        if now { for s in sessions { log?.write("at_limit", session: s, extra: ["state": s.state.rawValue, "tool": s.tool]) } }
    }

    /// A session the used-up limit has stopped: a Claude Code session that was working. Another tool's session
    /// runs on another plan (a working Codex conversation was drawn "out of limit").
    func limited(_ s: Session) -> Bool { outOfLimit && s.tool == "Claude Code" && s.state == .working }
    /// The model each session runs on, by session id (from the same reports).
    private(set) var models: [String: String] = [:]
    var summariesOn: Bool = UserDefaults.standard.object(forKey: "summaries") as? Bool ?? true {
        didSet { UserDefaults.standard.set(summariesOn, forKey: "summaries"); refresh() }
    }
    /// Called whenever the number of questions changes (the menu-bar count).
    var onCount: ((Int) -> Void)?
    /// Test rig only: told what would have happened outside the app (another app's window coming forward).
    @ObservationIgnored var onOutside: ((String) -> Void)?

    /// True while ⌘ is held with a surface open: the moment the shortcut hints show.
    var commandHeld = false
    @ObservationIgnored private var lastSend = Date.distantPast
    /// This build's dialog hooks are in Claude Code's settings, in their current form (read on every look).
    @ObservationIgnored private var hooksCurrent = false
    @ObservationIgnored private var sending: Set<String> = []
    @ObservationIgnored private var errorMeta: [String: (revision: String, at: Date)] = [:]
    @ObservationIgnored private let sources: [SessionSource]
    @ObservationIgnored private let summarizer: Summarizer?
    @ObservationIgnored private let bridge = BridgeClient()
    @ObservationIgnored private let log: EventLog?
    @ObservationIgnored private let server = SnapshotServer()
    @ObservationIgnored private let work = DispatchQueue(label: "clockoffice.refresh", qos: .userInitiated)
    @ObservationIgnored private let summaryQueue = DispatchQueue(label: "clockoffice.summaries", qos: .utility)
    @ObservationIgnored private var summarizing: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var seenAsking: [String: Date] = [:]
    @ObservationIgnored private var lastSnapshot: Snapshot?
    @ObservationIgnored private var lastReplyCheck = Date.distantPast
    @ObservationIgnored private var checkedIds: Set<String> = []
    /// Counts the reply-route checks, so a slow old one can never overwrite a newer answer.
    @ObservationIgnored private var replyCheck = 0
    /// How many surfaces (dropdown, window) are on screen right now.
    @ObservationIgnored var watching = 0 { didSet { if watching > oldValue { lastReplyCheck = .distantPast; refresh() } } }
    @ObservationIgnored let fixture: Bool
    /// This run's secret for answer links from the widget (see runSecret in Snapshot).
    @ObservationIgnored private let widgetSecret = UUID().uuidString

    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(Edition.current.folder)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The live store.
    init() {
        fixture = false
        // Claude Code, and Codex beside it (read-only: see CodexSource).
        sources = [ClaudeCodeSource(inbox: server.inbox), CodexSource()]
        summarizer = Summarizer(directory: Self.supportDirectory)
        log = EventLog(directory: Self.supportDirectory)
    }

    /// A fixed picture for test renders: nothing is read, nothing is sent.
    init(fixture sessions: [Session], replyable: Set<String>, turns: [String: [Turn]] = [:], stale: Set<String> = [],
         usage: UsageLimits? = nil, models: [String: String] = [:]) {
        self.usage = usage
        self.models = models
        fixture = true
        sources = []; summarizer = nil; log = nil
        self.sessions = sessions
        self.replyable = replyable.subtracting(stale)
        self.turns = turns
        self.stale = stale
        staleWindows = ReloadHint.windows(sessions.filter { stale.contains($0.id) }
            .map { (id: $0.id, folder: $0.cwd, host: "Visual Studio Code") })
        outOfLimit = limitNow()
        loaded = true
    }

    /// Test rig only: the made-up world moves on (a session the user answered starts working, then reports back).
    func rigReplace(_ s: Session, adding turn: Turn? = nil) {
        guard fixture, let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
        sessions[i] = s
        if let turn { turns[s.id, default: []].append(turn) }
        dropStalePending(sessions)
        sent[s.id] = nil
        onCount?(asking.count)
    }

    // MARK: Lists

    private func isSent(_ s: Session) -> Bool { sent[s.id]?.stamp == s.stamp }
    /// Questions, longest wait first.
    var asking: [Session] { sessions.filter { $0.state == .asking && !isSent($0) }.sorted { $0.since < $1.since } }
    var justSent: [Session] { sessions.filter { isSent($0) } }
    var working: [Session] { sessions.filter { $0.state == .working && !isSent($0) }.sorted { $0.since > $1.since } }
    var done: [Session] { sessions.filter { $0.state == .done && !isSent($0) }.sorted { $0.since > $1.since } }
    func session(_ id: String) -> Session? { sessions.first { $0.id == id } }
    func sentText(_ s: Session) -> String? { isSent(s) ? sent[s.id]?.text : nil }
    func sentAt(_ s: Session) -> Date? { isSent(s) ? sent[s.id]?.at : nil }
    func error(_ s: Session) -> String? { errors[s.id] }
    /// Only a Claude Code session can be typed into. Every Codex conversation carries the one Codex process, which
    /// says nothing about which terminal is whose: it must never get a message box.
    func canReply(_ s: Session) -> Bool { s.tool == "Claude Code" && replyable.contains(s.id) }

    /// The editor window this session sits in, when that window needs a reload before it takes replies.
    func staleWindow(of s: Session) -> StaleWindow? { staleWindows.first { $0.sessionIds.contains(s.id) } }

    /// The app each session runs in, looked up once per session (a process lookup is too slow for every redraw).
    @ObservationIgnored private var hostCache: [String: String] = [:]
    /// Test rig only: made-up host apps.
    @ObservationIgnored var hostNames: [String: String] = [:]
    /// Whether a session's own view puts the caret in its message box when it opens (not in still drawings).
    @ObservationIgnored lazy var autofocus: Bool = !fixture

    func host(of s: Session) -> String? {
        if let made = hostNames[s.id] { return made }
        guard !fixture else { return nil }
        let key = "\(s.id)#\(s.pid)"
        if let known = hostCache[key] { return known.isEmpty ? nil : known }
        let name = Hosts.name(for: s) ?? ""
        hostCache[key] = name
        return name.isEmpty ? nil : name
    }

    /// The words on the link that brings a session's own window forward: they name where it goes. ("Open window"
    /// read as "open ClockOffice's window", and "Open its window" left open which.)
    func goLabel(_ s: Session) -> String { host(of: s).map { "Show in \($0)" } ?? "Show its own window" }

    /// Whether there is anywhere to take the user for this session. Another tool's conversation with none of its
    /// processes running has no window: the link only beeped there.
    func canShow(_ s: Session) -> Bool { s.tool == "Claude Code" || host(of: s) != nil || s.remoteURL != nil }

    // MARK: Permission prompts

    /// What an Allow or Deny choice carries instead of keys to type: the request it answers. Never typed anywhere.
    static let allowMark = "\u{1}permission-allow:", denyMark = "\u{1}permission-deny:"
    static func isPermission(_ o: ReplyOption) -> Bool { o.send.hasPrefix(allowMark) || o.send.hasPrefix(denyMark) }

    /// A session waiting on a permission prompt that this app holds gets Allow and Deny. These need no editor
    /// terminal: the answer goes back through Claude Code's own hook, so they work in any terminal.
    private func withPermissionChoices(_ s: Session) -> Session {
        guard s.tool == "Claude Code", s.state == .asking, s.waitingFor == "permission prompt",
              let ask = server.permissions.ask(for: s.id), PermissionDesk.answerable(ask.toolName),
              // Two requests open in one session (a subagent asking beside the main prompt): the words shown and the
              // request a click would answer could differ, so both are answered in the terminal.
              server.permissions.all().filter({ $0.sessionId == s.id }).count == 1 else { return s }
        var s = s
        s.options = [ReplyOption(label: "Allow", send: Self.allowMark + ask.id),
                     ReplyOption(label: "Deny", send: Self.denyMark + ask.id)]
        return s
    }

    /// Allow and Deny are on offer for this session.
    func canDecide(_ s: Session) -> Bool { s.options.contains(where: Self.isPermission) }

    /// Answers a permission prompt through the hook that is holding it. Refused when it was answered meanwhile
    /// (in its window, or the session moved on): nothing is decided then.
    private func decide(_ shown: Session, _ option: ReplyOption, done: ((Bool) -> Void)?) {
        let allow = option.send.hasPrefix(Self.allowMark)
        let id = String(option.send.dropFirst((allow ? Self.allowMark : Self.denyMark).count))
        guard !fixture else { markSent(shown, option.label, words: option.label, files: 0, typed: false); done?(true); return }
        let sources = sources
        Task {
            // An answer typed in the terminal does not end the hook (Claude Code 2.1.326 leaves it running: verifier 1,
            // re-measured 2026-11-17), so an open request alone does not prove the prompt is still on screen. The
            // session is read again now: only while it still waits on this same permission prompt does the click count.
            let fresh = await Task.detached { Session.unique(sources.flatMap { $0.sessions() }).first { $0.id == shown.id } }.value
            let still = fresh?.state == .asking && fresh?.waitingFor == "permission prompt"
                && Reply.stillCurrent(shown: shown, fresh: fresh)
            if still, self.server.permissions.decide(id, allow: allow) {
                self.markSent(shown, option.label, words: option.label, files: 0, typed: false)
                self.log?.write("decided", session: shown, extra: ["waited_s": Int(Date().timeIntervalSince(shown.since)), "allow": allow])
                done?(true)
            } else {
                if !still { self.server.permissions.letGo(id) }
                self.fail(shown, "Not sent: it was already answered in its own window.")
                done?(false)
            }
            self.refresh()
        }
    }

    /// One plain line on why there is no message box for this session, and what to do about it.
    /// (A window that needs a reload is said by `ReloadNotice`, not here.)
    func whyNoReply(_ s: Session) -> String? {
        if canDecide(s) { return nil }
        if s.tool == "Claude Code", s.state == .asking, s.waitingFor == "permission prompt" {
            return hooksCurrent || fixture
                ? "Allow or deny this one in its own window."
                : "To allow or deny from here, right-click the icon in the menu bar and switch on “Show the words of Claude Code dialogs”."
        }
        if canReply(s) {
            // Only when the dialog offers nothing to click here; under live answers the line contradicted them.
            return s.certain && s.options.isEmpty ? "This is a dialog in its own window: pick one of its choices there." : nil
        }
        let host = self.host(of: s)
        // Only a Claude Code session in an editor's terminal can be typed into; another tool's conversation has no
        // terminal of its own.
        if s.tool != "Claude Code" {
            // The link brings the app forward (an editor: the window of this folder), not the conversation itself.
            guard let host else {
                // A process with no app around it (the command in tmux or over ssh) is running, just not in a window.
                return s.pid == 0
                    ? "A \(s.tool) session can't be answered from here. \(s.tool) isn't running now: open it to go on with this conversation."
                    : "A \(s.tool) session can't be answered from here. Go on with it where you started it."
            }
            return "A \(s.tool) session can't be answered from here. “Show in \(host)” brings \(host) forward: pick the conversation there."
        }
        if let host, Hosts.editors().contains(where: { $0.name == host }) {
            return "To reply from here, right-click the icon in the menu bar and choose “Set up replying in \(host)”."
        }
        return "This session can't be answered from here. “\(goLabel(s))” takes you to where it can."
    }

    static let firstTurns = 8

    /// True when the session's record may hold messages older than the ones read so far.
    func mayHaveEarlier(_ s: Session) -> Bool { (turns[s.id]?.count ?? 0) >= (turnLimits[s.id] ?? Self.firstTurns) }

    /// The user asked for earlier messages: read at least this many.
    func wantTurns(_ s: Session, _ count: Int) {
        guard count > (turnLimits[s.id] ?? Self.firstTurns) else { return }
        turnLimits[s.id] = count
        loadTurns(s)
    }

    /// Reads the last things said in a session, off the main thread.
    func loadTurns(_ s: Session) {
        let limit = turnLimits[s.id] ?? Self.firstTurns
        guard !fixture, let source = sources.first(where: { $0.tool == s.tool }) else { return }
        if !tidiedPictures { tidiedPictures = true; work.async { PastedPictures.tidy() } }
        work.async { [weak self] in
            let list = source.conversation(for: s, limit: limit)
            DispatchQueue.main.async { if self?.turns[s.id] != list { self?.turns[s.id] = list } }
        }
    }

    // MARK: Refresh

    /// Quitting: the widget's data address closes first, so a widget that refreshes now learns the app is gone
    /// instead of reading the last picture again.
    func stopServing() { server.stop() }

    // MARK: The local door

    /// Why the app's local door is not listening, in plain words; nil while it listens (or in a test picture).
    /// Without the door the widget, the dialog words, Allow/Deny and the usage line all get nothing (T-41).
    private(set) var doorProblem: String?

    private func openDoor() {
        do { try server.start() } catch { takeDoor(.failed("\(error)")) }
    }

    private func takeDoor(_ door: SnapshotServer.Door) {
        let next: String?
        if case .failed(let why) = door { next = "The widget, dialog words and usage are off: \(why) (\(server.doorPort))." } else { next = nil }
        if next != doorProblem { doorProblem = next }
    }

    /// The menu's "Try again": the door is opened once more on the same port.
    func openDoorAgain() {
        guard !fixture else { return }
        server.stop()
        openDoor()
    }

    func start() {
        guard !fixture else { return }
        server.onDoorChange = { [weak self] door in
            DispatchQueue.main.async { self?.takeDoor(door) }
        }
        openDoor()
        server.inbox.onChange = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() }
        }
        server.permissions.onChange = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.refresh() }
        }
        server.usage.onChange = { [weak self] in
            DispatchQueue.main.async { self?.takeUsage() }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Claude Code rewrites a file in this folder on every state change: react at once, not on the next tick.
        if let src = sources.first as? ClaudeCodeSource {
            let fd = open(src.registryDirectory, O_EVTONLY)
            if fd >= 0 {
                let w = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
                w.setEventHandler { [weak self] in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.refresh() }
                }
                w.setCancelHandler { Darwin.close(fd) }
                w.resume()
                watcher = w
            }
        }
    }

    func refresh() {
        guard !fixture else { return }
        if refreshing { again = true; return }
        refreshing = true
        let sources = sources, summarizer = summarizer, useSummaries = summariesOn
        work.async { [weak self] in
            // One row per session id, whatever the tools report: the same conversation can briefly be listed by two
            // processes (a resume, a stale registry file), and two rows with one id crashed the app.
            var all = Session.unique(sources.flatMap { $0.sessions() }.filter { !$0.automated })
            var wanted: [String] = []
            if useSummaries, let summarizer {
                all = all.map { s in
                    // Summaries go to a small Claude model through the user's Claude plan. Only Claude Code text is sent
                    // there: another tool's conversation stays on the Mac.
                    guard s.tool == "Claude Code", s.state != .working, let text = s.lastText, text.count > 40 else { return s }
                    if let m = summarizer.cached(text) { return s.applying(m) }
                    if !summarizer.recentlyFailed(text) { wanted.append(text) }
                    return s
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.publish(all)
                for text in wanted { self.summarize(text) }
                self.refreshing = false
                if self.again { self.again = false; self.refresh() }
            }
        }
    }

    /// Brings the newest limits and models on screen. The report's time is refreshed with every tick, so a surface
    /// can say how old the numbers are without redrawing on every report.
    private func takeUsage() {
        let next = server.usage.current()
        if next != usage, !(next?.sameNumbers(as: usage) ?? false) || (next.map { $0.at.timeIntervalSince(usage?.at ?? .distantPast) > 60 } ?? true) {
            usage = next
        }
        let m = server.usage.allModels()
        if m != models { models = m }
    }

    private func summarize(_ text: String) {
        let key = Summarizer.fingerprint(text)
        guard let summarizer, !summarizing.contains(key) else { return }
        summarizing.insert(key)
        summaryQueue.async { [weak self] in
            _ = summarizer.summarize(text)
            DispatchQueue.main.async {
                self?.summarizing.remove(key)
                self?.refresh()
            }
        }
    }

    private func publish(_ all: [Session]) {
        let now = Date()
        hooksCurrent = ClaudeHooks.isInstalled()
        let visible = all.map(withPermissionChoices)
        // A permission request from a session this app does not list (a script's run, a helper) or that is not
        // waiting on a permission prompt is let go of after a few seconds: its terminal, or Claude Code's own rule,
        // decides as if the hook were not there. Held, it would stall that run for ten minutes.
        for ask in server.permissions.all() where now.timeIntervalSince(ask.at) > 8
            && !visible.contains(where: { $0.id == ask.sessionId && $0.waitingFor == "permission prompt" }) {
            server.permissions.letGo(ask.id)
        }
        // A reply has landed once the session moved on from the state the user answered. One that got no reaction in
        // 90 seconds says so: it used to turn back into the question without a word.
        let before = sent
        sent = sent.filter { id, v in visible.contains { $0.id == id && $0.stamp == v.stamp } && now.timeIntervalSince(v.at) < 90 }
        for (id, v) in before where sent[id] == nil {
            if let s = visible.first(where: { $0.id == id }), s.stamp == v.stamp {
                fail(s, "No reaction to “\(Words.clip(v.text, 40))” in 90 seconds. It may not have arrived: check the session in its own window.")
            }
        }
        // A "Not sent" line belongs to the moment it happened: it goes once the session has moved on
        // (and has been readable for a few seconds), or when the session ends.
        errors = errors.filter { id, _ in
            guard let s = visible.first(where: { $0.id == id }) else { return false }
            guard let m = errorMeta[id] else { return true }
            return s.revision == m.revision || now.timeIntervalSince(m.at) < 8
        }
        errorMeta = errorMeta.filter { errors[$0.key] != nil }
        // A session that was closed and has left the list.
        for id in closing.keys where closing[id] == true && !visible.contains(where: { $0.id == id }) {
            closing[id] = nil
            closed.insert(id)
        }
        if turns.keys.contains(where: { id in !visible.contains { $0.id == id } }) {
            turns = turns.filter { id, _ in visible.contains { $0.id == id } }
            turnLimits = turnLimits.filter { id, _ in visible.contains { $0.id == id } }
        }

        // The diary: when a question appeared, and how long it waited before the session moved on.
        let askingNow = Dictionary(visible.filter { $0.state == .asking }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, s) in askingNow where seenAsking[id] == nil {
            seenAsking[id] = s.since
            log?.write("asked", session: s, extra: ["waiting_for": s.waitingFor ?? "end of turn"])
        }
        for (id, since) in seenAsking where askingNow[id] == nil {
            seenAsking[id] = nil
            if let s = visible.first(where: { $0.id == id }) {
                log?.write("answered", session: s, extra: ["waited_s": Int(now.timeIntervalSince(since))])
            } else if let old = sessions.first(where: { $0.id == id }) {
                log?.write("ended_unanswered", session: old, extra: ["waited_s": Int(now.timeIntervalSince(since))])
            }
        }

        if visible != sessions { sessions = visible }
        // While a surface is open, every listed session's last words are read ahead. A session's view opened on
        // one line of summary and jumped to its full height a moment later, when the conversation had been read
        // (seen in a screen recording at 60 frames a second, 2026-11-17).
        // Again when a session has spoken since, so its view does not open on the conversation of a while ago.
        if watching > 0 {
            // Every session once; after that only one that has stopped (a question, an answer finished). A working
            // session changes every few seconds and each read is up to 2 MB of its conversation.
            for s in visible where readAhead[s.id] == nil || (s.state != .working && readAhead[s.id] != s.revision) {
                readAhead[s.id] = s.revision; loadTurns(s)
            }
        }
        readAhead = readAhead.filter { id, _ in visible.contains { $0.id == id } }
        dropStalePending(visible)
        takeUsage()
        refreshLimit()
        loaded = true
        onCount?(asking.count)

        // The widget gets no Allow or Deny: its links can only type, and a permission is answered through the hook.
        let snap = Snapshot.from(visible.filter { !isSent($0) }.map { s in
            guard canDecide(s) else { return s }
            var bare = s; bare.options = []; return bare
        }, now: now, answerable: replyable, runSecret: widgetSecret,
                                 limited: outOfLimit)
        server.update(snap)
        if snap.asking != lastSnapshot?.asking || snap.working != lastSnapshot?.working || snap.done != lastSnapshot?.done
            || snap.limited != lastSnapshot?.limited {
            lastSnapshot = snap
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Asking the editors costs them a process lookup each time, so: when the set of sessions changes, and
        // otherwise only while the user is looking (a surface is open), at most every 15 seconds.
        let ids = Set(visible.map(\.id))
        if ids != checkedIds || (watching > 0 && now.timeIntervalSince(lastReplyCheck) > 15) {
            checkedIds = ids; lastReplyCheck = now; checkReplyRoutes(visible)
        }
    }

    private func checkReplyRoutes(_ list: [Session]) {
        let bridge = bridge
        replyCheck += 1
        let mine = replyCheck
        Task {
            var ok = Set<String>(), old: [(id: String, folder: String, host: String?)] = []
            for s in list where s.tool == "Claude Code" {
                let hit = await bridge.has(pid: s.pid)
                if hit.ok { ok.insert(s.id); continue }
                guard hit.status == 403 else { continue }
                // A refusal counts only for a session inside the app whose window refused: a window with an old
                // secret refuses every call, also for sessions that run in a plain terminal.
                let app = Procs.hostApp(of: s.pid)
                guard BridgeClient.needsReload(hit, sessionApp: app?.path) else { continue }
                // Which window that is: the folder it has open, so the notice can name it.
                let folder = app.flatMap { Hosts.ideFolder(cwd: s.cwd, app: $0) } ?? s.cwd
                old.append((id: s.id, folder: folder, host: app?.deletingPathExtension().lastPathComponent))
            }
            // A newer check started while this one was asking: its answer is the one that counts.
            guard mine == self.replyCheck else { return }
            let stale = Set(old.map(\.id)), windows = ReloadHint.windows(old)
            if ok != self.replyable { self.replyable = ok }
            if stale != self.stale { self.stale = stale }
            if windows != self.staleWindows { self.staleWindows = windows }
        }
    }

    // MARK: Actions

    /// Types the user's answer into the session's own terminal.
    /// - An answer to a question is refused if the session changed since they saw it. A message to a session that is
    ///   working or finished only needs the session to still be there (a working session changes every second).
    /// - Two sends within 0.7 seconds are one: after an answer the next question slides into the same spot, and a
    ///   double-click must never answer that one too.
    /// - One-click answers go alone: files the user attached for a typed reply are not sent with them.
    /// `done` reports whether it went out, so a surface only moves on after a success.
    func send(_ shown: Session, text: String, withAttachments: Bool = true, afterUndo: Bool = false, done: ((Bool) -> Void)? = nil) {
        let now = Date()
        // Nothing is typed into a session being closed (a reply sent in those four seconds went out and the
        // session was ended mid-turn a second later).
        guard closing[shown.id] == nil else { done?(false); return }
        // An answer that already waited out its undo time is not a double click: it skips the 0.7-second rule.
        guard afterUndo || now.timeIntervalSince(lastSend) > 0.7, !sending.contains(shown.id) else { done?(false); return }
        // An Allow or Deny is never typed: it goes through `decide`.
        guard !text.hasPrefix(Self.allowMark), !text.hasPrefix(Self.denyMark) else { done?(false); return }
        let files = withAttachments ? (attachments[shown.id] ?? []) : []
        let message = Reply.compose(text: text, files: files)
        guard !message.isEmpty else { done?(false); return }
        lastSend = now
        guard !fixture else { markSent(shown, message, words: text, files: files.count, typed: withAttachments); done?(true); return }
        if let problem = Reply.problem(message) {
            fail(shown, "Not sent: " + problem)
            done?(false)
            return
        }
        sending.insert(shown.id)
        let bridge = bridge, sources = sources
        Task {
            // Read the session again at the moment of sending.
            let fresh = await Task.detached { Session.unique(sources.flatMap { $0.sessions() }).first { $0.id == shown.id } }.value
            let stillThere = shown.state == .asking ? Reply.stillCurrent(shown: shown, fresh: fresh) : (fresh?.pid == shown.pid)
            var ok = false
            if !stillThere {
                self.fail(shown, shown.state == .asking ? "Not sent: this session moved on while you were answering."
                                                        : "Not sent: this session has ended.")
            } else {
                let hit = await bridge.reply(pid: shown.pid, text: message)
                ok = hit.ok
                if ok {
                    self.markSent(shown, message, words: text, files: files.count, typed: withAttachments)
                    self.log?.write("replied", session: shown, extra: ["waited_s": Int(Date().timeIntervalSince(shown.since)), "chars": message.count])
                } else {
                    self.fail(shown, hit.status == 400 ? "Not sent: that text can't be typed into a session."
                                                       : "Not sent: couldn't reach its terminal. Open its window instead.")
                }
            }
            self.sending.remove(shown.id)
            done?(ok)
            self.refresh()
        }
    }

    // MARK: One-click answers wait, so a slip can be taken back

    /// How long a one-click answer waits before it is typed.
    static let undoSeconds = 4.0
    /// The one-click answers that are waiting out their undo time, by session: the choices the user clicked.
    private(set) var pending: [String: [ReplyOption]] = [:]
    @ObservationIgnored private var pendingWork: [String: DispatchWorkItem] = [:]
    /// The question as it stood at the first click: what is sent is checked against this, not against a later click.
    @ObservationIgnored private var pendingFor: [String: Session] = [:]

    /// A one-click answer (a pill, or ⌘ and a number). It is typed after four seconds unless they take it back:
    /// a click that sends at once would have no way back. A typed reply is sent at once: typing it was deliberate.
    ///
    /// While it waits the user can add a second choice, or click a chosen one again to drop it. A dialog in its own window takes one choice only.
    func answer(_ s: Session, _ option: ReplyOption, done: ((Bool) -> Void)? = nil) {
        guard closing[s.id] == nil else { done?(false); return }
        guard !isSent(s) else { return }
        // A question that changed while an answer was waiting: the waiting answer is over, and this click, made
        // on a card that still showed the old choice, is not an answer to the new question either.
        // The user is told, and answers the new question with a fresh click.
        if let first = pendingFor[s.id], !Reply.stillCurrent(shown: first, fresh: s) {
            undo(s.id)
            fail(s, "Not sent: the question changed before your answer went out.")
            return
        }
        // A fresh answer: an older "Not sent" line on this session has done its job.
        if pendingFor[s.id] == nil { clearError(s.id) }
        if pendingFor[s.id] == nil { pendingFor[s.id] = s }
        let asked = pendingFor[s.id] ?? s
        var chosen = pending[s.id] ?? []
        // A choice is known by what it types, not by its label: a summary arriving late can reword the label, and
        // the same choice must still drop on a second click, not be added twice.
        if let i = chosen.firstIndex(where: { $0.send == option.send }) { chosen.remove(at: i) }
        else if s.certain { chosen = [option] }
        else { chosen.append(option) }
        // In the order the question offers them, whatever order they clicked in.
        chosen.sort { a, b in
            (s.options.firstIndex { $0.send == a.send } ?? 0) < (s.options.firstIndex { $0.send == b.send } ?? 0)
        }
        pendingWork[s.id]?.cancel()
        pendingWork[s.id] = nil
        guard !chosen.isEmpty else { undo(s.id); return }
        pending[s.id] = chosen
        let work = DispatchWorkItem { [weak self] in
            guard let self, let chosen = self.pending[s.id] else { return }
            self.undo(s.id)
            guard !self.isSent(asked) else { done?(false); return }
            if let p = chosen.first(where: Self.isPermission) { self.decide(asked, p, done: done); return }
            // The send reads the session again and compares it with the question as it stood at the first click:
            // an answer to a question that changed meanwhile is refused.
            self.send(asked, text: chosen.map(\.send).joined(separator: " + "), withAttachments: false, afterUndo: true, done: done)
        }
        pendingWork[s.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds, execute: work)
    }

    /// The choices waiting for this question, as it stands now. A question that changed has none: its card never
    /// shows the choice made for the question before it.
    func waiting(_ s: Session) -> [ReplyOption]? {
        guard let chosen = pending[s.id], let first = pendingFor[s.id], Reply.stillCurrent(shown: first, fresh: s) else { return nil }
        return chosen
    }

    /// Ends the waiting answers whose question has really changed, and says so on the session.
    /// "Changed" is what the send itself checks (`Reply.stillCurrent`: the same process and the same record from the
    /// tool): a summary arriving late, which only rewords what is shown, does not count. A session that is merely
    /// missing from one read keeps its waiting answer: the send looks again when the four seconds are over, and
    /// refuses with its own message if the session is really gone. Dropping on a missing read, or on a reworded
    /// label, lost an answer the user had given, without a word.
    func dropStalePending(_ list: [Session]) {
        for (id, first) in pendingFor {
            guard let now = list.first(where: { $0.id == id }), !Reply.stillCurrent(shown: first, fresh: now) else { continue }
            let permission = pending[id]?.contains(where: Self.isPermission) ?? false
            undo(id)
            // The true reason: a session restarted in a new process has not changed its question, and a permission
            // prompt that moves on while Allow or Deny waits was answered in its window (verifier 1 of T-30).
            fail(now, now.pid != first.pid ? "Not sent: the session was restarted before your answer went out."
                      : permission ? "Not sent: it was already answered in its own window."
                                   : "Not sent: the question changed before your answer went out.")
        }
    }

    /// Takes a waiting answer back: nothing is typed and the question stands as it was.
    func undo(_ id: String) {
        pendingWork[id]?.cancel()
        pendingWork[id] = nil
        pendingFor[id] = nil
        if pending[id] != nil { pending[id] = nil }
    }

    /// An answer clicked in the widget. It is typed only when everything still holds: the link came from a widget
    /// that read this run's snapshot, the question is the one the widget showed, and the session can be typed into.
    /// Anything else reports false, and the caller shows the session instead of answering blind.
    func answerFromWidget(session id: String, option n: Int, mark: String, secret: String, done: @escaping (Bool) -> Void) {
        // A second click on the same answer (a double click) is the first one again, not a failure: nothing more
        // is typed and nothing opens.
        if secret == widgetSecret, let s = session(id), isSent(s) || sending.contains(id) { done(true); return }
        guard secret == widgetSecret, let s = session(id), s.state == .asking, !isSent(s), canReply(s),
              n < s.options.count, Snapshot.mark(s.stamp) == mark else { done(false); return }
        // A widget link never answers a permission prompt, and never cancels an Allow or Deny waiting in the app.
        guard !canDecide(s) else { done(false); return }
        // An answer still waiting out its undo time in the app makes way: one question, one answer.
        undo(id)
        send(s, text: s.options[n].send, withAttachments: false, done: done)
    }

    // MARK: Closing a session

    /// Sessions being closed: false while the undo time runs, true once the session has been asked to quit.
    private(set) var closing: [String: Bool] = [:]
    /// The state of each session's record when its conversation was last read ahead of a click.
    @ObservationIgnored private var readAhead: [String: String] = [:]
    @ObservationIgnored private var tidiedPictures = false
    @ObservationIgnored private var closeWork: [String: DispatchWorkItem] = [:]
    /// The process each of them had at the click.
    @ObservationIgnored private var closePid: [String: Int32] = [:]
    /// Sessions that quit because the user closed them: the window moves on at once instead of holding their view.
    @ObservationIgnored private(set) var closed: Set<String> = []

    func canClose(_ s: Session) -> Bool { fixture ? s.tool == "Claude Code" : Closing.offered(tool: s.tool, pid: s.pid) }

    /// One click, then the same few seconds to take it back as a one-click answer has. Nothing is asked first: the
    /// conversation is kept and can be picked up again, and the Undo is right where the click was. From the click
    /// on nothing is typed into the session any more: its message box and answers rest until Undo.
    func close(_ s: Session) {
        guard canClose(s), closing[s.id] == nil else { return }
        // An answer still waiting out its own undo time is not typed into a session being closed.
        undo(s.id)
        clearError(s.id)
        closing[s.id] = false
        closePid[s.id] = s.pid
        let work = DispatchWorkItem { [weak self] in self?.closeNow(s.id) }
        closeWork[s.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoSeconds, execute: work)
    }

    func undoClose(_ id: String) {
        guard closing[id] == false else { return }
        closeWork[id]?.cancel()
        closeWork[id] = nil
        closing[id] = nil
        closePid[id] = nil
    }

    private func closeNow(_ id: String) {
        closeWork[id] = nil
        guard closing[id] == false else { return }
        let pid = closePid[id] ?? 0
        closePid[id] = nil
        // The session as it is now, not as it was at the click.
        guard let s = session(id) else {
            closing[id] = nil
            // Its process goes on under another name: the user began a new conversation in it meanwhile.
            if let now = sessions.first(where: { $0.pid == pid && pid > 1 }) {
                fail(now, "Not closed: this session began a new conversation since you clicked. Click “Close session” again to close it.", keep: 30)
            }
            return
        }
        if fixture {
            onOutside?("The session “\(s.title)” would be asked to quit in its own terminal (outside ClockOffice).")
            closing[id] = nil
            closed.insert(id)
            sessions.removeAll { $0.id == id }
            onCount?(asking.count)
            return
        }
        let ok = s.pid == pid && Closing.close(pid: s.pid, sessionId: s.id)
        log?.write("closed", session: s, extra: ["ok": ok, "state": s.state.rawValue])
        guard ok else {
            closing[id] = nil
            fail(s, "Not closed: this session has changed since you clicked. Close it in its own window.", keep: 30)
            return
        }
        closing[id] = true
        // It leaves the list on the next look. One that does not quit is said, not left "closing" for good.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.closing[id] == true else { return }
            self.closing[id] = nil
            if let still = self.session(id), Procs.alive(still.pid) {
                self.fail(still, "It was asked to quit and is still running. Close it in its own window.", keep: 60)
            }
        }
    }

    /// `keep`: how long the line stays at least, also when the session moves on meanwhile.
    private func fail(_ s: Session, _ text: String, keep: TimeInterval = 8) {
        errors[s.id] = text
        errorMeta[s.id] = (s.revision, Date().addingTimeInterval(keep - 8))
    }

    /// The user is typing again: the old "Not sent" line has done its job.
    func clearError(_ id: String) {
        if errors[id] != nil { errors[id] = nil; errorMeta[id] = nil }
    }

    private func markSent(_ s: Session, _ message: String, words typed: String, files n: Int, typed fromBox: Bool) {
        // The user reads back their own words; attached files show as a count, not as paths.
        let words = Reply.clean(typed)
        let shown = n == 0 ? message : (words.isEmpty ? "" : words + " + ") + "\(n) file\(n == 1 ? "" : "s")"
        sent[s.id] = (shown, s.stamp, Date())
        if fromBox { drafts[s.id] = ""; attachments[s.id] = [] }
        clearError(s.id)
        onCount?(asking.count)
    }

    func attach(_ id: String, paths: [String]) {
        var list = attachments[id] ?? []
        for p in paths where !list.contains(p) { list.append(p) }
        attachments[id] = list
    }

    func detach(_ id: String, path: String) {
        attachments[id] = (attachments[id] ?? []).filter { $0 != path }
    }

    /// Saves a pasted screenshot next to the app's data and attaches its path.
    func attachImage(_ id: String, png: Data) {
        let dir = Self.supportDirectory.appendingPathComponent("attachments")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let file = dir.appendingPathComponent("Pasted-\(f.string(from: Date())).png")
        if (try? png.write(to: file)) != nil { attach(id, paths: [file.path]) }
    }

    /// Brings the session's own window forward: the exact terminal tab when its editor has the extension.
    func openWindow(_ s: Session) {
        guard !fixture else { onOutside?("The session “\(s.title)” would come to the front in its own editor or terminal window (outside ClockOffice)."); return }
        log?.write("opened", session: s, extra: ["waited_s": Int(Date().timeIntervalSince(s.since))])
        if s.tool != "Claude Code" {
            // Every conversation of another tool carries that tool's one process, which sits in no terminal: there
            // is no tab to pick. Its app comes forward; an editor with the window of this folder.
            Hosts.bringForward(session: s, editorFolder: nil, ownFolder: true)
            return
        }
        let bridge = bridge
        Task {
            let hit = await bridge.reveal(pid: s.pid)
            Hosts.bringForward(session: s, editorFolder: hit.ok ? hit.folder : nil)
        }
    }

    /// Brings an editor window that needs a reload to the front, so ⇧⌘P lands in the right one.
    func show(_ w: StaleWindow) {
        guard let s = w.sessionIds.lazy.compactMap({ self.session($0) }).first else { return }
        openWindow(s)
    }

    /// A link in a session's words. A web address opens in the browser; a page, a picture or a document with its
    /// own app; any other file in the editor the session runs in (at its line, when the link names one), as a
    /// click in that session's own chat would.
    func openLink(_ url: URL, from s: Session) {
        let url = Linker.outer(url) ?? url
        if fixture {
            onOutside?(url.isFileURL ? "The file “\(url.lastPathComponent)” would open (outside ClockOffice)."
                                     : "The page \(url.absoluteString) would open in the web browser (outside ClockOffice).")
            return
        }
        // What a click may do is decided in one place (`Linker.click`): nothing a conversation says is ever run.
        switch Linker.click(url) {
        case .web(let page):
            NSWorkspace.shared.open(page)
        case .view(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .reveal(let path):
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        case .edit(let path, let line):
            let file = URL(fileURLWithPath: path)
            guard let app = Procs.hostApp(of: s.pid),
                  let editor = Hosts.editors().first(where: { $0.name == app.deletingPathExtension().lastPathComponent }) else {
                // No editor known for this session: the file is shown, not handed to whatever app claims its type.
                NSWorkspace.shared.activateFileViewerSelecting([file])
                return
            }
            if let line {
                work.async { _ = Shell.run(editor.cli, ["-g", "\(path):\(line)"], timeout: 10) }
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.open([file], withApplicationAt: app, configuration: cfg)
            }
        case .nothing:
            NSSound.beep()
        }
    }

    func openRemote(_ s: Session) {
        if fixture { onOutside?("The page of “\(s.title)” on claude.ai would open in the web browser (outside ClockOffice)."); return }
        guard let url = s.remoteURL else { return }
        // In the Claude desktop app when it is on this Mac, in the browser when it is not.
        if let link = RemoteLink.desktop(for: url),
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: RemoteLink.desktopApp) {
            log?.write("opened_remote", session: s, extra: ["in": "desktop app"])
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.open([link], withApplicationAt: app, configuration: cfg) { _, error in
                if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
            }
            return
        }
        log?.write("opened_remote", session: s, extra: ["in": "browser"])
        NSWorkspace.shared.open(url)
    }
}
