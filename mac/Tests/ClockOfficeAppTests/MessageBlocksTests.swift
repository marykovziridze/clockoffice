import Foundation
import Testing
@testable import ClockOffice

/// T-34 part 1: a message is cut into Markdown blocks, never inside a table or a code block.

private func kinds(_ text: String) -> [String] {
    MessageBlocks.split(text).map { b in
        switch b.kind {
        case .heading(let l, _): return "h\(l)"
        case .paragraph: return "p"
        case .list: return "list"
        case .table: return "table"
        case .code: return "code"
        case .quote: return "quote"
        case .rule: return "rule"
        }
    }
}

@Test func blankLinesInsideACodeBlockDoNotCutIt() {
    let text = "Run this:\n\n```swift\nlet a = 1\n\n\nlet b = 2\n```\n\nDone."
    #expect(kinds(text) == ["p", "code", "p"])
    guard case .code(let lang, let body) = MessageBlocks.split(text)[1].kind else { Issue.record("no code"); return }
    #expect(lang == "swift")
    #expect(body == "let a = 1\n\n\nlet b = 2")
    // The old blank-line cut made four pieces of it, two of them halves of the code block.
    #expect(text.components(separatedBy: "\n\n").count == 4)
}

@Test func aFenceInsideACodeBlockOfTheOtherKindDoesNotCloseIt() {
    let text = "~~~\n```\nstill code\n~~~\nafter"
    #expect(kinds(text) == ["code", "p"])
    // A longer fence is closed only by one at least as long.
    #expect(kinds("````\n```\n\nx\n````") == ["code"])
}

@Test func anUnclosedCodeBlockRunsToTheEnd() {
    let blocks = MessageBlocks.split("Start\n\n```\nline\n\nmore")
    #expect(blocks.count == 2)
    guard case .code(_, let body) = blocks[1].kind else { Issue.record("no code"); return }
    #expect(body == "line\n\nmore")
}

@Test func aTableIsOneBlockWithItsCellsAndAlignments() {
    let text = """
    Here is the table:
    | Name | Count | Note |
    |:-----|------:|:----:|
    | a | 1 | x `a|b` |
    | b \\| c | 2 |
    After.
    """
    #expect(kinds(text) == ["p", "table", "p"])
    guard case .table(let t) = MessageBlocks.split(text)[1].kind else { Issue.record("no table"); return }
    #expect(t.header == ["Name", "Count", "Note"])
    #expect(t.alignments == [.left, .right, .center])
    #expect(t.rows == [["a", "1", "x `a|b`"], ["b | c", "2", ""]])
}

@Test func linesWithPipesButNoDelimiterRowAreNotATable() {
    #expect(kinds("a | b\nc | d") == ["p"])
    #expect(kinds("| a | b |\n| - |") == ["p"]) // column counts differ
}

@Test func headingsRulesAndQuotes() {
    let text = "# Title #\n\nIntro\n\n---\n\n> quoted\n>\n> ```\n>\n> code\n> ```\nlazy line\n\nSub\n===\n\n### Three"
    #expect(kinds(text) == ["h1", "p", "rule", "quote", "h1", "h3"])
    let blocks = MessageBlocks.split(text)
    guard case .heading(_, let t) = blocks[0].kind else { return }
    #expect(t == "Title")
    guard case .quote(let inner) = blocks[3].kind else { Issue.record("no quote"); return }
    #expect(inner == "quoted\n\n```\n\ncode\n```\nlazy line")
    #expect(kinds(inner) == ["p", "code", "p"])
}

@Test func aNestedListStaysOneBlockAcrossBlankLines() {
    let text = """
    Steps:

    1. First
       - a
       - b

         more about b
    2. Second
       ```
       code in item

       still code
       ```
    3. Third

    Afterwards.
    """
    #expect(kinds(text) == ["p", "list", "p"])
    guard case .list(let items) = MessageBlocks.split(text)[1].kind else { Issue.record("no list"); return }
    #expect(items.map(\.number) == [1, 2, 3])
    #expect(items[0].text == "First")
    #expect(items[0].children.map(\.text) == ["a", "b\n\nmore about b"])
    #expect(items[0].children.allSatisfy { !$0.ordered })
    #expect(items[1].text == "Second\n```\ncode in item\n\nstill code\n```")
    #expect(items[2].text == "Third")
}

