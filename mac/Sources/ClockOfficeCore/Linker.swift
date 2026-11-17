import Foundation
import CryptoKit

/// Finds, in what was said, the things a click can open: web addresses, and files that are really there.
/// A path is linked only when the file exists, so "and/or" or "yes/no" never turn into links.
public enum Linker {
    public struct Found: Equatable, Sendable {
        /// Where in the text, counted in characters.
        public var start: Int
        public var length: Int
        public var url: URL
    }

    /// In any mix of capitals: "HTTPS://good.example" in a link's words is an address too. (Matched in lower
    /// case only, such words were not compared with the target and kept a link to another site.)
    private static let web = Rx(#"https?://[^\s<>"'`]+"#, [.caseInsensitive])
    /// A path without spaces: it has at least one "/" and may end in ":120" (a line number).
    private static let path = Rx(#"(?<![\w/.:~@-])((?:~/|\.{1,2}/|/)?(?:[\w.@+-]+/)*[\w.@+-]+)(?::(\d+))?(?::\d+)?"#, [])
    private static let lineEnd = Rx(#":(\d+)(?::\d+)?$"#, [])
    public static let pictureTypes: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
    /// What is looked at, not run, and opens with its own app: pages, pictures, documents, films.
    public static let viewedTypes: Set<String> = pictureTypes.union(
        ["html", "htm", "pdf", "svg", "mp4", "mov", "webm", "csv", "docx", "xlsx", "pptx", "key", "pages", "numbers"])

    /// What a click on a link does. Words in a conversation must never be able to RUN something with one click:
    /// the Mac "opens" an app, a `.command` file or any file marked as a program by running it
    /// (`/System/Applications/Calculator.app`, `./run.command` and a bare program all became links that
    /// would have started). So only three things are ever opened; everything else is shown in the Finder.
    public enum Click: Equatable, Sendable {
        /// A web page, in the browser.
        case web(URL)
        /// A page, picture or document, with its own app.
        case view(String)
        /// Any other plain file: in the editor the session runs in (at a line, when given). Never started.
        case edit(String, line: Int?)
        /// A folder, an app, a program, a script that would run: shown in the Finder, selected, not opened.
        case reveal(String)
        /// Not followed at all (an address that is neither a web page nor a file).
        case nothing
    }

    public static func click(_ url: URL,
                             isDirectory: (String) -> Bool? = { p in
                                 var d: ObjCBool = false
                                 return FileManager.default.fileExists(atPath: p, isDirectory: &d) ? d.boolValue : nil
                             },
                             runs: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                             odd: (String) -> Bool = Linker.isOdd) -> Click {
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            // An address with a name and password before the host ("https://good.example@evil.example/") or with
            // letters from another alphabet in the host shows one place and goes to another: not followed.
            // (The system has already turned foreign letters into the "xn--" form by the time the address is
            // read here: "аррӏе.com" in Cyrillic arrives as "xn--80ak6aa92e.com".)
            guard let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
                  host.unicodeScalars.allSatisfy({ $0.isASCII }),
                  !host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) else { return .nothing }
            return .web(url)
        }
        // A file link travels under a name of its own (see `inner`).
        let url = outer(url) ?? url
        guard url.isFileURL else { return .nothing }
        // What the name finally points at decides, not the name: a "picture" can be a link to an app.
        let path = URL(fileURLWithPath: url.path).resolvingSymlinksInPath().path
        guard let dir = isDirectory(path) else { return .nothing }
        // A Finder alias is an ordinary file that stands for another: "photo.jpg" can be an alias of a script, and
        // opening it starts the script. It is shown, like anything else that is not a
        // plain file (a device, a pipe).
        if dir || runs(path) || odd(path) { return .reveal(path) }
        let ext = (path as NSString).pathExtension.lowercased()
        if viewedTypes.contains(ext) { return .view(path) }
        let line = url.fragment.flatMap { $0.hasPrefix("L") ? Int($0.dropFirst()) : nil }
        return .edit(path, line: line)
    }

    /// A Finder alias, or something that is not a plain file at all.
    public static func isOdd(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let v = try? url.resourceValues(forKeys: [.isAliasFileKey, .isRegularFileKey])
        return v?.isAliasFile == true || v?.isRegularFile != true
    }

    /// Only web pages and files are shown as links; `javascript:`, `ssh:`, a settings address and the like are not.
    public static func followable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == fileScheme || url.isFileURL
    }

