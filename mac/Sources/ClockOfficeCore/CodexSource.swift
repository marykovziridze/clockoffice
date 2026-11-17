import Foundation

/// Codex (OpenAI's coding agent: the ChatGPT extension in an editor, the Codex app, the `codex` command) as a
/// second source of sessions, read-only.
///
/// What this rests on, read on one Mac on 2026-11-16 (extension openai.chatgpt 26.1111; the newest conversation there
/// then was of 2026-10-08, so the format of a conversation written by the current version is unsure):
/// - Codex writes each conversation to ~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl, one JSON object a
///   line: {timestamp, type, payload}. The folder is the day the conversation STARTED; Codex goes on writing there
///   on later days (a file in the 2026-09-04 folder was still changing on 7 September).
/// - The opening line (`session_meta`) carries the folder (`cwd`) and whether the thread is the user's
///   (`thread_source` "user") or one of Codex's helpers ("guardian_review").
/// - `event_msg` lines with payload.type `task_started`, `task_complete` (with `last_agent_message`) and
///   `turn_aborted` bracket each turn.
/// - `response_item` lines with payload.type `message` hold what was said: role `user` (content parts of type
///   `input_text`) and `assistant` (`output_text`). Single lines can be many megabytes (tool output: 13.7 MB seen).
/// Codex keeps no list of the conversations that are open, so "running" is judged from the record: a conversation
/// whose file changed within the last eight hours is listed. Nothing is written to Codex's folder, no Codex
/// setting is changed, and only conversation files are read. Answering a Codex conversation from here is not
/// possible: it has no terminal to type into.
public struct CodexSource: SessionSource {
    public let tool = "Codex"
    public var home: String
    /// How long after its last change a conversation is still listed.
    public var listedFor: TimeInterval = 8 * 3600
    /// A turn that started but wrote nothing for this long was stopped or its window was closed.
    public var stalledAfter: TimeInterval = 30 * 60
    /// How many day-folders back a conversation may have started and still be found.
    public var daysBack = 45

    public init(home: String = NSHomeDirectory()) { self.home = home }

    public func sessions() -> [Session] { sessions(now: Date(), pid: Self.process()) }

    func sessions(now: Date, pid: Int32) -> [Session] {
        let list = files(now: now)
        Self.forget(under: home, except: Set(list.map(\.path)))
        return list.compactMap { session(file: $0.path, changed: $0.changed, now: now, pid: pid) }
    }

    public func conversation(for s: Session, limit: Int) -> [Turn] {
        guard let file = files(now: Date()).first(where: { Self.id(of: $0.path) == s.id }) else { return [] }
        return Array(Self.parsed(file.path, changed: file.changed).record.turns.suffix(limit))
    }

    // MARK: Files

    private static let lock = NSLock()
    /// Per home folder: the conversation files of the last weeks, listed afresh at most twice a minute.
    nonisolated(unsafe) private static var listed: [String: (at: Date, paths: [String])] = [:]

    private func dayFolder(_ day: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: day)
        return String(format: "%@/.codex/sessions/%04d/%02d/%02d", home, c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func rollouts(in dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("rollout-") && $0.hasSuffix(".jsonl") }.map { dir + "/" + $0 }
    }

    /// The conversation files that changed within `listedFor`. A conversation lives in the folder of the day it
    /// started, so twice a minute the folders of the last `daysBack` days are listed and the files in use kept; in
    /// between only those, and the folders of today and yesterday (a new conversation shows at once, also one
    /// started just before midnight), are asked for their time of last change. An old conversation the user picks up
    /// again shows within half a minute.
    func files(now: Date) -> [(path: String, changed: Date)] {
        func inUse(_ paths: some Sequence<String>) -> [(path: String, changed: Date)] {
            paths.compactMap { path in
                guard let changed = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(changed) < listedFor else { return nil }
                return (path, changed)
            }
        }
        // By calendar days, not 24 hours at a time: that skipped the 23-hour day of the clock change.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        func folder(daysAgo: Int) -> String? { cal.date(byAdding: .day, value: -daysAgo, to: now).map(dayFolder) }
        Self.lock.lock()
        var known = Self.listed[home]
        Self.lock.unlock()
        if known == nil || abs(now.timeIntervalSince(known!.at)) > 30 {
            let all = (0...daysBack).compactMap(folder).flatMap(Self.rollouts)
            known = (now, inUse(all).map(\.path))
            Self.lock.lock(); Self.listed[home] = known; Self.lock.unlock()
        }
        let near = [0, 1].compactMap(folder).flatMap(Self.rollouts)
        return inUse(Set(known!.paths).union(near)).sorted { $0.changed > $1.changed }
    }

