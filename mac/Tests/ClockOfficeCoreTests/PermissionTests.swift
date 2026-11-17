import Testing
import Foundation
@testable import ClockOfficeCore

// MARK: permission prompts answered from the app (T-24)

private func permissionBody(_ sid: String, tool: String = "Bash", agent: String? = nil) -> Data {
    var o: [String: Any] = ["session_id": sid, "hook_event_name": "PermissionRequest", "tool_name": tool,
                            "tool_input": ["command": "touch probe.txt", "description": "Create a file"]]
    if let agent { o["agent_id"] = agent }
    return try! JSONSerialization.data(withJSONObject: o)
}

/// Requests that stay open for seconds: the shared session allows 6 per host, and tests running side by side queued
/// behind each other's held requests (a wait of over 5 s seen once).
private let heldRequests: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpMaximumConnectionsPerHost = 64
    return URLSession(configuration: c)
}()

/// Posts like the hook does (curl) and returns what the hook would print, or nil when it got no 200.
private func postPermission(_ port: UInt16, _ body: Data, header: Bool = true, timeout: TimeInterval = 20) async -> (Int, Data)? {
    var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/permission")!, timeoutInterval: timeout)
    r.httpMethod = "POST"; r.httpBody = body
    r.setValue("application/json", forHTTPHeaderField: "content-type")
    if header { r.setValue("hook", forHTTPHeaderField: "x-clockoffice") }
    guard let (data, resp) = try? await heldRequests.data(for: r) else { return nil }
    return ((resp as! HTTPURLResponse).statusCode, data)
}

private func startServer() async throws -> (SnapshotServer, UInt16) {
    let server = SnapshotServer()
    let port = try await server.startOnFreePort()
    try await waitUntilServing(port)
    return (server, port)
}

private func waitFor(_ what: () -> Bool) async throws {
    for _ in 0..<100 where !what() { try await Task.sleep(nanoseconds: 50_000_000) }
}

