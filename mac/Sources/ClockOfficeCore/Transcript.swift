import Foundation

/// What the end of a Claude Code transcript says about a session. Read-only, tail only.
public struct TranscriptTail: Sendable {
    /// The title Claude Code gave the conversation, when it has one.
    public var title: String?
    /// The last thing the user typed.
    public var lastPrompt: String?
    /// The last text Claude wrote in the main thread, unless the user has typed since.
    public var lastAssistantText: String?
    public var lastAssistantAt: Date?
    /// True when Claude went on working after that text (a tool call or its result came later): the text is not
    /// its last word, so a question in it was answered some other way (a peer's relayed answer, T-49).
    public var workedAfterText: Bool = false
    /// A tool call that has no result yet: what a dialog or permission prompt is about.
    public var pendingToolName: String?
    public var pendingToolInput: [String: AnySendable]?
    /// True when the user's message is the newest thing in the transcript (Claude has not answered yet).
    public var userSpokeLast: Bool = false
    public init() {}
}

/// JSON values carried across threads without pretending they are typed.
public enum AnySendable: Sendable {
    case string(String), number(Double), bool(Bool), array([AnySendable]), object([String: AnySendable]), null

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(AnySendable.init))
        case let o as [String: Any]: self = .object(o.mapValues(AnySendable.init))
        default: self = .null
        }
    }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var array: [AnySendable]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: AnySendable]? { if case .object(let o) = self { return o }; return nil }
}

public enum Transcript {
    /// Where Claude Code keeps a session's transcript.
    public static func path(cwd: String, sessionId: String, home: String = NSHomeDirectory()) -> String {
        let slug = String(cwd.unicodeScalars.map { s -> Character in
            (s.isASCII && (CharacterSet.alphanumerics.contains(s))) ? Character(s) : "-"
        })
        return "\(home)/.claude/projects/\(slug)/\(sessionId).jsonl"
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Reads the end of the file, growing the window (up to 8 MB) when one long line fills it.
    public static func tail(file: String, window: Int = 256 * 1024) -> TranscriptTail {
        var out = TranscriptTail()
        guard let fh = FileHandle(forReadingAtPath: file) else { return out }
        defer { try? fh.close() }
        let size = Int((try? fh.seekToEnd()) ?? 0)
        guard size > 0 else { return out }
        var win = min(size, window)
        while true {
            try? fh.seek(toOffset: UInt64(size - win))
            let data = (try? fh.read(upToCount: win)) ?? Data()
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if win < size, !lines.isEmpty { lines.removeFirst() } // the first line of a partial window is cut
            out = scan(lines)
            let settled = out.lastAssistantText != nil || out.userSpokeLast || out.pendingToolName != nil
            if settled || win >= size || win >= 8 * 1024 * 1024 { return out }
            win = min(size, win * 4)
        }
    }

    static func scan(_ lines: [Data.SubSequence]) -> TranscriptTail {
        var out = TranscriptTail()
        var toolResultSeen = false
        var toolCallSeen = false
        var decided = false
        for raw in lines.reversed() {
            // Cheap pre-filter: most lines are request blobs and attachments.
            guard let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            switch type {
            case "ai-title":
                if out.title == nil { out.title = o["aiTitle"] as? String }
            case "custom-title":
                if let t = o["customTitle"] as? String, !t.isEmpty { out.title = t }
            case "last-prompt":
                if out.lastPrompt == nil { out.lastPrompt = o["lastPrompt"] as? String }
            case "user":
                // The note written after compacting is not the user speaking (see `turns`).
                if decided || (o["isSidechain"] as? Bool) == true || (o["isMeta"] as? Bool) == true
                    || (o["isCompactSummary"] as? Bool) == true || (o["isVisibleInTranscriptOnly"] as? Bool) == true { continue }
                let content = (o["message"] as? [String: Any])?["content"]
                if let blocks = content as? [[String: Any]] {
                    if blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                        toolResultSeen = true
                    } else if blocks.contains(where: { ["text", "image"].contains($0["type"] as? String ?? "") }) {
                        out.userSpokeLast = true; decided = true
                    }
                } else if content is String {
                    out.userSpokeLast = true; decided = true
                }
            case "assistant":
                if decided || (o["isSidechain"] as? Bool) == true { continue }
                let blocks = ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
                if !toolResultSeen, out.pendingToolName == nil,
                   let tool = blocks.last(where: { $0["type"] as? String == "tool_use" }),
                   let name = tool["name"] as? String {
                    out.pendingToolName = name
                    out.pendingToolInput = (tool["input"] as? [String: Any])?.mapValues(AnySendable.init)
                }
                let text = blocks.filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.lastAssistantText = text
                    out.lastAssistantAt = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
                    // A tool call later in this same message counts too: the words came before the work.
                    let lastText = blocks.lastIndex { $0["type"] as? String == "text" } ?? 0
                    let callAfter = blocks[(lastText + 1)...].contains { $0["type"] as? String == "tool_use" }
                    out.workedAfterText = toolResultSeen || toolCallSeen || callAfter
                    decided = true
                } else if blocks.contains(where: { $0["type"] as? String == "tool_use" }) {
                    toolCallSeen = true
                }
            default:
                continue
            }
            if decided && out.title != nil && out.lastPrompt != nil { break }
        }
        return out
    }
}

/// One thing said in a session, for the short conversation shown in details.
public struct Turn: Identifiable, Equatable, Sendable {
    public enum Who: String, Sendable { case you, assistant }
    public var id: String
    public var who: Who
    public var text: String
    public var at: Date?
    /// Pictures that came with the message: files on this Mac (a screenshot the user dragged in, or one they pasted,
    /// kept by `PastedPictures`). Some may be gone by the time they are shown.
    public var pictures: [String]
    public init(id: String, who: Who, text: String, at: Date? = nil, pictures: [String] = []) {
        self.id = id; self.who = who; self.text = text; self.at = at; self.pictures = pictures
    }
}

