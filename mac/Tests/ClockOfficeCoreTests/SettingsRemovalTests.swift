import Foundation
import Testing
@testable import ClockOfficeCore

/// T-22: `--remove-settings` must find every ClockOffice entry a removal would otherwise leave behind.

private func folder() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("removal-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func settings(_ dir: URL, _ o: [String: Any]) -> URL {
    let u = dir.appendingPathComponent("settings.json")
    try! JSONSerialization.data(withJSONObject: o).write(to: u)
    return u
}

/// The hook command as the public build 1ebaa7c wrote it: both events post to /hook.
/// The standard build (port 47863); this checkout may carry a private look with its own port.
private let std = Edition()

private let oldHook = "curl -s -m 2 -o /dev/null -H 'x-clockoffice: hook' -H 'content-type: application/json' --data-binary @- http://127.0.0.1:47863/hook || true"

@Test func noFileOrNoEntriesIsNothing() {
    let dir = folder()
    #expect(SettingsRemoval.look(at: dir.appendingPathComponent("settings.json"), edition: std) == .nothing)
    #expect(SettingsRemoval.look(at: settings(dir, ["statusLine": ["type": "command", "command": "my-line.sh"]]), edition: std) == .nothing)
}

@Test func anUnreadableFileIsSaidSo() {
    let dir = folder()
    let u = dir.appendingPathComponent("settings.json")
    try! Data("// a comment\n{}".utf8).write(to: u)
    #expect(SettingsRemoval.look(at: u, edition: std) == .unreadable)
}

@Test func aRelayWhoseScriptIsGoneIsFound() {
    let dir = folder()
    let script = dir.appendingPathComponent("clockoffice-statusline.sh").path // never written
    let u = settings(dir, ["statusLine": ["type": "command", "command": StatusLineRelay.wrap("my-line.sh", scriptPath: script)]])
    #expect(SettingsRemoval.look(at: u, edition: std) == .entries(statusLine: true, hooks: false))
}

@Test func anOlderBuildsHooksAndASingleLeftoverHookAreFound() {
    let dir = folder()
    let old = settings(dir, ["hooks": [
        "PreToolUse": [["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": oldHook, "timeout": 3]]]],
        "PermissionRequest": [["hooks": [["type": "command", "command": oldHook, "timeout": 3]]]],
    ]])
    #expect(SettingsRemoval.look(at: old, edition: std) == .entries(statusLine: false, hooks: true))
    try! ClaudeHooks.set(false, at: old, backups: dir.appendingPathComponent("backups"), edition: std)
    #expect(SettingsRemoval.look(at: old, edition: std) == .nothing)

    let one = settings(folder(), ["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": ClaudeHooks.command(std)]]]]]])
    #expect(SettingsRemoval.look(at: one, edition: std) == .entries(statusLine: false, hooks: true))
}

@Test func anotherBuildsHooksAreNotOurs() {
    let other = oldHook.replacingOccurrences(of: "47863", with: "47999")
    let u = settings(folder(), ["hooks": ["PreToolUse": [["hooks": [["type": "command", "command": other]]]]]])
    #expect(SettingsRemoval.look(at: u, edition: std) == .nothing)
}

@Test func aSettingsFolderThatCannotBeOpenedIsUnreadable() {
    let dir = folder()
    let claude = dir.appendingPathComponent(".claude")
    try! FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let u = settings(claude, ["statusLine": ["type": "command", "command": "x"]])
    chmod(claude.path, 0)
    defer { chmod(claude.path, 0o755) }
    #expect(SettingsRemoval.look(at: u, edition: std) == .unreadable)
    let link = dir.appendingPathComponent("settings.json")
    try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: u)
    #expect(SettingsRemoval.look(at: link, edition: std) == .unreadable)
}

@Test func aMissingFileOrFolderIsNothing() {
    let dir = folder()
    #expect(SettingsRemoval.look(at: dir.appendingPathComponent("no/.claude/settings.json"), edition: std) == .nothing)
}
