import AppKit
import SwiftUI
import ClockOfficeUI

/// One of Claude's messages drawn as formatted text (T-34): headings, lists, tables, code blocks with Copy, quotes
/// and rules, block by block from `MessageBlocks`. Words inside a block are styled as `Prose` styles them (bold,
/// italics, inline code; links stay off, see `Prose.linksOn`). No outside package: SwiftUI's Grid draws tables.
///
/// The caller keeps putting `CopyMessageCatcher` over the whole message (T-35): nothing here takes a right-click.
struct MarkdownMessage: View {
    let blocks: [MessageBlock]
    var roomy = false
    var color: Color
    /// As wide as its words only.
    var hug = false

    init(_ text: String, roomy: Bool = false, color: Color, hug: Bool = false) {
        self.init(blocks: MessageBlocks.split(text), roomy: roomy, color: color, hug: hug)
    }

    init(blocks: [MessageBlock], roomy: Bool = false, color: Color, hug: Bool = false) {
        self.blocks = blocks; self.roomy = roomy; self.color = color; self.hug = hug
    }

    var body: some View {
        Blocks(blocks: blocks, roomy: roomy, color: color, depth: 0)
            .frame(maxWidth: hug ? nil : (roomy ? 680 : 600), alignment: .leading) // a line length the eye can follow
    }

    /// The blocks one under the other; also used inside a list item and a quote.
    /// Quotes and list items nest; past this depth their inside shows as its plain words (a line of a million
    /// `>` marks must not build a million views).
    static let deepest = 6

    struct Blocks: View {
        let blocks: [MessageBlock]
        let roomy: Bool
        let color: Color
        let depth: Int

