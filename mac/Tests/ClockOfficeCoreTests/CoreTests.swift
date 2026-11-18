import Testing
import Foundation
import ImageIO
import Network
@testable import ClockOfficeCore

// MARK: helpers

func fixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
}

/// Waits until a test server really answers, instead of a fixed pause. Test servers start on a port the system picks
/// (`startOnFreePort`): random ports from fixed ranges clashed with other tests and with app copies of other
/// sessions, and a clash started silently (T-37).
func waitUntilServing(_ port: UInt16) async throws {
    let url = URL(string: "http://127.0.0.1:\(port)/snapshot")!
    for _ in 0..<200 {
        if let (_, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 { return }
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    Issue.record("the test server on port \(port) never answered")
}

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ao-test-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func line(_ o: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
}

func userTyped(_ text: String) -> String { line(["type": "user", "message": ["role": "user", "content": text]]) }
func assistantText(_ text: String, at: String = "2026-11-16T10:00:00.000Z") -> String {
    line(["type": "assistant", "timestamp": at, "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}
func assistantTool(_ name: String, _ input: [String: Any]) -> String {
    line(["type": "assistant", "message": ["role": "assistant", "content": [["type": "tool_use", "id": "t1", "name": name, "input": input]]]])
}
func toolResult() -> String {
    line(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]])
}

/// A pretend home folder holding Claude Code's session registry and transcripts.
struct FakeHome {
    let url = tempDir()
    var path: String { url.path }
    let pid = ProcessInfo.processInfo.processIdentifier // alive for the whole test run

    func add(_ id: String, status: String, cwd: String = "/Users/x/Desktop/TEAM-HANDBOOK", waitingFor: String? = nil,
             kind: String = "interactive", pid: Int32? = nil, transcript: [String] = [], changedMs: Double = 1_794_830_000_000) {
        let dir = url.appendingPathComponent(".claude/sessions")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var o: [String: Any] = ["pid": Int(pid ?? self.pid), "sessionId": id, "cwd": cwd, "kind": kind, "entrypoint": kind == "interactive" ? "cli" : "sdk-cli",
                                "name": "name-\(id)", "status": status, "statusUpdatedAt": changedMs, "bridgeSessionId": "session_\(id)"]
        if let waitingFor { o["waitingFor"] = waitingFor }
        try! line(o).write(to: dir.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
        let t = URL(fileURLWithPath: Transcript.path(cwd: cwd, sessionId: id, home: path))
        try! FileManager.default.createDirectory(at: t.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! (transcript.joined(separator: "\n") + "\n").write(to: t, atomically: true, encoding: .utf8)
    }
}

// MARK: question or finished report

struct LastMessage: Decodable { let text: String; let k: String; let q: String? }

@Test func classifierKeepsThePrototypesRecordedCases() throws {
    let cases = try JSONDecoder().decode([LastMessage].self, from: Data(contentsOf: fixtureURL("last-messages.json")))
    #expect(cases.count == 9)
    for c in cases {
        let v = Classifier.classify(c.text)
        #expect(v.asks == (c.k == "ask"), "\(c.k): \(c.text.prefix(70))")
        if let q = c.q { #expect(v.question == q) }
    }
}

@Test(arguments: [
    ("I've updated the footer and deployed the preview. Let me know if you'd like any other changes.", false),
    ("Let me know if you want any other changes.", false),
    ("Fixed. The logs confirm the webhook now returns 200.", false),
    ("I will confirm the DNS change tomorrow.", false),
    ("Build passes and the layout looks ok to me on all three widths.", false),
    ("Applied your pick (option 2) to all 12 pages. Deployed.", false),
    ("Summary:\n1. Fixed the nav overlap\n2. Why did it break? A missing z-index.\n3. Added a test", false),
    ("Done. Preview: https://example-preview.vercel.app/?lang=nl", false),
    ("Did you know the CDN caches 404s? Anyway, deployed and purged.", false),
    ("Should I merge this to main?\n\nFiles changed: nav.tsx, footer.tsx.", true),
    ("I need the Stripe test key to continue. Paste it here when you have it.", true),
    ("Tell me which headline to use and I will apply it.", true),
    ("Waiting for your approval before I push to production.", true),
    ("Two ways forward:\n\n1. Keep the old footer\n2. Ship the new one\n\nWhich do you prefer?\n\n---\n_Preview: https://example.vercel.app_", true),
    ("Which do you prefer:\n1. Blue\n2. Green", true),
    ("Updated nav.tsx and footer.tsx. Shall I mail ann@example.com the preview at https://x.vercel.app/a.b now?", true),
    ("Two layouts are on the preview. Thoughts?", true),
    ("I tried both fixes; neither worked. Any idea?", true),
    ("Branch is pushed and verified. Next step is yours: merge when ready.", true),
    ("Migration script is ready. Do I run it against production, or only staging?", true),
    ("Both options are on the preview. Your call.", true),
    ("The cron config needs your OK before I touch it.", true),
    ("Go with option 2?", true),
    ("English page updated. Same for the Italian page?", true),
    ("Is the winter price €49 or €59 per night?", true),
    ("Where should the old /blog links point: the archive or the home page?", true),
    ("**Decision needed:** keep the old slug or switch to /winter-stays?", true),
    ("Did you know the old sitemap still listed 14 dead URLs? I removed them; the build passes.", false),
    ("You asked: should the footer be sticky? I made it sticky on all pages and deployed.", false),
    ("The FAQ heading now reads: Can you cancel a booking?", false),
])
func classifierCraftedEndings(text: String, asks: Bool) {
    #expect(Classifier.classify(text).asks == asks)
}

@Test func optionsCarryTheirOwnWordsAndTypeTheirKey() {
    let v = Classifier.classify("Which do you prefer:\n1. Quiet weeks in the hills\n2. Winter at the farm")
    #expect(v.options == [ReplyOption(label: "Quiet weeks in the hills", send: "1"), ReplyOption(label: "Winter at the farm", send: "2")])
    #expect(Classifier.classify("Merge to main now, or wait for your look?").options.map(\.send) == ["merge", "wait"])
    // A button pays off for "yes"; "no" nearly always needs words.
    #expect(Classifier.classify("Deployed to preview. Should I merge this to main?").options == [ReplyOption(label: "yes", send: "yes")])
    #expect(Classifier.classify("All done.").options.isEmpty)
}

// MARK: transcript tail

@Test func tailFindsTheLastThingClaudeSaid() throws {
    let f = tempDir().appendingPathComponent("t.jsonl")
    try [userTyped("build it"), assistantText("First part."), line(["type": "ai-title", "aiTitle": "Footer fix"]),
         assistantText("Deployed. Shall I merge?", at: "2026-11-16T10:05:00.000Z"),
         line(["type": "last-prompt", "lastPrompt": "build it"])].joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    let t = Transcript.tail(file: f.path)
    #expect(t.lastAssistantText == "Deployed. Shall I merge?")
    #expect(t.title == "Footer fix")
    #expect(t.lastPrompt == "build it")
    #expect(t.userSpokeLast == false)
    #expect(t.lastAssistantAt != nil)
}

@Test func tailKnowsWhenTheUserSpokeLast() throws {
    let f = tempDir().appendingPathComponent("t.jsonl")
    try [assistantText("Shall I merge?"), userTyped("yes")].joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    let t = Transcript.tail(file: f.path)
    #expect(t.userSpokeLast)
    #expect(t.lastAssistantText == nil)
}

@Test func tailSeesAnUnansweredToolCallButNotAnAnsweredOne() throws {
    let dir = tempDir()
    let open = dir.appendingPathComponent("open.jsonl"), closed = dir.appendingPathComponent("closed.jsonl")
    let ask = assistantTool("AskUserQuestion", ["questions": [["question": "Which fruit?", "options": [["label": "Apple"], ["label": "Pear"]]]]])
    try [userTyped("go"), ask].joined(separator: "\n").write(to: open, atomically: true, encoding: .utf8)
    try [userTyped("go"), ask, toolResult(), assistantText("PICKED Pear")].joined(separator: "\n").write(to: closed, atomically: true, encoding: .utf8)
    #expect(Transcript.tail(file: open.path).pendingToolName == "AskUserQuestion")
    #expect(Transcript.tail(file: closed.path).pendingToolName == nil)
    #expect(Transcript.tail(file: closed.path).lastAssistantText == "PICKED Pear")
}

@Test func tailGrowsItsWindowPastOneHugeLine() throws {
    let f = tempDir().appendingPathComponent("t.jsonl")
    let blob = line(["type": "api-request-blob", "blob": String(repeating: "x", count: 600_000)])
    try [assistantText("Ready. Deploy now?"), blob].joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    #expect(Transcript.tail(file: f.path).lastAssistantText == "Ready. Deploy now?")
}

@Test func tailOfAMissingFileIsEmptyNotACrash() {
    let t = Transcript.tail(file: "/nonexistent/x.jsonl")
    #expect(t.lastAssistantText == nil && !t.userSpokeLast)
}

// MARK: the Claude Code source

@Test func officialStatusDecidesAndOnlyIdleSessionsAreRead() {
    let home = FakeHome()
    home.add("busy", status: "busy", transcript: [assistantText("Shall I merge?"), line(["type": "last-prompt", "lastPrompt": "fix the footer"])])
    home.add("dialog", status: "waiting", waitingFor: "input needed", transcript: [userTyped("go"), assistantText("All done, nothing to ask.")])
    home.add("asks", status: "idle", transcript: [userTyped("go"), assistantText("Deployed to preview. Should I merge this to main?")])
    home.add("done", status: "idle", transcript: [userTyped("go"), assistantText("Deployed. All checks pass.")])
    home.add("auto", status: "idle", kind: "sdk-cli", transcript: [assistantText("Should I merge?")])
    home.add("dead", status: "waiting", waitingFor: "input needed", pid: 999_999)
    let all = ClaudeCodeSource(home: home.path).sessions()
    let by = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    #expect(by["dead"] == nil, "a registry file whose process is gone is ignored")
    #expect(by["busy"]?.state == .working, "busy wins even when the last message reads like a question")
    #expect(by["busy"]?.inShort == "Working on: fix the footer")
    // The case the October prototype got wrong: official waiting, last message not a question.
    #expect(by["dialog"]?.state == .asking)
    #expect(by["dialog"]?.certain == true)
    #expect(by["dialog"]?.waitingFor == "input needed")
    #expect(by["dialog"]?.question == "Has a question for you, in its window.")
    #expect(by["asks"]?.state == .asking)
    #expect(by["asks"]?.certain == false)
    #expect(by["asks"]?.question == "Should I merge this to main?")
    #expect(by["done"]?.state == .done)
    #expect(by["auto"]?.automated == true)
    #expect(by["asks"]?.project == "Team handbook")
    #expect(by["asks"]?.remoteURL?.absoluteString == "https://claude.ai/code/session_asks")
}

@Test func aDialogHandedOverByTheHookShowsItsOwnWordsAndNumberedChoices() {
    let home = FakeHome()
    let changed = Date().timeIntervalSince1970 * 1000
    home.add("d1", status: "waiting", waitingFor: "input needed", transcript: [userTyped("go")], changedMs: changed)
    home.add("d2", status: "waiting", waitingFor: "permission prompt", transcript: [userTyped("go")], changedMs: changed)
    home.add("d3", status: "waiting", waitingFor: "input needed", transcript: [userTyped("go")], changedMs: changed)
    let inbox = HookInbox()
    func hook(_ sid: String, _ tool: String, _ input: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["session_id": sid, "hook_event_name": "PreToolUse", "tool_name": tool, "tool_input": input])
    }
    #expect(inbox.receive(hook("d1", "AskUserQuestion", ["questions": [["question": "Which fruit?", "multiSelect": false,
        "options": [["label": "Apple"], ["label": "Pear"], ["label": "Plum"]]]]])))
    #expect(inbox.receive(hook("d2", "Bash", ["command": "git push origin t180-handover"])))
    #expect(inbox.receive(hook("d3", "AskUserQuestion", ["questions": [["question": "First?", "options": [["label": "A"], ["label": "B"]]],
                                                                       ["question": "Second?", "options": [["label": "C"], ["label": "D"]]]]])))
    #expect(inbox.receive(Data("not json".utf8)) == false)
    let by = Dictionary(uniqueKeysWithValues: ClaudeCodeSource(home: home.path, inbox: inbox).sessions().map { ($0.id, $0) })
    #expect(by["d1"]?.question == "Which fruit?")
    #expect(by["d1"]?.options == [ReplyOption(label: "Apple", send: "1"), ReplyOption(label: "Pear", send: "2"), ReplyOption(label: "Plum", send: "3")])
    #expect(by["d2"]?.question == "Allow Bash: git push origin t180-handover?")
    #expect(by["d2"]?.options.isEmpty == true)
    #expect(by["d3"]?.question?.hasPrefix("2 questions, starting with: First?") == true)
    #expect(by["d3"]?.options.isEmpty == true, "several questions are answered in the window, not by one number")
    // A dialog from an earlier wait of the same session is not shown for the current one.
    #expect(inbox.dialog(for: "d1", notBefore: Date().addingTimeInterval(60)) == nil)
}

@Test func theUserSpeakingLastMeansNothingIsPending() {
    let home = FakeHome()
    home.add("s", status: "idle", transcript: [assistantText("Shall I merge?"), userTyped("yes, merge")])
    let s = ClaudeCodeSource(home: home.path).sessions().first
    #expect(s?.state == .done)
    #expect(s?.question == nil)
}

// MARK: replies

@Test(arguments: [
    ("yes", true), ("deep scan, and attach the PPTX too", true), ("ja, doe maar: é ü ß", true),
    ("", false), ("/exit", false), ("  /clear", false), ("!rm -rf x", false), ("# remember this", false),
    ("／exit", false), ("yes\u{0003}", false), ("a\nb", false), ("a\u{2028}b", false), ("a\u{200B}b", false),
    ("continue \\", false), (String(repeating: "x", count: 2001), false),
])
func replyValidation(text: String, ok: Bool) {
    #expect(Reply.valid(text) == ok)
}

@Test func attachedFilesGoInAsQuotedPathsAndNeverStartTheReply() {
    #expect(Reply.compose(text: "yes", files: []) == "yes")
    #expect(Reply.compose(text: "look at this", files: ["/tmp/a.png"]) == "look at this (file: /tmp/a.png)")
    #expect(Reply.compose(text: "", files: ["/tmp/a b.png", "/tmp/c.pdf"]) == "See (files: \"/tmp/a b.png\" /tmp/c.pdf)")
    #expect(Reply.compose(text: "one\ntwo", files: []) == "one two")
    #expect(Reply.valid(Reply.compose(text: "", files: ["/tmp/a.png"])), "a lone path must not read as a slash command")
}

// MARK: summaries

