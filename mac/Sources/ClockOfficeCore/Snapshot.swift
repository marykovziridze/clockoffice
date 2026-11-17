import Foundation
import CryptoKit
import Network

/// What the desktop widget shows: only the questions, plus two counts. Smaller surface, stricter selection.
public struct Snapshot: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var project: String
        public var headline: String
        public var since: Date
        /// The one-click answers this question offers, when the app can type them into the session. Empty otherwise.
        public var options: [String]
        /// A short fingerprint of the question as it stood when this snapshot was made. An answer clicked in the
        /// widget carries it, so an answer to a question that has since changed is never typed.
        public var mark: String
        public init(id: String, project: String, headline: String, since: Date, options: [String] = [], mark: String = "") {
            self.id = id; self.project = project; self.headline = headline; self.since = since
            self.options = options; self.mark = mark
        }
    }
    /// A session that does not need the user: one quiet line, shown only where there is room.
    public struct Quiet: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var project: String
        public var line: String
        public var working: Bool
        /// When it finished (or started working), so a report from four days ago does not look like one from now.
        public var since: Date?
        /// It was working when the Claude plan's limit was used up: stopped until the limit resets.
        public var stopped: Bool
        public init(id: String, project: String, line: String, working: Bool, since: Date? = nil, stopped: Bool = false) {
            self.id = id; self.project = project; self.line = line; self.working = working; self.since = since
            self.stopped = stopped
        }
        /// Data written before `stopped` existed still reads (an older app beside a newer widget during an update
        /// showed an empty card).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            project = try c.decode(String.self, forKey: .project)
            line = try c.decode(String.self, forKey: .line)
            working = try c.decode(Bool.self, forKey: .working)
            since = try c.decodeIfPresent(Date.self, forKey: .since)
            stopped = try c.decodeIfPresent(Bool.self, forKey: .stopped) ?? false
        }
    }
    public var asOf: Date
    public var asking: [Item]
    public var quiet: [Quiet]
    public var working: Int
    public var done: Int
    /// False when the widget could not reach the app.
    public var live: Bool
    /// A secret of this run of the app. An answer link must carry it, so only a widget that read this snapshot
    /// (never a web page or a link in a document) can answer a question.
    public var runSecret: String
    /// True while the plan's limit is used up: sessions that were working are stopped by it, and the widget must
    /// not go on calling them "working".
    public var limited: Bool

    public init(asOf: Date, asking: [Item], quiet: [Quiet] = [], working: Int, done: Int, live: Bool = true,
                runSecret: String = "", limited: Bool = false) {
        self.asOf = asOf; self.asking = asking; self.quiet = quiet
        self.working = working; self.done = done; self.live = live; self.runSecret = runSecret; self.limited = limited
    }

    /// The fingerprint an answer link carries: 12 hex characters of the session's stamp.
    public static func mark(_ stamp: String) -> String {
        SHA256.hash(data: Data(stamp.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The standard build and a build with a private look listen on different ports, so both can run on one Mac.
    public static var port: UInt16 { Edition.current.port }
    public static var url: URL { URL(string: "http://127.0.0.1:\(port)/snapshot")! }

    /// `answerable`: the sessions the app can type into right now; only their questions carry one-click answers.
    public static func from(_ sessions: [Session], now: Date = Date(), answerable: Set<String> = [], runSecret: String = "",
                            limited: Bool = false) -> Snapshot {
        let asking = sessions.filter { $0.state == .asking }.sorted { $0.since < $1.since }
        return Snapshot(
            asOf: now,
            asking: asking.map {
                Item(id: $0.id, project: $0.project, headline: $0.headline ?? $0.question ?? $0.title, since: $0.since,
                     options: answerable.contains($0.id) ? $0.options.map(\.label) : [], mark: mark($0.stamp))
            },
            quiet: (sessions.filter { $0.state == .working }.sorted { $0.since > $1.since }
                    + sessions.filter { $0.state == .done }.sorted { $0.since > $1.since }).prefix(6)
                .map { Quiet(id: $0.id, project: $0.project, line: $0.state == .working ? $0.title : ($0.inShort ?? $0.title),
                             working: $0.state == .working, since: $0.since,
                             // Only a Claude Code session is stopped by the Claude plan's limit.
                             stopped: limited && $0.state == .working && $0.tool == "Claude Code") },
            working: sessions.filter { $0.state == .working }.count,
            done: sessions.filter { $0.state == .done }.count,
            runSecret: runSecret, limited: limited)
    }

    public static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .millisecondsSince1970; return e }()
    public static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .millisecondsSince1970; return d }()
}

/// What a click in the widget asks the app to do. A widget cannot show the dropdown or type by itself: it can only
/// open the app with a link, so every click is one of these three.
public enum WidgetLink: Equatable, Sendable {
    /// Anywhere on the widget: the dropdown's list.
    case open
    /// A session's row: its conversation in the dropdown.
    case session(String)
    /// One of a question's answers: type it into the session, show nothing.
    case answer(session: String, option: Int, mark: String, secret: String)

