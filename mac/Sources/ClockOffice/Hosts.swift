import AppKit
import ClockOfficeCore

/// The app a session runs inside, and how to bring its window forward. Not tied to one editor:
/// any app found among the session's parent processes is a host.
enum Hosts {
    static func name(for s: Session) -> String? {
        Procs.hostApp(of: s.pid).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// The folder open in the editor window that holds this session, from the lock files Claude Code's own editor
    /// integration writes (~/.claude/ide). Only the folder list and process id are read; the token in the file is never touched.
    static func ideFolder(cwd: String, app: URL) -> String? {
        let dir = NSHomeDirectory() + "/.claude/ide"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        var best: String?
        for n in names where n.hasSuffix(".lock") {
            guard let data = FileManager.default.contents(atPath: dir + "/" + n),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, Procs.alive(pid),
                  let path = Procs.path(of: pid), path.hasPrefix(app.path + "/"),
                  let folders = o["workspaceFolders"] as? [String] else { continue }
            for f in folders where cwd == f || cwd.hasPrefix(f + "/") {
                if f.count > (best?.count ?? 0) { best = f }
            }
        }
        return best
    }

    /// `ownFolder`: the session's own folder is opened in its editor (a tool that keeps no record of which editor
    /// window has which folder: the editor brings the window of that folder forward, or opens it).
    static func bringForward(session s: Session, editorFolder: String?, ownFolder: Bool = false) {
        guard let app = Procs.hostApp(of: s.pid) else {
            // No app around it (ssh, a background job): its page on claude.ai is the only window it has.
            if let url = s.remoteURL { NSWorkspace.shared.open(url) } else { NSSound.beep() }
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let name = app.deletingPathExtension().lastPathComponent
        let own = ownFolder && editors().contains(where: { $0.name == name }) && FileManager.default.fileExists(atPath: s.cwd) ? s.cwd : nil
        if let folder = editorFolder ?? ideFolder(cwd: s.cwd, app: app) ?? own {
            // An editor brings the window that already has this folder open to the front.
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: app, configuration: cfg)
        } else {
            NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        }
    }

    /// Editors on this Mac that can take the ClockOffice extension (VS Code and its forks), with their command-line tool.
    static func editors() -> [(name: String, cli: String)] {
        let known: [(String, String)] = [
            ("Visual Studio Code", "code"), ("Visual Studio Code - Insiders", "code"), ("Antigravity", "antigravity"),
            ("Cursor", "cursor"), ("Windsurf", "windsurf"), ("VSCodium", "codium"),
        ]
        var out: [(String, String)] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            for (app, tool) in known {
                let bin = "\(root)/\(app).app/Contents/Resources/app/bin"
                let cli = [tool, "code"].map { "\(bin)/\($0)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
                if let cli, !out.contains(where: { $0.0 == app }) { out.append((app, cli)) }
            }
        }
        return out
    }
}
