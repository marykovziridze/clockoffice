import Foundation

/// Talks to the ClockOffice extension running inside an editor window (VS Code and its forks: Antigravity, Cursor…).
/// The extension owns the terminals, so it is the only thing that can type into the exact one or bring it forward.
/// Each editor window announces its port in ~/.clockoffice/bridges/<pid>.json; a shared token guards every call.
public struct BridgeClient: Sendable {
    public var home: String
    public init(home: String = NSHomeDirectory() + "/.clockoffice") { self.home = home }

    public struct Hit: Sendable {
        public var ok: Bool
        /// The folder open in that editor window; opening it with the editor brings exactly that window forward.
        public var folder: String?
        public var status: Int
        /// The apps (bundle paths) whose editor windows refused the call with an old secret. A session can only
        /// be waiting on such a window if it runs inside one of these apps.
        public var refusedBy: [String] = []
    }

    func token() -> String? {
        (try? String(contentsOfFile: home + "/token", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ports of live editor windows. A file whose process is gone, or is no longer an app, is ignored,
    /// so a call never goes to whatever program now holds that port.
    func ports() -> [Int] { windows().map(\.port) }

    /// The same, with the app each window belongs to (its bundle path, "/Applications/Visual Studio Code.app").
    func windows() -> [(port: Int, app: String)] {
        let dir = home + "/bridges"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.compactMap { n -> (port: Int, app: String)? in
            guard let data = FileManager.default.contents(atPath: dir + "/" + n),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let port = (o["port"] as? NSNumber)?.intValue, let pid = (o["pid"] as? NSNumber)?.int32Value,
                  Procs.alive(pid), let path = Procs.path(of: pid), let r = path.range(of: ".app/") else { return nil }
            return (port, String(path[..<r.lowerBound]) + ".app")
        }
    }

    func post(port: Int, route: String, token: String, body: [String: Any]) async -> (Int, [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(route)") else { return (502, [:]) }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(token, forHTTPHeaderField: "x-clockoffice-token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return (502, [:]) }
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, o)
    }

    /// Asks every live window; the first one that owns the session's terminal answers.
    func first(_ route: String, _ body: [String: Any]) async -> Hit {
        guard let token = token() else { return Hit(ok: false, folder: nil, status: 404) }
        var last = 404, refused: [String] = []
        for w in windows() {
            let (status, o) = await post(port: w.port, route: route, token: token, body: body)
            // 404: not this window's session. 502: window gone. 403: that window holds another token (it started
            // before the token settled); another window may still own the session, so keep asking.
            if status == 404 || status == 502 { continue }
            last = status
            if status == 403 { if !refused.contains(w.app) { refused.append(w.app) }; continue }
            return Hit(ok: status == 200, folder: o["folder"] as? String, status: status)
        }
        return Hit(ok: false, folder: nil, status: last, refusedBy: refused)
    }

    /// Whether a refused call means "this session's own editor window needs a reload". A window with an old secret
    /// refuses every call before it looks at which session is asked about, so its refusal says nothing about a
    /// session in another app (a plain terminal, another editor): only a session inside that same app can be its.
    public static func needsReload(_ hit: Hit, sessionApp: String?) -> Bool {
        guard !hit.ok, hit.status == 403, let sessionApp else { return false }
        return hit.refusedBy.contains(sessionApp)
    }

    /// Whether some editor window can type into this session's terminal. A 403 means an editor window answered but
    /// holds an old secret: it loaded the extension before an update and needs one reload.
    public func has(pid: Int32) async -> Hit { await first("/has", ["pid": Int(pid)]) }
    /// Types the reply and one Enter into the session's own terminal. Never the active terminal as a fallback.
    public func reply(pid: Int32, text: String) async -> Hit {
        guard Reply.valid(text) else { return Hit(ok: false, folder: nil, status: 400) }
        return await first("/reply", ["pid": Int(pid), "text": text])
    }
    /// Shows the session's terminal tab inside its window.
    public func reveal(pid: Int32) async -> Hit { await first("/reveal", ["pid": Int(pid)]) }
}

public enum Reply {
    static let control = Rx(#"[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]"#, [])
    static let command = Rx(#"^[\s\x{3000}]*[!/#@&?！／＃﹗﹟∕＠＆？]"#, [])
    static let trailingSlash = Rx(#"\\\s*$"#, [])

    /// A reply is printable text only, at most 2000 UTF-16 units (the unit the editor extension counts in).
    /// It may not start with a character Claude Code's prompt treats as a command when it comes first:
    /// "/" (slash command), "!" (shell), "#" (memory note), "@" (file picker), "&" or "?" (help);
    /// and it may not end in a backslash (which turns Enter into a new line).
    public static func valid(_ text: String) -> Bool {
        !text.isEmpty && text.utf16.count <= 2000 && !control.test(text) && !command.test(text) && !trailingSlash.test(text)
    }

    /// Pasted text often carries characters nobody sees (tabs, soft hyphens, zero-width marks from web pages and
    /// Word). They are tidied away instead of refusing the reply: tabs and line breaks become spaces, invisible
    /// format marks are dropped (a joined emoji becomes its separate parts).
    public static func clean(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            switch s.properties.generalCategory {
            case .format: continue
            case .control, .lineSeparator, .paragraphSeparator: out.append(" ")
            default: out.append(s)
            }
        }
        return String(out).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Why a reply cannot be sent, in words for the person typing it; nil when it can.
    public static func problem(_ text: String) -> String? {
        if text.isEmpty { return "there is nothing to send." }
        if text.utf16.count > 2000 { return "it is longer than 2000 characters." }
        if command.test(text) { return "a reply can't start with / ! # @ & or ? (Claude Code reads those as commands)." }
        if trailingSlash.test(text) { return "a reply can't end with a backslash." }
        if control.test(text) { return "it contains a character that can't be typed into a session." }
        return nil
    }

    /// Whether the session is still exactly what the user was looking at when they answered: same process, and the tool
    /// reports the same status, since the same moment, with the same last message and the same open dialog.
    /// Summaries play no part, so the model and the wording rules disagreeing can never block a reply.
    public static func stillCurrent(shown: Session, fresh: Session?) -> Bool {
        guard let fresh else { return false }
        return fresh.pid == shown.pid && fresh.revision == shown.revision
    }

    /// The text that is actually typed: the user's words plus the paths of any files they attached.
    /// Paths go in as plain quoted paths; the session reads them itself (images included).
    public static func compose(text: String, files: [String]) -> String {
        let t = clean(text)
        guard !files.isEmpty else { return t }
        let list = files.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        let lead = t.isEmpty ? "See" : t
        // A reply that begins with a path would start with "/", which the session reads as a command.
        return "\(lead) \(files.count == 1 ? "(file:" : "(files:") \(list))"
    }
}
