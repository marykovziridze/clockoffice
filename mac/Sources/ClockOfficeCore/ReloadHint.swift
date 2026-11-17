import Foundation

/// An editor window that loaded the reply extension before an update. It answers with an old secret, so replies
/// to the sessions in it are refused until that window is reloaded once.
public struct StaleWindow: Identifiable, Equatable, Sendable {
    /// The folder open in that window.
    public let folder: String
    /// The app the window belongs to ("Visual Studio Code").
    public let host: String?
    /// The sessions running in it.
    public let sessionIds: [String]

    public init(folder: String, host: String?, sessionIds: [String]) {
        self.folder = folder; self.host = host; self.sessionIds = sessionIds
    }

    public var id: String { folder + "|" + (host ?? "") }
    /// What the window is called in its own title bar: the folder's name.
    public var name: String { (folder as NSString).lastPathComponent }
}

/// The words for "reload this window once". One place, so the dropdown, the window and the session view say the same.
public enum ReloadHint {
    /// One entry per window: several sessions in the same window need one reload, not several.
    public static func windows(_ sessions: [(id: String, folder: String, host: String?)]) -> [StaleWindow] {
        var order: [String] = [], grouped: [String: StaleWindow] = [:]
        for s in sessions {
            let key = s.folder + "|" + (s.host ?? "")
            if let w = grouped[key] {
                grouped[key] = StaleWindow(folder: w.folder, host: w.host, sessionIds: w.sessionIds + [s.id])
            } else {
                order.append(key)
                grouped[key] = StaleWindow(folder: s.folder, host: s.host, sessionIds: [s.id])
            }
        }
        return order.compactMap { grouped[$0] }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// What to do, in one sentence. The app is named because a folder can share its name with something else
    /// (a project folder can be called "ClockOffice").
    public static func headline(_ windows: [StaleWindow]) -> String {
        guard windows.count == 1, let w = windows.first else {
            return "To reply from here, reload these \(windows.count) editor windows once:"
        }
        let place = w.host.map { " in \($0)" } ?? ""
        return "To reply from here, reload the “\(w.name)” window\(place) once."
    }

    /// How, in one line.
    public static func steps(_ windows: [StaleWindow]) -> String {
        windows.count == 1
            ? "Press ⇧⌘P in that window and choose “Reload Window”. Terminals keep running."
            : "In each one, press ⇧⌘P and choose “Reload Window”. Terminals keep running."
    }
}
