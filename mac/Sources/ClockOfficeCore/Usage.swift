import Foundation

/// How much of the plan's limits is used, as Claude Code itself reports it: the 5-hour session window and the
/// 7-day window, each with the moment it starts again. One picture for the whole account, not per session.
public struct UsageLimits: Equatable, Sendable, Codable {
    public var sessionPercent: Double?
    public var sessionResets: Date?
    public var weekPercent: Double?
    public var weekResets: Date?
    /// When Claude Code last reported these numbers.
    public var at: Date

    public init(sessionPercent: Double? = nil, sessionResets: Date? = nil, weekPercent: Double? = nil,
                weekResets: Date? = nil, at: Date = Date()) {
        self.sessionPercent = sessionPercent; self.sessionResets = sessionResets
        self.weekPercent = weekPercent; self.weekResets = weekResets; self.at = at
    }

    /// True while the session or the weekly limit is used up and has not reset yet. "Used up" is what the screens
    /// round to 100%: from 99.5. With no reset time in the report, the limit is taken to last no longer than its
    /// own window from the report (five hours, seven days): it stayed on for good otherwise, since no new report
    /// comes while nothing runs.
    public func usedUp(now: Date = Date()) -> Bool {
        func full(_ percent: Double?, _ resets: Date?, window: TimeInterval) -> Bool {
            (percent ?? 0) >= 99.5 && (resets ?? at.addingTimeInterval(window)) > now
        }
        return full(sessionPercent, sessionResets, window: 5 * 3600) || full(weekPercent, weekResets, window: 7 * 86400)
    }

    /// The same numbers, whenever they were reported.
    public func sameNumbers(as other: UsageLimits?) -> Bool {
        guard let other else { return false }
        return sessionPercent == other.sessionPercent && sessionResets == other.sessionResets
            && weekPercent == other.weekPercent && weekResets == other.weekResets
    }
}

/// What Claude Code hands to a status line command, kept in memory only: the limits (the newest report from any
/// session stands) and the model each session runs on. Claude Code gives these to the status line and to nothing
/// else, so the app receives them through a small relay in front of the user's own status line (see `StatusLineRelay`).
public final class UsageInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var limits: UsageLimits?
    private var models: [String: String] = [:]
    /// Called (on a background queue) when something changed.
    public var onChange: (@Sendable () -> Void)?

    public init() {}

    /// Takes the JSON a status line command receives on stdin. Unknown or missing fields are simply not used.
    @discardableResult
    public func receive(_ body: Data, now: Date = Date()) -> Bool {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        var changed = false
        lock.lock()
        if let sid = o["session_id"] as? String, let model = (o["model"] as? [String: Any])?["display_name"] as? String,
           !model.isEmpty, models[sid] != model {
            models[sid] = model; changed = true
            if models.count > 300 { models = [sid: model] }
        }
        if let r = o["rate_limits"] as? [String: Any] {
            func window(_ name: String) -> (Double?, Date?) {
                let w = r[name] as? [String: Any]
                let pct = (w?["used_percentage"] as? NSNumber)?.doubleValue
                let at = (w?["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return (pct, at)
            }
            let (sp, sr) = window("five_hour"), (wp, wr) = window("seven_day")
            if sp != nil || wp != nil {
                let next = UsageLimits(sessionPercent: sp, sessionResets: sr, weekPercent: wp, weekResets: wr, at: now)
                // Sessions report at different moments. A report is taken when it is the first, when its numbers
                // moved, or to keep the time current; an older picture never replaces a newer one.
                if !next.sameNumbers(as: limits) { changed = true }
                limits = next
            }
        }
        lock.unlock()
        if changed { onChange?() }
        return true
    }

    public func current() -> UsageLimits? { lock.lock(); defer { lock.unlock() }; return limits }
    public func model(for sessionId: String) -> String? { lock.lock(); defer { lock.unlock() }; return models[sessionId] }
    public func allModels() -> [String: String] { lock.lock(); defer { lock.unlock() }; return models }
}

/// The words for the limits, the same on every surface.
public enum UsageWords {
    /// "Session 85% used · resets 19:50". Nil when that window was not reported, or when its reset time has
    /// passed (the number then belongs to a window that is over).
    public static func line(_ name: String, percent: Double?, resets: Date?, now: Date = Date(),
                            calendar: Calendar = .current) -> String? {
        guard let percent else { return nil }
        if let resets, resets <= now { return nil }
        var text = "\(name) \(Int(percent.rounded()))% used"
        if let resets { text += " · resets " + when(resets, now: now, calendar: calendar) }
        return text
    }

    /// "19:50" today, "Sun 19:00" on another day.
    public static func when(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = Locale(identifier: "en_GB")
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: date)
    }

    /// A limit this full is worth full ink instead of quiet grey.
    public static func isHigh(_ percent: Double?) -> Bool { (percent ?? 0) >= 80 }

    /// The dropdown's one quiet line, in parts: "62% used · resets 17:01" and "week 24%". A part is nil when that
    /// window was not reported or its reset time has passed; both nil when there is nothing to say.
    public static func short(_ u: UsageLimits?, now: Date = Date(), calendar: Calendar = .current)
        -> (session: (percent: Double, text: String)?, week: (percent: Double, text: String)?) {
        guard let u else { return (nil, nil) }
        func live(_ p: Double?, _ r: Date?) -> Double? { guard let p, r.map({ $0 > now }) ?? true else { return nil }; return p }
        let session = live(u.sessionPercent, u.sessionResets).map { p in
            (p, "\(Int(p.rounded()))% used" + (u.sessionResets.map { " · resets " + when($0, now: now, calendar: calendar) } ?? ""))
        }
        let week = live(u.weekPercent, u.weekResets).map { p in (p, "week \(Int(p.rounded()))%") }
        return (session, week)
    }
}

