import Foundation

/// Claude Code sessions on this Mac, whichever app they run in (VS Code, Antigravity, a terminal, the desktop app).
///
/// Truth order:
/// 1. The session registry Claude Code keeps per process (`~/.claude/sessions/<pid>.json`): status busy / waiting / idle
///    and what it waits for. This is the same data `claude agents --json` prints; if the files cannot be read,
///    that documented command is the fallback.
/// 2. Only for an idle session: its last message, to tell a question from a finished report.
public final class ClaudeCodeSource: SessionSource, @unchecked Sendable {
    public let tool = "Claude Code"
    let home: String
    private let lock = NSLock()
    private var tails: [String: (size: UInt64, mtime: Date, tail: TranscriptTail)] = [:]

    /// Questions handed over by the optional Claude Code hook (see HookInbox). Nil when hooks are not used.
    public var inbox: HookInbox?

    public init(home: String = NSHomeDirectory(), inbox: HookInbox? = nil) { self.home = home; self.inbox = inbox }

    struct Row {
        var pid: Int32, sessionId: String, cwd: String, kind: String, entrypoint: String
        var name: String?, status: String, waitingFor: String?, changed: Date, remote: String?
    }

    public func sessions() -> [Session] {
        var rows = registryRows()
        if rows == nil { rows = cliRows() }
        return (rows ?? []).filter { Procs.alive($0.pid) }.map(session(from:))
    }

    /// The last few things said in a session, for its details view.
    public func conversation(for s: Session, limit: Int) -> [Turn] {
        Transcript.recent(file: Transcript.path(cwd: s.cwd, sessionId: s.id, home: home), limit: limit)
    }

    /// The folder Claude Code's own registry lives in, watched by the app for instant updates.
    public var registryDirectory: String { "\(home)/.claude/sessions" }

