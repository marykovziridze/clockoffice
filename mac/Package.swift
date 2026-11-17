// swift-tools-version:5.9
import PackageDescription

// ClockOffice for macOS: a menu-bar app, a desktop widget and the logic both share.
// Built with the command-line Swift tools only (no Xcode project): scripts/build.sh assembles the .app.
let package = Package(
    name: "ClockOffice",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClockOfficeCore"),
        .target(name: "ClockOfficeUI", dependencies: ["ClockOfficeCore"]),
        .executableTarget(name: "ClockOffice", dependencies: ["ClockOfficeCore", "ClockOfficeUI"]),
        .executableTarget(
            name: "ClockOfficeWidget",
            dependencies: ["ClockOfficeCore", "ClockOfficeUI"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
        ),
        .testTarget(name: "ClockOfficeCoreTests", dependencies: ["ClockOfficeCore"]),
        .testTarget(name: "ClockOfficeAppTests", dependencies: ["ClockOffice", "ClockOfficeCore"]),
    ]
)
