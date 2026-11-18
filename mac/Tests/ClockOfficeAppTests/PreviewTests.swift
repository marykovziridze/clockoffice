import Foundation
import Testing
@testable import ClockOffice

/// T-34 / T-44: a held-short message in the dropdown shows its last words as plain text, never Markdown source.

private func preview(_ text: String) -> String? { ConversationView.preview(MessageBlocks.split(text)) }

@Test func aParagraphIsItsOwnPreview() {
    #expect(preview("First.\n\nThe last words.") == "The last words.")
}

@Test func aTableOrCodeAtTheEndIsNamed() {
    #expect(preview("Done:\n\n| Page | Old |\n|---|---|\n| a | b |") == "A table: Page, Old")
    #expect(preview("Run:\n\n```bash\nnpm i\n```") == "A block of bash code")
    #expect(preview("| | |\n|---|---|\n| a | b |") == "A table")
}

@Test func aStepWithCodeNamesTheCode() {
    #expect(preview("Two steps:\n\n1. Install it:\n\n   ```bash\n   npm install\n   ```") == "1. Install it: A block of bash code")
}

@Test func anItemThatIsOnlyCodeOrATableIsNamedNotALoneBullet() {
    let code = preview("Do this:\n\n- ```bash\n  npm install\n  ```")
    #expect(code == "• A block of bash code")
    let table = preview("- | A | B |\n  |---|---|\n  | 1 | 2 |")
    #expect(table == "• A table: A, B")
}

@Test func numbersAndNestingAreKept() {
    #expect(preview("1. first\n2. second") == "2. second")
    #expect(preview("- a\n- b\n  - child") == "• child")
}

@Test func codeAfterNestedItemsIsTheLastWord() {
    let p = preview("- a\n  - b\n\n  ```sh\n  ls\n  ```")
    #expect(p?.contains("A block of sh code") == true, "\(p ?? "nil")")
}

@Test func codeBeforeNestedItemsLeavesTheLastNestedItemAsTheLastWord() {
    #expect(preview("1. Install it:\n\n   ```bash\n   npm i\n   ```\n\n   - and a\n   - and b") == "• and b")
    #expect(preview("- See:\n\n  | A | B |\n  |---|---|\n  | 1 | 2 |\n\n  - last note") == "• last note")
}

@Test func nestedItemsAfterTheItemsOwnTextAreTheLastWordAgain() {
    #expect(preview("1. Install:\n   - b1\n\n   ```bash\n   ls\n   ```\n\n   - b2 last") == "• b2 last")
    #expect(preview("- A\n  - a1\n\n  middle text\n\n  - b2 last") == "• b2 last")
}

@Test func anEmptyLastNestedItemLooksAtItsEarlierSiblings() {
    #expect(preview("- Parent\n  - kid1\n  -") == "• kid1")
}

@Test func anEmptyLastItemLooksAtTheItemsBeforeIt() {
    #expect(preview("- first\n-") == "• first")
}

@Test func aDeeplyNestedListIsPreviewedAtOnce() {
    let text = (0..<40).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
    let start = Date()
    #expect(preview(text) == "• level 39")
    #expect(Date().timeIntervalSince(start) < 0.5)
}

@Test func aQuoteEndingInAnEmptyItemShowsNoSource() {
    let p = preview("> Hello\n>\n> -") ?? ""
    #expect(p == "Hello", "\(p)")
}

@Test func noPreviewEverShowsMarkdownSource() {
    let samples = [
        "- ```bash\n  ls\n  ```", "1. x\n\n   | A | B |\n   |---|---|\n   | 1 | 2 |",
        "> ```\n> code\n> ```", "- a\n  - b\n\n  ```sh\n  ls\n  ```",
    ]
    for s in samples {
        let p = preview(s) ?? ""
        #expect(!p.contains("```") && !p.contains("|---") && !p.hasSuffix("• "), "\(s) → \(p)")
    }
}