    /// "rollout-2026-10-08T16-59-59-01a11c07-3d98-7f11-a197-03cb522cd207.jsonl" → the id at its end.
    static func id(of path: String) -> String {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return name.count >= 36 ? String(name.suffix(36)) : name
    }

    // MARK: Reading

    public struct Record {
        public var cwd: String?
        public var startedAt: Date?
        public var completedAt: Date?
        /// The last turn was stopped by the user (or by an error) and did not complete.
        public var aborted = false
        public var lastAgentMessage: String?
        public var lastUserMessage: String?
        public var firstUserMessage: String?
        public var turns: [Turn] = []
        var counter = 0
        /// A turn is under way: the last turn event in the file is a start. By the order of the lines, not by
        /// their times (a start stamped before the stop above it, or with no time, read as done).
        var running = false
        var sawEvent = false
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private static let request = Rx(#"(?m)^## My request(?: for Codex)?:[ \t]*$"#, [])

    /// What the user typed, out of what Codex stored as their message. Seen in real files (2026-11-16): the editor's
    /// extension stores "# Context from my IDE setup: / ## Active file: … / ## Open tabs: … / ## My request:"
    /// followed by the user's words; blocks that open with a tag, and pages of instructions (24,000 characters and more,
    /// with no request in them), are the tool's own.
    static func usersWords(_ text: String) -> String? {
        let ns = text as NSString
        if let m = request.re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last {
            let said = ns.substring(from: m.range.location + m.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
            return said.isEmpty ? nil : said
        }
        if text.hasPrefix("<") || text.hasPrefix("# Context from my IDE setup") || text.count > 4000 { return nil }
        return text
    }

    /// The opening line: is the thread the user's, and in which folder. A file whose opening line cannot be read is
    /// taken as the user's.
    static func opening(_ file: String) -> (usersOwn: Bool, cwd: String?) {
        guard let fh = FileHandle(forReadingAtPath: file) else { return (false, nil) }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 524_288)) ?? Data()
        guard let end = head.firstIndex(of: UInt8(ascii: "\n")),
              let o = (try? JSONSerialization.jsonObject(with: head[..<end])) as? [String: Any],
              let p = o["payload"] as? [String: Any] else { return (true, nil) }
        let cwd = p["cwd"] as? String
        if let t = p["thread_source"] as? String, t != "user" { return (false, cwd) }
        if let src = p["source"] as? [String: Any], src["subagent"] != nil { return (false, cwd) }
        return (true, cwd)
    }