public extension Transcript {
    /// The last few things said: what the user typed and what Claude answered. Tool calls, system notes and the many
    /// in-between status lines of one long turn are left out: per turn only Claude's last words are kept.
    static func recent(file: String, limit: Int = 4, window: Int = 2 * 1024 * 1024) -> [Turn] {
        guard let fh = FileHandle(forReadingAtPath: file) else { return [] }
        defer { try? fh.close() }
        let size = Int((try? fh.seekToEnd()) ?? 0)
        guard size > 0 else { return [] }
        // A message with a pasted screenshot is one line of several megabytes, so the window grows (up to 24 MB)
        // until enough turns are in it.
        var win = min(size, window)
        while true {
            try? fh.seek(toOffset: UInt64(size - win))
            let data = (try? fh.read(upToCount: win)) ?? Data()
            var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            if win < size, !lines.isEmpty { lines.removeFirst() }
            let turns = turns(in: lines)
            if turns.count >= limit || win >= size || win >= 24 * 1024 * 1024 { return Array(turns.suffix(limit)) }
            win = min(size, win * 3)
        }
    }

    /// A note from the tool itself opens with a tag ("<system-reminder>", "<command-name>…"). A message of the user's
    /// that merely begins with "<" ("<3 thanks", "< 5 minutes?") is the user's and is shown.
    private static let pasted = Rx(#"<pasted_content[^>]*>[\s\S]*?</pasted_content[^>]*>\s*"#, [])
    private static let toolNote = Rx(#"^<[a-z][a-z0-9_-]*[\s>]"#, [])

    private static let userMark = Data(#""type":"user""#.utf8)
    private static let assistantMark = Data(#""type":"assistant""#.utf8)

    private static func turns(in lines: [Data.SubSequence]) -> [Turn] {
        var turns: [Turn] = []
        for (n, raw) in lines.enumerated() {
            // Skip the bulk (request blobs, attachments) without parsing it: only lines that say they are a
            // user or assistant message are read, however long they are.
            guard raw.range(of: userMark) != nil || raw.range(of: assistantMark) != nil,
                  let o = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  (o["isSidechain"] as? Bool) != true, (o["isMeta"] as? Bool) != true,
                  // The long note Claude Code writes after it compacts a conversation is stored as if the user had
                  // typed it; it filled the whole view as the user's message.
                  (o["isCompactSummary"] as? Bool) != true, (o["isVisibleInTranscriptOnly"] as? Bool) != true else { continue }
            let content = (o["message"] as? [String: Any])?["content"]
            let at = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }
            let id = (o["uuid"] as? String) ?? "line-\(n)"
            if type == "user" {
                var text: String?
                var pictures: [String] = []
                if let s = content as? String { text = s }
                else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
                    // The user's words only: an attached picture is already named in them by its path.
                    let parts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    if !parts.isEmpty { text = parts.joined(separator: " ") }
                    else if blocks.contains(where: { $0["type"] as? String == "image" }) { text = "[image]" }
                    // A picture the user pasted is kept inside the record: it is written out once, to be shown.
                    pictures = blocks.filter { $0["type"] as? String == "image" }.compactMap(PastedPictures.file(for:))
                }
                // Lines that start with a tag are notes from the tool itself (commands, reminders), not the user's words.
                // So is the line the tool writes when the user stops it mid-answer: it showed up as if they had typed it.
                // A message that opens with a pasted block is still the user's: the block becomes "[pasted text]" and
                // the user's own words after it are shown (they were hidden with it).
                let typed = text.map { pasted.replace($0, with: "[pasted text] ") }
                guard let said = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty, !toolNote.test(said),
                      !said.hasPrefix("[Request interrupted by user"),
                      !said.hasPrefix("This session is being continued from a previous conversation") else { continue }
                // A screenshot the user dragged in is named in their words by its path.
                pictures += Words.shots(in: said).filter { !pictures.contains($0) }
                turns.append(Turn(id: id, who: .you, text: Words.tidyPrompt(Redactor.redact(said)), at: at, pictures: pictures))
            } else {
                let text = ((content as? [[String: Any]]) ?? []).filter { $0["type"] as? String == "text" }
                    .compactMap { $0["text"] as? String }.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let turn = Turn(id: id, who: .assistant, text: Redactor.redact(text), at: at)
                // Within one turn only the latest words stand; earlier status lines are replaced.
                if turns.last?.who == .assistant { turns[turns.count - 1] = turn } else { turns.append(turn) }
            }
        }
        return turns
    }
}

/// Masks what is clearly a secret before text is shown on a glanceable surface or sent for a summary.
/// Deliberately narrow: only patterns that are secrets with near certainty, so questions stay readable.
public enum Redactor {
    static let patterns: [Rx] = [
        Rx(#"\b(?:password|passwd|pwd|wachtwoord|passphrase|secret|api[_ -]?key|token)\s*(?:is|:|=)\s*[^\s;,]+"#),
        Rx(#"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{8,}"#, []),
        Rx(#"\bgh[pousr]_[A-Za-z0-9]{8,}"#, []),
        Rx(#"\bAKIA[0-9A-Z]{12,}"#, []),
        Rx(#"\bAIza[0-9A-Za-z_-]{10,}"#, []),
        Rx(#"\beyJ[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_-]+)*"#, []),
        Rx(#"\b\w+:[^\s@/]+@[\w.-]+"#, []),
    ]
    public static func redact(_ s: String) -> String {
        patterns.reduce(s) { $1.replace($0, with: "…") }
    }
}