    /// The name a file link travels under inside a text. Only this app understands it, so nothing but the app's own
    /// rule (`click`) can ever act on it: the system's own menu on a link ("Open Link") would hand a plain
    /// `file://` address to whatever opens it, and for an app that means starting it
    /// (unsure whether that menu goes through the app; this makes the answer not matter).
    public static let fileScheme = "x-conversation-file"

    public static func inner(_ url: URL) -> URL {
        guard url.isFileURL, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        c.scheme = fileScheme
        return c.url ?? url
    }

    public static func outer(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == fileScheme, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = "file"
        return c.url
    }

    /// Whether the words of a link agree with where it goes. Every web address written in the words must be on
    /// the target's own host: "see https://good.example" over a link to evil.example is not a link
    /// (comparing only words that were nothing but an address was not enough).
    public static func honest(words shown: String, target: URL) -> Bool {
        // Marks that turn the reading direction can make an address read as another one: no link under such words.
        guard !shown.unicodeScalars.contains(where: { $0.properties.isBidiControl }) else { return false }
        // The address is read as the eye reads it, without the characters that take no room
        // ("h<zero-width space>ttps://good.example" shows as an address and was not read as one).
        var seen = String.UnicodeScalarView()
        seen.append(contentsOf: shown.unicodeScalars.filter { !takesNoRoom($0) })
        let words = String(seen)
        let ns = words as NSString
        // An address in the words that cannot be read ("https://good.example:abc") counts as another site: it
        // was passed over, and the link under it kept.
        let named = web.re.matches(in: words, range: NSRange(location: 0, length: ns.length))
            .map { URL(string: ns.substring(with: $0.range))?.host?.lowercased() ?? "\u{0}unreadable" }
        guard !named.isEmpty else { return true }
        guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = target.host?.lowercased() else { return false }
        return named.allSatisfy { $0 == host }
    }

    /// Characters that take no room of their own on screen: zero-width spaces and joiners, variation selectors,
    /// marks that sit on the letter before them.
    public static func takesNoRoom(_ s: Unicode.Scalar) -> Bool {
        let p = s.properties
        // 2006…200A and 202F are the thin and hair spaces: a gap too narrow to see between two underlined words.
        return p.isDefaultIgnorableCodePoint || p.isVariationSelector || p.generalCategory == .format
            || p.generalCategory == .nonspacingMark || p.generalCategory == .enclosingMark
            || (0x2006...0x200A).contains(s.value) || s.value == 0x202F
    }