        var body: some View {
            VStack(alignment: .leading, spacing: roomy ? 15 : 10) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    BlockView(block: b, roomy: roomy, color: color, depth: depth)
                }
            }
        }
    }

    struct BlockView: View {
        let block: MessageBlock
        let roomy: Bool
        let color: Color
        let depth: Int
        @Environment(\.theme) private var theme
        @Environment(\.linkFolder) private var folder

        var body: some View {
            switch block.kind {
            case .paragraph(let text):
                words(text)
            case .heading(let level, let text):
                words(text, font: MarkdownMessage.headingFont(level, roomy: roomy))
                    .padding(.top, level <= 2 ? (roomy ? 8 : 4) : (roomy ? 4 : 2)) // more room above a heading than below
                    .accessibilityAddTraits(.isHeader)
            case .list(let items) where depth < MarkdownMessage.deepest:
                ListView(items: items, roomy: roomy, color: color, depth: depth + 1)
            case .table(let table):
                TableView(table: table, roomy: roomy, color: color)
            case .code(let language, let text):
                CodeView(language: language, code: text, roomy: roomy)
            case .quote(let inner) where depth < MarkdownMessage.deepest:
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 1.5).fill(theme.hair).frame(width: 3)
                    Blocks(blocks: MessageBlocks.split(inner), roomy: roomy, color: theme.sub, depth: depth + 1)
                }
                .fixedSize(horizontal: false, vertical: true)
            case .list, .quote:
                words(block.source)
            case .rule:
                Rectangle().fill(theme.hair).frame(height: 1).padding(.vertical, roomy ? 4 : 2)
            }
        }

        private func words(_ text: String, font: Font? = nil) -> some View {
            MarkdownMessage.words(text, folder: folder, roomy: roomy, color: color, font: font)
        }
    }

    /// Words as `Prose` draws them: same size, line spacing and colour, selectable.
    static func words(_ text: String, folder: String?, roomy: Bool, color: Color, font: Font? = nil) -> some View {
        let styled = Prose.styled(text, folder: folder)
        return Text(styled)
            .font(font ?? (roomy ? Theme.body : Theme.small))
            .lineSpacing(roomy ? 6 : 4)
            .foregroundStyle(color)
            .tint(color)
            .fixedSize(horizontal: false, vertical: true)
            // Words with links are drawn by AppKit, with a pointing hand over each link (T-23); all words stay
            // selectable. Only at the body size: a heading keeps its own face, as SwiftUI text without the hand.
            .modifier(LinkWords(text: font == nil ? styled : AttributedString(), size: roomy ? 15 : 13, lineSpacing: roomy ? 6 : 4, color: color))
    }

    static func headingFont(_ level: Int, roomy: Bool) -> Font {
        switch level {
        case 1: return .system(size: roomy ? 20 : 16, weight: .semibold)
        case 2: return .system(size: roomy ? 17 : 14, weight: .semibold)
        default: return .system(size: roomy ? 15 : 13, weight: .semibold)
        }
    }

    // MARK: Lists

    struct ListView: View {
        let items: [MessageBlock.ListItem]
        let roomy: Bool
        let color: Color
        let depth: Int
        @Environment(\.theme) private var theme

        var body: some View {
            VStack(alignment: .leading, spacing: roomy ? 6 : 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.number.map { "\($0)." } ?? "•")
                            .font(roomy ? Theme.body : Theme.small)
                            .monospacedDigit()
                            .foregroundStyle(item.ordered ? color : theme.sub)
                            .frame(minWidth: item.ordered ? (roomy ? 20 : 17) : (roomy ? 12 : 10), alignment: .trailing)
                        VStack(alignment: .leading, spacing: roomy ? 6 : 4) {
                            // An item's text is Markdown again: a second paragraph or a code block inside it.
                            Blocks(blocks: MessageBlocks.split(item.text), roomy: roomy, color: color, depth: depth)
                            if !item.children.isEmpty {
                                if depth < MarkdownMessage.deepest {
                                    ListView(items: item.children, roomy: roomy, color: color, depth: depth + 1)
                                } else {
                                    MarkdownMessage.words(MarkdownMessage.plain(item.children), folder: nil, roomy: roomy, color: color)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Tables

    struct TableView: View {
        let table: MessageBlock.Table
        let roomy: Bool
        let color: Color
        @Environment(\.theme) private var theme
        @Environment(\.linkFolder) private var folder

        var body: some View {
            let mins = Self.columnWidths(table, roomy: roomy)
            let spacing: CGFloat = roomy ? 16 : 12
            // A table whose columns fit is drawn as a table, exactly as wide as the column offers (TableLayout);
            // one that does not (many columns, long words) shows each row as "Header: value" lines, so no column
            // is squeezed to a letter or two and nothing scrolls sideways inside the conversation.
            ViewThatFits(in: .horizontal) {
                TableLayout(columns: table.header.count, mins: mins, spacing: spacing) {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { c, cell in
                        self.cell(cell, column: c, header: true, last: table.rows.isEmpty)
                    }
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            self.cell(cell, column: c, header: false, last: r == table.rows.count - 1)
                        }
                    }
                }
                records
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Table, \(table.header.count) columns, \(table.rows.count) rows")
        }

        /// One cell, filling its slot (TableLayout gives every cell of a row the row's height), with the line under
        /// its row drawn on its own bottom edge so the lines of a row join up across the columns.
        private func cell(_ text: String, column c: Int, header: Bool, last: Bool) -> some View {
            let spacing: CGFloat = roomy ? 16 : 12
            return MarkdownMessage.words(text, folder: folder, roomy: roomy, color: color,
                                         font: header ? .system(size: roomy ? 15 : 13, weight: .semibold) : nil)
                .multilineTextAlignment(Self.text(alignment(c)))
                .padding(.vertical, roomy ? 6 : 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.top(alignment(c)))
                .padding(.trailing, c < table.header.count - 1 ? spacing : Self.overhang)
                .overlay(alignment: .bottom) {
                    if !last || header { Rectangle().fill(header ? theme.hair : theme.hair.opacity(0.5)).frame(height: 1) }
                }
        }

        /// The table as "Header: value" lines, row by row. Every cell keeps its header; an empty one shows the
        /// header alone, and a table with no rows shows its headers.
        private var records: some View {
            VStack(alignment: .leading, spacing: roomy ? 10 : 8) {
                if table.rows.isEmpty {
                    Text(table.header.map { Prose.styled($0) }.reduce(AttributedString()) { $0 + ($0.characters.isEmpty ? "" : " · ") + $1 })
                        .font(.system(size: roomy ? 15 : 13, weight: .semibold)).foregroundStyle(color)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                    if r > 0 { Rectangle().fill(theme.hair.opacity(0.5)).frame(height: 1) }
                    // (Each cell keeps its header, empty or not.)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(row.enumerated()), id: \.offset) { c, cell in
                            record(header: table.header[c], value: cell)
                        }
                    }
                }
            }
        }

        private func record(header: String, value: String) -> some View {
            var name = Prose.styled(header, folder: folder)
            name.font = .system(size: roomy ? 15 : 13, weight: .semibold)
            return Text(name + AttributedString(": ") + Prose.styled(value, folder: folder))
                .font(roomy ? Theme.body : Theme.small)
                .lineSpacing(roomy ? 6 : 4)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }

        /// Each column at least as wide as its longest word (up to 200 points), so words are not broken. A word is
        /// measured as it is drawn: the cell's styled text (`Prose.styled`), run by run in its own face (code in
        /// monospace, strong in bold, emphasis in italics; a header semibold), a word being everything between two
        /// spaces, across runs. 3% to spare for how SwiftUI sets it.
        static func columnWidths(_ table: MessageBlock.Table, roomy: Bool) -> [CGFloat] {
            let size: CGFloat = roomy ? 15 : 13
            return table.header.indices.map { c in
                var w = longestWord(table.header[c], size: size, header: true)
                for row in table.rows where c < row.count { w = max(w, longestWord(row[c], size: size, header: false)) }
                return ceil(w * 1.03) + 2
            }
        }

        /// A single word wider than this may break: a long address must not force a table out of its form.
        static let wordCap: CGFloat = 200
        // A piece the text engine cannot break at its space ("Copy .env.development.local", ".a, .b, .c") is not
        // capped: capped, it broke inside a word. A table whose pieces do not fit shows as "Header: value" lines.

        static func longestWord(_ text: String, size: CGFloat, header: Bool) -> CGFloat {
            let styled = Prose.styled(text)
            // The words as drawn, each with its width and the width of the space before it.
            var words: [(text: String, width: CGFloat, space: CGFloat, head: CGFloat)] = []
            var word = "", width: CGFloat = 0, space: CGFloat = 0, pendingSpace: CGFloat = 0, head: CGFloat = -1
            for run in styled.runs {
                let intent = run.inlinePresentationIntent ?? []
                let strong = intent.contains(.stronglyEmphasized)
                var font: NSFont = intent.contains(.code)
                    ? .monospacedSystemFont(ofSize: size, weight: strong || header ? .bold : .regular)
                    : .systemFont(ofSize: size, weight: strong ? .bold : (header ? .semibold : .regular))
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var piece = ""
                func add() {
                    guard !piece.isEmpty else { return }
                    // A word that starts with "/" may break after its next "/": only that head joins the word before.
                    if head < 0, (word + piece).first == "/" {
                        let all = word + piece
                        if let cut = all.dropFirst().firstIndex(of: "/") {
                            let headText = String(all[...cut])
                            if headText.count > word.count {
                                head = width + (String(headText.dropFirst(word.count)) as NSString).size(withAttributes: [.font: font]).width
                            }
                        }
                    }
                    width += (piece as NSString).size(withAttributes: [.font: font]).width; word += piece; piece = ""
                }
                for ch in String(styled[run.range].characters) {
                    if breaks(ch) {
                        add()
                        if !word.isEmpty { words.append((word, width, space, head < 0 ? width : head)); word = ""; width = 0; pendingSpace = 0; head = -1 }
                        pendingSpace += (String(ch) as NSString).size(withAttributes: [.font: font]).width
                        space = pendingSpace
                    } else { piece.append(ch) }
                }
                add()
            }
            if !word.isEmpty { words.append((word, width, space, head < 0 ? width : head)) }
            // A line never starts with a closing mark (". , : ; ! ? / ) ] }"), even after a space, and an opening
            // bracket or quote standing alone goes with the word after it: such pieces are drawn as one.
            var joined: [CGFloat] = []
            var i = 0
            while i < words.count {
                var w = words[i].width, pieces = 1
                while i + 1 < words.count, Self.opens(words[i].text) || Self.closes(words[i + 1].text) {
                    let next = words[i + 1]
                    if next.text.first == "/" && next.head < next.width {
                        // Joined only up to where the path may break; the path itself is measured on its own.
                        joined.append(w + next.space + next.head)
                        break
                    }
                    w += next.space + next.width
                    i += 1; pieces += 1
                }
                // A single word over the word cap counts only up to it (it will break wherever it is set).
                joined.append(pieces == 1 ? min(w, wordCap / 1.03) : w)
                i += 1
            }
            return joined.max() ?? 0
        }

        /// A piece a line cannot start with.
        static func closes(_ word: String) -> Bool {
            guard let c = word.first else { return false }
            return ".,:;!?/)]}»”’…%".contains(c)
        }

        /// An opening bracket or quote standing on its own.
        static func opens(_ word: String) -> Bool {
            !word.isEmpty && word.allSatisfy { "([{“‘«\"'".contains($0) }
        }

        /// Room after the last column for a glyph that leans past its box (an italic f).
        static let overhang: CGFloat = 2

        /// A space where a line may break. No-break spaces (as in "10 000" or "€ 1.250") hold a word together.
        static func breaks(_ ch: Character) -> Bool {
            guard ch.isWhitespace else { return false }
            return !ch.unicodeScalars.contains { [0x00A0, 0x202F, 0x2007, 0x2060, 0xFEFF].contains($0.value) }
        }

        private func alignment(_ column: Int) -> MessageBlock.Table.Alignment {
            column < table.alignments.count ? table.alignments[column] : .none
        }

        static func top(_ a: MessageBlock.Table.Alignment) -> Alignment {
            switch a { case .center: return .top; case .right: return .topTrailing; default: return .topLeading }
        }

        static func frame(_ a: MessageBlock.Table.Alignment) -> Alignment {
            switch a { case .center: return .center; case .right: return .trailing; default: return .leading }
        }

        static func text(_ a: MessageBlock.Table.Alignment) -> TextAlignment {
            switch a { case .center: return .center; case .right: return .trailing; default: return .leading }
        }
    }

    /// Lays out a table's cells (row by row, `columns` per row) in exactly the width offered. Every column gets at
    /// least its minimum; room left over goes to the columns whose words want more, in proportion. Asked for its
    /// ideal width it answers the sum of the minimums, so `ViewThatFits` chooses this form only when that fits.
    struct TableLayout: Layout {
        let columns: Int
        let mins: [CGFloat]
        let spacing: CGFloat

        private func minWidths() -> [CGFloat] {
            mins.enumerated().map { c, m in m + (c < columns - 1 ? spacing : TableView.overhang) }
        }

        private func widths(_ width: CGFloat?, _ cells: Subviews) -> [CGFloat] {
            var w = minWidths()
            let floor = w.reduce(0, +)
            guard let width, width > floor, columns > 0 else { return w }
            var want = w
            for (i, v) in cells.enumerated() {
                let c = i % columns
                want[c] = max(want[c], v.sizeThatFits(.unspecified).width)
            }
            let more = zip(want, w).map { max($0 - $1, 0) }
            let total = more.reduce(0, +)
            let room = width - floor
            if total <= room {
                // Everything fits on one line: the table is as wide as its words, not stretched.
                for c in w.indices { w[c] += more[c] }
            } else {
                for c in w.indices { w[c] += room * more[c] / total }
            }
            return w
        }

        private func rows(_ widths: [CGFloat], _ cells: Subviews) -> [CGFloat] {
            guard columns > 0 else { return [] }
            var heights: [CGFloat] = []
            for (i, v) in cells.enumerated() {
                let r = i / columns, c = i % columns
                if r == heights.count { heights.append(0) }
                heights[r] = max(heights[r], v.sizeThatFits(ProposedViewSize(width: widths[c], height: nil)).height)
            }
            return heights
        }

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let w = widths(proposal.width, subviews)
            return CGSize(width: w.reduce(0, +), height: rows(w, subviews).reduce(0, +))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let w = widths(bounds.width, subviews)
            let h = rows(w, subviews)
            var y = bounds.minY
            for (i, v) in subviews.enumerated() {
                let r = i / columns, c = i % columns
                if c == 0 && r > 0 { y += h[r - 1] }
                let x = bounds.minX + w[..<c].reduce(0, +)
                v.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: w[c], height: h[r]))
            }
        }
    }

    // MARK: Code

    struct CodeView: View {
        let language: String?
        let code: String
        let roomy: Bool
        @Environment(\.theme) private var theme
        @State private var copied = false
        @State private var hover = false

        var body: some View {
            VStack(alignment: .leading, spacing: 2) { // the Copy area's own 6 below makes the gap
                HStack {
                    if let language, !language.isEmpty {
                        Text(language).font(.system(size: 11)).foregroundStyle(theme.sub)
                    }
                    Spacer(minLength: 8)
                    Button {
                        MarkdownMessage.copy(code, to: Clip.board)   // the rig swaps in its own board
                        withAnimation(.easeOut(duration: 0.15)) { copied = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation(.easeOut(duration: 0.15)) { copied = false }
                        }
                    } label: {
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.ink.opacity(hover ? 1 : 0.75))
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(theme.ink.opacity(0.5)).frame(height: 1).offset(y: 2).opacity(hover ? 1 : 0)
                            }
                            // A larger area to hit than the word itself (the box's top inset is smaller by as much).
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hover = $0 }
                    .help("Copy the code")
                    .accessibilityLabel(copied ? "Copied" : "Copy the code")
                }
                // Long lines wrap: a sideways scroll area inside the conversation would catch the scroll wheel.
                Text(code)
                    .font(.system(size: roomy ? 13 : 12, design: .monospaced))
                    .lineSpacing(roomy ? 3 : 2)
                    .foregroundStyle(theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.trailing, 8) // with the box's own 8 / 4: the same right inset as before
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, roomy ? 16 : 12)
            .padding(.trailing, roomy ? 8 : 4) // the Copy area's own 8 brings the word to 16 / 12
            .padding(.top, roomy ? 6 : 2)       // and its 6 brings it to 12 / 8
            .padding(.bottom, roomy ? 12 : 8)
            .background(theme.bubble, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    /// Items past the nesting limit, as indented plain lines.
    static func plain(_ items: [MessageBlock.ListItem], level: Int = 0) -> String {
        items.map { item in
            String(repeating: "  ", count: level) + (item.number.map { "\($0). " } ?? "• ") + item.text
                + (item.children.isEmpty ? "" : "\n" + plain(item.children, level: level + 1))
        }.joined(separator: "\n")
    }

    /// The code exactly as written, as plain text. Tests pass a private board, never the user's clipboard.
    static func copy(_ code: String, to pb: NSPasteboard = .general) {
        pb.clearContents()
        pb.setString(code, forType: .string)
    }
}