/// The relay that lets the app see what Claude Code tells the status line. It stands in front of the user's own status
/// line command: it passes the data to the app (on 127.0.0.1, in the background, at most one second) and then runs
/// their command exactly as before, so their status line looks and behaves the same. It changes
/// ~/.claude/settings.json, so it is off until the user switches it on in the menu; the file is backed up first.
/// Fail open: with the app closed the hand-over fails silently and the user's status line still runs.
public enum StatusLineRelay {
    /// The relay script's name. Each build has its own (the standard one, and one per private look), so two builds
    /// on one Mac can both stand in front of the status line, one behind the other, and each takes away only its own.
    /// (With one shared name, switching it on in one app took the other app's relay out, and that app's menu still
    /// said it was on.)
    public static var marker: String { marker(.current) }
    static func marker(_ e: Edition) -> String { "clockoffice" + (e.suffix.map { "-" + $0 } ?? "") + "-statusline" }

    /// The script's text. `$1` is the user's own status line command, run through the shell as Claude Code would run it.
    public static var script: String { script(port: Snapshot.port) }

    static func script(port: UInt16) -> String {
        """
        #!/bin/sh
        # ClockOffice: hands the status line data to the app, then runs your own status line unchanged.
        # Installed and removed by ClockOffice's menu ("Show usage and model"). Safe to delete when that is off.
        input=$(cat)
        printf '%s' "$input" | curl -s -m 1 -o /dev/null -H 'x-clockoffice: status' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:\(port)/status >/dev/null 2>&1 &
        if [ -n "$1" ]; then printf '%s' "$input" | sh -c "$1"; fi

        """
    }

    static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The command to put in settings: the relay, then the user's own command as one quoted word.
    public static func wrap(_ original: String?, scriptPath: String) -> String {
        quoted(scriptPath) + " " + quoted(original ?? "")
    }

