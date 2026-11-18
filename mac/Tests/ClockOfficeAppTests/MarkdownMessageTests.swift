import AppKit
import SwiftUI
import Testing
@testable import ClockOffice
import ClockOfficeUI

/// T-34 part 2: a message drawn as formatted text. With CLOCKOFFICE_SHOTS=<folder> set, the sample is also saved
/// as PNG pictures in light and dark, for the window and the dropdown, so the design can be looked at.

let markdownSample = """
## What changed

The splitter now keeps **tables** and `code` whole. Three things:

1. Headings, paragraphs and rules
2. Lists, with nesting:
   - a bullet under a number
   - another, with a second line
     that goes on
3. Tables and code blocks

| File | Lines | State |
|:-----|------:|:-----:|
| MessageBlocks.swift | 420 | done |
| MarkdownMessage.swift | 260 | **new** |

```swift
let blocks = MessageBlocks.split(text)

// a blank line above stays inside the block
print(blocks.count)
```

> A quote: what the verifier said,
> on two lines.

---

Shall I merge it?
"""

@MainActor
private func render(_ view: some View, width: CGFloat, dark: Bool) -> NSImage? {
    let theme = dark ? Theme.dark : Theme.light
    let content = view
        .environment(\.theme, theme)
        .padding(20)
        .frame(width: width, alignment: .leading)
        .background(theme.panel)
        .environment(\.colorScheme, dark ? .dark : .light)
    let r = ImageRenderer(content: content)
    r.scale = 2
    return r.nsImage
}

/// The width the view itself takes when offered `width`: a forced frame cannot hide a view that is too wide.
@MainActor
private func takes(_ view: some View, width: CGFloat) -> CGSize {
    let host = NSHostingController(rootView: view.environment(\.theme, Theme.light))
    return host.sizeThatFits(in: CGSize(width: width, height: 100_000))
}