    private static let userRole = Data(#""role":"user""#.utf8)
    private static let eventType = Data(#""type":"event_msg""#.utf8)

    /// A very long line is tool output (13.7 MB seen) and is passed over unread, unless its opening says it is one
    /// of the user's or a turn event: a message with a pasted screenshot is one line of about a megabyte, and passing
    /// it over made the second message the title.
    private static func worthReading(_ raw: Data.SubSequence) -> Bool {
        guard raw.count >= 524_288 else { return true }
        guard raw.count < 32 * 1_048_576 else { return false }
        // In Codex's own files the type and the role come first (23 long lines of these kinds in real files, 2026-11-16);
        // the end of the line is looked at too, in case the order of the keys ever changes.
        return [raw.prefix(400), raw.suffix(400)].contains { $0.range(of: userRole) != nil || $0.range(of: eventType) != nil }
    }

    /// One line of the file, added to what is known.
    private static func take(_ raw: Data.SubSequence, into r: inout Record) {
        guard worthReading(raw),
              let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
              let type = o["type"] as? String, let p = o["payload"] as? [String: Any] else { return }
        let at = date(o["timestamp"])
        r.counter += 1
        switch (type, p["type"] as? String) {
        case ("session_meta", _), ("turn_context", _):
            if let cwd = p["cwd"] as? String { r.cwd = cwd }
        case ("event_msg", "task_started"):
            r.startedAt = at; r.aborted = false; r.running = true; r.sawEvent = true
        case ("event_msg", "task_complete"):
            r.completedAt = at; r.aborted = false; r.running = false; r.sawEvent = true
            if let m = p["last_agent_message"] as? String, !m.isEmpty { r.lastAgentMessage = m }
        case ("event_msg", "turn_aborted"):
            // The user stopped the turn: it is over, without a closing message.
            r.completedAt = at; r.aborted = true; r.running = false; r.sawEvent = true
        case ("response_item", "message"):
            let role = p["role"] as? String
            guard role == "user" || role == "assistant" else { return }
            let text = ((p["content"] as? [[String: Any]]) ?? [])
                .filter { ["input_text", "output_text"].contains($0["type"] as? String ?? "") }
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let id = (p["id"] as? String) ?? "codex-\(r.counter)"
            if role == "user" {
                // The user's own words only: the editor's extension wraps them in a block about the open files.
                guard let said = usersWords(text) else { return }
                if r.firstUserMessage == nil { r.firstUserMessage = said }
                r.lastUserMessage = said
                r.turns.append(Turn(id: id, who: .you, text: Words.tidyPrompt(Redactor.redact(said)), at: at))
            } else {
                guard !text.hasPrefix("<") else { return }
                let turn = Turn(id: id, who: .assistant, text: Redactor.redact(text), at: at)
                // Within one turn only the latest words stand; earlier progress lines are replaced.
                if r.turns.last?.who == .assistant { r.turns[r.turns.count - 1] = turn } else { r.turns.append(turn) }
            }
            if r.turns.count > 60 { r.turns.removeFirst(r.turns.count - 60) }
        default: break
        }
    }

    /// Reads the bytes from `start` to the end of the file, whole lines only, and adds them to `record`.
    /// Returns the place after the last whole line: a line still being written is left for the next read.
    /// Assumption: Codex only ever adds to a conversation file (every file read on 2026-11-16 is in time order).
    private static func readOn(_ fh: FileHandle, from start: Int, size: Int, skipFirst: Bool, into record: inout Record) -> Int {
        guard size > start else { return start }
        try? fh.seek(toOffset: UInt64(start))
        let data = (try? fh.read(upToCount: size - start)) ?? Data()
        var at = data.startIndex, consumed = start, first = true
        while let nl = data[at...].firstIndex(of: UInt8(ascii: "\n")) {
            if !(first && skipFirst) { take(data[at..<nl], into: &record) }
            first = false
            at = data.index(after: nl)
            consumed = start + (at - data.startIndex)
        }
        // The last line has no line end yet. If it is already a whole JSON object it counts (a cut-off object never
        // parses, so a line still being written is left for the next read).
        if at < data.endIndex, !(first && skipFirst) {
            let rest = data[at...]
            if worthReading(rest), (try? JSONSerialization.jsonObject(with: Data(rest))) is [String: Any] {
                take(rest, into: &record)
                consumed = start + data.count
            }
        }
        return consumed
    }

    // MARK: What was read, kept until the file changes

    private struct Entry {
        var changed: Date
        var usersOwn: Bool
        /// Up to where the file has been read (the end of the last whole line).
        var readTo: Int
        var record: Record
        /// The bytes just before `readTo`: if they are no longer there, the file is not the one that was read.
        var mark = Data()
    }

    private static func mark(_ fh: FileHandle, upTo end: Int) -> Data {
        let start = max(0, end - 64)
        try? fh.seek(toOffset: UInt64(start))
        return (try? fh.read(upToCount: end - start)) ?? Data()
    }
    /// The app looks for sessions every few seconds. A conversation file is read again only when it has changed,
    /// and then only what was added to it: reading megabytes of each recent file on every look, or the whole of a
    /// file that grows by a line a second, would be work for nothing.
    nonisolated(unsafe) private static var cache: [String: Entry] = [:]

    public static func parsed(_ path: String, changed: Date) -> (usersOwn: Bool, record: Record) {
        lock.lock()
        let old = cache[path]
        lock.unlock()
        if let old, old.changed == changed { return (old.usersOwn, old.record) }
        guard let fh = FileHandle(forReadingAtPath: path) else { return (false, Record()) }
        defer { try? fh.close() }
        let size = Int((try? fh.seekToEnd()) ?? 0)
        var entry: Entry
        if let old, old.usersOwn, old.readTo > 0, size >= old.readTo, mark(fh, upTo: old.readTo) == old.mark {
            // Only what was added since the last read. (A file that was replaced by another is read afresh.)
            entry = old
            entry.changed = changed
            entry.readTo = readOn(fh, from: old.readTo, size: size, skipFirst: false, into: &entry.record)
        } else {
            let open = opening(path)
            entry = Entry(changed: changed, usersOwn: open.usersOwn, readTo: 0, record: Record())
            if open.usersOwn {
                // From the end, in a window that grows until a turn's start or end is in it: the last megabyte can
                // be one long line of tool output with nothing else in it.
                var window = 1_048_576
                while true {
                    let start = max(0, size - window)
                    var record = Record()
                    let readTo = readOn(fh, from: start, size: size, skipFirst: start > 0, into: &record)
                    entry.record = record
                    entry.readTo = readTo
                    if record.sawEvent || start == 0 || window >= 64 * 1_048_576 { break }
                    window *= 4
                }
                if entry.record.cwd == nil { entry.record.cwd = open.cwd }
                // Read from somewhere in the middle: the title is still the user's first message, which is at the start
                // (it changed as the conversation grew).
                if entry.readTo > 0, size > 1_048_576 {
                    var head = Record()
                    _ = readOn(fh, from: 0, size: min(size, 4 * 1_048_576), skipFirst: false, into: &head)
                    if let first = head.firstUserMessage { entry.record.firstUserMessage = first }
                }
            }
        }
        entry.mark = mark(fh, upTo: entry.readTo)
        lock.lock(); cache[path] = entry; lock.unlock()
        return (entry.usersOwn, entry.record)
    }

    private static func forget(under home: String, except keep: Set<String>) {
        lock.lock(); defer { lock.unlock() }
        for path in cache.keys where path.hasPrefix(home + "/") && !keep.contains(path) { cache[path] = nil }
    }

    // MARK: A session from a record

    public func session(file: String, changed: Date, now: Date, pid: Int32) -> Session? {
        // Codex's own helper threads (its "guardian" reviewer writes a second file for the same conversation,
        // found in real files on 2026-11-16) are not the user's conversations.
        let read = Self.parsed(file, changed: changed)
        guard read.usersOwn else { return nil }
        let r = read.record
        // A file with nothing said in it (a conversation opened and left) is not a session to show.
        guard let cwd = r.cwd, r.sawEvent || r.lastAgentMessage != nil || !r.turns.isEmpty else { return nil }
        let project = Words.prettyProject((cwd as NSString).lastPathComponent)
        let said = r.firstUserMessage ?? r.lastUserMessage
        let title = said.map { Words.clip(Words.tidyPrompt(Redactor.redact($0)), 60) } ?? project
        var s = Session(id: Self.id(of: file), tool: tool, pid: pid, cwd: cwd, project: project, title: title,
                        state: .done, since: changed)
        let last = (r.aborted ? r.turns.last(where: { $0.who == .assistant })?.text
                              : (r.lastAgentMessage ?? r.turns.last(where: { $0.who == .assistant })?.text)).map(Redactor.redact)
        s.lastText = last.map { Words.clip($0, 6000) }

        // A turn is under way when the last "started" has no "complete" or "aborted" after it, and the file still moves.
        let running = r.running
        if running, now.timeIntervalSince(changed) < stalledAfter {
            s.state = .working
            s.since = r.startedAt ?? changed
            if let p = r.lastUserMessage { s.inShort = "Working on: " + Words.clip(Words.tidyPrompt(Redactor.redact(p)), 140) }
        } else {
            let v = Classifier.classify(last)
            if v.asks, !running, !r.aborted {
                s.state = .asking
                s.question = v.question
                s.headline = v.question.map { Words.clip($0, 90) }
                // No one-click answers: a Codex conversation cannot be typed into from here.
            }
            s.inShort = r.aborted ? "You stopped this turn." : last.map { ClaudeCodeSource.firstSentences($0, 220) }
            s.lastDid = s.inShort
            if let at = r.completedAt { s.since = at }
        }
        s.revision = [s.state.rawValue, String(Int(changed.timeIntervalSince1970 * 1000)),
                      last.map(Summarizer.fingerprint) ?? "-"].joined(separator: "|")
        return s
    }

    // MARK: The process

    nonisolated(unsafe) private static var cached: (pid: Int32, at: Date) = (0, .distantPast)

    /// A running Codex process, so "Show in …" can name the app it lives in. Looked up at most twice a minute.
    /// Every Codex conversation gets this same process: it says where Codex runs, never which conversation is whose,
    /// and it is never used to type anything (see `Store.canReply`).
    static func process() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        if Date().timeIntervalSince(cached.at) < 30, cached.pid == 0 || Procs.alive(cached.pid) { return cached.pid }
        let r = Shell.run("/usr/bin/pgrep", ["-f", "/codex( |$)"], timeout: 3)
        let pids = r.stdout.split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
        let pid = pids.first { Procs.hostApp(of: $0) != nil } ?? pids.first ?? 0
        cached = (pid, Date())
        return pid
    }
}
