import Foundation

/// One block of a message as Claude writes it (Markdown). A message is shown and shortened block by block, so a
/// table or a code block is never cut in two, not even where it holds a blank line.
struct MessageBlock: Equatable {
    enum Kind: Equatable {
        /// `#` to `######`, or a line underlined with `===` (1) or `---` (2).
        case heading(level: Int, text: String)
        case paragraph(String)
        /// A list with its nested lists, as items.
        case list([ListItem])
        case table(Table)
        /// A fenced code block (``` or ~~~): its language word, if any, and its lines exactly as written.
        case code(language: String?, text: String)
        /// A quote, without its `>` marks. Its inside is Markdown again: `MessageBlocks.split` reads it.
        case quote(String)
        case rule
    }

    struct ListItem: Equatable {
        /// The item's number in a numbered list (`3.` or `3)`), nil for a bullet (`-`, `*`, `+`).
        var number: Int?
        /// The item's own text, its continuation lines joined with a line break. A code block or a paragraph
        /// after a blank line inside the item stays in this text.
        var text: String
        var children: [ListItem] = []
        var ordered: Bool { number != nil }
    }

    struct Table: Equatable {
        enum Alignment: Equatable { case none, left, center, right }
        var header: [String]
        var alignments: [Alignment]
        /// Every row has as many cells as the header (missing cells are empty, extra cells are dropped).
        var rows: [[String]]
    }

    let kind: Kind
    /// The block's lines exactly as written: what a plain renderer can draw, and what Copy should copy.
    let source: String
}