@Test func aBulletListAndANumberedListAreTwoBlocks() {
    #expect(kinds("- a\n- b\n1. c\n2. d") == ["list", "list"])
}

@Test func runningTextWithANumberIsNotAList() {
    // "2024." at a line start inside a paragraph does not start a list (CommonMark: only 1. may interrupt).
    #expect(kinds("We shipped it in\n2024. Then more.") == ["p"])
    #expect(kinds("Text\n- item") == ["p", "list"])
}

@Test func starsAndDashesAloneAreRulesNotItems() {
    #expect(kinds("***\n\n- - -\n\n- item") == ["rule", "rule", "list"])
}

@Test func paragraphsAreKeptAsTheOldCutKeptThem() {
    let text = "One line\nsecond line\n\nTwo\n\n\n\nThree"
    #expect(MessageBlocks.paragraphs(text) == ["One line\nsecond line", "Two", "Three"])
}

@Test func windowsLineEndingsReadTheSame() {
    #expect(kinds("a\r\n\r\n```\r\nx\r\n\r\ny\r\n```") == ["p", "code"])
}

@Test func theClosingBlocksNeverCutAndAlwaysKeepTheLast() {
    let table = "| a | b |\n|---|---|\n" + Array(repeating: "| xxxxxxxxxx | yyyyyyyyyy |", count: 40).joined(separator: "\n")
    let blocks = MessageBlocks.split("Intro.\n\n" + table)
    let shown = MessageBlocks.closing(blocks)
    #expect(shown.count == 1)
    guard case .table(let t) = shown[0].kind else { Issue.record("no table"); return }
    #expect(t.rows.count == 40)

    let short = MessageBlocks.split("A.\n\nB.\n\nC?")
    #expect(MessageBlocks.closing(short).map(\.source) == ["A.", "B.", "C?"])
    let long = MessageBlocks.split(String(repeating: "x", count: 400) + "\n\n" + String(repeating: "y", count: 100) + "\n\nWhat next?")
    #expect(MessageBlocks.closing(long).map(\.source.count) == [100, 10])
}

@Test func theSourceOfEveryBlockIsTheTextAsWritten() {
    let text = "# H\n\n| a |\n|---|\n| 1 |\n\n```js\nx\n```\n\n> q"
    let sources = MessageBlocks.split(text).map(\.source)
    #expect(sources == ["# H", "| a |\n|---|\n| 1 |", "```js\nx\n```", "> q"])
    #expect(MessageBlocks.split("").isEmpty)
    #expect(MessageBlocks.split("\n\n  \n").isEmpty)
}

@Test func aHeadingWithALongRunOfSpacesIsReadInLinearTime() {
    // Verifier T-34-part1-1 F1: a pattern match on such a line took 12 s for 16,384 spaces.
    let line = "# a" + String(repeating: " ", count: 65_536) + "b #"
    let start = Date()
    let blocks = MessageBlocks.split(line)
    #expect(Date().timeIntervalSince(start) < 1)
    guard case .heading(_, let t) = blocks.first?.kind else { Issue.record("no heading"); return }
    #expect(t.hasPrefix("a") && t.hasSuffix("b"))
    #expect(kinds("# Title ##") == ["h1"])
    guard case .heading(_, let u) = MessageBlocks.split("# C# and F#").first?.kind else { return }
    #expect(u == "C# and F#")
}

@Test func anIndentedCodeBlockWithBlankLinesIsOneBlock() {
    let text = "Text\n\n    ```\n    a\n\n    b\n    ```\n\nAfter"
    #expect(kinds(text) == ["p", "code", "p"])
    guard case .code(_, let body) = MessageBlocks.split(text)[1].kind else { return }
    #expect(body == "```\na\n\nb\n```")
    #expect(kinds("Text\n\n\tx\n\n\ty") == ["p", "code"])
    // Indented under a paragraph line it is the paragraph going on, not code.
    #expect(kinds("Text\n    more") == ["p"])
}

