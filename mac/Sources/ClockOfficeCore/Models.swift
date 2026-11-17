import Foundation

/// What a session needs from the user right now. One meaning per state:
/// asking = a question for the user (the only state that glows), working = turning, done = finished and quiet.
public enum SessionState: String, Codable, Sendable {
    case asking, working, done
}

/// One reply the user can give with a single click.
public struct ReplyOption: Codable, Equatable, Hashable, Sendable {
    /// What the user reads.
    public var label: String
    /// What is typed into the session, without the Enter.
    public var send: String
    public init(label: String, send: String) { self.label = label; self.send = send }
}

/// One coding session, whatever tool runs it. Every adapter (Claude Code first) reports this shape.
public struct Session: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var tool: String
    public var pid: Int32
    public var cwd: String
    public var project: String
    public var title: String
    public var state: SessionState
    /// When the current state began.
    public var since: Date
    /// True when the tool itself reports the session as waiting; false when the question was read from its last message.
    public var certain: Bool
    /// The tool's own word for what it waits for ("input needed", "permission prompt"), when it gives one.
    public var waitingFor: String?
    /// The full question.
    public var question: String?
    /// The question as a headline for small surfaces.
    public var headline: String?
    public var options: [ReplyOption]
    /// One or two plain sentences on where the session stands.
    public var inShort: String?
    /// The last thing it did.
    public var lastDid: String?
    /// The last message it wrote, clipped; the source for summaries.
    public var lastText: String?
    /// The session's page on claude.ai (Remote Control), when it has one.
    public var remoteURL: URL?
    /// Runs started by scripts (sdk-cli); hidden by default.
    public var automated: Bool
    /// A fingerprint of what the tool itself reported: status, when it changed, the last message, an open dialog.
    /// It does not depend on summaries, so "is this still the session the user was looking at?" has one honest answer.
    public var revision: String = ""

    public init(id: String, tool: String, pid: Int32, cwd: String, project: String, title: String,
                state: SessionState, since: Date, certain: Bool = false, waitingFor: String? = nil,
                question: String? = nil, headline: String? = nil, options: [ReplyOption] = [],
                inShort: String? = nil, lastDid: String? = nil, lastText: String? = nil,
                remoteURL: URL? = nil, automated: Bool = false) {
        self.id = id; self.tool = tool; self.pid = pid; self.cwd = cwd; self.project = project
        self.title = title; self.state = state; self.since = since; self.certain = certain
        self.waitingFor = waitingFor; self.question = question; self.headline = headline
        self.options = options; self.inShort = inShort; self.lastDid = lastDid; self.lastText = lastText
        self.remoteURL = remoteURL; self.automated = automated
    }

    /// Identifies what is shown for this session (used to tell "sent" and "dismissed" rows from new states).
    public var stamp: String { "\(state.rawValue)@\(Int(since.timeIntervalSince1970 * 1000))@\(revision)" }
}

public extension Session {
    /// One session per id: when several are reported, the one whose state changed last stands. Order is kept.
    static func unique(_ list: [Session]) -> [Session] {
        var best: [String: Session] = [:]
        for s in list { if let b = best[s.id], b.since >= s.since { continue }; best[s.id] = s }
        var seen = Set<String>()
        return list.compactMap { s in seen.insert(s.id).inserted ? best[s.id] : nil }
    }
}

/// A source of sessions: one per tool. Adding a tool is adding one of these, not rewriting the app.
public protocol SessionSource: Sendable {
    var tool: String { get }
    func sessions() -> [Session]
    /// The last few things said in one of its sessions, for that session's own view.
    func conversation(for s: Session, limit: Int) -> [Turn]
}

public enum Words {
    /// Collapses whitespace and cuts at `n` characters with an ellipsis.
    public static func clip(_ s: String, _ n: Int = 120) -> String {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.count <= n { return t }
        return String(t.prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "TEAM-HANDBOOK" → "Team handbook", "clock_office" → "Clock office"; mixed case is left alone.
    public static func prettyProject(_ folder: String) -> String {
        var s = folder.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        s = s.split(separator: " ").joined(separator: " ")
        guard !s.isEmpty else { return folder }
        let letters = s.filter { $0.isLetter }
        let shouty = !letters.isEmpty && letters.allSatisfy { $0.isUppercase }
        let lower = !letters.isEmpty && letters.allSatisfy { $0.isLowercase }
        if shouty || lower { return s.prefix(1).uppercased() + s.dropFirst().lowercased() }
        return s
    }

    static let tempShot = Rx(#"'?/(?:private/)?var/folders/\S*?/([^/']+?\.(?:png|jpe?g|gif|heic|pdf))'?"#)
    static let quotedFile = Rx(#"'(/[^']*/)([^/']+\.[A-Za-z0-9]{2,5})'"#)

    static let pictureFile = Rx(#"'(/[^'\n]+?\.(?:png|jpe?g|gif|heic|webp))'|(?<![\w'])(/(?:private/)?var/folders/\S+?\.(?:png|jpe?g|gif|heic|webp))"#)

    /// The picture files the user's message names by their path (a screenshot dragged into the prompt arrives as its
    /// path, in quotes when it has spaces).
    public static func shots(in s: String) -> [String] {
        let ns = s as NSString
        var out: [String] = []
        for m in pictureFile.re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
            let p = ns.substring(with: r)
            if !out.contains(p) { out.append(p) }
        }
        return out
    }

    /// The user's prompt as they would say it: a pasted screenshot path becomes "[screenshot]", a quoted file path its name.
    public static func tidyPrompt(_ s: String) -> String {
        var t = tempShot.replace(s, with: "[screenshot]")
        t = quotedFile.replace(t, with: "[$2]")
        return t.split(whereSeparator: { $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// "34 min", "2 h", "4 d"; under a minute is "now".
    public static func age(since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) d"
    }
}
