import Foundation

/// What `ClockOffice --remove-settings` (run by `./install.sh --remove`) must take out of ~/.claude/settings.json
/// before the app and its folder are deleted (T-22). Wider than the menu switches' "is it on": a relay whose script is
/// already gone, hooks written by an older build, or a single hook left over all count, because each of them stays in
/// the user's settings after a removal. A settings file that exists but cannot be read is its own answer: the caller
/// must then delete nothing, or a relay still in that file would point at a script that is gone.
public enum SettingsRemoval {
    public enum Found: Equatable {
        case nothing
        case unreadable
        case entries(statusLine: Bool, hooks: Bool)
    }

    public static func look(at link: URL = ClaudeHooks.settingsURL, edition: Edition = .current) -> Found {
        let url = link.resolvingSymlinksInPath()
        // Only a file that is truly not there is "nothing". One that cannot be reached (a ~/.claude folder this
        // user may not open, a link into such a folder) may well hold a relay, so it counts as unreadable
        // (verifier 4: fileExists said false there, and the removal went on).
        var st = stat()
        if stat(link.path, &st) != 0 {
            if errno != ENOENT { return .unreadable }
            if lstat(link.path, &st) == 0 { return .nothing } // a link to nowhere: no settings behind it
            let folder = link.deletingLastPathComponent().path
            return access(folder, X_OK) == 0 || errno == ENOENT ? .nothing : .unreadable
        }
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unreadable }
        var line = false
        if let command = (root["statusLine"] as? [String: Any])?["command"] as? String {
            line = StatusLineRelay.layers(command, edition).scripts.contains {
                StatusLineRelay.dead($0) || StatusLineRelay.ours($0, edition)
            }
        }
        var hooks = false
        for value in (root["hooks"] as? [String: Any] ?? [:]).values {
            for entry in value as? [Any] ?? [] {
                let inner = (entry as? [String: Any])?["hooks"] as? [[String: Any]] ?? []
                if inner.contains(where: { ClaudeHooks.ours($0["command"] as? String ?? "", edition) }) { hooks = true }
            }
        }
        return line || hooks ? .entries(statusLine: line, hooks: hooks) : .nothing
    }
}