@Test func summaryIsReadOutOfClaudeCodesEnvelope() {
    let inner = #"{"asks": true, "headline": "Merge now?", "question": "Shall I merge to main now?", "options": ["yes"], "in_short": "Preview deployed. Asks to merge.", "did": "Deployed the preview."}"#
    let fenced = "```json\n\(inner)\n```"
    for body in [inner, fenced] {
        let env = String(data: try! JSONSerialization.data(withJSONObject: ["result": body, "is_error": false]), encoding: .utf8)!
        let s = Summarizer.parse(env)
        #expect(s?.asks == true)
        #expect(s?.headline == "Merge now?")
        #expect(s?.options == ["yes"])
    }
    #expect(Summarizer.parse(#"{"result":"sorry, no JSON","is_error":false}"#) == nil)
    #expect(Summarizer.parse(#"{"result":"{\"asks\":true}","is_error":true}"#) == nil)
    #expect(Summarizer.parse("garbage") == nil)
}

@Test func aSummaryNeverOverrulesAnOfficialWaitOrAWorkingSession() {
    let base = Session(id: "s", tool: "Claude Code", pid: 1, cwd: "/x", project: "X", title: "T", state: .done, since: Date())
    let asks = Summary(asks: true, headline: "Merge now?", question: "Shall I merge?", options: ["yes"], inShort: "Deployed.", did: "Deployed the preview.")
    let quiet = Summary(asks: false, headline: "", question: "", options: [], inShort: "All done.", did: "Ran the tests.")

    let a = base.applying(asks)
    #expect(a.state == .asking && a.headline == "Merge now?" && a.options == [ReplyOption(label: "yes", send: "yes")])

    var asking = base; asking.state = .asking; asking.question = "Shall I merge?"
    #expect(asking.applying(quiet).state == .done, "the model may call a rule-based question a finished report")

    var official = asking; official.certain = true; official.question = "Which fruit?"
    let o = official.applying(quiet)
    #expect(o.state == .asking && o.question == "Which fruit?" && o.inShort == "All done.")

    var working = base; working.state = .working
    #expect(working.applying(asks).state == .working)

    var numbered = asking; numbered.options = [ReplyOption(label: "Blue", send: "1"), ReplyOption(label: "Green", send: "2")]
    #expect(numbered.applying(asks).options.map(\.send) == ["1", "2"], "a numbered list keeps its numbers")
}

// MARK: the hook switch

@Test func hookSwitchAddsAndRemovesOnlyItsOwnEntries() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json"), backups = dir.appendingPathComponent("backups")
    let original = #"{"model":"fable","hooks":{"PreToolUse":[{"matcher":"Read|Edit","hooks":[{"type":"command","command":"node guard.mjs"}]}]},"theme":"light"}"#
    try original.write(to: settings, atomically: true, encoding: .utf8)
    func read() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any] }

    #expect(!ClaudeHooks.isInstalled(at: settings))
    try ClaudeHooks.set(true, at: settings, backups: backups)
    try ClaudeHooks.set(true, at: settings, backups: backups) // twice: still one entry each
    #expect(ClaudeHooks.isInstalled(at: settings))
    var hooks = read()["hooks"] as! [String: Any]
    let pre = hooks["PreToolUse"] as! [[String: Any]]
    #expect(pre.count == 2)
    #expect(pre[0]["matcher"] as? String == "Read|Edit", "the user's own hook stays first and untouched")
    #expect(pre[1]["matcher"] as? String == "AskUserQuestion")
    #expect((hooks["PermissionRequest"] as! [[String: Any]]).count == 1)
    #expect(read()["model"] as? String == "fable" && read()["theme"] as? String == "light")
    #expect(try FileManager.default.contentsOfDirectory(atPath: backups.path).count >= 1)

    try ClaudeHooks.set(false, at: settings, backups: backups)
    #expect(!ClaudeHooks.isInstalled(at: settings))
    hooks = read()["hooks"] as! [String: Any]
    #expect((hooks["PreToolUse"] as! [[String: Any]]).count == 1)
    #expect(hooks["PermissionRequest"] == nil)
    #expect(NSDictionary(dictionary: read()).isEqual(to: try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]))
}

@Test func hookSwitchLeavesABrokenSettingsFileAlone() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    try "{ not json".write(to: settings, atomically: true, encoding: .utf8)
    #expect(throws: ClaudeHooks.Failure.self) { try ClaudeHooks.set(true, at: settings, backups: dir.appendingPathComponent("b")) }
    #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
}

// MARK: the local door

@Test func localDoorServesTheWidgetAndTakesHookPostsOnlyFromItsOwnHeader() async throws {
    let server = SnapshotServer()
    let port = try await server.startOnFreePort()
    defer { server.stop() }
    try await waitUntilServing(port)
    let s = Session(id: "a", tool: "Claude Code", pid: 1, cwd: "/x", project: "Desktop", title: "Scan", state: .asking,
                    since: Date(timeIntervalSince1970: 1_794_830_000), question: "Deep scan?", headline: "Deep scan?")
    server.update(Snapshot.from([s], now: Date(timeIntervalSince1970: 1_794_830_600)))

    let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/snapshot")!)
    let snap = try Snapshot.decoder.decode(Snapshot.self, from: data)
    #expect(snap.asking.map(\.headline) == ["Deep scan?"])

    func post(_ headers: [String: String], _ body: Data) async throws -> Int {
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        r.httpMethod = "POST"; r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return ((try await URLSession.shared.data(for: r)).1 as! HTTPURLResponse).statusCode
    }
    // A big payload, as real hooks send (the whole tool input), arrives whole.
    let big = try JSONSerialization.data(withJSONObject: ["session_id": "sid", "tool_name": "AskUserQuestion",
        "tool_input": ["questions": [["question": "Which fruit?", "options": [["label": "Apple"], ["label": "Pear"]]]], "pad": String(repeating: "p", count: 150_000)]])
    #expect(try await post([:], big) == 400, "no header: refused")
    #expect(server.inbox.dialog(for: "sid", notBefore: .distantPast) == nil)
    #expect(try await post(["x-clockoffice": "hook"], big) == 200)
    #expect(server.inbox.dialog(for: "sid", notBefore: .distantPast)?.toolName == "AskUserQuestion")
    #expect(try await post(["x-clockoffice": "hook"], Data("nope".utf8)) == 400)
    #expect(try await post(["x-clockoffice": "hook", "Host": "evil.example"], big) == 404, "another host name is refused")
}

// MARK: words and snapshot

@Test func wordsHelpers() {
    #expect(Words.prettyProject("TEAM-HANDBOOK") == "Team handbook")
    #expect(Words.prettyProject("clock_office") == "Clock office")
    #expect(Words.prettyProject("ClockOffice") == "ClockOffice")
    #expect(Words.prettyProject("Fig & olive shop") == "Fig & olive shop")
    let now = Date()
    #expect(Words.age(since: now.addingTimeInterval(-30), now: now) == "now")
    #expect(Words.age(since: now.addingTimeInterval(-34 * 60), now: now) == "34 min")
    #expect(Words.age(since: now.addingTimeInterval(-3 * 3600), now: now) == "3 h")
    #expect(Words.age(since: now.addingTimeInterval(-4 * 86400), now: now) == "4 d")
    #expect(Words.clip("a  b\n c", 10) == "a b c")
    #expect(Words.clip(String(repeating: "x", count: 50), 10).count == 10)
}

@Test func snapshotPutsTheLongestWaitFirstAndCountsTheRest() {
    let now = Date()
    func s(_ id: String, _ state: SessionState, _ minutes: Double) -> Session {
        Session(id: id, tool: "Claude Code", pid: 1, cwd: "/x", project: id, title: "t-\(id)", state: state,
                since: now.addingTimeInterval(-minutes * 60), question: "q-\(id)?", headline: "q-\(id)?")
    }
    let snap = Snapshot.from([s("new", .asking, 2), s("old", .asking, 40), s("w", .working, 1), s("d", .done, 9)], now: now)
    #expect(snap.asking.map(\.id) == ["old", "new"])
    #expect(snap.working == 1 && snap.done == 1)
    #expect(snap.quiet.map(\.id) == ["w", "d"])
}

@Test func secretsAreMaskedBeforeAnythingIsShown() {
    #expect(!Redactor.redact("use token: abc123secretvalue now").contains("abc123secretvalue"))
    #expect(!Redactor.redact("key sk-ant-REDACTED ok").contains("sk-ant"))
    #expect(Redactor.redact("Shall I merge to main?") == "Shall I merge to main?")
}

// MARK: regressions

@Test func aReplyIsNeverBlockedBecauseTheModelAndTheRulesDisagree() {
    // B1: the shown state came from the model summary, the re-read at send time did not, and the two never matched.
    let home = FakeHome()
    home.add("s", status: "idle", transcript: [userTyped("go"), assistantText("The records answer 3 of 16 questions. Seven still need your own memory or mailbox.")])
    let source = ClaudeCodeSource(home: home.path)
    let raw = source.sessions()[0]
    #expect(raw.state == .done, "the wording rules read this as a finished report")
    let shown = raw.applying(Summary(asks: true, headline: "Which seven can you answer?", question: "Can you answer the seven?", options: [], inShort: "x", did: "y"))
    #expect(shown.state == .asking, "the model reads it as a question: this is what the user sees")
    #expect(Reply.stillCurrent(shown: shown, fresh: source.sessions()[0]))

    // And the other way round: rules say question, model says report.
    home.add("t", status: "idle", transcript: [userTyped("go"), assistantText("Deployed to preview. Should I merge this to main?")])
    let rawT = source.sessions().first { $0.id == "t" }!
    let shownT = rawT.applying(Summary(asks: false, headline: "", question: "", options: [], inShort: "x", did: "y"))
    #expect(shownT.state == .done)
    #expect(Reply.stillCurrent(shown: shownT, fresh: source.sessions().first { $0.id == "t" }))
}

@Test func aReplyIsRefusedOnceTheSessionReallyMovedOn() {
    // S1: same state, but a newer moment or a newer message, is a different question.
    let home = FakeHome()
    home.add("s", status: "idle", transcript: [userTyped("go"), assistantText("Should I merge this to main?")], changedMs: 1_794_830_000_000)
    let shown = ClaudeCodeSource(home: home.path).sessions()[0]

    home.add("s", status: "idle", transcript: [userTyped("go"), assistantText("Should I merge this to main?")], changedMs: 1_794_830_300_000)
    #expect(!Reply.stillCurrent(shown: shown, fresh: ClaudeCodeSource(home: home.path).sessions()[0]), "asked again later")

    home.add("s", status: "idle", transcript: [userTyped("go"), assistantText("Should I delete the old branch?")], changedMs: 1_794_830_000_000)
    #expect(!Reply.stillCurrent(shown: shown, fresh: ClaudeCodeSource(home: home.path).sessions()[0]), "a different question")

    home.add("s", status: "busy", transcript: [userTyped("go"), assistantText("Should I merge this to main?")], changedMs: 1_794_830_000_000)
    #expect(!Reply.stillCurrent(shown: shown, fresh: ClaudeCodeSource(home: home.path).sessions()[0]), "already working")

    #expect(!Reply.stillCurrent(shown: shown, fresh: nil), "the session ended")
    var otherProcess = shown; otherProcess.pid = 1
    #expect(!Reply.stillCurrent(shown: shown, fresh: otherProcess))
}

@Test func anOldDialogIsNeverShownForANewWait() {
    // S2: a dialog handed over by the hook belongs to one wait only.
    let home = FakeHome()
    let inbox = HookInbox()
    let source = ClaudeCodeSource(home: home.path, inbox: inbox)
    func post(_ sid: String, _ tool: String) {
        let input: [String: Any] = tool == "AskUserQuestion"
            ? ["questions": [["question": "Which fruit?", "options": [["label": "Apple"], ["label": "Pear"]]]]]
            : ["command": "git push"]
        inbox.receive(try! JSONSerialization.data(withJSONObject: ["session_id": sid, "tool_name": tool, "tool_input": input]))
    }
    let now = Date().timeIntervalSince1970 * 1000

    // A wait that began 20 seconds after the dialog arrived is another wait.
    post("late", "AskUserQuestion")
    home.add("late", status: "waiting", waitingFor: "input needed", transcript: [userTyped("go")], changedMs: now + 20_000)
    #expect(source.sessions().first { $0.id == "late" }?.question == "Has a question for you, in its window.")

    // A question dialog is not shown for a permission wait, nor a permission prompt for a question wait.
    post("kind", "AskUserQuestion")
    home.add("kind", status: "waiting", waitingFor: "permission prompt", transcript: [userTyped("go")], changedMs: now)
    #expect(source.sessions().first { $0.id == "kind" }?.question == "Asks permission for a step, in its window.")
    #expect(source.sessions().first { $0.id == "kind" }?.options.isEmpty == true)

    // Once the session moved on after the dialog, the dialog is forgotten for good.
    post("gone", "AskUserQuestion")
    home.add("gone", status: "waiting", waitingFor: "input needed", transcript: [userTyped("go")], changedMs: now)
    #expect(source.sessions().first { $0.id == "gone" }?.question == "Which fruit?")
    home.add("gone", status: "busy", transcript: [userTyped("go")], changedMs: now + 60_000)
    _ = source.sessions()
    #expect(inbox.dialog(for: "gone", notBefore: .distantPast) == nil)

    // A dialog that arrived just before the status flips (still "busy" from earlier) is kept for the wait that follows.
    home.add("soon", status: "busy", transcript: [userTyped("go")], changedMs: now - 60_000)
    post("soon", "AskUserQuestion")
    _ = source.sessions()
    #expect(inbox.dialog(for: "soon", notBefore: .distantPast) != nil)
}

@Test(arguments: ["@README.md look", "&background", "?", "  ?help", "＠file", String(repeating: "😀", count: 1001)])
func repliesTheClaudePromptWouldTreatAsCommandsAreRefused(text: String) {
    #expect(!Reply.valid(text))
}

@Test func twoThousandUnitsIsTheLimitTheExtensionCountsIn() {
    #expect(Reply.valid(String(repeating: "😀", count: 1000)))   // 2000 UTF-16 units
    #expect(Reply.valid("is it ok? yes & no @ home"), "these characters are fine anywhere but first")
}

