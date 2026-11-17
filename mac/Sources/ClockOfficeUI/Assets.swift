import SwiftUI
import AppKit
import ClockOfficeCore

/// Loads the artwork: from the app (or widget) bundle when installed, from the repository when run from source.
/// The dial is drawn in code (DialView); the menu-bar glyph is a file. A private look (see `Edition`) may bring a
/// picture of its own for the mark and its own glyph: its files are looked for first.
public enum Assets {
    public static func url(_ name: String) -> URL? {
        var places = Edition.lookFolders
        if !Edition.insideBundle {
            // Run from source: Sources/ClockOfficeUI/Assets.swift → ../../Resources
            places.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for p in places {
            let u = p.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    static func cgImage(_ name: String) -> CGImage? {
        guard let u = url(name), let src = CGImageSourceCreateWithURL(u as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// A private look's picture for the mark; nil with the built-in dial. A picture counts only together with the
    /// look's settings: a stray picture must not change how a standard build looks.
    public static let mark: CGImage? = Edition.current.suffix == nil ? nil : cgImage("mark.png")

    /// 108 frames of that picture turning, cut from one sheet (12 across, 128 px each): an exact loop.
    public static let spin: [CGImage] = {
        guard let sheet = cgImage("spin.png") else { return [] }
        let n = 128, cols = 12
        return (0..<108).compactMap { i in
            sheet.cropping(to: CGRect(x: (i % cols) * n, y: (i / cols) * n, width: n, height: n))
        }
    }()

    /// The menu-bar glyph: one colour, which macOS tints for light and dark menu bars.
    public static func menuGlyph(points: CGFloat = 20) -> NSImage? {
        guard let u = url("menu-glyph.svg"), let img = NSImage(contentsOf: u) else { return nil }
        img.size = NSSize(width: points, height: points)
        img.isTemplate = true
        return img
    }
}
