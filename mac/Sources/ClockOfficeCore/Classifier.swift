import Foundation

/// Decides from a session's last message whether it ends on a question for the user or is simply done.
/// Used only when the tool itself does not say "waiting": an official waiting status always wins.
/// A port of the October prototype's classify.ts, whose 81 fixtures this keeps passing in spirit:
/// it looks at the last content paragraph only, skips footers, and ignores rhetorical or self-answered questions.
public struct Verdict: Equatable, Sendable {
    public var asks: Bool
    public var question: String?
    public var options: [ReplyOption]
    public static let done = Verdict(asks: false, question: nil, options: [])
}

struct Rx {
    let re: NSRegularExpression
    init(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) {
        // Patterns are compile-time constants; a typo must fail loudly in tests, not silently match nothing.
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }
    func test(_ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
    func groups(_ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }
    func replace(_ s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }
    func split(_ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out
    }
}

public enum Classifier {
    static let asking = Rx(#"^\s*(?:\d+[.)]\s*)?(should|shall|do you|did you|would you|could you|can (?:i|you|we)|may i|want me|which|what (?:do|would|should) you|ok to|okay to|ready (?:to|for)|is (?:it|that|this) (?:ok|okay|fine|right)|are you|does (?:that|this)|merge|deploy|send|continue|proceed|go ahead|keep|apply|publish|push|ship|approve|start|run|go with|same for|do (?:i|we)|is (?:the|it|this|that)|are (?:the|we|these|those)|should we|shall we|can we|use|pay|put|add|remove|delete|rename|install|update|upgrade|create|open|close|book|mail|email|post|commit|release|restart|try|switch|rerun|revert|roll back)\b"#)
    static let request = Rx(#"\b((?:next step|the call|the next move|your move) is yours|your call\b|decision needed|needs? your (?:ok|okay|go|approval|decision|input|answer|call|look)|please (?:confirm|choose|pick|reply|send|paste|tell|approve|review|decide)|can you (?:confirm|send|paste|tell|check)|tell me which|paste (?:it|the|your)|i need (?:the|your)|(?:waiting|ready) (?:for|on) your (?:go|ok|okay|look|review|approval|call|answer|decision|input)|awaiting your|need your (?:go|approval|ok|okay|decision|input|call|look|answer)|your go-ahead|pick one|reply with)\b"#)
    static let courtesy = Rx(#"\b(let me know|tell me|feel free to ask) if\b|\bhappy to help\b"#)
    static let footer = Rx(#"^\s*(?:-{3,}|_{3,}|\*{3,}|_.*_\s*$|\*\*?(?:files|preview|branch|commit|links?)\b|(?:files? changed|changed files|preview|links?|branch|commit|sha|pr|sources?)\s*:)"#)
    static let listLine = Rx(#"^\s*(?:[-*•]|\(?(?:\d{1,2}|[a-dA-D])[.):])\s+\S"#, [])
    static let optionLine = Rx(#"^\s*(?:[-*]\s*)?\(?(\d{1,2}|[a-dA-D])[.):]\s+(\S.*)$"#, [])
    static let codeFence = Rx(#"```[\s\S]*?```"#, [])
    static let paraBreak = Rx(#"\n\s*\n"#, [])
    static let marks = Rx(#"\*\*|__|`"#, [])
    static let newlines = Rx(#"\n+"#, [])
    static let sentenceEnd = Rx(#"(?<=[.?!])\s+"#, [])
    static let wh = Rx(#"^\s*(where|when|what|which|who|how)\b.*\b(should|shall|do|would|will)\b"#)
    static let trivia = Rx(#"^\s*did you know\b"#)
    static let quoted = Rx(#"\b(reads|says|asks|titled|heading|you asked)\s*:"#)
    static let clauseBreak = Rx(#"[,;:–—]\s+|\s+-\s+"#, [])
    static let you = Rx(#"\byou(r)?\b"#)
    static let selfAnswer = Rx(#"\b(i|we)(?:'ve| have)?\s+(made|did|added|removed|fixed|deployed|went|chose|used|set|kept|switched|merged|pushed|ran)\b|\b(done|deployed|fixed|merged)\b"#)
    static let verb = Rx(#"^(merge|deploy|send|continue|proceed|keep|apply|publish|push|ship|start|run|wait|stop|skip|retry|use|go)$"#)
    static let orSplit = Rx(#",?\s+or\s+"#)
    static let orTail = Rx(#"(\w[\w-]*)\s+or\s+(\w[\w-]*)\?$"#)
    static let leadNumber = Rx(#"^\s*\d+[.)]\s*"#, [])
    static let canYou = Rx(#"^(can|could|would) you\b"#)
    static let orWord = Rx(#"\bor\b"#)
    static let yesNoStart = Rx(#"^(should|shall|do|does|can|could|would|will|is|are|ok|okay|want|merge|send|deploy|go|continue|proceed|keep|apply|publish|push|ship|approve|start|run|ready)\b"#)
    static let url = Rx(#"https?://"#)

    static func paragraphs(_ text: String) -> [String] {
        let t = codeFence.replace(text, with: " ").replacingOccurrences(of: "\r", with: "")
        return paraBreak.split(t).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func lines(_ p: String) -> [String] {
        p.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    static func isFooter(_ p: String) -> Bool {
        let ls = lines(p)
        guard let first = ls.first else { return true }
        return footer.test(first) || ls.allSatisfy { listLine.test($0) } || (ls.count == 1 && url.test(p) && p.count < 160)
    }

    /// A numbered or lettered list as options: the user reads the option's own words, the key is what gets typed.
    static func listOptions(_ block: String) -> [ReplyOption]? {
        var seen = Set<String>()
        var out: [ReplyOption] = []
        for l in block.components(separatedBy: "\n") {
            guard let g = optionLine.groups(l) else { continue }
            let key = g[1].lowercased()
            if seen.insert(key).inserted {
                let label = Words.clip(marks.replace(g[2], with: ""), 32)
                out.append(ReplyOption(label: label, send: key))
            }
        }
        return out.count >= 2 ? out : nil
    }

    static func sentences(_ p: String) -> [String] {
        let t = newlines.replace(marks.replace(p, with: ""), with: " ")
        return sentenceEnd.split(t).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A question aimed at the user: an asking form, "you", or a short open prompt such as "Thoughts?".
    static func directed(_ s: String) -> Bool {
        if trivia.test(s) || quoted.test(s) { return false }
        let clauses = clauseBreak.split(s)
        if clauses.contains(where: { asking.test($0) || wh.test($0) }) { return true }
        if you.test(s) { return true }
        return s.hasSuffix("?") && s.split(separator: " ").count <= 5
    }

    /// "Merge now, or wait for your look?" → merge / wait. "Blue or green?" → blue / green.
    static func either(_ q: String) -> [ReplyOption]? {
        let body = q.hasSuffix("?") ? String(q.dropLast()) : q
        let parts = orSplit.split(body)
        guard parts.count == 2 else { return nil }
        let a = parts[0].trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        let b = parts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        if let a0 = a.first, let b0 = b.first, verb.test(a0), verb.test(b0) {
            return [a0, b0].map { ReplyOption(label: $0.lowercased(), send: $0.lowercased()) }
        }
        if let g = orTail.groups(q), g[1].count <= 14, g[2].count <= 14 {
            return [g[1], g[2]].map { ReplyOption(label: $0.lowercased(), send: $0.lowercased()) }
        }
        return nil
    }

    public static func classify(_ lastMessage: String?) -> Verdict {
        guard let lastMessage, !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .done }
        let ps = paragraphs(lastMessage)
        guard !ps.isEmpty else { return .done }
        var i = ps.count - 1
        while i > 0 && isFooter(ps[i]) { i -= 1 }
        let main = ps[i]
        let around = ps[max(0, i - 1)...].joined(separator: "\n")
        let prose = main.components(separatedBy: "\n").filter { !listLine.test($0) }.joined(separator: "\n")
        let ss = sentences(prose)

        // A question to the user that is the last thing said (one short closing sentence may follow).
        var q: String?
        if let qi = ss.indices.last(where: { ss[$0].hasSuffix("?") && directed(ss[$0]) }) {
            let after = ss[(qi + 1)...].joined(separator: " ")
            if after.count < 160 && !selfAnswer.test(after) { q = ss[qi] }
        }
        // Or a request for the user's input, as long as it is not a polite closer.
        if q == nil { q = ss.reversed().first(where: { request.test($0) && !courtesy.test($0) }) }
        // Or a question put as "Which do you prefer:" right before its option list.
        if q == nil, listOptions(main) != nil {
            let lead = main.components(separatedBy: "\n").filter { !listLine.test($0) }.last?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if lead.hasSuffix(":") && directed(lead) { q = String(lead.dropLast()) + "?" }
        }
        guard var question = q else { return .done }
        question = leadNumber.replace(question, with: "")

        // Buttons pay off only for "yes" and for real option lists; "no" nearly always needs words.
        let yesNo = !canYou.test(question) && !orWord.test(question) && yesNoStart.test(question)
        let opts = listOptions(around) ?? either(question) ?? (yesNo ? [ReplyOption(label: "yes", send: "yes")] : [])
        return Verdict(asks: true, question: Words.clip(question, 400), options: opts)
    }
}
