import Foundation
import Network

/// Permission prompts answered from ClockOffice.
///
/// Claude Code runs a `PermissionRequest` hook the moment it is about to ask for permission. With the dialog switch
/// on, that hook posts the request to this app and waits for the reply on the same connection. While it waits, the
/// dialog is on screen in the terminal as always (measured on Claude Code 2.1.326, 2026-11-17):
/// - a click on Allow or Deny here becomes the hook's decision, and Claude Code closes its dialog;
/// - an answer typed in the terminal does NOT end the hook: it keeps waiting (verifier 1, re-measured 2026-11-17).
///   So the app checks the session is still waiting on this prompt before a click counts, and lets go of a request
///   once its session has moved on (Store) or a newer request arrives from the same session (below);
/// - with the app closed or quitting, the hook gets no decision and the terminal dialog decides.
/// So nothing is ever decided without a click, and the terminal stays a full way to answer.
/// Docs: code.claude.com/docs/en/hooks#permissionrequest (read 2026-11-17).
public final class PermissionDesk: @unchecked Sendable {
    public struct Ask: Sendable, Equatable {
        /// This app's own name for the request; a click answers exactly this one.
        public var id: String
        public var sessionId: String
        public var toolName: String
        /// The subagent that asks, when it is one (Claude Code's `agent_id`); nil for the session's main agent.
        public var agentId: String?
        public var at: Date
    }

    private struct Open {
        var ask: Ask
        let conn: NWConnection
    }

    private let lock = NSLock()
    private var open: [String: Open] = [:]
    /// Called (on a background queue) when a request arrives or goes away.
    public var onChange: (@Sendable () -> Void)?
    /// How long a request is held before the app lets go of it (the hook's own limit is longer).
    let holdFor: TimeInterval

    public init(holdFor: TimeInterval = 570) { self.holdFor = holdFor }

    /// Holds a hook's connection open until the user decides. False when the body is not a permission request.
    func park(_ body: Data, on conn: NWConnection) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let sid = o["session_id"] as? String, let tool = o["tool_name"] as? String else { return false }
        let agent = o["agent_id"] as? String
        let ask = Ask(id: UUID().uuidString, sessionId: sid, toolName: tool, agentId: agent, at: Date())
        // One agent asks one permission at a time: its older request was answered in the terminal. Subagents of the
        // same session ask in parallel under the same session_id (verifier 1 of T-30, measured), so only the same
        // agent's older request is let go.
        lock.lock()
        let older = open.values.filter { $0.ask.sessionId == sid && $0.ask.agentId == agent }.map(\.ask.id)
        open[ask.id] = Open(ask: ask, conn: conn)
        lock.unlock()
        older.forEach(release)
        // The hook sends nothing more; the read ends when curl gives up or its session ends.
        watch(ask.id, conn)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + holdFor) { [weak self] in self?.release(ask.id) }
        onChange?()
        return true
    }

    private func watch(_ id: String, _ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            if done || error != nil { self?.forget(id); conn.cancel(); return }
            if data != nil { self?.watch(id, conn) }
        }
    }

    private func forget(_ id: String) {
        lock.lock(); let had = open.removeValue(forKey: id) != nil; lock.unlock()
        if had { onChange?() }
    }

    /// Lets go of a request without deciding: the terminal's dialog decides.
    func release(_ id: String) {
        lock.lock(); let o = open.removeValue(forKey: id); lock.unlock()
        guard let o else { return }
        Self.send(o.conn, Data())
        onChange?()
    }

    /// Lets go of every request without deciding (the app is quitting).
    public func releaseAll() {
        lock.lock(); let ids = Array(open.keys); lock.unlock()
        ids.forEach(release)
    }

    /// The request still waiting in a session, newest first. Nil once it was answered anywhere.
    public func ask(for sessionId: String) -> Ask? {
        lock.lock(); defer { lock.unlock() }
        return open.values.map(\.ask).filter { $0.sessionId == sessionId }.max { $0.at < $1.at }
    }

    /// Every request still waiting.
    public func all() -> [Ask] {
        lock.lock(); defer { lock.unlock() }
        return open.values.map(\.ask)
    }

    /// Lets go of one request without deciding (public: the app does this for a session it does not list).
    public func letGo(_ id: String) { release(id) }

    /// Whether a click here can answer this tool's prompt. A question dialog and the plan approval need the user's
    /// own words or choice sent with the answer (docs: "need updatedInput"), so they stay in the terminal.
    public static func answerable(_ toolName: String) -> Bool {
        !["AskUserQuestion", "ExitPlanMode"].contains(toolName)
    }

    /// Answers one request. False when it is no longer waiting (answered in the terminal, or the session moved on):
    /// nothing is decided then.
    @discardableResult
    public func decide(_ id: String, allow: Bool) -> Bool {
        lock.lock(); let o = open.removeValue(forKey: id); lock.unlock()
        guard let o else { return false }
        Self.send(o.conn, Self.decision(allow: allow))
        onChange?()
        return true
    }

    /// What the hook prints for Claude Code. A deny stops the turn, as "No" in the terminal does: Claude then waits
    /// for the user instead of trying another way round the step that was refused.
    public static func decision(allow: Bool) -> Data {
        var d: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow {
            d["message"] = "The user denied this from ClockOffice."
            d["interrupt"] = true
        }
        let o: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": d]]
        return (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
    }

    private static func send(_ conn: NWConnection, _ body: Data) {
        var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        reply.append(body)
        conn.send(content: reply, completion: .contentProcessed { _ in conn.cancel() })
    }
}
