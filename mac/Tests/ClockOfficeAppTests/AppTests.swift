import Foundation
import Testing
@testable import ClockOffice
@testable import ClockOfficeCore

/// The app's own code, which the core tests cannot reach: what a conversation's text becomes on screen.

private func links(_ markdown: String) -> [String] {
    let a = Prose.styled(markdown, links: true)
    // Letter by letter: read by whole characters, a link that an accent follows loses its last letter.
    return a.runs.compactMap { run in
        var words = String.UnicodeScalarView()
        words.append(contentsOf: a.unicodeScalars[run.range])
        return run.link.map { "\(String(words))>\($0.host ?? $0.scheme ?? "?")" }
    }
}

@Test func twoLinksThatReadAsOneAddressAreNeitherALink() {
    // Verifiers 16, 17 and 18 (2026-11-17): "https://good.example" followed at once by "/login" that goes to
    // another site reads as one address. Nothing visible between them: both lose their link.
    let unseen = ["", "\u{200B}", "\u{2060}", "\u{00AD}", "\u{FE0F}", "\u{0301}", "\u{200D}", "\u{200A}", "\u{3164}", "\u{200B}\u{FEFF}"]
    for mid in unseen {
        let got = links("[https://good.example](https://good.example)\(mid)[/login](https://evil.example)")
        #expect(got.isEmpty, "between the links: \(mid.unicodeScalars.map { String($0.value, radix: 16) }), still linked: \(got)")
    }
    // A space the eye sees separates them: two links, each going where it says.
    #expect(links("[https://good.example](https://good.example) [the docs](https://docs.example)").count == 2)
    #expect(links("see [one](https://a.example/one) and [two](https://b.example/two)").count == 2)
}

@Test func aLinkWhoseWordsNameAnotherSiteIsPlainWords() {
    for words in ["https://good.example", "HTTPS://GOOD.EXAMPLE", "h\u{200B}ttps://good.example", "https\u{200B}://good.example",
                  "ht\u{00AD}tps://good.example", "https://good.example\u{200D}", "\u{202E}elpmaxe.doog//:sptth\u{202C}",
                  "https://\u{202E}elpmaxe.doog\u{202C}"] {
        #expect(links("[\(words)](https://evil.example)").isEmpty, "\(words.unicodeScalars.map { String($0.value, radix: 16) })")
    }
    #expect(links("[https://good.example](https://good.example)") == ["https://good.example>good.example"])
    // An accent after a link is part of the text, and the link under the words before it still goes where it says.
    #expect(links("[https://good.example](https://good.example)\u{0301} and more") == ["https://good.example>good.example"])
    #expect(links("[the docs](https://docs.example)") == ["the docs>docs.example"])
}

@Test func aConversationsTextHasNoLinksForNow() {
    // Switched off on 2026-11-17: a click on a file link did nothing in the real app. Until that is found and
    // fixed, nothing in a message may look clickable.
    #expect(!Prose.linksOn)
    for text in ["see https://example.com/docs here", "[the docs](https://docs.example)", "open `/usr/bin/true` now", "/tmp is a folder"] {
        let a = Prose.styled(text, folder: "/tmp")
        #expect(a.runs.allSatisfy { $0.link == nil && $0.underlineStyle == nil }, "\(text)")
    }
    #expect(String(Prose.styled("[the docs](https://docs.example)").characters) == "the docs")
}
