import Foundation

/// The optional link that lets ClockOffice show the words of a Claude Code dialog (a question with choices, or a
/// permission prompt). Claude Code keeps those words inside the session's window until the dialog is answered, so the
/// only way to see them from outside is a hook: a small command Claude Code runs itself, which posts the dialog to
/// this app on 127.0.0.1. It changes ~/.claude/settings.json, so it is off until the user switches it on in the menu.
/// Fail open: with the app closed the command fails in milliseconds and the session carries on untouched.
public enum ClaudeHooks {
    public static let marker = "x-clockoffice: hook"
    public static var command: String { command(.current) }
    static func command(_ e: Edition) -> String {
        "curl -s -m 2 -o /dev/null -H '\(marker)' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:\(e.port)/hook || true"
    }
    /// A hook entry is this build's when it posts to this build's port. Two builds on one Mac each keep their own:
    /// told apart by the marker alone, switching the hooks on in one app took the other app's out.
    static func ours(_ command: String, _ e: Edition) -> Bool {
        command.contains(marker) && command.contains("127.0.0.1:\(e.port)/hook")
    }
    public static var settingsURL: URL { URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json") }

    public static func isInstalled(at url: URL = settingsURL, edition: Edition = .current) -> Bool {
        guard let data = try? Data(contentsOf: url.resolvingSymlinksInPath()),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = o["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { list in
            (list as? [Any] ?? []).contains { entry in
                ((entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []).contains { ours($0["command"] as? String ?? "", edition) }
            }
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case unreadable, unexpectedShape, decimals
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "Claude Code's settings file could not be read as JSON, so nothing was changed."
            case .unexpectedShape: return "The hooks section of Claude Code's settings has a shape this app does not know, so nothing was changed."
            case .decimals: return "Claude Code's settings contain decimal numbers that this app cannot rewrite exactly, so nothing was changed."
            }
        }
    }

    /// Adds (or with `on: false` removes) the two hook entries. The file is backed up first and written in one step;
    /// every other setting is kept as it was (key order and spacing are normalised). Anything it does not fully
    /// understand makes it stop without writing.
    public static func set(_ on: Bool, at link: URL = settingsURL, backups: URL, edition: Edition = .current) throws {
        let url = link.resolvingSymlinksInPath() // a linked settings file stays a link; its target is edited
        var root: [String: Any] = [:]
        var mode: Any?
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.unreadable }
            guard !hasDecimals(o) else { throw Failure.decimals }
            root = o
            mode = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss-SSS"
            try data.write(to: backups.appendingPathComponent("settings-\(f.string(from: Date()))-\(UUID().uuidString.prefix(4)).json"))
        }
        if let h = root["hooks"], !(h is [String: Any]) { throw Failure.unexpectedShape }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // This build's command is taken out wherever it stands, and nothing else with it: a hook of the user's own
        // that sits in the same entry stays (the whole entry used to go), and so does every other event.
        for (event, value) in hooks {
            guard let list = value as? [Any] else { continue }
            let cleaned: [Any] = list.compactMap { entry in
                guard var e = entry as? [String: Any], let inner = e["hooks"] as? [[String: Any]],
                      inner.contains(where: { Self.ours($0["command"] as? String ?? "", edition) }) else { return entry }
                let rest = inner.filter { !Self.ours($0["command"] as? String ?? "", edition) }
                if rest.isEmpty { return nil }
                e["hooks"] = rest
                return e
            }
            hooks[event] = cleaned.isEmpty ? nil : cleaned
        }
        for (event, matcher) in [("PreToolUse", "AskUserQuestion" as String?), ("PermissionRequest", nil)] {
            if let existing = hooks[event], !(existing is [Any]) { throw Failure.unexpectedShape }
            var list = hooks[event] as? [Any] ?? []
            if on {
                var entry: [String: Any] = ["hooks": [["type": "command", "command": command(edition), "timeout": 3]]]
                if let matcher { entry["matcher"] = matcher }
                list.append(entry)
            }
            hooks[event] = list.isEmpty ? nil : list
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Proof before replacing: what will be written reads back as exactly the settings intended.
        guard let back = (try? JSONSerialization.jsonObject(with: out)) as? [String: Any],
              NSDictionary(dictionary: back).isEqual(to: root) else { throw Failure.unreadable }
        try out.write(to: url, options: .atomic)
        if let mode { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path) }
    }

    /// JSON numbers such as 0.1 do not survive a read-and-write unchanged, so a file that has any is left alone.
    static func hasDecimals(_ any: Any) -> Bool {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return false }
            return n.doubleValue != n.doubleValue.rounded()
        case let a as [Any]: return a.contains(where: hasDecimals)
        case let o as [String: Any]: return o.values.contains(where: hasDecimals)
        default: return false
        }
    }
}