    /// A path as written → the file it names, if there is one. `~`, an absolute path, or one inside the session's
    /// folder; a line number at the end is carried in the link as "#L120".
    public static func file(_ written: String, cwd: String, home: String = NSHomeDirectory(),
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> URL? {
        var p = written.trimmingCharacters(in: .whitespacesAndNewlines)
        var line: String?
        let ns = p as NSString
        if let m = lineEnd.re.firstMatch(in: p, range: NSRange(location: 0, length: ns.length)) {
            line = ns.substring(with: m.range(at: 1))
            p = ns.substring(to: m.range.location)
        }
        guard p.contains("/"), p.count < 1024, !p.contains("\n") else { return nil }
        if p.hasPrefix("~/") { p = home + p.dropFirst(1) }
        else if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
        p = (p as NSString).standardizingPath
        guard p.count > 1, exists(p) else { return nil }
        var c = URLComponents()
        c.scheme = "file"; c.host = ""; c.path = p
        if let line { c.fragment = "L" + line }
        return c.url
    }

    /// Web addresses and existing files in a text. Paths with spaces are not found here: a path written in
    /// code type is tried whole by the caller (`file`).
    public static func find(in text: String, cwd: String, home: String = NSHomeDirectory(),
                            exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Found] {
        let ns = text as NSString
        var out: [Found] = []
        // A very long text is left without links: looking through 100,000 characters of paths took 0.46 s,
        // while the screen was being drawn.
        guard ns.length <= 20_000 else { return [] }
        func chars(_ r: NSRange) -> (Int, Int) {
            let s = text.utf16.index(text.utf16.startIndex, offsetBy: r.location)
            let e = text.utf16.index(s, offsetBy: r.length)
            return (text.distance(from: text.startIndex, to: s), text.distance(from: s, to: e))
        }
        for m in web.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            // The full stop or bracket that ends the sentence is not part of the address.
            while r.length > 0, let last = ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)).first,
                  ".,;:!?)]}'\"".contains(last) { r.length -= 1 }
            guard r.length > 10, let url = URL(string: ns.substring(with: r)) else { continue }
            let (s, l) = chars(r)
            out.append(Found(start: s, length: l, url: url))
        }
        for m in path.re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var r = m.range
            while r.length > 0, ns.substring(with: NSRange(location: r.location + r.length - 1, length: 1)) == "." { r.length -= 1 }
            // Only something with a "/" in it is a path; a plain word is not looked up.
            guard r.length > 2, ns.substring(with: r).contains("/") else { continue }
            let (s, l) = chars(r)
            guard !out.contains(where: { $0.start < s + l && s < $0.start + $0.length }),
                  let url = file(ns.substring(with: r), cwd: cwd, home: home, exists: exists) else { continue }
            out.append(Found(start: s, length: l, url: url))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// The pictures a message names: paths of picture files, in the order written, each once.
    public static func pictures(in text: String, cwd: String, home: String = NSHomeDirectory(),
                                exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [String] {
        var seen: Set<String> = [], out: [String] = []
        for f in find(in: text, cwd: cwd, home: home, exists: exists) where f.url.isFileURL {
            let p = f.url.path
            if pictureTypes.contains((p as NSString).pathExtension.lowercased()), seen.insert(p).inserted { out.append(p) }
        }
        return out
    }
}

/// Pictures the user pasted into a message. Claude Code keeps them inside the conversation's record; to show one it is
/// written once to this app's cache folder, named by what is in it, and old ones are cleared out.
public enum PastedPictures {
    nonisolated(unsafe) public static var folder: String = NSHomeDirectory() + "/Library/Caches/\(Edition.current.folder)/pictures"

    /// The picture of one "image" part of a message → a file. Nil when the part holds no picture data.
    public static func file(for block: [String: Any]) -> String? {
        guard let src = block["source"] as? [String: Any], (src["type"] as? String) == "base64",
              let b64 = src["data"] as? String, b64.count > 64 else { return nil }
        let kind = ((src["media_type"] as? String) ?? "image/png").split(separator: "/").last.map(String.init) ?? "png"
        let ext = Linker.pictureTypes.contains(kind) ? kind : "png"
        let name = SHA256.hash(data: Data(b64.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let path = "\(folder)/\(name).\(ext)"
        if FileManager.default.fileExists(atPath: path) {
            // Still in use: the two weeks before it is cleared out count from the last time it was shown.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
            return path
        }
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return FileManager.default.createFile(atPath: path, contents: data) ? path : nil
    }

    /// Clears pictures not looked at for two weeks.
    public static func tidy(now: Date = Date()) {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
            let p = folder + "/" + name
            if let at = (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
               now.timeIntervalSince(at) > 14 * 86400 { try? FileManager.default.removeItem(atPath: p) }
        }
    }
}