    /// The names this app gives its relay script: the standard build's and a private look's, plus the names a
    /// look says its relay had in earlier versions. Nothing else is ever taken for a relay: a user's own status line
    /// script may well be called "my-statusline.sh".
    static func isRelayName(_ name: String, _ e: Edition = .current) -> Bool {
        name.range(of: #"^clockoffice(-[a-z0-9]{1,24})?-statusline\.sh$"#, options: .regularExpression) != nil
            || e.oldRelays.contains(name)
    }

    /// Whether a script is a relay of this app, of any build. A script that can be read is one when it does what
    /// a relay does: it hands the data to an address on this Mac under the app's header. Its file name does not
    /// matter then, so a build sees its own relay behind another build's, whatever that one is called (verifier
    /// 20: behind a relay with a name it did not know, the standard build no longer found its own). A script that
    /// is gone or cannot be read is judged by its name alone: the names this app gives, and a look's earlier ones.
    static func isRelay(script: String, _ e: Edition = .current) -> Bool {
        if let text = try? String(contentsOfFile: script, encoding: .utf8) {
            return text.contains("-H 'x-clockoffice: status'") && text.contains("http://127.0.0.1:")
        }
        return isRelayName((script as NSString).lastPathComponent, e)
    }

    /// A command that is nothing but words in single quotes with one space between them, as `wrap` writes it →
    /// those words. Nil for anything else.
    static func quotedWords(_ command: String) -> [String]? {
        var words: [String] = []
        var rest = Substring(command)
        while true {
            guard rest.first == "'" else { return nil }
            rest = rest.dropFirst()
            var word = ""
            while true {
                guard let end = rest.firstIndex(of: "'") else { return nil }
                word += rest[..<end]
                rest = rest[rest.index(after: end)...]
                // \'' after a closing quote: one quote mark inside the word. Anything else ends the word.
                if rest.hasPrefix("\\''") { word += "'"; rest = rest.dropFirst(3) } else { break }
            }
            words.append(word)
            if rest.isEmpty { return words }
            guard rest.first == " " else { return nil }
            rest = rest.dropFirst()
        }
    }

    /// One relay taken off the front of a command: its script, and what it runs after itself. Nil unless the
    /// command is exactly what `wrap` writes for a script with one of this app's own names. (Verifier 18,
    /// 2026-11-17: a user's command of the shape 'x-statusline.sh' 'one' 'two' was taken apart and written back
    /// changed.)
    static func peel(_ command: String, _ e: Edition = .current) -> (script: String, inner: String?)? {
        // The app always writes the script's full path; a bare name is somebody's own command.
        guard let words = quotedWords(command), words.count == 2, words[0].hasPrefix("/"),
              isRelay(script: words[0], e) else { return nil }
        let inner = words[1].isEmpty ? nil : words[1]
        guard wrap(inner, scriptPath: words[0]) == command else { return nil }
        return (words[0], inner)
    }

    /// Every relay in front of the user's own command, outermost first, and that command.
    static func layers(_ command: String, _ e: Edition = .current) -> (scripts: [String], original: String?) {
        var scripts: [String] = []
        var rest: String? = command
        while let c = rest, scripts.count < 8, let p = peel(c, e) { scripts.append(p.script); rest = p.inner }
        return (scripts, rest)
    }

    static func rebuild(_ scripts: [String], _ original: String?) -> String? {
        var command = original
        for s in scripts.reversed() { command = wrap(command, scriptPath: s) }
        return command
    }

    /// Whether a relay script is this build's: it hands the data to this build's port. The name does not decide:
    /// an earlier version of a private build named its script like the standard one.
    static func ours(_ script: String, _ e: Edition) -> Bool {
        ((try? String(contentsOfFile: script, encoding: .utf8)) ?? "").contains("127.0.0.1:\(e.port)/status")
    }

    /// A relay whose script file is gone. The shell cannot start it, so the status line shows an error and the
    /// user's own command behind it never runs: whichever build writes the settings next takes it out.
    static func dead(_ script: String) -> Bool { !FileManager.default.fileExists(atPath: script) }

    /// Where a relay keeps the note that says the refresh setting was added by it.
    static func refreshNote(for script: String) -> URL {
        URL(fileURLWithPath: (script as NSString).deletingPathExtension + "-added-refresh")
    }

    /// The user's own command, read back out of a wrapped one. Nil when the command is not a relay's.
    public static func unwrap(_ command: String) -> String?? {
        guard let p = peel(command) else { return nil }
        return .some(p.inner)
    }

    public static func isInstalled(at url: URL = ClaudeHooks.settingsURL, edition: Edition = .current) -> Bool {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let command = (o["statusLine"] as? [String: Any])?["command"] as? String else { return false }
        return layers(command, edition).scripts.contains { ours($0, edition) }
    }

    public enum Failure: LocalizedError, Equatable {
        case unreadable, unexpectedShape, decimals
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "Claude Code's settings file could not be read as JSON, so nothing was changed."
            case .unexpectedShape: return "The status line section of Claude Code's settings has a shape this app does not know, so nothing was changed."
            case .decimals: return "Claude Code's settings contain decimal numbers that this app cannot rewrite exactly, so nothing was changed."
            }
        }
    }

    /// Puts the relay in front of the user's status line command (or with `on: false` takes it away again). Only the
    /// status line's `command` changes; every other setting is kept. The file is backed up first and written in one
    /// step. Anything it does not fully understand makes it stop without writing.
    public static func set(_ on: Bool, at link: URL = ClaudeHooks.settingsURL, scriptDirectory: URL, backups: URL,
                           edition: Edition = .current) throws {
        let marker = marker(edition)
        let url = link.resolvingSymlinksInPath()
        var root: [String: Any] = [:]
        var mode: Any?
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadable }
            guard !ClaudeHooks.hasDecimals(o) else { throw Failure.decimals }
            root = o
            mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
            try data.write(to: backups.appendingPathComponent("settings-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4)).json"))
        }
        if let s = root["statusLine"], !(s is [String: Any]) { throw Failure.unexpectedShape }
        var line = root["statusLine"] as? [String: Any]
        if let c = line?["command"], !(c is String) { throw Failure.unexpectedShape }
        let current = line?["command"] as? String
        var addedRefresh = false
        var handOver: URL?
        // The relays that stand in front of the user's own command now (another build's may be among them, and
        // stays), and that command.
        let (scripts, original) = current.map { layers($0, edition) } ?? ([], nil)
        let alive = scripts.filter { !dead($0) }
        let mine = alive.filter { ours($0, edition) }
        let wasOurs = !mine.isEmpty
        let others = alive.filter { !mine.contains($0) }
        let hadDead = alive.count < scripts.count
        // The relays that were put in front of ours: they came later, and found the refresh setting already there.
        let later = alive.firstIndex(where: { mine.contains($0) }).map { alive[..<$0].filter { !mine.contains($0) } } ?? []
        let ownNote = scriptDirectory.appendingPathComponent("\(marker)-added-refresh")
        // Notes beside a script of ours that an earlier version left in another folder.
        let oldNotes = mine.map(refreshNote).filter { $0.path != ownNote.path && FileManager.default.fileExists(atPath: $0.path) }

        if on {
            let scriptURL = scriptDirectory.appendingPathComponent("\(marker).sh")
            try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
            try script(port: edition.port).write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            var next = line ?? ["type": "command"]
            // Ours keeps its place among the others (a relay switched on again does not jump the queue); new, it
            // goes in front.
            var chain = others
            chain.insert(scriptURL.path, at: later.count)
            next["command"] = rebuild(chain, original)
            // Without a refresh interval the numbers would only move when a session speaks. A note beside the
            // script remembers that the setting is ours, so switching off takes it back.
            if next["refreshInterval"] == nil {
                next["refreshInterval"] = 30
                addedRefresh = true
            } else if !wasOurs {
                // The user has an interval of their own: a note left over from an earlier time must not claim it.
                try? FileManager.default.removeItem(at: ownNote)
            } else if !oldNotes.isEmpty, (next["refreshInterval"] as? NSNumber)?.intValue == 30 {
                // The setting was added by our relay under its old name: the note moves with the relay.
                addedRefresh = true
            }
            oldNotes.forEach { try? FileManager.default.removeItem(at: $0) }
            line = next
        } else if wasOurs || hadDead {
            if let rest = rebuild(others, original) { line?["command"] = rest } else { line = nil }
            // The refresh setting is ours if a note says so: beside the script in this build's folder, or beside
            // a script of ours that an earlier version left somewhere else.
            let notes = [ownNote] + mine.map(refreshNote)
            if notes.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                if (line?["refreshInterval"] as? NSNumber)?.intValue == 30 {
                    // A relay that came after ours counts on the setting: the note is handed to it, and that build
                    // takes the setting away when it is switched off in its turn. A relay that was there before
                    // ours lived without it, and gets its settings back as they were.
                    // (The one that came right after ours, the innermost of them: with three builds, handing it
                    // to the outermost lost the setting while a third relay was still on. Verifier 19.)
                    if let next = later.last { handOver = refreshNote(for: next) } else { line?["refreshInterval"] = nil }
                }
                notes.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }
        root["statusLine"] = line
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let back = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
              NSDictionary(dictionary: back).isEqual(to: root) else { throw Failure.unreadable }
        try out.write(to: url, options: .atomic)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
        // Only now, with the settings written, is the refresh setting on record as ours.
        if let handOver { try? "30".write(to: handOver, atomically: true, encoding: .utf8) }
        if addedRefresh {
            try? "30".write(to: scriptDirectory.appendingPathComponent("\(marker)-added-refresh"), atomically: true, encoding: .utf8)
        }
    }
}