enum MessageBlocks {
    /// The blocks of a message, in order. Blank lines separate blocks, except inside a code block, a list item
    /// that goes on below them, or a quote that goes on below them.
    static func split(_ text: String) -> [MessageBlock] {
        var reader = Reader(lines: text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n"))
        return reader.blocks()
    }

    /// The blocks' source text: a drop-in for the old blank-line cut (`Prose.split`), with tables and code blocks
    /// kept whole.
    static func paragraphs(_ text: String) -> [String] {
        split(text).map { $0.source.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The closing blocks of a message, up to about `limit` characters, always at least the last one: a message
    /// ends on what it wants from the user. Blocks are never cut, so a long table at the end comes whole.
    static func closing(_ blocks: [MessageBlock], limit: Int = 480) -> [MessageBlock] {
        var out: [MessageBlock] = [], total = 0
        for b in blocks.reversed() {
            if !out.isEmpty && total + b.source.count > limit { break }
            out.insert(b, at: 0); total += b.source.count
        }
        return out
    }

    // MARK: Reading

    private struct Reader {
        let lines: [String]
        var i = 0

        mutating func blocks() -> [MessageBlock] {
            var out: [MessageBlock] = []
            while i < lines.count {
                let line = lines[i]
                if Self.isBlank(line) { i += 1; continue }
                if let fence = Self.fence(line) { out.append(code(fence)); continue }
                if Self.indent(of: line) >= 4 { out.append(indentedCode()); continue }
                if let h = Self.atxHeading(line) {
                    out.append(MessageBlock(kind: .heading(level: h.level, text: h.text), source: line.trimmingCharacters(in: .whitespaces)))
                    i += 1; continue
                }
                if Self.isRule(line) { out.append(MessageBlock(kind: .rule, source: line.trimmingCharacters(in: .whitespaces))); i += 1; continue }
                if Self.quoteBody(line) != nil { out.append(quote()); continue }
                if Self.listMarker(line) != nil { out.append(list()); continue }
                if i + 1 < lines.count, Self.isTableRow(line), let aligns = Self.delimiterRow(lines[i + 1]),
                   aligns.count == Self.cells(line).count {
                    out.append(table(aligns)); continue
                }
                out.append(paragraph())
            }
            return out
        }

        private mutating func code(_ open: Fence) -> MessageBlock {
            let start = i
            i += 1
            var body: [String] = []
            while i < lines.count {
                if let close = Self.fence(lines[i]), close.char == open.char, close.count >= open.count, close.info.isEmpty {
                    i += 1
                    return MessageBlock(kind: .code(language: open.language, text: body.joined(separator: "\n")),
                                        source: lines[start..<i].joined(separator: "\n"))
                }
                body.append(Self.unindent(lines[i], by: open.indent))
                i += 1
            }
            // Never closed: the rest of the message is code (a message cut off mid-block reads right this way).
            return MessageBlock(kind: .code(language: open.language, text: body.joined(separator: "\n")),
                                source: lines[start..<i].joined(separator: "\n"))
        }

        /// Lines indented by four spaces or a tab, with any blank lines between them: one code block.
        private mutating func indentedCode() -> MessageBlock {
            let start = i
            var end = i
            while i < lines.count {
                if Self.isBlank(lines[i]) { i += 1; continue }
                guard Self.indent(of: lines[i]) >= 4 else { break }
                i += 1; end = i
            }
            i = end
            let body = lines[start..<end].map { Self.isBlank($0) ? "" : Self.unindentColumns($0, 4) }
            return MessageBlock(kind: .code(language: nil, text: body.joined(separator: "\n")),
                                source: lines[start..<end].joined(separator: "\n"))
        }

        private mutating func quote() -> MessageBlock {
            let start = i
            var inner: [String] = []
            var fence: Fence?
            while i < lines.count {
                let line = lines[i]
                if let body = Self.quoteBody(line) {
                    if let f = fence {
                        if let c = Self.fence(body), c.char == f.char, c.count >= f.count, c.info.isEmpty { fence = nil }
                    } else if let f = Self.fence(body) { fence = f }
                    inner.append(body); i += 1; continue
                }
                // A line without `>` right under the quote's words still belongs to it (lazy continuation),
                // unless it starts a block of its own.
                if fence == nil, !Self.isBlank(line), let last = inner.last, !Self.isBlank(last), !Self.startsBlock(line) {
                    inner.append(line); i += 1; continue
                }
                break
            }
            return MessageBlock(kind: .quote(inner.joined(separator: "\n")), source: lines[start..<i].joined(separator: "\n"))
        }

        private mutating func table(_ aligns: [MessageBlock.Table.Alignment]) -> MessageBlock {
            let start = i
            let header = Self.cells(lines[i])
            i += 2
            var rows: [[String]] = []
            while i < lines.count, !Self.isBlank(lines[i]), Self.isTableRow(lines[i]) {
                var r = Self.cells(lines[i])
                if r.count < header.count { r += Array(repeating: "", count: header.count - r.count) }
                rows.append(Array(r.prefix(header.count)))
                i += 1
            }
            return MessageBlock(kind: .table(.init(header: header, alignments: aligns, rows: rows)),
                                source: lines[start..<i].joined(separator: "\n"))
        }

        private mutating func paragraph() -> MessageBlock {
            let start = i
            var text: [String] = []
            while i < lines.count {
                let line = lines[i]
                if Self.isBlank(line) { break }
                if !text.isEmpty {
                    // A line of === or --- under a paragraph makes it a heading.
                    if let level = Self.setext(line) {
                        i += 1
                        return MessageBlock(kind: .heading(level: level, text: text.joined(separator: " ")),
                                            source: lines[start..<i].joined(separator: "\n"))
                    }
                    if Self.interruptsParagraph(line) { break }
                    if i + 1 < lines.count, Self.isTableRow(line), let a = Self.delimiterRow(lines[i + 1]),
                       a.count == Self.cells(line).count { break }
                }
                text.append(line.trimmingCharacters(in: .whitespaces))
                i += 1
            }
            return MessageBlock(kind: .paragraph(text.joined(separator: "\n")), source: lines[start..<i].joined(separator: "\n"))
        }

        /// A list goes on across blank lines while what follows is another item of it, or is indented under one.
        private mutating func list() -> MessageBlock {
            let start = i
            let base = Self.listMarker(lines[i])!
            var raw: [(indent: Int, marker: Marker?, text: String)] = []
            var fence: Fence?
            var contentIndent = base.contentIndent
            /// The text columns of the items open at this point, outermost first.
            var open: [Int] = []
            while i < lines.count {
                let line = lines[i]
                if let f = fence {
                    // A code block inside an item ends with its closing fence, or where its item ends: a line that
                    // is not blank and starts left of the item's text. Blank lines stay inside.
                    if Self.isBlank(line) || Self.indent(of: line) >= f.owner {
                        raw.append((Self.indent(of: line), nil, line))
                        if let c = Self.fence(Self.unindent(line, by: f.indent)), c.char == f.char, c.count >= f.count, c.info.isEmpty { fence = nil }
                        i += 1; continue
                    }
                    fence = nil
                    // The item ended inside its code block. Only another item, or a line under an outer item's
                    // text, keeps the list going; anything else is after the list.
                    // A marker four or more columns from the left edge (and not under an item's text) is code, not
                    // an item, however far in the list itself starts.
                    let ind = Self.indent(of: line)
                    let item = Self.listMarker(line) != nil && ind <= 3
                    if !item && ind < contentIndent { break }
                }
                if Self.isBlank(line) {
                    // Look past the blank lines: the list goes on only if the next line is part of it.
                    var j = i
                    while j < lines.count, Self.isBlank(lines[j]) { j += 1 }
                    guard j < lines.count else { break }
                    let next = lines[j]
                    let nextIndent = Self.indent(of: next)
                    let sameList = Self.listMarker(next).map { $0.indent >= base.indent && $0.ordered == base.ordered } ?? false
                    if sameList || nextIndent >= contentIndent {
                        for k in i..<j { raw.append((0, nil, lines[k])) }
                        i = j; continue
                    }
                    break
                }
                if let m = Self.listMarker(line) {
                    if m.indent < base.indent { break }
                    if m.indent == base.indent && m.ordered != base.ordered { break } // another kind of list
                    raw.append((m.indent, m, m.text))
                    if m.indent == base.indent { contentIndent = m.contentIndent }
                    while let last = open.last, m.indent < last { open.removeLast() }
                    open.append(m.contentIndent)
                    if let f = Self.fence(m.text) {
                        fence = Fence(char: f.char, count: f.count, info: f.info, indent: m.contentIndent, owner: m.contentIndent)
                    }
                    i += 1; continue
                }
                // A line that is not an item: inside the item when indented, or a lazy continuation of its
                // last line; a new block at the left edge ends the list.
                let ind = Self.indent(of: line)
                if ind < base.contentIndent, Self.startsBlock(line) { break }
                if let f = Self.fence(Self.unindent(line, by: ind)) {
                    // Its item: the deepest open one whose text column the fence is not left of.
                    let owner = open.last(where: { $0 <= ind }) ?? min(ind, contentIndent)
                    fence = Fence(char: f.char, count: f.count, info: f.info, indent: ind, owner: owner)
                }
                raw.append((ind, nil, line))
                i += 1
            }
            // Blank lines at the end are not the list's.
            var end = i
            while end > start, Self.isBlank(lines[end - 1]) { end -= 1 }
            while let last = raw.last, last.marker == nil, Self.isBlank(last.text) { raw.removeLast() }
            return MessageBlock(kind: .list(Self.tree(raw)), source: lines[start..<end].joined(separator: "\n"))
        }

        /// Items by indent: an item indented to (or past) another item's text is its child.
        private static func tree(_ raw: [(indent: Int, marker: Marker?, text: String)]) -> [MessageBlock.ListItem] {
            struct Open { var item: MessageBlock.ListItem; let contentIndent: Int; let indent: Int }
            var stack: [Open] = []
            var roots: [MessageBlock.ListItem] = []
            func close(downTo level: Int) {
                while stack.count > level {
                    var done = stack.removeLast()
                    while done.item.text.hasSuffix("\n") { done.item.text.removeLast() }
                    if stack.isEmpty { roots.append(done.item) } else { stack[stack.count - 1].item.children.append(done.item) }
                }
            }
            var prevBlank = false
            for r in raw {
                defer { prevBlank = r.marker == nil && isBlank(r.text) }
                if let m = r.marker {
                    // Close every open item this one is not inside.
                    var keep = stack.count
                    while keep > 0, m.indent < stack[keep - 1].contentIndent { keep -= 1 }
                    close(downTo: keep)
                    stack.append(Open(item: .init(number: m.number, text: m.text), contentIndent: m.contentIndent, indent: m.indent))
                } else if !stack.isEmpty {
                    // A continuation line belongs to the deepest open item whose text it is indented under; right
                    // under a line of text (no blank between) it goes on that text wherever it starts.
                    if isBlank(r.text) { stack[stack.count - 1].item.text += "\n"; continue }
                    var at = stack.count - 1
                    if prevBlank {
                        while at > 0, r.indent < stack[at].contentIndent { at -= 1 }
                    }
                    close(downTo: at + 1)
                    stack[at].item.text += "\n" + unindent(r.text, by: stack[at].contentIndent)
                }
            }
            close(downTo: 0)
            return roots
        }

        // MARK: Line tests

        struct Fence { let char: Character; let count: Int; let info: String; var indent: Int = 0
            /// Inside a list: the text column of the item the code block belongs to. The block ends where that
            /// item ends (a line that is not blank and starts left of it), as in CommonMark.
            var owner: Int = 0
            var language: String? { info.split(separator: " ").first.map(String.init) }
        }

        struct Marker { let indent: Int; let number: Int?; let contentIndent: Int; let text: String
            var ordered: Bool { number != nil }
        }

        static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

        static func indent(of s: String) -> Int {
            var n = 0
            for c in s { if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break } }
            return n
        }

        /// Drops `n` columns of indentation; a tab counts to the next multiple of four, as in `indent(of:)`.
        static func unindent(_ s: String, by n: Int) -> String { unindentColumns(s, n) }

        /// Drops `n` columns of indentation, a tab counting to the next multiple of four.
        static func unindentColumns(_ s: String, _ n: Int) -> String {
            var col = 0, idx = s.startIndex
            while idx < s.endIndex, col < n {
                if s[idx] == " " { col += 1 } else if s[idx] == "\t" { col += 4 - col % 4 } else { break }
                idx = s.index(after: idx)
            }
            return String(s[idx...])
        }

        static func fence(_ s: String) -> Fence? {
            let ind = indent(of: s)
            guard ind <= 3 else { return nil }
            let t = s.drop { $0 == " " }
            guard let c = t.first, c == "`" || c == "~" else { return nil }
            let run = t.prefix { $0 == c }.count
            guard run >= 3 else { return nil }
            let info = t.dropFirst(run).trimmingCharacters(in: .whitespaces)
            if c == "`" && info.contains("`") { return nil }
            return Fence(char: c, count: run, info: info, indent: ind)
        }

        static func atxHeading(_ s: String) -> (level: Int, text: String)? {
            guard indent(of: s) <= 3 else { return nil }
            let t = s.drop { $0 == " " }
            let hashes = t.prefix { $0 == "#" }.count
            guard (1...6).contains(hashes) else { return nil }
            let rest = t.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            var text = rest.trimmingCharacters(in: .whitespaces)
            // A closing run of #s is not part of the heading.
            // A closing run of #s after a space is not part of the heading (a scan from the end: a pattern match
            // here took seconds on a line with a long run of spaces).
            if text.allSatisfy({ $0 == "#" }) { text = "" }
            else if text.hasSuffix("#") {
                var end = text.endIndex
                while end > text.startIndex, text[text.index(before: end)] == "#" { end = text.index(before: end) }
                if end > text.startIndex, text[text.index(before: end)] == " " || text[text.index(before: end)] == "\t" {
                    text = String(text[..<end]).trimmingCharacters(in: .whitespaces)
                }
            }
            return (hashes, text)
        }

        static func isRule(_ s: String) -> Bool {
            guard indent(of: s) <= 3 else { return false }
            let t = s.filter { $0 != " " && $0 != "\t" }
            guard let c = t.first, c == "-" || c == "*" || c == "_" else { return false }
            return t.count >= 3 && t.allSatisfy { $0 == c }
        }

        static func setext(_ s: String) -> Int? {
            guard indent(of: s) <= 3 else { return nil }
            let t = s.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return nil }
            if t.allSatisfy({ $0 == "=" }) { return 1 }
            if t.allSatisfy({ $0 == "-" }) { return 2 }
            return nil
        }

        static func quoteBody(_ s: String) -> String? {
            guard indent(of: s) <= 3 else { return nil }
            let t = s.drop { $0 == " " }
            guard t.first == ">" else { return nil }
            var body = t.dropFirst()
            if body.first == " " { body = body.dropFirst() }
            return String(body)
        }

        static func listMarker(_ s: String) -> Marker? {
            let ind = indent(of: s)
            let t = s.drop { $0 == " " || $0 == "\t" }
            var number: Int?
            var width: Int
            if let c = t.first, c == "-" || c == "*" || c == "+" {
                width = 1
            } else {
                let digits = t.prefix { $0.isASCII && $0.isNumber }
                guard (1...9).contains(digits.count), let n = Int(digits) else { return nil }
                let after = t.dropFirst(digits.count)
                guard let d = after.first, d == "." || d == ")" else { return nil }
                number = n; width = digits.count + 1
            }
            let rest = t.dropFirst(width)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            // `***` and `- - -` are rules, not items.
            if number == nil && isRule(s) { return nil }
            let spaces = min(max(rest.prefix { $0 == " " }.count, 1), 4)
            let text = rest.trimmingCharacters(in: .whitespaces)
            return Marker(indent: ind, number: number, contentIndent: ind + width + (text.isEmpty ? 1 : spaces), text: text)
        }

        static func isTableRow(_ s: String) -> Bool { s.contains("|") && !isBlank(s) }

        static func delimiterRow(_ s: String) -> [MessageBlock.Table.Alignment]? {
            guard s.contains("-") else { return nil }
            let parts = cells(s)
            guard !parts.isEmpty else { return nil }
            var out: [MessageBlock.Table.Alignment] = []
            for p in parts {
                let c = p.trimmingCharacters(in: .whitespaces)
                let left = c.hasPrefix(":"), right = c.hasSuffix(":")
                let dashes = c.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
                out.append(left && right ? .center : left ? .left : right ? .right : .none)
            }
            // One column needs its pipes, or a line of dashes would be a table.
            if out.count == 1 && !s.trimmingCharacters(in: .whitespaces).hasPrefix("|") { return nil }
            return out
        }

        /// A row's cells: split on `|` that is not escaped (`\|`) and not inside `code`; outer pipes dropped.
        static func cells(_ s: String) -> [String] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("|") { t.removeFirst() }
            if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
            var out: [String] = [], cur = "", inCode = false, escaped = false
            for c in t {
                if escaped { cur.append(c == "|" ? "|" : "\\" + String(c)); escaped = false; continue }
                if c == "\\" { escaped = true; continue }
                if c == "`" { inCode.toggle() }
                if c == "|" && !inCode { out.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""; continue }
                cur.append(c)
            }
            if escaped { cur.append("\\") }
            out.append(cur.trimmingCharacters(in: .whitespaces))
            return out
        }

        /// A line that starts a block of its own (so it is not a continuation of the line above).
        static func startsBlock(_ s: String) -> Bool {
            fence(s) != nil || atxHeading(s) != nil || isRule(s) || quoteBody(s) != nil || listMarker(s) != nil
        }

        /// What may end a paragraph without a blank line between: as in CommonMark, a numbered list only when it
        /// starts at 1, so "in 2024. Then" in running text is not a list.
        static func interruptsParagraph(_ s: String) -> Bool {
            if fence(s) != nil || atxHeading(s) != nil || isRule(s) || quoteBody(s) != nil { return true }
            if let m = listMarker(s), !m.text.isEmpty, m.indent <= 3 { return m.number == nil || m.number == 1 }
            return false
        }
    }
}