@MainActor @Test func theSampleDrawsInTheWindowAndTheDropdownInBothLooks() throws {
    let out = ProcessInfo.processInfo.environment["CLOCKOFFICE_SHOTS"].map { URL(fileURLWithPath: $0) }
    if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
    for (name, roomy, width) in [("window", true, CGFloat(720)), ("dropdown", false, CGFloat(420))] {
        for dark in [false, true] {
            let theme = dark ? Theme.dark : Theme.light
            let image = render(MarkdownMessage(markdownSample, roomy: roomy, color: theme.ink), width: width, dark: dark)
            let size = try #require(image).size
            #expect(size.width == width)
            // Everything is laid out: the sample's eighteen lines and its code block, not one squeezed line.
            #expect(size.height > (roomy ? 550 : 450))
            if let out, let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: out.appendingPathComponent("markdown-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }
}

@MainActor @Test func aMessageWithoutMarkdownDrawsAsTheOldParagraphsDid() {
    let text = "First paragraph.\n\nSecond one, a little longer."
    let blocks = MessageBlocks.split(text)
    #expect(blocks.count == 2)
    let a = render(MarkdownMessage(blocks: blocks, roomy: false, color: .black), width: 420, dark: false)
    let b = render(Prose(paragraphs: MessageBlocks.paragraphs(text), roomy: false, color: .black), width: 420, dark: false)
    // Same layout: same height to the point.
    #expect(a?.size.height == b?.size.height)
}

@Test func copyPutsTheCodeExactlyOnTheClipboard() {
    // A private board: a test never touches the user's own clipboard.
    // Of the user's clipboard only its change counter is looked at, never its contents.
    let before = NSPasteboard.general.changeCount
    let pb = NSPasteboard(name: NSPasteboard.Name("clockoffice-test-\(UUID().uuidString)"))
    defer { pb.releaseGlobally() }
    MarkdownMessage.copy("let a = 1\n\n  indented\n", to: pb)
    #expect(pb.string(forType: .string) == "let a = 1\n\n  indented\n")
    #expect(NSPasteboard.general.changeCount == before)
}

@MainActor @Test func aWideTableAndALongCodeLineStayInsideTheColumn() throws {
    let header = (1...9).map { "Column \($0)" }
    let row = (1...9).map { "value-\($0)-with-some-length" }
    let top: String = "| " + header.joined(separator: " | ") + " |"
    let rule: String = "|" + String(repeating: "---|", count: 9)
    let cells: String = "| " + row.joined(separator: " | ") + " |"
    let table = [top, rule, cells].joined(separator: "\n")
    let code = "```\n" + String(repeating: "x", count: 600) + "\n```"
    for text in [table, code] {
        let size = takes(MarkdownMessage(text, roomy: false, color: .black), width: 420)
        #expect(size.width <= 420) // nothing pushes the page sideways
    }
    // Control: the measure sees a view that is too wide.
    #expect(takes(Text(String(repeating: "x", count: 300)).fixedSize(), width: 420).width > 420)
}

@MainActor @Test func deepQuotesAndListsStopNestingAtTheLimit() throws {
    // Verifier T-34-part1-2: a quote's inside is split again by the view; a long line of > marks must stay cheap.
    let quotes = String(repeating: ">", count: 50_000) + " deep"
    var list = ""
    for d in 0..<40 { list += String(repeating: "  ", count: d) + "- level \(d)\n" }
    for text in [quotes, list] {
        let start = Date()
        let image = try #require(render(MarkdownMessage(text, roomy: false, color: .black), width: 420, dark: false))
        #expect(image.size.width == 420)
        #expect(Date().timeIntervalSince(start) < 5)
    }
}

@MainActor @Test func noTableColumnIsNarrowerThanItsLongestWord() {
    // Verifier T-34-3 F12: columns were squeezed to one letter.
    let header = (1...12).map { "Col\($0)" }
    let row = (1...12).map { "word\($0)" }
    let text = ["| " + header.joined(separator: " | ") + " |", "|" + String(repeating: "---|", count: 12), "| " + row.joined(separator: " | ") + " |"].joined(separator: "\n")
    guard case .table(let table) = MessageBlocks.split(text).first?.kind else { Issue.record("no table"); return }
    let mins = MarkdownMessage.TableView.columnWidths(table, roomy: false)
    let word = ("word12" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    #expect(mins.allSatisfy { $0 >= 30 })
    #expect(mins.last! >= word)
    #expect(takes(MarkdownMessage(text, roomy: false, color: .black), width: 420).width <= 420)
    let few = "| Name | What it does | State |\n|---|---|:---:|\n| MessageBlocks.swift | splits a message into whole blocks, never inside a table or code block | done |\n| MarkdownMessage.swift | draws the blocks | new |"
    if let dir = ProcessInfo.processInfo.environment["CLOCKOFFICE_SHOTS"] {
        for (name, t) in [("table-wide", text), ("table-wrapping", few)] {
            if let tiff = render(MarkdownMessage(t, roomy: false, color: Theme.light.ink), width: 420, dark: false)?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("markdown-\(name).png"))
            }
        }
    }
}

@MainActor @Test func aTableNeverDrawsWiderThanItsColumnAndKeepsEveryHeader() throws {
    // Verifier T-34-4 F15, F16, F17.
    let headerOnly = "| " + (1...12).map { "Heading number \($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 12)
    let emptyColumn = "| A | Empty | C |\n|---|---|---|\n| " + String(repeating: "word ", count: 30) + "| | c |"
    let bold = "| Term | Note |\n|---|---|\n| **Internationalisation** | a long bold word in a narrow column |"
    for text in [headerOnly, emptyColumn, bold, markdownSample] {
        for width in [CGFloat(420), 720] {
            let size = takes(MarkdownMessage(text, roomy: width > 500, color: .black), width: width)
            #expect(size.width <= width)
            #expect(size.height > 10)
        }
    }
    guard case .table(let t) = MessageBlocks.split(bold).first?.kind else { Issue.record("no table"); return }
    let word = ("Internationalisation" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .semibold)]).width
    #expect(MarkdownMessage.TableView.columnWidths(t, roomy: true)[0] >= word)
    if let dir = ProcessInfo.processInfo.environment["CLOCKOFFICE_SHOTS"] {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, text) in [("table-header-only", headerOnly), ("table-empty-column", emptyColumn), ("table-bold", bold)] {
            if let tiff = render(MarkdownMessage(text, roomy: false, color: Theme.light.ink), width: 420, dark: false)?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("markdown-\(name).png"))
            }
        }
    }
}

@Test func aBoldWordOfWideCapitalsFitsItsColumn() {
    // Verifier T-34-5 F17b: ACKNOWLEDGEMENT in bold needed 162 pt where its column got 161.5.
    for word in ["ACKNOWLEDGEMENT", "WWWWWWWWWWWWW", "MWMWMWMWMWMWMW"] {
        let text = "| Term | Note |\n|---|---|\n| **\(word)** | " + String(repeating: "a long sentence ", count: 12) + "|"
        guard case .table(let t) = MessageBlocks.split(text).first?.kind else { Issue.record("no table"); return }
        for roomy in [true, false] {
            let size: CGFloat = roomy ? 15 : 13
            let drawn = (word as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold)]).width
            #expect(MarkdownMessage.TableView.columnWidths(t, roomy: roomy)[0] >= drawn)
        }
    }
    // Plain words are no longer measured as code: a column of ordinary words is not widened to monospace.
    let plain = "| N |\n|---|\n| illicitly |"
    guard case .table(let p) = MessageBlocks.split(plain).first?.kind else { return }
    let mono = ("illicitly" as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)]).width
    #expect(MarkdownMessage.TableView.columnWidths(p, roomy: false)[0] < mono)
}