@Test func hookSwitchStopsOnAnythingItDoesNotFullyUnderstand() throws {
    let dir = tempDir()
    let backups = dir.appendingPathComponent("b")
    func attempt(_ text: String, _ expected: ClaudeHooks.Failure) throws {
        let f = dir.appendingPathComponent("s-\(UUID().uuidString).json")
        try text.write(to: f, atomically: true, encoding: .utf8)
        #expect(throws: expected) { try ClaudeHooks.set(true, at: f, backups: backups) }
        #expect(try String(contentsOf: f, encoding: .utf8) == text, "left exactly as it was")
    }
    try attempt(#"{"model":"fable","temperature":0.1}"#, .decimals)
    try attempt(#"{"hooks":"oops"}"#, .unexpectedShape)
    try attempt(#"{"hooks":{"PreToolUse":{"matcher":"x"}}}"#, .unexpectedShape)
    try attempt("[1,2]", .unreadable)
}

@Test func hookSwitchKeepsALinkedSettingsFileALinkAndItsPermissions() throws {
    let dir = tempDir()
    let real = dir.appendingPathComponent("real.json"), link = dir.appendingPathComponent("settings.json")
    try #"{"model":"fable","count":3}"#.write(to: real, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    try ClaudeHooks.set(true, at: link, backups: dir.appendingPathComponent("b"))
    try ClaudeHooks.set(false, at: link, backups: dir.appendingPathComponent("b"))
    #expect(try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType == .typeSymbolicLink)
    #expect((try FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let back = try JSONSerialization.jsonObject(with: Data(contentsOf: real)) as! [String: Any]
    #expect(back["model"] as? String == "fable" && back["count"] as? Int == 3 && back["hooks"] == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("b").path).count == 2, "one backup per change, none overwritten")
}

@Test func localDoorAnswersOnlyItsExactPathsAndOnlyOnLoopback() async throws {
    // The app's own door, `start(port:)`, on a port that was just free: this is the one test that runs it, so a
    // change that made the app listen on every address fails here (verifier 2 of T-37).
    let probe = SnapshotServer()
    let port = try await probe.startOnFreePort()
    probe.stop()
    try await Task.sleep(nanoseconds: 100_000_000)
    let server = SnapshotServer()
    try server.start(port: port)
    defer { server.stop() }
    try await waitUntilServing(port)
    func status(_ path: String) async throws -> Int {
        ((try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)).1 as! HTTPURLResponse).statusCode
    }
    #expect(try await status("/snapshot") == 200)
    #expect(try await status("/snapshotXYZ") == 404)
    #expect(try await status("/") == 404)
    // Listening on 127.0.0.1 only, not on every address.
    let listening = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).stdout
    #expect(listening.contains("127.0.0.1:\(port)"))
    #expect(!listening.contains("*:\(port)"))
    // And it is this test's own server that listens there, not another process that took the port meanwhile.
    let pid = String(ProcessInfo.processInfo.processIdentifier)
    #expect(listening.split(separator: "\n").dropFirst().allSatisfy { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().first.map(String.init) == pid },
            "listeners: \(listening)")
}

/// One HTTP request over a plain socket, read until the server closes the connection, then closed here. Gives up
/// after `timeout` seconds without data, so a server that never closes fails the test instead of freezing the whole
/// run (verifier 2 of T-39).
func readUntilClosed(port: UInt16, timeout: Int = 3) -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return "" }
    defer { close(fd) }
    var limit = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard ok == 0 else { return "" }
    let req = "GET /snapshot HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
    _ = req.withCString { send(fd, $0, strlen($0), 0) }
    var out = Data(), buf = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = recv(fd, &buf, buf.count, 0)
        if n <= 0 { break }
        out.append(contentsOf: buf[0..<n])
    }
    return String(data: out, encoding: .utf8) ?? ""
}

@Test func theRequestHelperGivesUpOnAServerThatNeverAnswers() throws {
    // A listener that accepts nothing and never closes: the connection completes in its queue, then stays silent.
    let srv = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(srv) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &addr) { p in
        p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(srv, $0, len) == 0 && listen(srv, 4) == 0 && getsockname(srv, $0, &len) == 0 }
    }
    try #require(bound)
    let started = Date()
    #expect(readUntilClosed(port: UInt16(bigEndian: addr.sin_port), timeout: 1) == "")
    #expect(Date().timeIntervalSince(started) < 3, "it gave up instead of waiting for ever")
}

@Test func theAppsDoorOpensAgainAtOnceOnTheSamePortAfterAQuit() async throws {
    // The installer quits the app and starts the new build straight away, on the same port. The door closes each
    // connection itself, which leaves the port in TIME_WAIT for a while; without port reuse the new app could not
    // listen there and the widget and the hooks would find nobody (T-39).
    let probe = SnapshotServer()
    let port = try await probe.startOnFreePort()
    probe.stop()
    try await Task.sleep(nanoseconds: 100_000_000)
    let first = SnapshotServer()
    try first.start(port: port)
    try await waitUntilServing(port)
    // A plain socket that reads to the end before it closes: the door closes first, so the TIME_WAIT lands on the
    // door's own port. (URLSession often closed its end first, leaving TIME_WAIT on its own temporary port, which
    // can never block a restart: verifier 1 of T-39.)
    for _ in 0..<5 { #expect(readUntilClosed(port: port).hasPrefix("HTTP/1.1 200")) }
    first.stop()
    // As when the app quits: the old door has stopped listening (its closed connections stay in TIME_WAIT).
    // (A `for … where` loop does not stop when its condition turns false: it ran lsof 100 times, 10 s per run.)
    for _ in 0..<100 {
        if !Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).stdout.contains("LISTEN") { break }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    // Server side only: the local address (4th column of netstat) is the door's port.
    let waiting = Shell.run("/usr/sbin/netstat", ["-an", "-p", "tcp"]).stdout.split(separator: "\n").filter { row in
        let f = row.split(separator: " ", omittingEmptySubsequences: true)
        return f.count >= 6 && f[3] == "127.0.0.1.\(port)" && f[5] == "TIME_WAIT"
    }.count
    #expect(waiting > 0, "the case under test: the door's own port still has connections in TIME_WAIT")
    let second = SnapshotServer()
    try second.start(port: port)
    defer { second.stop() }
    let url = URL(string: "http://127.0.0.1:\(port)/snapshot")!
    var answered = false
    for _ in 0..<80 where !answered {
        if let (_, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 { answered = true }
        else { try await Task.sleep(nanoseconds: 25_000_000) }
    }
    #expect(answered, "the restarted door answers on the same port within 2 seconds")
    let listening = Shell.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]).stdout
    #expect(listening.contains("127.0.0.1:\(port)"))
}

@Test func theDoorSaysSoWhenItsPortIsTaken() async throws {
    // Another program holds the port: start() returns without an error, and only the door's state can tell (T-41).
    let holder = SnapshotServer()
    let port = try await holder.startOnFreePort()
    defer { holder.stop() }
    let door = SnapshotServer()
    try door.start(port: port)
    defer { door.stop() }
    for _ in 0..<100 { if case .failed = door.door { break }; try await Task.sleep(nanoseconds: 20_000_000) }
    // The holder here is this test process itself, named as the system names it.
    guard case .failed(let why) = door.door else { Issue.record("state: \(door.door)"); return }
    #expect(why.hasSuffix("is using the connection it needs"), "reason: \(why)")
    #expect(!why.contains("POSIX") && !why.contains("port"))
    // A free port: the same door says it listens.
    let probe = SnapshotServer()
    let free = try await probe.startOnFreePort()
    probe.stop()
    try await Task.sleep(nanoseconds: 100_000_000)
    let ok = SnapshotServer()
    try ok.start(port: free)
    for _ in 0..<100 { if ok.door == .listening { break }; try await Task.sleep(nanoseconds: 20_000_000) }
    #expect(ok.door == .listening)
    ok.stop()
    #expect(ok.door == .stopped)
}

@Test func tryAgainRightAfterAWorkingDoorDoesNotBlameAnotherApp() async throws {
    // Stop and start at once on the same port, as "Try again" does: the old listener may still be closing.
    let probe = SnapshotServer()
    let port = try await probe.startOnFreePort()
    probe.stop()
    try await Task.sleep(nanoseconds: 100_000_000)
    let door = SnapshotServer()
    defer { door.stop() }
    for _ in 0..<20 {
        try door.start(port: port)
        for _ in 0..<150 { if door.door == .listening { break }; if case .failed = door.door { break }; try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(door.door == .listening, "state after a quick restart: \(door.door)")
        door.stop()
    }
}

@Test func theDoorsReasonsAreInPlainWords() {
    #expect(SnapshotServer.why(NWError.posix(.EADDRINUSE)) == "another app is using the connection it needs")
    #expect(SnapshotServer.why(NWError.posix(.EADDRNOTAVAIL)) == "it could not open its connection (error 49)")
    // The path where setting up the door throws (verifier 1 of T-43): the same plain words, never system text.
    #expect(SnapshotServer.why(POSIXError(.EINVAL)) == "it could not open its connection (error 22)")
    #expect(SnapshotServer.why(NSError(domain: "x", code: 1)) == "it could not open its connection")
    #expect(SnapshotServer.why(nil) == "it could not open its connection")
    for e: Error in [NWError.posix(.EACCES), POSIXError(.EINVAL), NWError.dns(-1)] {
        let w = SnapshotServer.why(e)
        #expect(!w.contains("POSIX") && !w.contains("rawValue") && !w.contains("port"), "\(w)")
    }
}

@Test func invisibleCharactersFromPastedTextAreTidiedNotRefused() {
    // Tabs, soft hyphens and zero-width marks came in with pasted text and blocked the reply.
    #expect(Reply.compose(text: "yes\tplease", files: []) == "yes please")
    #expect(Reply.compose(text: "co\u{00AD}operate zero\u{200B}width", files: []) == "cooperate zerowidth")
    #expect(Reply.compose(text: "line one\nline two\u{2028}three", files: []) == "line one line two three")
    #expect(Reply.valid(Reply.compose(text: "great 👩‍💻 work", files: [])))
    #expect(Reply.problem(Reply.compose(text: "yes\tplease", files: [])) == nil)
    // And each refusal names its own reason.
    #expect(Reply.problem("/exit")?.contains("commands") == true)
    #expect(Reply.problem(String(repeating: "x", count: 2001))?.contains("2000") == true)
    #expect(Reply.problem("go on \\")?.contains("backslash") == true)
    #expect(Reply.problem("") != nil)
    for text in ["yes", "/exit", "a\u{0003}", "x \\", ""] { #expect((Reply.problem(text) == nil) == Reply.valid(text)) }
}

// MARK: the short conversation in details

@Test func theConversationKeepsTheUsersWordsAndClaudesLastWordsPerTurn() throws {
    let f = tempDir().appendingPathComponent("t.jsonl")
    try [
        userTyped("first question"),
        assistantText("Looking into it."),
        assistantTool("Bash", ["command": "ls"]), toolResult(),
        assistantText("Here is the answer to the first question."),
        line(["type": "user", "isMeta": true, "message": ["role": "user", "content": "<system-reminder>ignore</system-reminder>"]]),
        userTyped("<command-name>/model</command-name>"),
        userTyped("'/var/folders/59/abc/T/TemporaryItems/NSIRD_x/Screenshot 2026-11-16 at 14.54.26.png' they overlap?"),
        assistantText("Fixing the overlap now."),
        line(["type": "api-request-blob", "blob": String(repeating: "x", count: 500_000)]),
        assistantText("Fixed. Shall I install it?"),
    ].joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    let turns = Transcript.recent(file: f.path, limit: 4)
    #expect(turns.map(\.who) == [.you, .assistant, .you, .assistant])
    #expect(turns[0].text == "first question")
    #expect(turns[1].text == "Here is the answer to the first question.", "status lines inside a turn give way to its last words")
    #expect(turns[2].text == "[screenshot] they overlap?", "a pasted screenshot path is not shown as a path")
    #expect(turns[3].text == "Fixed. Shall I install it?")
    #expect(Transcript.recent(file: f.path, limit: 2).map(\.text) == ["[screenshot] they overlap?", "Fixed. Shall I install it?"])
    #expect(Transcript.recent(file: "/nonexistent.jsonl").isEmpty)
}

@Test func promptsAreTidiedForReading() {
    #expect(Words.tidyPrompt("look at '/Users/x/Desktop/Time Sheets/report final.pdf' please") == "look at [report final.pdf] please")
    #expect(Words.tidyPrompt("plain words stay") == "plain words stay")
    #expect(Words.tidyPrompt("/private/var/folders/aa/bb/T/shot.png and more") == "[screenshot] and more")
}

@Test func aMessageWithAPastedScreenshotIsStillPartOfTheConversation() throws {
    // A message carried the screenshot as megabytes of image data on one line, the reader
    // skipped long lines, and the user's side of the conversation vanished from the details view.
    let f = tempDir().appendingPathComponent("t.jsonl")
    let withImage = line(["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
        ["type": "text", "text": "'/var/folders/59/x/T/TemporaryItems/NSIRD_y/Screenshot 2026-11-16 at 15.07.39.png' its pink now but the dial is not centered"],
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": String(repeating: "A", count: 3_000_000)]],
    ]]])
    try [userTyped("earlier question"), assistantText("earlier answer"), withImage, assistantText("You were right: fixed.")]
        .joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    let turns = Transcript.recent(file: f.path, limit: 4)
    #expect(turns.map(\.text) == ["earlier question", "earlier answer", "[screenshot] its pink now but the dial is not centered", "You were right: fixed."])
}

@Test func twoReportsOfOneSessionBecomeOneRow() {
    // The app crashed on this (a dictionary built from session ids that were not unique).
    let now = Date()
    func s(_ id: String, _ state: SessionState, _ ago: Double) -> Session {
        Session(id: id, tool: "Claude Code", pid: 1, cwd: "/x", project: id, title: id, state: state, since: now.addingTimeInterval(-ago))
    }
    let list = Session.unique([s("a", .done, 60), s("b", .working, 5), s("a", .asking, 10), s("a", .working, 300)])
    #expect(list.map(\.id) == ["a", "b"])
    #expect(list[0].state == .asking, "the report whose state changed last stands")
    #expect(Session.unique([]).isEmpty)
}

@Test func aWindowThatNeedsAReloadIsNamedOnceHoweverManySessionsItHolds() {
    // Two sessions in one editor window need one reload, so the notice names that window once.
    let windows = ReloadHint.windows([
        (id: "b", folder: "/Users/x/Desktop/TEAM-HANDBOOK", host: "Visual Studio Code"),
        (id: "c", folder: "/Users/x/Desktop/ClockOffice", host: "Visual Studio Code"),
        (id: "d", folder: "/Users/x/Desktop/TEAM-HANDBOOK", host: "Visual Studio Code"),
    ])
    #expect(windows.map(\.name) == ["ClockOffice", "TEAM-HANDBOOK"])
    #expect(windows[1].sessionIds == ["b", "d"])
    #expect(ReloadHint.headline(windows) == "To reply from here, reload these 2 editor windows once:")

    // One window: the sentence names the folder and the app, because a folder can be called "ClockOffice" too.
    let one = Array(windows.prefix(1))
    #expect(ReloadHint.headline(one) == "To reply from here, reload the “ClockOffice” window in Visual Studio Code once.")
    #expect(ReloadHint.steps(one).contains("⇧⌘P"))
    #expect(ReloadHint.headline([StaleWindow(folder: "/x/site", host: nil, sessionIds: ["s"])])
            == "To reply from here, reload the “site” window once.")
    #expect(ReloadHint.windows([]).isEmpty)
}

