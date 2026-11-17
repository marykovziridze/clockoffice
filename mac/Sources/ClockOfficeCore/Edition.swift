import Foundation

/// Which ClockOffice this build is. There is one source; a build may carry a private look (a folder of artwork with
/// a small settings file, `look.json`). The look brings its own picture and accent colour, and its own identity
/// (a name part, a port), so that build can run beside the standard one on the same Mac without the two answering
/// each other's widget or links. Without the file this is the standard ClockOffice.
public struct Edition: Sendable, Equatable {
    /// The name part of a private look, as its settings file gives it; nil for the standard build.
    public var suffix: String?
    /// The local port the app serves its widget and the usage relay on.
    public var port: UInt16
    /// The accent colour for dark and light appearance, as hex, when the look sets one.
    public var accentDark: UInt32?
    public var accentLight: UInt32?

    /// File names this build's status line relay had in earlier versions (a private look that was once called
    /// something else). The standard build has none.
    public var oldRelays: [String] = []

    public init(suffix: String? = nil, port: UInt16 = 47863, accentDark: UInt32? = nil, accentLight: UInt32? = nil,
                oldRelays: [String] = []) {
        self.suffix = suffix; self.port = port; self.accentDark = accentDark; self.accentLight = accentLight
        self.oldRelays = oldRelays
    }

    /// The scheme of the links the widget opens the app with.
    public var scheme: String { "clockoffice" + (suffix.map { "-" + $0 } ?? "") }
    /// The folder name for this build's settings, diary and cache.
    public var folder: String { "ClockOffice" + (suffix.map { " " + $0.prefix(1).uppercased() + $0.dropFirst() } ?? "") }

    public static let current: Edition = load()

    /// The folders a look's files may be in: the app's (or widget's) own resources when installed, a folder named
    /// in CLOCKOFFICE_RESOURCES, and the repository's Resources/look when run from source.
    public static var lookFolders: [URL] {
        var places: [URL] = []
        if let r = Bundle.main.resourceURL { places.append(r) }
        if let env = ProcessInfo.processInfo.environment["CLOCKOFFICE_RESOURCES"] {
            places.append(URL(fileURLWithPath: env)); places.append(URL(fileURLWithPath: env).appendingPathComponent("look"))
        }
        // Run from source (tests, `swift run`) there is no app around the program: the repository's own
        // Resources/look counts then. An installed app or widget reads only what was built into it, or it could be
        // turned into another build by a file appearing in the folder it was once built from.
        if !Edition.insideBundle {
            // Sources/ClockOfficeCore/Edition.swift → ../../Resources/look
            places.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/look"))
        }
        return places
    }

    /// True for the installed app and its widget.
    public static var insideBundle: Bool {
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") || path.hasSuffix(".appex")
    }

    static func load() -> Edition {
        for place in lookFolders {
            guard let data = FileManager.default.contents(atPath: place.appendingPathComponent("look.json").path) else { continue }
            return read(data) ?? Edition()
        }
        return Edition()
    }

    /// A look's settings. A file that cannot be read, or names nothing, leaves the standard build.
    public static func read(_ data: Data) -> Edition? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func hex(_ key: String) -> UInt32? { (o[key] as? String).flatMap { UInt32($0, radix: 16) } }
        var e = Edition()
        // The same rules as scripts/build.sh, which refuses to build from a file that breaks them: a name part of
        // plain lower-case letters and digits (it becomes part of an ID and of a link scheme), and a port of its own.
        // Half a look would give two builds that answer for each other, so it is all or nothing.
        guard let s = o["suffix"] as? String, validSuffix(s),
              let n = o["port"] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue == Double(n.intValue), n.intValue > 1024, n.intValue < 65536, n.intValue != 47863 else { return nil }
        e.suffix = s
        e.port = UInt16(n.intValue)
        e.accentDark = hex("accentDark"); e.accentLight = hex("accentLight")
        e.oldRelays = (o["oldRelays"] as? [String] ?? []).filter(validRelayName)
        return e
    }

    /// A relay script's file name: lower-case letters, digits and hyphens, ending in "-statusline.sh".
    public static func validRelayName(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9-]{0,40}-statusline\.sh$"#, options: .regularExpression) != nil
    }

    public static func validSuffix(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 24 && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}