@Test func decisionIsWhatClaudeCodeReads() throws {
    let allow = try JSONSerialization.jsonObject(with: PermissionDesk.decision(allow: true)) as! [String: Any]
    let h = allow["hookSpecificOutput"] as! [String: Any]
    #expect(h["hookEventName"] as? String == "PermissionRequest")
    #expect((h["decision"] as! [String: Any]) as NSDictionary == ["behavior": "allow"] as NSDictionary)
    let deny = try JSONSerialization.jsonObject(with: PermissionDesk.decision(allow: false)) as! [String: Any]
    let d = (deny["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
    #expect(d["behavior"] as? String == "deny")
    #expect(d["interrupt"] as? Bool == true, "a deny stops the turn, as No in the terminal does")
}

@Test func onlyToolsThatNeedNoWordsCanBeAnsweredHere() {
    #expect(PermissionDesk.answerable("Bash"))
    #expect(PermissionDesk.answerable("Edit"))
    #expect(!PermissionDesk.answerable("AskUserQuestion"))
    #expect(!PermissionDesk.answerable("ExitPlanMode"))
}

@Test func aClickAnswersTheWaitingHookWithAllow() async throws {
    let (server, port) = try await startServer()
    defer { server.stop() }
    async let reply = postPermission(port, permissionBody("s1"))
    try await waitFor { server.permissions.ask(for: "s1") != nil }
    let ask = try #require(server.permissions.ask(for: "s1"))
    #expect(ask.toolName == "Bash")
    #expect(server.inbox.dialog(for: "s1", notBefore: .distantPast)?.toolName == "Bash", "the words reach the inbox too")
    // Held past the 5-second limit that ends every other request.
    try await Task.sleep(nanoseconds: 5_600_000_000)
    #expect(server.permissions.ask(for: "s1") != nil)
    #expect(server.permissions.decide(ask.id, allow: true))
    let (status, data) = try #require(await reply)
    #expect(status == 200)
    #expect(data == PermissionDesk.decision(allow: true))
    #expect(server.permissions.ask(for: "s1") == nil)
    #expect(!server.permissions.decide(ask.id, allow: false), "one request, one answer")
}

@Test func aDenyReachesTheHookAsDeny() async throws {
    let (server, port) = try await startServer()
    defer { server.stop() }
    async let reply = postPermission(port, permissionBody("s2"))
    try await waitFor { server.permissions.ask(for: "s2") != nil }
    #expect(server.permissions.decide(try #require(server.permissions.ask(for: "s2")).id, allow: false))
    let (_, data) = try #require(await reply)
    #expect(data == PermissionDesk.decision(allow: false))
}

@Test func lettingGoDecidesNothing() async throws {
    let (server, port) = try await startServer()
    defer { server.stop() }
    async let reply = postPermission(port, permissionBody("s3"))
    try await waitFor { server.permissions.ask(for: "s3") != nil }
    server.permissions.letGo(try #require(server.permissions.ask(for: "s3")).id)
    let (status, data) = try #require(await reply)
    #expect(status == 200 && data.isEmpty, "an empty reply: Claude Code's own dialog decides")
}

@Test func aHookThatGivesUpEndsTheRequestHere() async throws {
    // curl's own limit, or the session ending, closes the connection. (An answer typed in the terminal does not:
    // Claude Code leaves the hook running. That case is the Store's check before a click counts.)
    let (server, port) = try await startServer()
    defer { server.stop() }
    let task = Task { await postPermission(port, permissionBody("s4")) }
    try await waitFor { server.permissions.ask(for: "s4") != nil }
    let id = try #require(server.permissions.ask(for: "s4")).id
    task.cancel()
    try await waitFor { server.permissions.ask(for: "s4") == nil }
    #expect(server.permissions.ask(for: "s4") == nil)
    #expect(!server.permissions.decide(id, allow: true), "a click after that decides nothing")
}

@Test func aNewRequestFromTheSameSessionLetsGoOfTheOldOne() async throws {
    let (server, port) = try await startServer()
    defer { server.stop() }
    async let first = postPermission(port, permissionBody("s7"))
    try await waitFor { server.permissions.ask(for: "s7") != nil }
    let old = try #require(server.permissions.ask(for: "s7")).id
    async let second = postPermission(port, permissionBody("s7"))
    try await waitFor { server.permissions.ask(for: "s7")?.id != old }
    let (_, data) = try #require(await first)
    #expect(data.isEmpty, "the old request is let go without a decision")
    #expect(server.permissions.all().count == 1)
    #expect(!server.permissions.decide(old, allow: true))
    #expect(server.permissions.decide(try #require(server.permissions.ask(for: "s7")).id, allow: false))
    _ = await second
}

@Test func subagentsAskingInParallelKeepEachOthersRequests() async throws {
    let (server, port) = try await startServer()
    defer { server.stop() }
    async let main = postPermission(port, permissionBody("s8"))
    try await waitFor { server.permissions.all().count == 1 }
    async let sub = postPermission(port, permissionBody("s8", agent: "agent-1"))
    try await waitFor { server.permissions.all().count == 2 }
    #expect(server.permissions.all().count == 2, "a subagent's request does not let go of the main agent's")
    #expect(Set(server.permissions.all().map(\.agentId)) == [nil, "agent-1"])
    server.permissions.releaseAll()
    _ = await main; _ = await sub
}

@Test func permissionDoorRefusesWithoutItsHeaderOrWithAnotherShape() async throws {
    let (server, port) = try await startServer()
    defer { server.stop() }
    #expect(await postPermission(port, permissionBody("s5"), header: false)?.0 == 400)
    #expect(await postPermission(port, Data("nope".utf8))?.0 == 400)
    #expect(server.permissions.all().isEmpty)
}

@Test func stoppingTheServerLetsGoOfEveryRequest() async throws {
    let (server, port) = try await startServer()
    async let reply = postPermission(port, permissionBody("s6"))
    try await waitFor { server.permissions.ask(for: "s6") != nil }
    server.stop()
    let (status, data) = try #require(await reply)
    #expect(status == 200 && data.isEmpty)
}

@Test func hookSwitchInstallsTheWaitingPermissionHookAndUpgradesAnOldOne() throws {
    let dir = tempDir()
    let settings = dir.appendingPathComponent("settings.json"), backups = dir.appendingPathComponent("b")
    // The entries an older build wrote: the permission hook only reported.
    let old = ClaudeHooks.command(.current)
    let before: [String: Any] = ["hooks": [
        "PreToolUse": [["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": old, "timeout": 3]]]],
        "PermissionRequest": [["hooks": [["type": "command", "command": old, "timeout": 3]]]]]]
    try JSONSerialization.data(withJSONObject: before).write(to: settings)
    #expect(!ClaudeHooks.isInstalled(at: settings), "an old install reads as off, so one click brings it up to date")
    try ClaudeHooks.set(true, at: settings, backups: backups)
    #expect(ClaudeHooks.isInstalled(at: settings))
    let hooks = (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])["hooks"] as! [String: Any]
    let perm = hooks["PermissionRequest"] as! [[String: Any]]
    #expect(perm.count == 1, "the old entry is replaced, not kept beside the new one")
    let h = (perm[0]["hooks"] as! [[String: Any]])[0]
    let cmd = h["command"] as! String
    #expect(cmd.contains("/permission") && cmd.contains(" -f ") && cmd.hasSuffix("|| true"))
    #expect((h["timeout"] as! Int) > ClaudeHooks.permissionWait, "Claude Code's limit outlasts curl's own")
    let pre = hooks["PreToolUse"] as! [[String: Any]]
    #expect(pre.count == 1 && ((pre[0]["hooks"] as! [[String: Any]])[0]["timeout"] as! Int) == 3)
    try ClaudeHooks.set(false, at: settings, backups: backups)
    let after = (try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any])
    #expect(after["hooks"] == nil)
}