@Test func aWindowWithAnOldSecretOnlySpeaksForSessionsInItsOwnApp() {
    // One editor window that needs a reload refuses every call, so a session in a plain
    // terminal was told to "reload the window in Terminal". Only a session in the refusing window's app is its.
    let code = "/Applications/Visual Studio Code.app"
    let refused = BridgeClient.Hit(ok: false, folder: nil, status: 403, refusedBy: [code])
    #expect(BridgeClient.needsReload(refused, sessionApp: code))
    #expect(!BridgeClient.needsReload(refused, sessionApp: "/System/Applications/Utilities/Terminal.app"))
    #expect(!BridgeClient.needsReload(refused, sessionApp: "/Applications/Cursor.app"))
    #expect(!BridgeClient.needsReload(refused, sessionApp: nil), "no app around the session: nothing to reload")
    let notMine = BridgeClient.Hit(ok: false, folder: nil, status: 404)
    #expect(!BridgeClient.needsReload(notMine, sessionApp: code))
    let fine = BridgeClient.Hit(ok: true, folder: "/x", status: 200, refusedBy: [code])
    #expect(!BridgeClient.needsReload(fine, sessionApp: code), "another window of the same app owns it and answered")
}

@Test func aClickInTheWidgetIsOneOfThreeLinksAndNothingElse() {
    // The widget can only open the app with a link. Each kind survives the trip; anything else is ignored.
    let links: [WidgetLink] = [.open, .session("9b765c59-fddf"), .answer(session: "9b765c59-fddf", option: 2, mark: "a1b2c3d4e5f6", secret: "S-1")]
    for link in links { #expect(WidgetLink(link.url) == link) }
    #expect(WidgetLink(URL(string: Edition.current.scheme + "://answer?id=x&n=1")!) == nil, "an answer without its mark and secret is not an answer")
    #expect(WidgetLink(URL(string: Edition.current.scheme + "://answer?id=x&n=-1&mark=m&s=k")!) == nil)
    #expect(WidgetLink(URL(string: Edition.current.scheme + "://session")!) == nil)
    #expect(WidgetLink(URL(string: Edition.current.scheme + "://delete?id=x")!) == nil)
    #expect(WidgetLink(URL(string: "https://open")!) == nil)
}

@Test func theWidgetOnlyOffersAnswersTheAppCanTypeAndMarksTheQuestionItSaw() {
    let now = Date()
    func asking(_ id: String, revision: String) -> Session {
        var s = Session(id: id, tool: "Claude Code", pid: 1, cwd: "/x", project: id, title: id, state: .asking,
                        since: now.addingTimeInterval(-60), question: "Go on?", options: [ReplyOption(label: "yes", send: "yes"), ReplyOption(label: "no", send: "no")])
        s.revision = revision
        return s
    }
    let snap = Snapshot.from([asking("a", revision: "r1"), asking("b", revision: "r1")], now: now, answerable: ["a"], runSecret: "S-1")
    #expect(snap.asking.first { $0.id == "a" }?.options == ["yes", "no"])
    #expect(snap.asking.first { $0.id == "b" }?.options == [], "a session the app cannot type into offers no answers in the widget")
    #expect(snap.runSecret == "S-1")
    // The same question later, changed: its mark differs, so an old widget's answer no longer matches.
    let later = Snapshot.from([asking("a", revision: "r2")], now: now, answerable: ["a"])
    #expect(later.asking[0].mark != snap.asking.first { $0.id == "a" }?.mark)
    #expect(snap.asking[0].mark.count == 12)
    // What the widget reads is what the app wrote.
    let back = try! Snapshot.decoder.decode(Snapshot.self, from: Snapshot.encoder.encode(snap))
    #expect(back.asking.map(\.options) == snap.asking.map(\.options) && back.runSecret == "S-1")
}

@Test func theToolsOwnInterruptedLineIsNotShownAsTheUsersWords() throws {
    // Seen in use: "[Request interrupted by user]" stood in the conversation under "You".
    let dir = tempDir()
    let file = dir.appendingPathComponent("s.jsonl")
    try [userTyped("build the release"), assistantText("On it."), userTyped("[Request interrupted by user]"),
         userTyped("[Request interrupted by user for tool use]"), userTyped("the clock is already drawn")]
        .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    let turns = Transcript.recent(file: file.path, limit: 10)
    #expect(turns.map(\.text) == ["build the release", "On it.", "the clock is already drawn"])
}

@Test func whatClaudeCodeTellsTheStatusLineBecomesLimitsAndModels() {
    // The shape is from the Claude Code status line docs (read 2026-11-16).
    let inbox = UsageInbox()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let report = line(["session_id": "s1", "model": ["id": "claude-fable-5-2", "display_name": "Fable 5.2"],
                       "rate_limits": ["five_hour": ["used_percentage": 85.0, "resets_at": 1_800_010_800],
                                       "seven_day": ["used_percentage": 23.5, "resets_at": 1_800_500_000]]])
    #expect(inbox.receive(Data(report.utf8), now: now))
    let u = inbox.current()
    #expect(u?.sessionPercent == 85 && u?.weekPercent == 23.5)
    #expect(u?.sessionResets == Date(timeIntervalSince1970: 1_800_010_800))
    #expect(inbox.model(for: "s1") == "Fable 5.2")
    // A session that reports no limits (they can be absent) changes the model list only.
    #expect(inbox.receive(Data(line(["session_id": "s2", "model": ["display_name": "Opus 5.5"]]).utf8), now: now))
    #expect(inbox.current()?.sessionPercent == 85 && inbox.model(for: "s2") == "Opus 5.5")
    #expect(!inbox.receive(Data("not json".utf8)))

    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let words = UsageWords.line("Session", percent: 85, resets: u?.sessionResets, now: now, calendar: utc)
    #expect(words == "Session 85% used · resets " + UsageWords.when(u!.sessionResets!, now: now, calendar: utc))
    #expect(UsageWords.line("Week", percent: 23.5, resets: u?.weekResets, now: now, calendar: utc)?.hasPrefix("Week 24% used · resets ") == true)
    #expect(UsageWords.when(u!.weekResets!, now: now, calendar: utc).count == 9, "another day carries its weekday: 'Sun 19:00'")
    // A number whose window is over is not shown as if it still counted.
    #expect(UsageWords.line("Session", percent: 85, resets: now.addingTimeInterval(-1), now: now) == nil)
    #expect(UsageWords.isHigh(85) && !UsageWords.isHigh(24))
}

@Test func theStatusLineRelayWrapsTheUsersCommandAndGivesItBackExactly() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    let original = #"{"model":"opus","statusLine":{"command":"ccstatusline --theme 'my theme'","padding":0,"refreshInterval":10,"type":"command"}}"#
    try original.write(to: settings, atomically: true, encoding: .utf8)
    try StatusLineRelay.set(true, at: settings, scriptDirectory: dir.appendingPathComponent("support dir"), backups: dir.appendingPathComponent("b"))
    #expect(StatusLineRelay.isInstalled(at: settings))
    var o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    var line = o["statusLine"] as! [String: Any]
    let wrapped = line["command"] as! String
    #expect(wrapped.contains("support dir/\(StatusLineRelay.marker).sh"), "the relay's path, spaces and all")
    #expect(StatusLineRelay.unwrap(wrapped) == .some("ccstatusline --theme 'my theme'"), "the user's own command survives the quoting")
    #expect((line["refreshInterval"] as? NSNumber)?.intValue == 10 && o["model"] as? String == "opus", "nothing else changed")
    #expect(FileManager.default.isExecutableFile(atPath: dir.appendingPathComponent("support dir/\(StatusLineRelay.marker).sh").path))
    // Switching it on twice does not wrap the wrapper.
    try StatusLineRelay.set(true, at: settings, scriptDirectory: dir.appendingPathComponent("support dir"), backups: dir.appendingPathComponent("b"))
    o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    #expect(StatusLineRelay.unwrap((o["statusLine"] as! [String: Any])["command"] as! String) == .some("ccstatusline --theme 'my theme'"))
    // Off: the user's settings are as they were.
    try StatusLineRelay.set(false, at: settings, scriptDirectory: dir.appendingPathComponent("support dir"), backups: dir.appendingPathComponent("b"))
    o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    line = o["statusLine"] as! [String: Any]
    #expect(line["command"] as? String == "ccstatusline --theme 'my theme'" && !StatusLineRelay.isInstalled(at: settings))
    #expect(NSDictionary(dictionary: o).isEqual(to: try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]))
    #expect(StatusLineRelay.unwrap("ccstatusline") == nil, "a command that is not ours is left alone")
}

@Test func theRelayScriptHandsTheDataToTheAppAndStillRunsTheUsersStatusLine() async throws {
    // The real script, run by the real shell, against the app's local door on a test port.
    let server = SnapshotServer()
    let port = try await server.startOnFreePort()
    defer { server.stop() }
    try await waitUntilServing(port)
    let dir = tempDir()
    let script = dir.appendingPathComponent("relay with space.sh")
    try StatusLineRelay.script(port: port).write(to: script, atomically: true, encoding: .utf8)

    func run(_ original: String, _ input: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, original]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin; p.standardOutput = stdout; p.standardError = Pipe()
        try p.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        p.waitUntilExit()
        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    let report = line(["session_id": "live-1", "model": ["display_name": "Fable 5.2"],
                       "rate_limits": ["five_hour": ["used_percentage": 85, "resets_at": 1_900_000_000],
                                       "seven_day": ["used_percentage": 24, "resets_at": 1_900_400_000]]])
    // The user's own status line gets the very same data on its stdin and its output is what Claude Code shows.
    let shown = try run("grep -o 'Fable 5.2' | head -1", report)
    #expect(shown.contains("Fable 5.2"), "the user's command ran on the same input: \(shown)")
    // The relay posts in the background: wait for it (up to 5 seconds) instead of a fixed pause.
    for _ in 0..<200 where server.usage.model(for: "live-1") == nil || server.usage.current() == nil {
        try await Task.sleep(nanoseconds: 25_000_000)
    }
    #expect(server.usage.current()?.sessionPercent == 85 && server.usage.current()?.weekPercent == 24)
    #expect(server.usage.model(for: "live-1") == "Fable 5.2")
    // No command of their own: the relay prints nothing and does not fail.
    #expect(try run("", report) == "")
}

@Test func theNoteClaudeCodeWritesAfterCompactingIsNotShownAsTheUsersWords() throws {
    // Seen in use: a page-long "This session is being continued…" stood in the user's bubble.
    let dir = tempDir()
    let file = dir.appendingPathComponent("s.jsonl")
    let note = line(["type": "user", "isCompactSummary": true, "isVisibleInTranscriptOnly": true,
                     "message": ["role": "user", "content": "This session is being continued from a previous conversation that ran out of context. Summary: …"]])
    let unflagged = userTyped("This session is being continued from a previous conversation that ran out of context.")
    try [userTyped("ship it"), assistantText("Shipping."), note, unflagged, userTyped("thanks")]
        .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    #expect(Transcript.recent(file: file.path, limit: 10).map(\.text) == ["ship it", "Shipping.", "thanks"])
}

@Test func theUsersWordsThatBeginWithAnAngleBracketAreStillTheUsersWords() throws {
    // Only a note from the tool opens with a tag; "<3 thanks" is the user's.
    let dir = tempDir()
    let file = dir.appendingPathComponent("s.jsonl")
    try [userTyped("<3 thanks"), userTyped("< 5 minutes?"), userTyped("<system-reminder>note</system-reminder>"),
         userTyped("<command-name>/clear</command-name>"), assistantText("ok")]
        .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    #expect(Transcript.recent(file: file.path, limit: 10).map(\.text) == ["<3 thanks", "< 5 minutes?", "ok"])
}

@Test func switchingTheRelayOffTakesBackTheRefreshSettingItAdded() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    // No refresh interval of their own: the relay adds one, and removes it again.
    let original = #"{"statusLine":{"command":"ccstatusline","type":"command"}}"#
    try original.write(to: settings, atomically: true, encoding: .utf8)
    try StatusLineRelay.set(true, at: settings, scriptDirectory: dir.appendingPathComponent("s"), backups: dir.appendingPathComponent("b"))
    var o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    #expect(((o["statusLine"] as! [String: Any])["refreshInterval"] as? NSNumber)?.intValue == 30)
    try StatusLineRelay.set(false, at: settings, scriptDirectory: dir.appendingPathComponent("s"), backups: dir.appendingPathComponent("b"))
    o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    #expect(NSDictionary(dictionary: o).isEqual(to: try JSONSerialization.jsonObject(with: Data(original.utf8)) as! [String: Any]))
    // The user's own interval is never touched, even when it is 30.
    let theirs = #"{"statusLine":{"command":"ccstatusline","refreshInterval":30,"type":"command"}}"#
    try theirs.write(to: settings, atomically: true, encoding: .utf8)
    try StatusLineRelay.set(true, at: settings, scriptDirectory: dir.appendingPathComponent("s2"), backups: dir.appendingPathComponent("b"))
    try StatusLineRelay.set(false, at: settings, scriptDirectory: dir.appendingPathComponent("s2"), backups: dir.appendingPathComponent("b"))
    o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    #expect(((o["statusLine"] as! [String: Any])["refreshInterval"] as? NSNumber)?.intValue == 30)
}

@Test func theUsersWordsAfterAPastedBlockAreShown() throws {
    // A message that opens with a pasted block was hidden whole, the user's own question with it.
    let dir = tempDir()
    let file = dir.appendingPathComponent("s.jsonl")
    try [userTyped("<pasted_content id=\"3f5b\">\nStill open:\n1. reload the window\n</pasted_content id=\"3f5b\">\n\nwhich of these is mine?"),
         assistantText("The first.")]
        .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    #expect(Transcript.recent(file: file.path, limit: 10).map(\.text) == ["[pasted text] which of these is mine?", "The first."])
}

// MARK: Codex