    public var url: URL {
        var c = URLComponents()
        c.scheme = Edition.current.scheme
        switch self {
        case .open: c.host = "open"
        case .session(let id):
            c.host = "session"; c.queryItems = [URLQueryItem(name: "id", value: id)]
        case .answer(let id, let n, let mark, let secret):
            c.host = "answer"
            c.queryItems = [URLQueryItem(name: "id", value: id), URLQueryItem(name: "n", value: String(n)),
                            URLQueryItem(name: "mark", value: mark), URLQueryItem(name: "s", value: secret)]
        }
        return c.url ?? URL(string: Edition.current.scheme + "://open")!
    }

    public init?(_ url: URL) {
        guard url.scheme == Edition.current.scheme, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        switch c.host {
        case "session":
            guard let id = value("id"), !id.isEmpty else { return nil }
            self = .session(id)
        case "answer":
            guard let id = value("id"), !id.isEmpty, let n = value("n").flatMap({ Int($0) }), n >= 0,
                  let mark = value("mark"), !mark.isEmpty, let secret = value("s"), !secret.isEmpty else { return nil }
            self = .answer(session: id, option: n, mark: mark, secret: secret)
        case "open": self = .open
        default: return nil
        }
    }
}

/// Dialog questions handed to the app by Claude Code's hooks, kept in memory only.
/// Optional: without the hook the app still knows a session is waiting, just not the dialog's words.
public final class HookInbox: @unchecked Sendable {
    public struct Dialog: Sendable {
        public var toolName: String
        public var input: [String: AnySendable]
        public var at: Date
    }
    private let lock = NSLock()
    private var dialogs: [String: Dialog] = [:]
    /// Called (on a background queue) when something new arrived, so the app can refresh at once.
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Takes the JSON a Claude Code hook receives on stdin (PreToolUse for AskUserQuestion, PermissionRequest).
    @discardableResult
    public func receive(_ body: Data) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let sid = o["session_id"] as? String, let tool = o["tool_name"] as? String else { return false }
        let input = (o["tool_input"] as? [String: Any])?.mapValues(AnySendable.init) ?? [:]
        lock.lock()
        dialogs[sid] = Dialog(toolName: tool, input: input, at: Date())
        if dialogs.count > 200 { dialogs = dialogs.filter { Date().timeIntervalSince($0.value.at) < 86400 } }
        lock.unlock()
        onChange?()
        return true
    }

    /// Forgets a session's dialog once the session has moved on after it.
    public func clear(_ sessionId: String, ifBefore: Date) {
        lock.lock(); defer { lock.unlock() }
        if let d = dialogs[sessionId], d.at < ifBefore { dialogs[sessionId] = nil }
    }

    public func dialog(for sessionId: String, notBefore: Date) -> Dialog? {
        lock.lock(); defer { lock.unlock() }
        guard let d = dialogs[sessionId], d.at >= notBefore else { return nil }
        return d
    }
}

/// The app's one local door (127.0.0.1 only): the widget reads the snapshot from it, and the optional Claude Code
/// hook posts dialog questions to it. The widget runs in Apple's sandbox and cannot read Claude's files itself.
public final class SnapshotServer: @unchecked Sendable {
    private var listener: NWListener?
    private let lock = NSLock()
    private var body = Data("{}".utf8)
    public let inbox: HookInbox
    /// What Claude Code tells the status line (limits, models), when the status line relay is on.
    public let usage = UsageInbox()
    /// Permission prompts waiting for Allow or Deny (their connections stay open meanwhile).
    public let permissions = PermissionDesk()
    /// Connections a permission request holds open: the 5-second limit does not end them.
    private var parked = Set<ObjectIdentifier>()

    public init(inbox: HookInbox = HookInbox()) { self.inbox = inbox }

    public func update(_ snapshot: Snapshot) {
        guard let data = try? Snapshot.encoder.encode(snapshot) else { return }
        lock.lock(); body = data; lock.unlock()
    }