/// Live check with a real Claude Code session (off unless CLOCKOFFICE_E2E_PORT is set): serves the permission door on
/// that port, waits for one real request, answers it with CLOCKOFFICE_E2E_DECISION (allow, deny or letgo), and writes
/// what happened to CLOCKOFFICE_E2E_LOG. Driven by a script that runs a throwaway session with the real hook command.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CLOCKOFFICE_E2E_PORT"] != nil))
func liveRequestFromARealSession() async throws {
    let env = ProcessInfo.processInfo.environment
    let port = UInt16(env["CLOCKOFFICE_E2E_PORT"]!)!
    let log = URL(fileURLWithPath: env["CLOCKOFFICE_E2E_LOG"] ?? "/dev/null")
    func note(_ s: String) { try? (((try? String(contentsOf: log, encoding: .utf8)) ?? "") + s + "\n").write(to: log, atomically: true, encoding: .utf8) }
    let server = SnapshotServer()
    try server.start(port: port)
    defer { server.stop() }
    note("ready")
    var ask: PermissionDesk.Ask?
    for _ in 0..<1800 { if let a = server.permissions.all().first { ask = a; break }; try await Task.sleep(nanoseconds: 50_000_000) }
    let a = try #require(ask)
    note("asked \(a.toolName) \(a.sessionId)")
    try await Task.sleep(nanoseconds: 2_000_000_000)
    switch env["CLOCKOFFICE_E2E_DECISION"] {
    case "deny": note("decided \(server.permissions.decide(a.id, allow: false))")
    case "letgo": server.permissions.letGo(a.id); note("let go")
    case "wait":
        // The terminal answers. Claude Code leaves the hook running (measured): this notes whether the request is
        // still open, it does not expect it to close.
        for _ in 0..<600 where server.permissions.ask(for: a.sessionId) != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        note("still open after terminal answer: \(server.permissions.ask(for: a.sessionId) != nil)")
    default: note("decided \(server.permissions.decide(a.id, allow: true))")
    }
    try await Task.sleep(nanoseconds: 3_000_000_000)
}