/// Writes a Codex conversation file as Codex names and shapes them (read on 2026-11-16), changed `ago` seconds before `now`.
func codexFile(home: URL, now: Date, ago: TimeInterval, id: String, lines: [[String: Any]]) throws {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let changed = now.addingTimeInterval(-ago)
    let c = cal.dateComponents([.year, .month, .day], from: changed)
    let dir = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("rollout-2026-11-16T10-00-00-\(id).jsonl")
    try lines.map(line).joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: file.path)
}
func codexSaid(_ role: String, _ text: String, at: String) -> [String: Any] {
    ["timestamp": at, "type": "response_item",
     "payload": ["type": "message", "role": role, "id": UUID().uuidString,
                 "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]]
}
func codexEvent(_ kind: String, at: String, last: String? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": kind]
    if let last { p["last_agent_message"] = last }
    return ["timestamp": at, "type": "event_msg", "payload": p]
}

@Test func codexConversationsBecomeSessionsWithTheRightState() throws {
    let home = tempDir()
    let now = Date()
    let cwd: [String: Any] = ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Code/web-shop"]]
    let id = { (n: Int) in "01a11c07-3d98-7f11-a197-0000000000\(String(format: "%02d", n))" }
    // 1: a turn under way (started, not complete, the file moved a minute ago).
    try codexFile(home: home, now: now, ago: 60, id: id(1), lines: [cwd,
        codexSaid("user", "<environment_context>cwd</environment_context>", at: "2026-11-16T10:00:01.000Z"),
        codexSaid("user", "Add a discount field to the checkout", at: "2026-11-16T10:00:02.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:03.000Z"),
        codexSaid("assistant", "Looking at the checkout form.", at: "2026-11-16T10:00:09.000Z")])
    // 2: finished with a report.
    try codexFile(home: home, now: now, ago: 600, id: id(2), lines: [cwd,
        codexSaid("user", "Rename the product table", at: "2026-11-16T09:40:00.000Z"),
        codexEvent("task_started", at: "2026-11-16T09:40:01.000Z"),
        codexSaid("assistant", "Renamed the table and updated the three queries that use it.", at: "2026-11-16T09:50:00.000Z"),
        codexEvent("task_complete", at: "2026-11-16T09:50:01.000Z", last: "Renamed the table and updated the three queries that use it.")])
    // 3: finished on a question for the user.
    try codexFile(home: home, now: now, ago: 300, id: id(3), lines: [cwd,
        codexSaid("user", "Clean up the old migrations", at: "2026-11-16T09:55:00.000Z"),
        codexEvent("task_started", at: "2026-11-16T09:55:01.000Z"),
        codexEvent("task_complete", at: "2026-11-16T09:56:00.000Z", last: "I found 14 old migration files. Should I delete them, or move them to an archive folder?")])
    // 4: a turn that started and then wrote nothing for two hours: stopped, not "working".
    try codexFile(home: home, now: now, ago: 7200, id: id(4), lines: [cwd,
        codexSaid("user", "Run the whole test suite", at: "2026-11-16T08:00:00.000Z"),
        codexEvent("task_started", at: "2026-11-16T08:00:01.000Z")])
    // 5: last touched yesterday morning: not listed any more.
    try codexFile(home: home, now: now, ago: 20 * 3600, id: id(5), lines: [cwd,
        codexEvent("task_started", at: "2026-11-15T12:00:00.000Z"),
        codexEvent("task_complete", at: "2026-11-15T12:01:00.000Z", last: "Done.")])

    let sessions = CodexSource(home: home.path).sessions(now: now, pid: 0)
    let by = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    #expect(Set(by.keys) == [id(1), id(2), id(3), id(4)], "the day-old one is no longer listed")
    #expect(by[id(1)]?.state == .working)
    #expect(by[id(1)]?.title == "Add a discount field to the checkout", "the tool's own block is not the user's words")
    #expect(by[id(1)]?.project == "Web shop" && by[id(1)]?.tool == "Codex")
    #expect(by[id(2)]?.state == .done)
    #expect(by[id(2)]?.inShort?.hasPrefix("Renamed the table") == true)
    #expect(by[id(3)]?.state == .asking)
    #expect(by[id(3)]?.options.isEmpty == true, "no one-click answers: a Codex conversation cannot be typed into from here")
    #expect(by[id(4)]?.state == .done, "a turn that stalled is not shown as working")

    let turns = CodexSource(home: home.path).conversation(for: by[id(2)]!, limit: 8)
    #expect(turns.map(\.who) == [.you, .assistant])
    #expect(turns.first?.text == "Rename the product table")
}

@Test func codexWrapsTheUsersWordsInItsOwnBlockAndOnlyTheUsersWordsAreShown() throws {
    // The shape found in real Codex files on 2026-11-16 (headings only were read, not the words).
    let home = tempDir(), now = Date()
    let wrapped = "# Context from my IDE setup:\n\n## Active file: PM/notes.md\n\n## Open tabs:\n- notes.md\n- plan.md\n\n## My request:\nSummarise the notes in five lines"
    try codexFile(home: home, now: now, ago: 120, id: "01a11c07-3d98-7f11-a197-000000000099", lines: [
        ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Desktop/Handover"]],
        codexSaid("user", String(repeating: "## Plugin Management\nHow plugins work. ", count: 200), at: "2026-11-16T10:00:00.500Z"),
        codexSaid("user", wrapped, at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z"),
        codexEvent("task_complete", at: "2026-11-16T10:01:00.000Z", last: "Here are the five lines.")])
    let s = try #require(CodexSource(home: home.path).sessions(now: now, pid: 0).first)
    #expect(s.title == "Summarise the notes in five lines")
    #expect(CodexSource(home: home.path).conversation(for: s, limit: 8).first?.text == "Summarise the notes in five lines")
}

@Test func codexHelperThreadsAreNotListedAsTheUsersSessions() throws {
    // Each Codex conversation had a second file from Codex's "guardian" reviewer (2026-11-16).
    let home = tempDir(), now = Date()
    let body: [[String: Any]] = [
        ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Desktop/Handover"]],
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z"),
        codexEvent("task_complete", at: "2026-11-16T10:01:00.000Z", last: "Reviewed.")]
    try codexFile(home: home, now: now, ago: 60, id: "01a11c07-3d98-7f11-a197-0000000000a1",
                  lines: [["timestamp": "2026-11-16T10:00:00.000Z", "type": "session_meta", "payload": ["thread_source": "user", "source": "vscode"]]] + body)
    try codexFile(home: home, now: now, ago: 60, id: "01a11c07-3e84-7e03-afc5-0000000000a2",
                  lines: [["timestamp": "2026-11-16T10:00:00.000Z", "type": "session_meta",
                           "payload": ["thread_source": "guardian_review", "source": ["subagent": ["other": "guardian"]]]]] + body)
    #expect(CodexSource(home: home.path).sessions(now: now, pid: 0).map(\.id) == ["01a11c07-3d98-7f11-a197-0000000000a1"])
}

@Test func aCodexConversationStartedDaysAgoIsStillFoundWhileItIsInUse() throws {
    // Codex keeps writing in the folder of the day a conversation started.
    let home = tempDir(), now = Date()
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let started = now.addingTimeInterval(-5 * 86400)
    let c = cal.dateComponents([.year, .month, .day], from: started)
    let dir = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("rollout-2026-11-11T10-00-00-01a11c07-3d98-7f11-a197-0000000000b1.jsonl")
    try [["timestamp": "2026-11-11T10:00:00.000Z", "type": "session_meta", "payload": ["thread_source": "user", "cwd": "/Users/x/Code/long-runner"]],
         codexEvent("task_started", at: "2026-11-16T10:00:02.000Z")].map(line).joined(separator: "\n").appending("\n")
        .write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-30)], ofItemAtPath: file.path)
    let s = try #require(CodexSource(home: home.path).sessions(now: now, pid: 0).first)
    #expect(s.state == .working && s.project == "Long runner", "the folder comes from the opening line when no turn names it")
}

@Test func aCodexFileWithOneVeryLongLineNearItsEndStillReadsRight() throws {
    // The last megabyte can be a single line of tool output (13.7 MB seen in real files): the turn before it counts.
    let home = tempDir(), now = Date()
    let huge: [String: Any] = ["timestamp": "2026-11-16T10:00:05.000Z", "type": "response_item",
                               "payload": ["type": "custom_tool_call_output", "output": String(repeating: "x", count: 1_400_000)]]
    try codexFile(home: home, now: now, ago: 60, id: "01a11c07-3d98-7f11-a197-0000000000c1", lines: [
        ["timestamp": "2026-11-16T10:00:00.000Z", "type": "session_meta", "payload": ["thread_source": "user", "cwd": "/Users/x/Code/big"]],
        codexSaid("user", "Dump the whole table", at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z"),
        huge])
    let s = try #require(CodexSource(home: home.path).sessions(now: now, pid: 0).first)
    #expect(s.state == .working && s.title == "Dump the whole table")
}

@Test func aCodexTurnSheStoppedIsNotShownAsWorking() throws {
    let home = tempDir(), now = Date()
    try codexFile(home: home, now: now, ago: 60, id: "01a11c07-3d98-7f11-a197-0000000000d1", lines: [
        ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Code/web"]],
        codexSaid("user", "Refactor everything", at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z"),
        codexSaid("assistant", "Starting with the models. Should I also rename the tables?", at: "2026-11-16T10:00:09.000Z"),
        codexEvent("turn_aborted", at: "2026-11-16T10:00:12.000Z")])
    let s = try #require(CodexSource(home: home.path).sessions(now: now, pid: 0).first)
    #expect(s.state == .done, "stopped by the user: neither working nor a question for them")
    #expect(s.inShort == "You stopped this turn.")
}

@Test func aCodexFileThatGrowsIsReadOnFromWhereItStopped() throws {
    let home = tempDir(), now = Date()
    let id = "01a11c07-3d98-7f11-a197-0000000000e1"
    let first: [[String: Any]] = [
        ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Code/web"]],
        codexSaid("user", "Add a footer", at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z")]
    try codexFile(home: home, now: now, ago: 20, id: id, lines: first)
    let src = CodexSource(home: home.path)
    #expect(src.sessions(now: now, pid: 0).first?.state == .working)
    let more = first + [codexSaid("assistant", "Footer added. Which colour should it be: grey or white?", at: "2026-11-16T10:00:30.000Z"),
                        codexEvent("task_complete", at: "2026-11-16T10:00:31.000Z", last: "Footer added. Which colour should it be: grey or white?")]
    try codexFile(home: home, now: now, ago: 5, id: id, lines: more)
    let file = try #require(src.files(now: now).first)
    try (try String(contentsOfFile: file.path, encoding: .utf8) + "\n").write(toFile: file.path, atomically: false, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2)], ofItemAtPath: file.path)
    let s = try #require(src.sessions(now: now, pid: 0).first)
    #expect(s.state == .asking && s.title == "Add a footer")
    #expect(src.conversation(for: s, limit: 8).count == 2, "nothing is counted twice when the file is read on")
}

@Test func onlyClaudeCodeSessionsAreStoppedByTheClaudePlansLimit() {
    let now = Date()
    func working(_ id: String, _ tool: String) -> Session {
        Session(id: id, tool: tool, pid: 1, cwd: "/x", project: id, title: id, state: .working, since: now)
    }
    let snap = Snapshot.from([working("claude", "Claude Code"), working("codex", "Codex")], now: now, limited: true)
    #expect(snap.quiet.first { $0.id == "claude" }?.stopped == true)
    #expect(snap.quiet.first { $0.id == "codex" }?.stopped == false, "Codex runs on another plan")
    #expect(Snapshot.from([working("claude", "Claude Code")], now: now).quiet[0].stopped == false)
}

@Test func aCodexLineStillBeingWrittenWaitsForTheNextRead() throws {
    let home = tempDir(), now = Date()
    let id = "01a11c07-3d98-7f11-a197-0000000000f1"
    try codexFile(home: home, now: now, ago: 20, id: id, lines: [
        ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Code/web"]],
        codexSaid("user", "Add a footer", at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z")])
    let src = CodexSource(home: home.path)
    let file = try #require(src.files(now: now).first)
    let whole = line(codexEvent("task_complete", at: "2026-11-16T10:00:31.000Z", last: "Footer added."))
    let fh = try #require(FileHandle(forWritingAtPath: file.path))
    try fh.seekToEnd()
    try fh.write(contentsOf: Data(("\n" + whole.prefix(40)).utf8))   // half a line
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10)], ofItemAtPath: file.path)
    #expect(src.sessions(now: now, pid: 0).first?.state == .working, "half a line changes nothing")
    try fh.seekToEnd()
    try fh.write(contentsOf: Data((whole.dropFirst(40) + "\n").utf8))
    try fh.close()
    try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: file.path)
    let s = try #require(src.sessions(now: now, pid: 0).first)
    #expect(s.state == .done && s.inShort == "Footer added.")
}

@Test func aLongCodexConversationKeepsTheUsersFirstMessageAsItsTitle() throws {
    let home = tempDir(), now = Date()
    var lines: [[String: Any]] = [
        ["timestamp": "2026-11-16T09:00:00.000Z", "type": "session_meta", "payload": ["thread_source": "user", "cwd": "/Users/x/Code/long"]],
        codexSaid("user", "Build the import screen", at: "2026-11-16T09:00:01.000Z")]
    // More than a megabyte of tool output between the user's first message and their latest.
    for _ in 0..<6 {
        lines.append(["timestamp": "2026-11-16T09:10:00.000Z", "type": "response_item",
                      "payload": ["type": "custom_tool_call_output", "output": String(repeating: "y", count: 300_000)]])
    }
    lines += [codexSaid("user", "Now add a progress bar", at: "2026-11-16T10:00:01.000Z"),
              codexEvent("task_started", at: "2026-11-16T10:00:02.000Z")]
    try codexFile(home: home, now: now, ago: 30, id: "01a11c07-3d98-7f11-a197-0000000000a7", lines: lines)
    let s = try #require(CodexSource(home: home.path).sessions(now: now, pid: 0).first)
    #expect(s.title == "Build the import screen")
    #expect(s.inShort == "Working on: Now add a progress bar")
}

@Test func theUsersCodexMessageWithAPastedScreenshotIsStillTheUsersFirstMessage() throws {
    // A pasted screenshot makes a message one line of about a megabyte.
    let home = tempDir(), now = Date()
    // Written out by hand in the order Codex writes its keys (type and role first, the content after): in 12
    // real lines of this kind the role is within the first 400 bytes.
    let withImage = #"{"timestamp":"2026-11-16T10:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Why is this button cut off?"},{"type":"input_image","image_url":"data:image/png;base64,"#
        + String(repeating: "A", count: 900_000) + #""}]}}"#
    #expect(withImage.utf8.count > 524_288)
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let changed = now.addingTimeInterval(-60)
    let c = cal.dateComponents([.year, .month, .day], from: changed)
    let dir = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("rollout-2026-11-16T10-00-00-01a11c07-3d98-7f11-a197-0000000000a8.jsonl")
    let rows: [String] = [
        line(["timestamp": "2026-11-16T10:00:00.000Z", "type": "session_meta", "payload": ["thread_source": "user", "cwd": "/Users/x/Code/shop"]]),
        withImage,
        line(codexEvent("task_started", at: "2026-11-16T10:00:02.000Z")),
        line(codexEvent("task_complete", at: "2026-11-16T10:00:40.000Z", last: "The container has a fixed height.")),
        line(codexSaid("user", "Fix it then", at: "2026-11-16T10:01:00.000Z")),
        line(codexEvent("task_started", at: "2026-11-16T10:01:01.000Z"))]
    try (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: file.path)
    let s = try #require(CodexSource(home: home.path).sessions(now: now, pid: 0).first)
    #expect(s.title == "Why is this button cut off?")
    #expect(s.state == .working)
}

@Test func widgetDataWrittenBeforeTheStoppedFlagStillReads() throws {
    let old = #"{"id":"a","project":"Web","line":"Doing things","working":true}"#
    let q = try JSONDecoder().decode(Snapshot.Quiet.self, from: Data(old.utf8))
    #expect(q.stopped == false && q.working)
}

@Test func aCodexTurnIsJudgedByTheOrderOfItsLinesNotTheirTimes() throws {
    let home = tempDir(), now = Date()
    let cwd: [String: Any] = ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Code/web"]]
    // A new turn stamped two seconds BEFORE the stop above it.
    try codexFile(home: home, now: now, ago: 30, id: "01a11c07-3d98-7f11-a197-0000000000b2", lines: [cwd,
        codexSaid("user", "First", at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z"),
        codexEvent("turn_aborted", at: "2026-11-16T10:00:10.000Z"),
        codexSaid("user", "Second", at: "2026-11-16T10:00:07.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:08.000Z")])
    // A start with no time at all.
    var bare = codexEvent("task_started", at: "x"); bare["timestamp"] = nil
    try codexFile(home: home, now: now, ago: 40, id: "01a11c07-3d98-7f11-a197-0000000000b3", lines: [cwd,
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z"),
        codexEvent("task_complete", at: "2026-11-16T10:00:10.000Z", last: "Done."),
        codexSaid("user", "Again", at: "2026-11-16T10:00:11.000Z"),
        bare])
    let all = CodexSource(home: home.path).sessions(now: now, pid: 0)
    #expect(all.count == 2 && all.allSatisfy { $0.state == .working })
}

@Test func aCodexFileReplacedByAnotherIsReadAfresh() throws {
    let home = tempDir(), now = Date()
    let id = "01a11c07-3d98-7f11-a197-0000000000b4"
    let cwd: [String: Any] = ["timestamp": "2026-11-16T10:00:00.000Z", "type": "turn_context", "payload": ["cwd": "/Users/x/Code/web"]]
    try codexFile(home: home, now: now, ago: 30, id: id, lines: [cwd,
        codexSaid("user", "Alpha", at: "2026-11-16T10:00:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:00:02.000Z")])
    let src = CodexSource(home: home.path)
    #expect(src.sessions(now: now, pid: 0).first?.title == "Alpha")
    try codexFile(home: home, now: now, ago: 10, id: id, lines: [cwd,
        codexSaid("user", "Gamma, a longer first message than the one before", at: "2026-11-16T10:05:01.000Z"),
        codexEvent("task_started", at: "2026-11-16T10:05:02.000Z"),
        codexEvent("task_complete", at: "2026-11-16T10:05:30.000Z", last: "Done with gamma.")])
    let s = try #require(src.sessions(now: now, pid: 0).first)
    #expect(s.title.hasPrefix("Gamma") && s.state == .done)
    #expect(src.conversation(for: s, limit: 9).count == 1, "nothing of the file it replaced is left")
}

@Test func aCodexConversationStartedYesterdayShowsAtOnce() throws {
    // Started just before midnight: its folder is yesterday's. It was hidden for up to half a minute.
    let home = tempDir(), now = Date()
    let src = CodexSource(home: home.path)
    #expect(src.sessions(now: now, pid: 0).isEmpty)   // the folders are listed now, and not again for 30 seconds
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let c = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: -1, to: now)!)
    let dir = home.appendingPathComponent(String(format: ".codex/sessions/%04d/%02d/%02d", c.year!, c.month!, c.day!))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("rollout-2026-11-15T23-59-00-01a11c07-3d98-7f11-a197-0000000000b5.jsonl")
    try ([["timestamp": "2026-11-15T22:59:00.000Z", "type": "session_meta", "payload": ["thread_source": "user", "cwd": "/Users/x/Code/late"]],
          codexEvent("task_started", at: "2026-11-15T22:59:02.000Z")].map(line).joined(separator: "\n") + "\n")
        .write(to: file, atomically: true, encoding: .utf8)
    #expect(src.sessions(now: now.addingTimeInterval(5), pid: 0).count == 1)
}