    public func start(port: UInt16 = Snapshot.port) throws {
        let params = NWParameters.tcp
        // Bound to 127.0.0.1 itself, not to every address with a filter on top.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        // No port reuse (T-39): measured on macOS 26, a restart on the same port works without it while the old
        // door's connections are still in TIME_WAIT (test theAppsDoorOpensAgainAtOnceOnTheSamePortAfterAQuit), and
        // with it a second copy started silently on a port another process held while that process kept answering.
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            self.accept(conn)
        }
        l.start(queue: .global(qos: .utility))
        listener = l
    }

    private func accept(_ conn: NWConnection) {
            conn.start(queue: .global(qos: .utility))
            // A request that is not complete within 5 seconds is dropped (a parked permission request is complete).
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { conn.cancel(); return }
                self.lock.lock(); let keep = self.parked.contains(ObjectIdentifier(conn)); self.lock.unlock()
                if !keep { conn.cancel() }
            }
            read(conn, Data())
    }

    public func stop() { permissions.releaseAll(); listener?.cancel(); listener = nil }

    /// Starts on a port the system picks and nothing else holds, and returns it once the server listens. For tests:
    /// fixed ports clashed with other tests and other sessions' app copies (T-37).
    public func startOnFreePort() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let port: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            let finish: @Sendable (Result<UInt16, Error>) -> Void = { r in
                guard once.first() else { return }
                if case .failure = r { l.cancel() }
                cont.resume(with: r)
            }
            // Never waits forever: a listener that is not ready within 5 seconds is given up.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { finish(.failure(NWError.posix(.ETIMEDOUT))) }
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(l.port.map { .success($0.rawValue) } ?? .failure(NWError.posix(.EADDRNOTAVAIL)))
                case .failed(let e): finish(.failure(e))
                case .cancelled: finish(.failure(NWError.posix(.ECANCELED)))
                default: break
                }
            }
            l.start(queue: .global(qos: .utility))
        }
        listener = l
        return port
    }

    /// Reads until the headers and the announced body are in (hook payloads can be tens of kilobytes; capped at 1 MB).
    private func read(_ conn: NWConnection, _ soFar: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = soFar
            if let data { buf.append(data) }
            let sep = Data("\r\n\r\n".utf8)
            if let r = buf.range(of: sep) {
                let head = String(data: buf[..<r.lowerBound], encoding: .utf8) ?? ""
                let length = head.range(of: #"(?im)^content-length:\s*(\d+)"#, options: .regularExpression)
                    .flatMap { Int(head[$0].split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let payload = buf[r.upperBound...]
                if payload.count >= min(length, 1_048_576) || done || error != nil {
                    self.respond(conn, head: head, payload: Data(payload.prefix(length)))
                    return
                }
            }
            if done || error != nil || buf.count > 1_100_000 { conn.cancel(); return }
            self.read(conn, buf)
        }
    }

    private func respond(_ conn: NWConnection, head: String, payload: Data) {
        let first = head.split(separator: "\r\n").first ?? ""
        // Only our own name for this Mac: a page on another host name (DNS rebinding) is refused.
        let hostOK = head.range(of: #"(?im)^host:\s*(127\.0\.0\.1|localhost)(:\d+)?\s*$"#, options: .regularExpression) != nil
        var status = "404 Not Found"
        var out = Data("{}".utf8)
        if hostOK && first.hasPrefix("GET /snapshot ") {
            lock.lock(); out = body; lock.unlock()
            status = "200 OK"
        } else if hostOK && first.hasPrefix("POST /hook ") {
            // A browser page cannot send this without a preflight it will not pass; the header keeps it that way.
            let fromHook = head.range(of: #"(?im)^x-clockoffice:\s*hook\s*$"#, options: .regularExpression) != nil
            status = fromHook && inbox.receive(payload) ? "200 OK" : "400 Bad Request"
        } else if hostOK && first.hasPrefix("POST /permission ") {
            // The same guard as /hook. The reply is held back until the user decides (PermissionDesk); the dialog's
            // words also go to the inbox, as the plain hook's do.
            let fromHook = head.range(of: #"(?im)^x-clockoffice:\s*hook\s*$"#, options: .regularExpression) != nil
            if fromHook && inbox.receive(payload) {
                lock.lock(); parked.insert(ObjectIdentifier(conn)); lock.unlock()
                conn.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled, .failed:
                        self?.lock.lock(); self?.parked.remove(ObjectIdentifier(conn)); self?.lock.unlock()
                    default: break
                    }
                }
                if permissions.park(payload, on: conn) { return }
            }
            status = "400 Bad Request"
        } else if hostOK && first.hasPrefix("POST /status ") {
            // The same guard as the hook: a header a web page cannot send without a preflight it will not pass.
            let fromRelay = head.range(of: #"(?im)^x-clockoffice:\s*status\s*$"#, options: .regularExpression) != nil
            status = fromRelay && usage.receive(payload) ? "200 OK" : "400 Bad Request"
        }
        var reply = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(out.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        reply.append(out)
        conn.send(content: reply, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// A local diary of questions: when one appeared and how long it waited. This is the number the app exists to shrink
/// (late replies and never-answered questions), kept on this Mac only.
public final class EventLog: @unchecked Sendable {
    let file: URL
    private let queue = DispatchQueue(label: "clockoffice.eventlog")
    public init(directory: URL) { file = directory.appendingPathComponent("events.jsonl") }

    public func write(_ event: String, session: Session, extra: [String: Any] = [:]) {
        var o: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()), "event": event, "session": session.id,
            "project": session.project, "certain": session.certain,
        ]
        for (k, v) in extra { o[k] = v }
        guard let data = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) else { return }
        queue.async { [file] in
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            guard let fh = try? FileHandle(forWritingTo: file) else { return }
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data + Data("\n".utf8))
        }
    }
}

/// True the first time only, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}