    func registryRows() -> [Row]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: registryDirectory) else { return nil }
        var rows: [Row] = []
        for n in names where n.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: "\(registryDirectory)/\(n)"),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let row = Self.row(o) else { continue }
            rows.append(row)
        }
        return rows
    }

    func cliRows() -> [Row]? {
        guard let bin = ClaudeBinary.locate() else { return nil }
        let r = Shell.run(bin, ["agents", "--json"], timeout: 10)
        guard r.status == 0, let data = r.stdout.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return arr.compactMap(Self.row)
    }

    static func row(_ o: [String: Any]) -> Row? {
        guard let pid = (o["pid"] as? NSNumber)?.int32Value, let sid = o["sessionId"] as? String,
              let cwd = o["cwd"] as? String else { return nil }
        let ms = (o["statusUpdatedAt"] as? NSNumber) ?? (o["updatedAt"] as? NSNumber) ?? (o["startedAt"] as? NSNumber)
        return Row(pid: pid, sessionId: sid, cwd: cwd,
                   kind: o["kind"] as? String ?? "interactive", entrypoint: o["entrypoint"] as? String ?? "",
                   name: o["name"] as? String, status: o["status"] as? String ?? "idle",
                   waitingFor: o["waitingFor"] as? String,
                   changed: Date(timeIntervalSince1970: (ms?.doubleValue ?? 0) / 1000),
                   remote: o["bridgeSessionId"] as? String)
    }

    func tail(for row: Row) -> TranscriptTail {
        let file = Transcript.path(cwd: row.cwd, sessionId: row.sessionId, home: home)
        let attrs = try? FileManager.default.attributesOfItem(atPath: file)
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = attrs?[.modificationDate] as? Date ?? .distantPast
        lock.lock()
        if let c = tails[file], c.size == size, c.mtime == mtime { lock.unlock(); return c.tail }
        lock.unlock()
        let t = Transcript.tail(file: file)
        lock.lock(); tails[file] = (size, mtime, t); lock.unlock()
        return t
    }

    func session(from row: Row) -> Session {
        let folder = (row.cwd as NSString).lastPathComponent
        // A session inside a Claude worktree belongs to the project above it.
        let project: String = {
            if let r = row.cwd.range(of: "/.claude/worktrees/") {
                return Words.prettyProject((String(row.cwd[..<r.lowerBound]) as NSString).lastPathComponent)
            }
            return Words.prettyProject(folder)
        }()
        let t = tail(for: row)
        var s = Session(
            id: row.sessionId, tool: tool, pid: row.pid, cwd: row.cwd, project: project,
            title: t.title ?? row.name ?? project, state: .done, since: row.changed,
            remoteURL: row.remote.flatMap { URL(string: "https://claude.ai/code/\($0)") },
            automated: row.kind.lowercased().contains("sdk") || row.entrypoint.lowercased().contains("sdk"))
        let last = t.lastAssistantText.map(Redactor.redact)
        s.lastText = last.map { Words.clip($0, 6000) }

        var dialogAt: Date?
        if row.status != "waiting" {
            // The session moved on after the dialog arrived: it was answered, so it is never shown again.
            inbox?.clear(row.sessionId, ifBefore: row.changed)
        }
        switch row.status {
        case "busy":
            s.state = .working
            if let p = t.lastPrompt { s.inShort = "Working on: " + Words.clip(Words.tidyPrompt(Redactor.redact(p)), 140) }
            s.lastDid = last.map { Self.firstSentences($0, 200) }
        case "waiting":
            s.state = .asking
            s.certain = true
            s.waitingFor = row.waitingFor
            // While a dialog is open Claude Code has not yet written it to the transcript (measured 2026-11-16 on
            // 2.1.325), so the hook's copy, when there is one, is the only place its words exist.
            // The hook fires a moment before the status flips to waiting, so a dialog counts for this wait only if
            // it arrived no more than 10 seconds before it, and is the kind this wait is for.
            var handed = inbox?.dialog(for: row.sessionId, notBefore: row.changed.addingTimeInterval(-10))
            if let h = handed, (h.toolName == "AskUserQuestion") != (row.waitingFor == "input needed") { handed = nil }
            dialogAt = handed?.at
            Self.fillFromDialog(&s, toolName: t.pendingToolName ?? handed?.toolName,
                                input: t.pendingToolInput ?? handed?.input ?? [:], last: last)
        default:
            guard !t.userSpokeLast else {
                // The user's message is the newest thing: nothing is pending on their side.
                s.inShort = t.lastPrompt.map { "You said: " + Words.clip(Words.tidyPrompt(Redactor.redact($0)), 140) }
                break
            }
            let v = Classifier.classify(last)
            if v.asks {
                s.state = .asking
                s.question = v.question
                s.headline = v.question.map { Words.clip($0, 90) }
                s.options = v.options
            }
            s.inShort = last.map { Self.firstSentences($0, 220) }
            s.lastDid = s.inShort
            if let at = t.lastAssistantAt, at > s.since { s.since = at }
        }
        s.revision = [row.status, String(Int(row.changed.timeIntervalSince1970 * 1000)),
                      last.map(Summarizer.fingerprint) ?? "-", t.userSpokeLast ? "u" : "a",
                      dialogAt.map { String(Int($0.timeIntervalSince1970 * 1000)) } ?? "-"].joined(separator: "|")
        return s
    }

    /// The question behind an official "waiting": a question dialog, a permission prompt, or something only its window shows.
    static func fillFromDialog(_ s: inout Session, toolName: String?, input: [String: AnySendable], last: String?) {
        if toolName == "AskUserQuestion",
           let questions = input["questions"]?.array, let first = questions.first?.object, let q = first["question"]?.string {
            s.question = Redactor.redact(q)
            if questions.count > 1 {
                // Several questions in one dialog are answered one after another in its window.
                s.question = "\(questions.count) questions, starting with: " + (s.question ?? "")
            } else if case .bool(true)? = first["multiSelect"] {
                // Tick-several lists need the window too.
            } else {
                // Numbered the way the dialog numbers them; the number plus Enter picks it
                // (checked against Claude Code 2.1.325 on 2026-11-16).
                s.options = (first["options"]?.array ?? []).enumerated().compactMap { i, o in
                    guard let label = o.object?["label"]?.string else { return nil }
                    return ReplyOption(label: Words.clip(label, 32), send: String(i + 1))
                }
            }
        } else if s.waitingFor == "permission prompt", let name = toolName {
            let detail = ["command", "file_path", "url", "description", "prompt"].lazy
                .compactMap { input[$0]?.string }.first
            // Long enough to hold a whole command: Allow can be clicked in the app, so what it allows must be readable
            // there in full (the list shows its short headline and offers Allow only when that is the whole of it).
            s.question = "Allow \(name)" + (detail.map { ": " + Words.clip(Redactor.redact($0), 2000) } ?? "") + "?"
        } else if let v = Optional(Classifier.classify(last)), v.asks {
            s.question = v.question
        } else {
            // The dialog's own words exist only inside its window (or via the optional hook).
            s.question = s.waitingFor == "permission prompt"
                ? "Asks permission for a step, in its window."
                : "Has a question for you, in its window."
        }
        s.headline = s.question.map { Words.clip($0, 90) }
        s.inShort = last.map { firstSentences($0, 220) }
        s.lastDid = s.inShort
    }

    /// The opening of a message as plain text: markdown marks dropped, cut at a sentence end near `n` characters.
    static func firstSentences(_ text: String, _ n: Int) -> String {
        let plain = Classifier.marks.replace(Classifier.codeFence.replace(text, with: " "), with: "")
        let para = Classifier.paragraphs(plain).first { !$0.hasPrefix("#") && !$0.hasPrefix("|") } ?? plain
        var out = ""
        for sentence in Classifier.sentences(para) {
            if !out.isEmpty && out.count + sentence.count + 1 > n { break }
            out += (out.isEmpty ? "" : " ") + sentence
        }
        return Words.clip(out, n)
    }
}