@Test func aUsedUpLimitWithNoResetTimeEndsWithItsOwnWindow() {
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    let noReset = UsageLimits(sessionPercent: 100, weekPercent: 40, at: t)
    #expect(noReset.usedUp(now: t.addingTimeInterval(3600)))
    #expect(!noReset.usedUp(now: t.addingTimeInterval(5 * 3600 + 1)), "five hours after the report at the latest")
    let withReset = UsageLimits(sessionPercent: 99.6, sessionResets: t.addingTimeInterval(600), weekPercent: 40, at: t)
    #expect(withReset.usedUp(now: t.addingTimeInterval(599)) && !withReset.usedUp(now: t.addingTimeInterval(601)))
    #expect(!UsageLimits(sessionPercent: 99.4, weekPercent: 40, at: t).usedUp(now: t))
    #expect(UsageLimits(sessionPercent: 10, weekPercent: 100, at: t).usedUp(now: t.addingTimeInterval(6 * 86400)))
}

/// The way Claude Code writes a process's start into its entry: "Mon Nov 16 14:56:54 2026", universal time.
func procStart(_ d: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return f.string(from: d)
}

@Test func aSessionIsClosedOnlyWhileItsProcessIsStillThatSession() throws {
    let home = tempDir()
    let dir = home.appendingPathComponent(".claude/sessions")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let me = ProcessInfo.processInfo.processIdentifier   // a process that is certainly alive
    let born = try #require(Procs.started(me))
    let entry = dir.appendingPathComponent("\(me).json")
    func write(_ o: [String: Any]) throws { try line(o).write(to: entry, atomically: true, encoding: .utf8) }
    try write(["pid": Int(me), "sessionId": "s-1", "cwd": "/x", "procStart": procStart(born)])
    var asked: [(Int32, Int32)] = []
    let record: (Int32, Int32) -> Int32 = { pid, sig in asked.append((pid, sig)); return 0 }

    #expect(Closing.stillThat(pid: me, sessionId: "s-1", home: home.path))
    #expect(Closing.close(pid: me, sessionId: "s-1", home: home.path, signal: record))
    #expect(asked.count == 1 && asked[0].0 == me && asked[0].1 == SIGTERM, "asked to quit, once, with the terminate signal")

    // The entry names another session: nothing is sent.
    #expect(!Closing.close(pid: me, sessionId: "s-2", home: home.path, signal: record))
    // An entry left behind by a session that died, whose process number another program now has: the same number,
    // the same session name, but that process started at another time.
    try write(["pid": Int(me), "sessionId": "s-1", "cwd": "/x", "procStart": procStart(born.addingTimeInterval(-3600))])
    #expect(!Closing.close(pid: me, sessionId: "s-1", home: home.path, signal: record), "another process has the number now")
    // An entry that does not say when its process started proves nothing.
    try write(["pid": Int(me), "sessionId": "s-1", "cwd": "/x"])
    #expect(!Closing.close(pid: me, sessionId: "s-1", home: home.path, signal: record))
    try FileManager.default.removeItem(at: entry)
    #expect(!Closing.close(pid: me, sessionId: "s-1", home: home.path, signal: record), "no entry for the process: not a session")
    #expect(!Closing.close(pid: 0, sessionId: "s-1", home: home.path, signal: record))
    #expect(!Closing.close(pid: 1, sessionId: "s-1", home: home.path, signal: record))
    #expect(asked.count == 1)
}

@Test func closingIsOfferedOnlyForAClaudeCodeSessionWithItsOwnProcess() {
    #expect(Closing.offered(tool: "Claude Code", pid: 4242))
    #expect(!Closing.offered(tool: "Codex", pid: 4242), "every Codex conversation shares one process")
    #expect(!Closing.offered(tool: "Claude Code", pid: 0) && !Closing.offered(tool: "Claude Code", pid: 1))
}

@Test func theStartOfAProcessIsReadTheWayClaudeCodeWritesIt() {
    let t = Date(timeIntervalSince1970: 1_794_841_014)
    #expect(procStart(t) == "Mon Nov 16 14:56:54 2026")
    #expect(Closing.startTimes("Mon Nov 16 14:56:54 2026").contains(t))
    #expect(Closing.startTimes("Fri Nov  6 09:05:03 2026").count == 1, "a one-digit day is padded with a second space")
    // Universal time only: the same words read as local time are another moment, and must not count.
    #expect(Closing.startTimes("Mon Nov 16 14:56:54 2026") == [t])
    #expect(Closing.startTimes("not a date").isEmpty)
}

/// Runs only when asked to, on a throwaway session started for it: CLOSE_PID and CLOSE_SID name the process and
/// the session. (`scratch` scripts start one in a temporary folder, run this, and watch it quit.)
@Test func closesARealThrowawaySessionWhenAskedTo() throws {
    let env = ProcessInfo.processInfo.environment
    guard let pid = env["CLOSE_PID"].flatMap({ Int32($0) }), let sid = env["CLOSE_SID"] else { return }
    #expect(!Closing.close(pid: pid, sessionId: sid + "-not"), "another session's name: nothing is sent")
    #expect(Procs.alive(pid))
    #expect(Closing.close(pid: pid, sessionId: sid))
}

@Test func aSessionsPageBecomesALinkTheDesktopAppOpens() {
    #expect(RemoteLink.desktop(for: URL(string: "https://claude.ai/code/session_01AbC-d_9")!)?.absoluteString == "claude://code/session_01AbC-d_9")
    #expect(RemoteLink.desktop(for: URL(string: "https://claude.ai/code/cse_42")!) != nil)
    // Anything that is not a session's own page goes to the browser as before.
    #expect(RemoteLink.desktop(for: URL(string: "https://claude.ai/code")!) == nil)
    #expect(RemoteLink.desktop(for: URL(string: "https://claude.ai/code/routines")!) == nil)
    #expect(RemoteLink.desktop(for: URL(string: "https://claude.ai/chat/session_01")!) == nil)
    #expect(RemoteLink.desktop(for: URL(string: "https://example.com/code/session_01")!) == nil)
    #expect(RemoteLink.desktop(for: URL(string: "https://claude.ai/code/session_01/extra")!) == nil)
}

@Test func linksAreFoundOnlyWhereThereIsSomethingToOpen() {
    let there: Set<String> = ["/Users/x/Code/site/mock/profile-dark.html", "/Users/x/Code/site/src/app.ts", "/Users/x/notes.md"]
    let exists: (String) -> Bool = { there.contains($0) }
    let text = "Open /Users/x/Code/site/mock/profile-dark.html to see it. Docs: https://code.claude.com/docs/en/statusline). See src/app.ts:120, ~/notes.md and yes/no or and/or."
    let found = Linker.find(in: text, cwd: "/Users/x/Code/site", home: "/Users/x", exists: exists)
    let said = found.map { f -> String in
        let s = text.index(text.startIndex, offsetBy: f.start)
        return String(text[s..<text.index(s, offsetBy: f.length)])
    }
    #expect(said == ["/Users/x/Code/site/mock/profile-dark.html", "https://code.claude.com/docs/en/statusline", "src/app.ts:120", "~/notes.md"],
            "the bracket after the address, and words with a slash that name no file, are left alone")
    #expect(found[2].url.path == "/Users/x/Code/site/src/app.ts" && found[2].url.fragment == "L120", "a path in the session's folder, with its line")
    #expect(found[3].url.path == "/Users/x/notes.md")
    // A path with spaces is linked when it is tried whole (written in code type).
    #expect(Linker.file("/Users/x/Desktop/ClockOffice/a.md", cwd: "/", exists: { $0 == "/Users/x/Desktop/ClockOffice/a.md" }) != nil)
    #expect(Linker.file("not a path", cwd: "/", exists: { _ in true }) == nil)
    #expect(Linker.pictures(in: "see /Users/x/a.png and /Users/x/notes.md", cwd: "/", exists: { _ in true }) == ["/Users/x/a.png"])
}

@Test func aMessageCarriesThePicturesThatCameWithIt() throws {
    let dir = tempDir()
    PastedPictures.folder = dir.appendingPathComponent("pictures").path
    let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(7), count: 200)).base64EncodedString()
    let file = dir.appendingPathComponent("t.jsonl")
    let pasted: [String: Any] = ["type": "user", "uuid": "u1", "message": ["role": "user", "content": [
        ["type": "text", "text": "[Image #1] why is this cut off?"],
        ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png]]]]]
    let dragged = userTyped("'/var/folders/59/abc/T/TemporaryItems/NSIRD_x/Screenshot 2026-11-16 at 22.50.07.png' and this one?")
    try [line(pasted), dragged].joined(separator: "\n").appending("\n").write(to: file, atomically: true, encoding: .utf8)
    let turns = Transcript.recent(file: file.path, limit: 8)
    #expect(turns.count == 2)
    let first = try #require(turns.first?.pictures.first)
    #expect(first.hasPrefix(PastedPictures.folder) && first.hasSuffix(".png"))
    #expect((try Data(contentsOf: URL(fileURLWithPath: first))).count == 204, "the pasted picture is written out, whole")
    #expect(turns[1].pictures == ["/var/folders/59/abc/T/TemporaryItems/NSIRD_x/Screenshot 2026-11-16 at 22.50.07.png"])
    #expect(turns[1].text == "[screenshot] and this one?")
    // Read again: the same file, not a second copy.
    #expect(Transcript.recent(file: file.path, limit: 8).first?.pictures.first == first)
    #expect(try FileManager.default.contentsOfDirectory(atPath: PastedPictures.folder).count == 1)
}