@Test func aFenceInAListItemEndsWithTheItem() {
    // Verifier F3: an item that opens a fence and never closes it must not swallow what follows the list.
    let text = "- ```\n  code\n- next\n\nAfter the list.\n\n| a |\n|---|\n| 1 |"
    #expect(kinds(text) == ["list", "p", "table"])
    // A fence that closes at the item's indent closes.
    let nested = "- item\n  - sub\n    ```\n    x\n\n    y\n    ```\n- two\n\nEnd."
    #expect(kinds(nested) == ["list", "p"])
    guard case .list(let items) = MessageBlocks.split(nested)[0].kind else { return }
    #expect(items.count == 2)
    #expect(items[0].children.first?.text == "sub\n```\nx\n\ny\n```")
}

@Test func paragraphsAreTrimmedAsTheOldCutTrimmedThem() {
    #expect(MessageBlocks.paragraphs("  lead\n\ntrail  ") == ["lead", "trail"])
}

@Test func aCodeBlockLeftOfItsItemsTextEndsTheItemAndStaysWhole() {
    // Verifier T-34-part1-2 F8: the item's text starts at column 5, its code at column 4. CommonMark: the item
    // ends, and the indented lines with their blank line are one code block.
    let one = "1.   ```bash\n    npm i\n\n    npm test\n     ```\n\nDone."
    #expect(kinds(one) == ["list", "code", "p"])
    #expect(MessageBlocks.split(one)[1].source == "    npm i\n\n    npm test\n     ```")
    let two = "Steps:\n\n   1. Add this to `config.py`:\n      ```python\n    DEBUG = True\n\n    PORT = 8080\n      ```\n\nThen run it."
    let blocks = MessageBlocks.split(two)
    #expect(kinds(two) == ["p", "list", "code", "p"])
    #expect(blocks[2].source == "    DEBUG = True\n\n    PORT = 8080\n      ```")
    // Control: the code at the item's own text column stays in the item.
    #expect(kinds("1.   ```bash\n     npm i\n\n     npm test\n     ```\n\nDone.") == ["list", "p"])
}

@Test func anOpenCodeBlockInTheLastItemDoesNotSwallowWhatFollows() {
    // Verifier F3b and F3c.
    #expect(kinds("- a\n- ```\n  code\n\nAfter.\n\n| a |\n|---|\n| 1 |") == ["list", "p", "table"])
    #expect(kinds("- item\n      ```\n      x\n      ```\n\nNext paragraph.") == ["list", "p"])
}

@Test func aCodeBlockWhoseLinesLookLikeItemsStaysWhole() {
    // Verifier T-34-3 F10: a diff's "- old" lines left of the item's text are code, not list items.
    let text = "1.   ```diff\n    - old\n    + new\n\n    - old2\n    + new2\n     ```\n\nDone."
    #expect(kinds(text) == ["list", "code", "p"])
    #expect(MessageBlocks.split(text)[1].source == "    - old\n    + new\n\n    - old2\n    + new2\n     ```")
    // Control: a real next item after a closed fence goes on the list.
    #expect(kinds("1. ```\n   x\n   ```\n2. next") == ["list"])
}

@Test func tabIndentedCodeInAListItemStaysOneBlock() {
    // Verifier T-34-3 F11: tabs were not taken off an item's lines, so its fence was not seen.
    let text = "1. Run:\n\t```bash\n\tnpm i\n\n\tnpm test\n\t```\n2. Next"
    guard case .list(let items) = MessageBlocks.split(text).first?.kind else { Issue.record("no list"); return }
    let inner = MessageBlocks.split(items[0].text)
    #expect(inner.map(\.kind).count == 2)
    guard case .code(let lang, let body) = inner[1].kind else { Issue.record("no code"); return }
    #expect(lang == "bash")
    #expect(body == "npm i\n\nnpm test")
}

@Test func anIndentedListsCodeBlockWithItemLikeLinesStaysWhole() {
    // Verifier T-34-4 F10b: the list starts two columns in; "- old" at column 4 is still code.
    let text = "  1.   ```diff\n    - old line\n    + new line\n\n    - old2\n    + new2\n       ```\n\nDone."
    let blocks = MessageBlocks.split(text)
    #expect(kinds(text) == ["list", "code", "p"])
    #expect(blocks.count == 3 && blocks[1].source.hasPrefix("    - old line") && blocks[1].source.hasSuffix("```"))
}
