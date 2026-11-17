import Foundation
import Darwin

/// Ends a Claude Code session from outside, by asking its process to quit.
///
/// Measured on a throwaway session on 2026-11-16 (Claude Code 2.1.325 on one Mac): on the terminate signal an
/// idle session quits within seconds, puts its terminal back in order (cursor, screen, paste mode), removes its own
/// entry in `~/.claude/sessions/`, and its conversation file stays. The docs say every conversation is saved and
/// can be picked up again with `claude --continue` or `claude --resume`
/// (code.claude.com/docs/en/common-workflows, read 2026-11-16). Not measured: a session in the middle of a turn.
public enum Closing {
    /// Which sessions get the offer at all: a Claude Code session with a process of its own. Every Codex
    /// conversation carries the one Codex process: asking that to quit would end all of them.
    public static func offered(tool: String, pid: Int32) -> Bool { tool == "Claude Code" && pid > 1 }

    /// Claude Code writes the start of its process into its entry as "Mon Nov 16 14:56:54 2026", in universal
    /// time (real entries compared with the system's own record, 2026-11-16, and a throwaway session closed through
    /// this check three times). Read as universal time only: also reading it as local time let through an entry
    /// that was off by exactly the hours between the two. If Claude Code ever writes local time,
    /// closing is refused, which is the safe way to be wrong.
    static func startTimes(_ text: String) -> [Date] {
        let tidy = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return [TimeZone(identifier: "UTC")!].compactMap { zone in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
            return f.date(from: tidy)
        }
    }

    /// Whether this process is still that session. Three things must hold: Claude Code's own entry for the process
    /// names the same session; the process is alive; and it started when the entry says it did. Without the last
    /// one, an entry left behind by a session that died, whose process number was since handed to another
    /// program, passed: that other program would have been asked to quit.
    public static func stillThat(pid: Int32, sessionId: String, home: String = NSHomeDirectory(),
                                 started: (Int32) -> Date? = Procs.started) -> Bool {
        guard pid > 1, Procs.alive(pid),
              let data = FileManager.default.contents(atPath: "\(home)/.claude/sessions/\(pid).json"),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              (o["sessionId"] as? String) == sessionId,
              let said = o["procStart"] as? String, let real = started(pid) else { return false }
        return startTimes(said).contains { abs($0.timeIntervalSince(real)) < 2.5 }
    }

    /// Asks the session to quit. False, and nothing is done, when the process is no longer that session.
    @discardableResult
    public static func close(pid: Int32, sessionId: String, home: String = NSHomeDirectory(),
                             started: (Int32) -> Date? = Procs.started,
                             signal: (Int32, Int32) -> Int32 = { kill($0, $1) }) -> Bool {
        guard stillThat(pid: pid, sessionId: sessionId, home: home, started: started) else { return false }
        return signal(pid, SIGTERM) == 0
    }
}