@Test func aClickOnALinkNeverRunsAnything() {
    // What the Mac would START if it were simply "opened": an app, a .command file, a bare program, a script
    // marked as a program, a folder made to look like one.
    let dirs: Set<String> = ["/System/Applications/Calculator.app", "/Users/x/Fake.app", "/Users/x/Code", "/Users/x/flow.workflow"]
    let programs: Set<String> = ["/Users/x/run.command", "/bin/ls", "/Users/x/tool", "/Users/x/deploy.sh"]
    let files: Set<String> = ["/Users/x/a.png", "/Users/x/page.html", "/Users/x/src/app.ts", "/Users/x/notes.sh", "/Users/x/x.terminal"]
    let isDir: (String) -> Bool? = { dirs.contains($0) ? true : (programs.contains($0) || files.contains($0) ? false : nil) }
    let runs: (String) -> Bool = { programs.contains($0) }
    func click(_ s: String) -> Linker.Click { Linker.click(URL(string: s)!, isDirectory: isDir, runs: runs, odd: { $0.hasSuffix("alias.jpg") }) }

    for p in dirs.union(programs) { #expect(click("file://" + p) == .reveal(p), "\(p) is shown in the Finder, never opened") }
    #expect(click("file:///Users/x/a.png") == .view("/Users/x/a.png"))
    #expect(click("file:///Users/x/page.html") == .view("/Users/x/page.html"))
    #expect(click("file:///Users/x/src/app.ts#L120") == .edit("/Users/x/src/app.ts", line: 120))
    // A script that is not marked as a program, and a file type an app would act on: to the editor, as text.
    #expect(click("file:///Users/x/notes.sh") == .edit("/Users/x/notes.sh", line: nil))
    #expect(click("file:///Users/x/x.terminal") == .edit("/Users/x/x.terminal", line: nil))
    #expect(click("file:///Users/x/gone.txt") == .nothing)
    // An address that shows one place and goes to another.
    #expect(click("https://good.example@evil.example/") == .nothing && click("https://user:pw@evil.example/") == .nothing)
    // Letters of another alphabet reach the app already turned into the "xn--" form: such a host is not followed.
    #expect(Linker.click(URL(string: "https://xn--pple-43d.com/")!) == .nothing)
    #expect(Linker.click(URL(string: "https://www.xn--80ak6aa92e.com/a")!) == .nothing)
    #expect(click("https://code.claude.com/docs") == .web(URL(string: "https://code.claude.com/docs")!))
    for other in ["javascript:alert(1)", "ssh://host", "tel:123", "x-apple.systempreferences:com.apple.preference", "claude://code/new", "vscode://x/y", "https:///nohost"] {
        #expect(click(other) == .nothing, "\(other) is not followed")
    }
    #expect(Linker.followable(URL(string: "https://a.b")!) && Linker.followable(URL(fileURLWithPath: "/x")))
    #expect(!Linker.followable(URL(string: "javascript:alert(1)")!) && !Linker.followable(URL(string: "ssh://h")!))
    // A long text is left without links rather than searched while the screen is drawn.
    #expect(Linker.find(in: String(repeating: "see https://a.example/page ", count: 1000), cwd: "/", exists: { _ in true }).isEmpty)
}

@Test func onTheRealDiskAppsProgramsAndDisguisedLinksAreOnlyShown() throws {
    // The same rule against real files: nothing here is opened, only the decision is read.
    let dir = tempDir()
    func make(_ name: String, program: Bool = false) throws -> String {
        let p = dir.appendingPathComponent(name).path
        try "echo hi\n".write(toFile: p, atomically: true, encoding: .utf8)
        if program { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p) }
        return URL(fileURLWithPath: p).resolvingSymlinksInPath().path
    }
    let command = try make("run.command", program: true), bare = try make("tool", program: true)
    let script = try make("notes.sh"), page = try make("page.html")
    let disguised = dir.appendingPathComponent("holiday.png").path
    try FileManager.default.createSymbolicLink(atPath: disguised, withDestinationPath: "/System/Applications/Calculator.app")
    func click(_ p: String) -> Linker.Click { Linker.click(URL(fileURLWithPath: p)) }

    #expect(click("/System/Applications/Calculator.app") == .reveal("/System/Applications/Calculator.app"))
    #expect(click("/bin/ls") == .reveal("/bin/ls"))
    #expect(click(command) == .reveal(command) && click(bare) == .reveal(bare))
    #expect(click(disguised) == .reveal("/System/Applications/Calculator.app"), "a 'picture' that is really a link to an app")
    #expect(click(script) == .edit(script, line: nil), "a script that is not marked as a program is text for the editor")
    #expect(click(page) == .view(page))
    #expect(click(dir.path) == .reveal(URL(fileURLWithPath: dir.path).resolvingSymlinksInPath().path), "a folder is shown, not opened")
}

@Test func aFinderAliasIsShownNotOpened() throws {
    // A Finder alias is a plain file that stands for another one: "holiday.png" can be an alias of an app or a
    // script, and opening it starts that.
    let dir = tempDir()
    let alias = dir.appendingPathComponent("holiday.png")
    let data = try URL(fileURLWithPath: "/System/Applications/Calculator.app").bookmarkData(options: .suitableForBookmarkFile)
    try URL.writeBookmarkData(data, to: alias)
    let path = alias.resolvingSymlinksInPath().path
    #expect(Linker.isOdd(path))
    #expect(Linker.click(URL(fileURLWithPath: path)) == .reveal(path))
    #expect(Linker.click(URL(fileURLWithPath: "/dev/zero")) == .reveal("/dev/zero"), "a device is not a file to open")
    let real = dir.appendingPathComponent("real.png")
    try Data([1, 2, 3]).write(to: real)
    #expect(Linker.click(real) == .view(real.resolvingSymlinksInPath().path))
}

/// Runs only when asked to, on a real conversation record named in REAL_TRANSCRIPT (read only): how many messages
/// carry pictures, and whether each picture written out can be read as one. Prints counts, never words.
@Test func picturesOfARealConversationWhenAskedTo() throws {
    guard let file = ProcessInfo.processInfo.environment["REAL_TRANSCRIPT"] else { return }
    PastedPictures.folder = tempDir().appendingPathComponent("pictures").path
    let turns = Transcript.recent(file: file, limit: 60, window: 64 * 1024 * 1024)
    let with = turns.filter { !$0.pictures.isEmpty }
    let all = with.flatMap(\.pictures)
    let pasted = all.filter { $0.hasPrefix(PastedPictures.folder) }
    let readable = pasted.filter { p in
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil) else { return false }
        return CGImageSourceGetCount(src) > 0
    }
    let dragged = all.filter { !$0.hasPrefix(PastedPictures.folder) }
    let there = dragged.filter { FileManager.default.fileExists(atPath: $0) }
    print("REAL: turns \(turns.count), with pictures \(with.count); pasted \(pasted.count), readable as pictures \(readable.count); dragged \(dragged.count), file still there \(there.count)")
    #expect(readable.count == pasted.count)
}

@Test func aLinkGoesWhereItsWordsSay() {
    let evil = URL(string: "https://evil.example/x")!, good = URL(string: "https://good.example/docs")!
    #expect(Linker.honest(words: "the docs", target: good))
    #expect(Linker.honest(words: "https://good.example/other", target: good), "another page on the same host is honest")
    #expect(Linker.honest(words: "see https://GOOD.example here", target: good))
    #expect(!Linker.honest(words: "https://good.example", target: evil))
    #expect(!Linker.honest(words: "see https://good.example", target: evil), "an address among other words is compared too")
    #expect(!Linker.honest(words: "https://good.example and https://evil.example", target: evil))
    #expect(!Linker.honest(words: "https://good.example", target: URL(fileURLWithPath: "/Applications/Calculator.app")),
            "words that are a web address over a link to a file")
    #expect(Linker.honest(words: "Views.swift", target: URL(fileURLWithPath: "/x/Views.swift")))
    // Capitals, and an address the system cannot read, do not get past the comparison.
    #expect(!Linker.honest(words: "HTTPS://good.example", target: evil))
    #expect(!Linker.honest(words: "see Https://Good.Example/x", target: evil))
    #expect(Linker.honest(words: "HTTPS://GOOD.EXAMPLE/docs", target: good))
    #expect(!Linker.honest(words: "https://good.example:abc", target: evil))
    #expect(!Linker.honest(words: "https://good.example:abc", target: good), "unreadable words are never a reason to keep a link")
}

@Test func aFileLinkTravelsUnderANameOnlyTheAppUnderstands() {
    let file = URL(string: "file:///Users/x/src/app.ts#L120")!
    let inner = Linker.inner(file)
    #expect(inner.scheme == Linker.fileScheme && !inner.isFileURL, "the system has nothing to open it with")
    #expect(Linker.outer(inner) == file && Linker.followable(inner))
    #expect(Linker.inner(URL(string: "https://a.example")!).scheme == "https", "a web address stays as it is")
    #expect(Linker.outer(URL(string: "https://a.example")!) == nil)
    // The app's own rule reads it as the file it stands for.
    #expect(Linker.click(inner, isDirectory: { $0 == "/Users/x/src/app.ts" ? false : nil }, runs: { _ in false }, odd: { _ in false })
            == .edit("/Users/x/src/app.ts", line: 120))
    #expect(Linker.click(Linker.inner(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
            == .reveal("/System/Applications/Calculator.app"))
}

@Test func twoBuildsOnOneMacEachKeepTheirOwnRelayAndHooks() throws {
    // The standard build and a build with a private look both write into Claude Code's settings. Each must add
    // and remove only its own entry (verifier 17, 2026-11-17: they shared one name, so one took the other's out).
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    try #"{"model":"opus","statusLine":{"type":"command","command":"ccstatusline --theme 'my theme'"}}"#
        .write(to: settings, atomically: true, encoding: .utf8)
    let standard = Edition(), look = Edition(suffix: "studio", port: 47999, oldRelays: ["old-name-statusline.sh"])
    let a = dir.appendingPathComponent("ClockOffice"), b = dir.appendingPathComponent("ClockOffice Studio")
    func command() throws -> String {
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        return (o["statusLine"] as! [String: Any])["command"] as! String
    }

    try StatusLineRelay.set(true, at: settings, scriptDirectory: a, backups: dir.appendingPathComponent("ba"), edition: standard)
    try StatusLineRelay.set(true, at: settings, scriptDirectory: b, backups: dir.appendingPathComponent("bb"), edition: look)
    #expect(StatusLineRelay.isInstalled(at: settings, edition: standard) && StatusLineRelay.isInstalled(at: settings, edition: look))
    var l = StatusLineRelay.layers(try command())
    #expect(l.scripts.map { ($0 as NSString).lastPathComponent } == ["clockoffice-studio-statusline.sh", "clockoffice-statusline.sh"])
    #expect(l.original == "ccstatusline --theme 'my theme'", "the user's own command is still at the end of the chain")
    // Switching one on again does not add it twice.
    try StatusLineRelay.set(true, at: settings, scriptDirectory: a, backups: dir.appendingPathComponent("ba"), edition: standard)
    #expect(StatusLineRelay.layers(try command()).scripts.count == 2)

    // The one that stands behind the other is taken out: the other stays.
    try StatusLineRelay.set(false, at: settings, scriptDirectory: a, backups: dir.appendingPathComponent("ba"), edition: standard)
    #expect(!StatusLineRelay.isInstalled(at: settings, edition: standard) && StatusLineRelay.isInstalled(at: settings, edition: look))
    l = StatusLineRelay.layers(try command())
    #expect(l.scripts.count == 1 && l.original == "ccstatusline --theme 'my theme'")
    try StatusLineRelay.set(false, at: settings, scriptDirectory: b, backups: dir.appendingPathComponent("bb"), edition: look)
    #expect(try command() == "ccstatusline --theme 'my theme'")

    // A relay an earlier version of a build left behind under another name counts as that build's: it hands the
    // data to the same port. Switching the build's relay on replaces it instead of standing in front of it.
    let old = dir.appendingPathComponent("Old Name/old-name-statusline.sh")
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try StatusLineRelay.script(port: look.port).write(to: old, atomically: true, encoding: .utf8)
    let chained = StatusLineRelay.wrap("ccstatusline", scriptPath: old.path)
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": chained]]).write(to: settings)
    #expect(StatusLineRelay.isInstalled(at: settings, edition: look) && !StatusLineRelay.isInstalled(at: settings, edition: standard))
    try StatusLineRelay.set(true, at: settings, scriptDirectory: b, backups: dir.appendingPathComponent("bb"), edition: look)
    l = StatusLineRelay.layers(try command())
    #expect(l.scripts.map { ($0 as NSString).lastPathComponent } == ["clockoffice-studio-statusline.sh"] && l.original == "ccstatusline")

    // The same old relay with the standard build's relay in front of it (the state after a rename, with both
    // builds installed): each build sees its own, and the look's is taken out from behind the other.
    try StatusLineRelay.script(port: look.port).write(to: old, atomically: true, encoding: .utf8)
    try StatusLineRelay.script(port: standard.port).write(to: a.appendingPathComponent("clockoffice-statusline.sh"), atomically: true, encoding: .utf8)
    let both = StatusLineRelay.rebuild([a.appendingPathComponent("clockoffice-statusline.sh").path, old.path], "ccstatusline")!
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": both]]).write(to: settings)
    #expect(StatusLineRelay.isInstalled(at: settings, edition: look) && StatusLineRelay.isInstalled(at: settings, edition: standard))
    try StatusLineRelay.set(false, at: settings, scriptDirectory: b, backups: dir.appendingPathComponent("bb"), edition: look)
    #expect(try command() == StatusLineRelay.wrap("ccstatusline", scriptPath: a.appendingPathComponent("clockoffice-statusline.sh").path))
    #expect(!StatusLineRelay.isInstalled(at: settings, edition: look) && StatusLineRelay.isInstalled(at: settings, edition: standard))

    // The dialog hooks: one entry per build and event, told apart by the port.
    let hooks = dir.appendingPathComponent("hooks.json")
    try "{}".write(to: hooks, atomically: true, encoding: .utf8)
    try ClaudeHooks.set(true, at: hooks, backups: dir.appendingPathComponent("bh"), edition: standard)
    try ClaudeHooks.set(true, at: hooks, backups: dir.appendingPathComponent("bh"), edition: look)
    func entries() throws -> Int {
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as! [String: Any]
        return (((o["hooks"] as? [String: Any])?["PermissionRequest"] as? [Any]) ?? []).count
    }
    #expect(try entries() == 2 && ClaudeHooks.isInstalled(at: hooks, edition: standard) && ClaudeHooks.isInstalled(at: hooks, edition: look))
    try ClaudeHooks.set(false, at: hooks, backups: dir.appendingPathComponent("bh"), edition: standard)
    #expect(try entries() == 1 && !ClaudeHooks.isInstalled(at: hooks, edition: standard) && ClaudeHooks.isInstalled(at: hooks, edition: look))
}

