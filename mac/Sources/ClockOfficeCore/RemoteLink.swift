import Foundation

/// A session's page on claude.ai, as a link the Claude desktop app opens itself.
///
/// The docs describe one desktop link, `claude://code/new` (code.claude.com/docs/en/desktop, read 2026-11-16).
/// The form used here is NOT in the docs: it was read from the desktop app's own code (version 5.11492.5:
/// a path `/code/<id>` whose id matches `(cse|session)_…` is taken as a session to open) and tried once on
/// 2026-11-16: the app went to that session's page. An app update may change it without notice; the browser link
/// stays as the way back when the app is not installed or refuses the link.
public enum RemoteLink {
    public static let desktopApp = "com.anthropic.claudefordesktop"
    private static let sessionId = Rx(#"^(cse|session)_[A-Za-z0-9_-]+$"#, [])

    /// `https://claude.ai/code/session_…` → `claude://code/session_…`. Nil for anything else.
    public static func desktop(for page: URL) -> URL? {
        guard page.host == "claude.ai", page.pathComponents.count == 3, page.pathComponents[1] == "code" else { return nil }
        let id = page.pathComponents[2]
        guard sessionId.re.firstMatch(in: id, range: NSRange(location: 0, length: (id as NSString).length)) != nil else { return nil }
        return URL(string: "claude://code/" + id)
    }
}