@MainActor @Test func aWordThatIsPartCodePartTextIsMeasuredWhole() {
    // Verifier T-34-6 F18: `Views.swift`:1161 was measured as its longest piece and broke inside its column.
    for cell in ["`Views.swift`:1161", "`TableLayout`s", "`ViewThatFits`(in:)", "(`MessageBlocks.split`)", "`**kwargs`"] {
        let text = "| Where | Note |\n|---|---|\n| \(cell) | " + String(repeating: "a long sentence ", count: 12) + "|"
        guard case .table(let t) = MessageBlocks.split(text).first?.kind else { Issue.record("no table"); return }
        for roomy in [true, false] {
            let size: CGFloat = roomy ? 15 : 13
            // The whole word as drawn, in one piece, measured by SwiftUI itself.
            let drawn = NSHostingController(rootView: Text(Prose.styled(cell)).font(.system(size: size)).fixedSize())
                .sizeThatFits(in: CGSize(width: 10_000, height: 1_000)).width
            #expect(MarkdownMessage.TableView.columnWidths(t, roomy: roomy)[0] >= drawn, "\(cell) at \(size)")
        }
    }
}

@MainActor @Test func wordsJoinedByNoBreakSpacesAreMeasuredWhole() {
    // Verifier T-34-7 F19.
    for cell in ["10\u{00A0}000\u{00A0}000\u{00A0}000", "€\u{00A0}1.250.000", "99,5\u{202F}%", "12\u{2007}345\u{2007}678"] {
        let text = "| Amount | Note |\n|---|---|\n| \(cell) | " + String(repeating: "a long sentence ", count: 12) + "|"
        guard case .table(let t) = MessageBlocks.split(text).first?.kind else { Issue.record("no table"); return }
        for roomy in [true, false] {
            let size: CGFloat = roomy ? 15 : 13
            let drawn = NSHostingController(rootView: Text(Prose.styled(cell)).font(.system(size: size)).fixedSize())
                .sizeThatFits(in: CGSize(width: 10_000, height: 1_000)).width
            #expect(MarkdownMessage.TableView.columnWidths(t, roomy: roomy)[0] >= drawn, "\(cell) at \(size)")
        }
    }
    #expect(MarkdownMessage.TableView.breaks(" "))
    #expect(!MarkdownMessage.TableView.breaks("\u{00A0}"))
}

@MainActor @Test func aPieceThatCannotStartALineIsMeasuredWithTheWordBeforeIt() {
    // Verifier T-34-8 F22 and F21: "Edit .gitignore" is drawn as one piece, so is "( Configuration )".
    for cell in ["Edit `.gitignore`", "Copy `.env.local`", "overwrote .env.local", "add !important", "in `.claude/worktrees/x`", "( Configuration )", "{ ...defaultProps }"] {
        let text = "| What | Note |\n|---|---|\n| \(cell) | " + String(repeating: "a long sentence ", count: 12) + "|"
        guard case .table(let t) = MessageBlocks.split(text).first?.kind else { Issue.record("no table"); return }
        for roomy in [true, false] {
            let size: CGFloat = roomy ? 15 : 13
            let drawn = NSHostingController(rootView: Text(Prose.styled(cell)).font(.system(size: size)).fixedSize())
                .sizeThatFits(in: CGSize(width: 10_000, height: 1_000)).width
            #expect(MarkdownMessage.TableView.columnWidths(t, roomy: roomy)[0] >= min(drawn, 200), "\(cell) at \(size)")
        }
    }
    // Ordinary words still measure one by one: a column of a sentence is not as wide as the sentence.
    let text = "| A |\n|---|\n| one two three four five six seven |"
    guard case .table(let t) = MessageBlocks.split(text).first?.kind else { return }
    #expect(MarkdownMessage.TableView.columnWidths(t, roomy: false)[0] < 60)
}

@MainActor @Test func aJoinedPieceKeepsItsWholeWidth() {
    // Verifiers T-34-9 and T-34-11: a piece the text engine draws unbroken was capped (200, then 320) and broke.
    for cell in ["Copy `.env.development.local`", "`.env.development.local`, `.env.production.local`, `.env.local`",
                 "`.ts`, `.tsx`, `.js`, `.jsx`, `.json`, `.css`, `.html`, `.md`"] {
        let text = "| What | Note |\n|---|---|\n| \(cell) | short |"
        guard case .table(let t) = MessageBlocks.split(text).first?.kind else { Issue.record("no table"); return }
        let drawn = NSHostingController(rootView: Text(Prose.styled(cell)).font(.system(size: 13)).fixedSize())
            .sizeThatFits(in: CGSize(width: 10_000, height: 1_000)).width
        #expect(MarkdownMessage.TableView.columnWidths(t, roomy: false)[0] >= drawn - 1, "\(cell)")
    }
    // A path after a word joins only up to its first inner "/", where a line may break.
    let path = "| A |\n|---|\n| in /usr/local/share/very/long/path/name |"
    guard case .table(let p) = MessageBlocks.split(path).first?.kind else { return }
    let whole = ("in /usr/local/share/very/long/path/name" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width
    #expect(MarkdownMessage.TableView.columnWidths(p, roomy: false)[0] < whole)
    // A single very long word is still capped, so one long address does not push a table out of its form.
    let long = "| A |\n|---|\n| " + String(repeating: "x", count: 120) + " |"
    guard case .table(let t) = MessageBlocks.split(long).first?.kind else { return }
    #expect(MarkdownMessage.TableView.columnWidths(t, roomy: false)[0] <= MarkdownMessage.TableView.wordCap + 2)
}