@Test func aLooksSettingsAreTakenWholeOrNotAtAll() {
    func read(_ json: String) -> Edition? { Edition.read(Data(json.utf8)) }
    let good = read(#"{"suffix":"studio","port":47999,"accentDark":"FF9DBB","accentLight":"B0285A"}"#)
    #expect(good?.suffix == "studio" && good?.port == 47999 && good?.accentDark == 0xFF9DBB)
    #expect(good?.scheme == "clockoffice-studio" && good?.folder == "ClockOffice Studio")
    #expect(Edition().scheme == "clockoffice" && Edition().folder == "ClockOffice" && Edition().port == 47863)
    // Half a look would give a build that answers for another one (verifier 17, 2026-11-17).
    for bad in [#"{"suffix":"my-look","port":47999}"#,      // a hyphen: the ID would differ, the link scheme not
                #"{"suffix":"dïsco","port":47999}"#,        // not plain letters: a link scheme cannot be made of it
                #"{"suffix":"Studio","port":47999}"#,
                #"{"suffix":"studio","port":"47999"}"#,     // a port written as text
                #"{"suffix":"studio","port":80}"#,
                #"{"suffix":"studio","port":47863}"#,       // the standard app's own port
                #"{"suffix":"studio","port":47999.5}"#,
                #"{"suffix":"studio","port":true}"#,
                #"{"suffix":"studio"}"#, #"{"port":47999}"#, "not json"] {
        #expect(read(bad) == nil, "\(bad) must not be half understood")
    }
}

@Test func aUsersOwnStatusLineIsNeverTakenForARelay() throws {
    // Verifier 18, 2026-11-17: a command of the shape 'x-statusline.sh' 'one' 'two' was taken apart as if the app
    // had written it, and written back changed. Only a script with one of this app's own names, in exactly the
    // form the app writes, is a relay.
    let dir = tempDir()
    let own = [#"'/Users/someone/bin/my-statusline.sh' 'one' 'two'"#, #"'/Users/someone/bin/my-statusline.sh' 'one'"#,
               #"'/Users/someone/bin/clockoffice-statusline.sh' 'one' 'two'"#, #"'/Users/someone/bin/clockoffice-statusline.sh'"#,
               #"'/Users/someone/bin/clockoffice-statusline.sh'  'one'"#, #"echo "it's" ' ' done"#, "ccstatusline "]
    for command in own {
        #expect(StatusLineRelay.layers(command).scripts.isEmpty, "taken for a relay: \(command)")
        let settings = dir.appendingPathComponent("s-\(abs(command.hashValue)).json")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": command, "refreshInterval": 5]]).write(to: settings)
        for e in [Edition(), Edition(suffix: "studio", port: 47999)] {
            try StatusLineRelay.set(true, at: settings, scriptDirectory: dir.appendingPathComponent(e.folder), backups: dir.appendingPathComponent("b"), edition: e)
        }
        for e in [Edition(), Edition(suffix: "studio", port: 47999)] {
            try StatusLineRelay.set(false, at: settings, scriptDirectory: dir.appendingPathComponent(e.folder), backups: dir.appendingPathComponent("b"), edition: e)
        }
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
        let line = o["statusLine"] as! [String: Any]
        #expect(line["command"] as? String == command, "after both on and both off: \(String(describing: line["command"]))")
        #expect((line["refreshInterval"] as? NSNumber)?.intValue == 5)
    }
    // The words of a quoted command, and only of one that is nothing but quoted words.
    #expect(StatusLineRelay.quotedWords(#"'a b' 'it'\''s'"#) == ["a b", "it's"])
    #expect(StatusLineRelay.quotedWords(#"'a' b"#) == nil && StatusLineRelay.quotedWords(#"'a'  'b'"#) == nil && StatusLineRelay.quotedWords("") == nil)
    // A script folder with a quote and with ' ' in its name still comes back whole.
    for odd in ["it's", "a' 'b"] {
        let script = "/tmp/\(odd)/clockoffice-statusline.sh"
        #expect(StatusLineRelay.peel(StatusLineRelay.wrap("mine --x 'y'", scriptPath: script))?.script == script)
    }
}

@Test func whatARelayLeavesBehindIsTakenAwayWithTheLastOne() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    let a = Edition(), b = Edition(suffix: "studio", port: 47999, oldRelays: ["old-name-statusline.sh"])
    func set(_ on: Bool, _ e: Edition) throws {
        try StatusLineRelay.set(on, at: settings, scriptDirectory: dir.appendingPathComponent(e.folder), backups: dir.appendingPathComponent("b"), edition: e)
    }
    func line() throws -> [String: Any]? {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["statusLine"] as? [String: Any]
    }
    // The refresh setting the first relay added goes when the last relay goes, whichever order they leave in
    // (verifier 18: A on, B on, A off, B off left "refreshInterval": 30 behind).
    for order in [[a, b], [b, a]] {
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "mine"]]).write(to: settings)
        try set(true, a); try set(true, b)
        #expect((try line()?["refreshInterval"] as? NSNumber)?.intValue == 30)
        try set(false, order[0])
        #expect((try line()?["refreshInterval"] as? NSNumber)?.intValue == 30, "the other relay still needs it")
        try set(false, order[1])
        let left = try line()
        #expect(left?["command"] as? String == "mine" && left?["refreshInterval"] == nil, "left behind: \(String(describing: left))")
    }
    // A relay whose script file is gone cannot run, and the command behind it never would: the next write takes
    // it out, and until then no build calls it its own.
    let gone = StatusLineRelay.wrap("mine", scriptPath: dir.appendingPathComponent("Old Name/old-name-statusline.sh").path)
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": gone]]).write(to: settings)
    #expect(!StatusLineRelay.isInstalled(at: settings, edition: a) && !StatusLineRelay.isInstalled(at: settings, edition: b))
    try set(true, b)
    #expect(StatusLineRelay.layers(try line()?["command"] as? String ?? "").scripts.map { ($0 as NSString).lastPathComponent } == ["clockoffice-studio-statusline.sh"])
    try set(false, b)
    #expect(try line()?["command"] as? String == "mine")
    // An earlier version of a private build named its script like the standard one. It is that build's by the
    // port it hands the data to: the standard build neither calls it its own nor removes it.
    let old = dir.appendingPathComponent("ClockOffice Studio/clockoffice-statusline.sh")
    try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
    try StatusLineRelay.script(port: b.port).write(to: old, atomically: true, encoding: .utf8)
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": StatusLineRelay.wrap("mine", scriptPath: old.path)]]).write(to: settings)
    #expect(StatusLineRelay.isInstalled(at: settings, edition: b) && !StatusLineRelay.isInstalled(at: settings, edition: a))
    try set(true, a); try set(false, a)
    let back = try line()
    #expect(back?["command"] as? String == StatusLineRelay.wrap("mine", scriptPath: old.path))
    #expect(back?["refreshInterval"] == nil, "a relay that was there before ours gets its settings back as they were")
    // That old relay had added the refresh setting itself. Its build, switched on again, writes its script under
    // today's name and takes the note along; switched off, it takes the setting away.
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "refreshInterval": 30,
        "command": StatusLineRelay.wrap("mine", scriptPath: old.path)]]).write(to: settings)
    try "30".write(to: StatusLineRelay.refreshNote(for: old.path), atomically: true, encoding: .utf8)
    try set(true, b)
    #expect(StatusLineRelay.layers(try line()?["command"] as? String ?? "").scripts.map { ($0 as NSString).lastPathComponent } == ["clockoffice-studio-statusline.sh"])
    try set(false, b)
    let end = try line()
    #expect(end?["command"] as? String == "mine" && end?["refreshInterval"] == nil, "\(String(describing: end))")
    // Switched on a second time, a relay keeps its place: the one in front of it stays in front.
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "mine"]]).write(to: settings)
    try set(true, a); try set(true, b); try set(true, a)
    #expect(StatusLineRelay.layers(try line()?["command"] as? String ?? "").scripts.map { ($0 as NSString).lastPathComponent }
            == ["clockoffice-studio-statusline.sh", "clockoffice-statusline.sh"])
}

@Test func theHooksMenuSaysOnOnlyForThisBuildsOwnEntry() throws {
    // Verifier 18: "on" was read from the whole file, so the other build's hooks plus this build's address in a
    // permission rule read as on.
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    let a = Edition(), b = Edition(suffix: "studio", port: 47999)
    try JSONSerialization.data(withJSONObject: ["permissions": ["allow": ["Bash(curl http://127.0.0.1:\(a.port)/hook)"]]]).write(to: settings)
    try ClaudeHooks.set(true, at: settings, backups: dir.appendingPathComponent("b"), edition: b)
    #expect(ClaudeHooks.isInstalled(at: settings, edition: b) && !ClaudeHooks.isInstalled(at: settings, edition: a))
}

@Test func charactersThatTakeNoRoomAreNotReadAsPartOfAnAddress() {
    let evil = URL(string: "https://evil.example")!, good = URL(string: "https://good.example/x")!
    #expect(!Linker.honest(words: "h\u{200B}ttps://good.example", target: evil))
    #expect(!Linker.honest(words: "\u{202E}elpmaxe.doog//:sptth\u{202C}", target: evil))
    #expect(!Linker.honest(words: "see \u{202E}this", target: good), "a mark that turns the reading direction: no link at all")
    #expect(Linker.honest(words: "https://good.example\u{0301}", target: good))
    #expect(Linker.honest(words: "the docs", target: evil))
    for s in ["\u{200B}", "\u{200D}", "\u{FE0F}", "\u{0301}", "\u{00AD}", "\u{2060}", "\u{200A}", "\u{3164}"] {
        #expect(Linker.takesNoRoom(s.unicodeScalars.first!), "\(String(s.unicodeScalars.first!.value, radix: 16))")
    }
    #expect(!Linker.takesNoRoom(" ") && !Linker.takesNoRoom("\u{00A0}") && !Linker.takesNoRoom("a"))
}

@Test func switchingTheHooksOffTakesOnlyThisBuildsCommand() throws {
    // Verifier 19, 2026-11-17: a hook of the user's own in the same entry as the app's went with it, and the
    // app's command filed under another event kept the menu on "on".
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    let e = Edition()
    try ClaudeHooks.set(true, at: settings, backups: dir.appendingPathComponent("b"), edition: e)
    var o = try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any]
    var hooks = o["hooks"] as! [String: Any]
    var entry = (hooks["PermissionRequest"] as! [[String: Any]])[0]
    entry["hooks"] = (entry["hooks"] as! [[String: Any]]) + [["type": "command", "command": "say asked"]]
    hooks["PermissionRequest"] = [entry]
    hooks["Stop"] = [["hooks": [["type": "command", "command": ClaudeHooks.command(e)]]], ["hooks": [["type": "command", "command": "say done"]]]]
    o["hooks"] = hooks
    try JSONSerialization.data(withJSONObject: o).write(to: settings)
    try ClaudeHooks.set(false, at: settings, backups: dir.appendingPathComponent("b"), edition: e)
    #expect(!ClaudeHooks.isInstalled(at: settings, edition: e))
    let left = (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["hooks"] as! [String: Any]
    let commands = left.mapValues { ($0 as! [[String: Any]]).flatMap { ($0["hooks"] as! [[String: Any]]).map { $0["command"] as! String } } }
    #expect(commands == ["PermissionRequest": ["say asked"], "Stop": ["say done"]], "\(commands)")
}

@Test func threeBuildsLeaveTheRefreshSettingToTheLastRelay() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    let a = Edition(), b = Edition(suffix: "studio", port: 47999), c = Edition(suffix: "third", port: 47998)
    func set(_ on: Bool, _ e: Edition) throws {
        try StatusLineRelay.set(on, at: settings, scriptDirectory: dir.appendingPathComponent(e.folder), backups: dir.appendingPathComponent("bk"), edition: e)
    }
    func line() throws -> [String: Any]? {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["statusLine"] as? [String: Any]
    }
    // Every order of switching three builds on and then off: the setting stays while any relay is on, and the
    // status line ends exactly as it began.
    func orders(_ x: [Edition]) -> [[Edition]] {
        x.count < 2 ? [x] : x.indices.flatMap { i -> [[Edition]] in var r = x; let h = r.remove(at: i); return orders(r).map { [h] + $0 } }
    }
    for on in orders([a, b, c]) {
        for off in orders([a, b, c]) {
            try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "mine"]]).write(to: settings)
            for e in on { try set(true, e) }
            for (n, e) in off.enumerated() {
                try set(false, e)
                if n < 2 { #expect((try line()?["refreshInterval"] as? NSNumber)?.intValue == 30, "lost with a relay still on") }
            }
            let end = try line()
            #expect(end?["command"] as? String == "mine" && end?.count == 2, "\(String(describing: end))")
        }
    }
    // A bare script name is somebody's own command, also when it is called like the app's.
    #expect(StatusLineRelay.peel("'clockoffice-statusline.sh' 'x'") == nil)
}

@Test func aBuildFindsItsOwnRelayBehindOneWithANameItDoesNotKnow() throws {
    // Verifier 20, 2026-11-17: with a look's old-named relay in FRONT of the standard build's, the standard build
    // read its own menu item as off and a click added a second copy of its relay.
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    let a = Edition(), b = Edition(suffix: "studio", port: 47999, oldRelays: ["old-name-statusline.sh"])
    let old = dir.appendingPathComponent("Old Name/old-name-statusline.sh")
    let mine = dir.appendingPathComponent(a.folder).appendingPathComponent("clockoffice-statusline.sh")
    for u in [old, mine] { try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true) }
    try StatusLineRelay.script(port: b.port).write(to: old, atomically: true, encoding: .utf8)
    try StatusLineRelay.script(port: a.port).write(to: mine, atomically: true, encoding: .utf8)
    let chain = StatusLineRelay.rebuild([old.path, mine.path], "mine --x")!
    try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": chain, "refreshInterval": 10]]).write(to: settings)
    func line() throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["statusLine"] as! [String: Any]
    }
    #expect(StatusLineRelay.isInstalled(at: settings, edition: a) && StatusLineRelay.isInstalled(at: settings, edition: b))
    // On again: still one copy of each, in the same order.
    try StatusLineRelay.set(true, at: settings, scriptDirectory: mine.deletingLastPathComponent(), backups: dir.appendingPathComponent("bk"), edition: a)
    #expect(try line()["command"] as? String == chain)
    // Off: the standard build's goes, the other one and the user's command stay, and so does the user's own interval.
    try StatusLineRelay.set(false, at: settings, scriptDirectory: mine.deletingLastPathComponent(), backups: dir.appendingPathComponent("bk"), edition: a)
    let after = try line()
    #expect(after["command"] as? String == StatusLineRelay.wrap("mine --x", scriptPath: old.path))
    #expect((after["refreshInterval"] as? NSNumber)?.intValue == 10)
    #expect(!StatusLineRelay.isInstalled(at: settings, edition: a) && StatusLineRelay.isInstalled(at: settings, edition: b))
    // A script of the user's own with one of the app's names, which does not do what a relay does, is theirs.
    let theirs = dir.appendingPathComponent("bin/clockoffice-statusline.sh")
    try FileManager.default.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\necho \"$1\"\n".write(to: theirs, atomically: true, encoding: .utf8)
    #expect(StatusLineRelay.peel(StatusLineRelay.wrap("one", scriptPath: theirs.path)) == nil)
}
