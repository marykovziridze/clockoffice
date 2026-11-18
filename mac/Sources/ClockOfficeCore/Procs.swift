import Foundation
import Darwin

/// Small read-only facts about processes: is it alive, who started it, which app hosts it.
public enum Procs {
    public static func alive(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    public static func parent(of pid: Int32) -> Int32? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let p = info.kp_eproc.e_ppid
        return p > 0 ? p : nil
    }

    /// When the process started. With the process number it names one process for good: the number alone is handed
    /// out again after a process ends.
    public static func started(_ pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard pid > 1, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_starttime
        guard t.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }

    public static func path(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// The pid and its ancestors, nearest first.
    public static func ancestry(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var cur: Int32? = pid
        while let c = cur, c > 1, !chain.contains(c), chain.count < 32 {
            chain.append(c)
            cur = parent(of: c)
        }
        return chain
    }

    /// The app a session runs inside: the outermost .app bundle among its ancestors
    /// (VS Code, Antigravity, Cursor, Terminal, iTerm, Claude…). Nil for a bare ssh or launchd-run session.
    public static func hostApp(of pid: Int32) -> URL? {
        for p in ancestry(of: pid).dropFirst() {
            guard let path = path(of: p), let r = path.range(of: ".app/") else { continue }
            return URL(fileURLWithPath: String(path[..<r.lowerBound]) + ".app")
        }
        return nil
    }
}

/// Finds the `claude` command. A menu-bar app starts with a bare PATH, so the usual install places are checked first.
public enum ClaudeBinary {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String??

    public static func locate() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let c = cached { return c }
        let home = NSHomeDirectory()
        let candidates = [
            ProcessInfo.processInfo.environment["CLOCKOFFICE_CLAUDE"],
            "\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ].compactMap { $0 }
        var found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if found == nil {
            // Last resort: ask the user's login shell once.
            let out = Shell.run("/bin/zsh", ["-lic", "command -v claude"], timeout: 8).stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: out) { found = out }
        }
        cached = .some(found)
        return found
    }
}

public enum Shell {
    public struct Result: Sendable { public var status: Int32; public var stdout: String; public var stderr: String }

    /// Runs a program and waits, with a hard timeout. Never a shell string: arguments are passed as given.
    public static func run(_ exe: String, _ args: [String], stdin: String? = nil, cwd: String? = nil,
                           env: [String: String]? = nil, timeout: TimeInterval = 20) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        if let env { p.environment = env }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        do { try p.run() } catch { return Result(status: -1, stdout: "", stderr: "\(error)") }
        if let stdin { inp.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data()) }
        try? inp.fileHandleForWriting.close()
        // Read on background queues so a full pipe can never block the child.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let deadline = DispatchTime.now() + timeout
        if group.wait(timeout: deadline) == .timedOut {
            p.terminate()
            // A program that ignores the polite stop is ended: the timeout is a promise to the caller (a stub lsof
            // that ignored it held its caller for 10 s: verifier 2 of T-43).
            if group.wait(timeout: .now() + 1) == .timedOut, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = group.wait(timeout: .now() + 1)
        }
        p.waitUntilExit()
        return Result(status: p.terminationStatus,
                      stdout: String(data: outData, encoding: .utf8) ?? "",
                      stderr: String(data: errData, encoding: .utf8) ?? "")
    }
}
