import Foundation
import Testing
@testable import ClockOfficeCore

/// T-13: the widget's quiet usage line, the dropdown foot's words.

private let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/Amsterdam")!; return c }()
private func at(_ h: Int, _ m: Int, day: Int = 18) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m))! }

@Test func theWidgetLineSaysWhatTheDropdownFootSays() {
    let u = UsageLimits(sessionPercent: 62.4, sessionResets: at(17, 1), weekPercent: 24, weekResets: at(10, 0, day: 22), at: at(14, 0))
    let p = UsageWords.short(u, now: at(14, 5), calendar: cal)
    #expect(p.session?.text == "62% used · resets 17:01")
    #expect(p.week?.text == "week 24%")
    let snap = Snapshot(asOf: at(14, 5), asking: [], working: 1, done: 0, usage: u)
    #expect(snap.usageLine?.hasPrefix("62% used · resets ") == true && snap.usageLine?.hasSuffix(" · week 24%") == true)
}

@Test func aWindowThatHasResetIsLeftOut() {
    let u = UsageLimits(sessionPercent: 90, sessionResets: at(13, 0), weekPercent: 30, weekResets: at(10, 0, day: 22), at: at(12, 0))
    let p = UsageWords.short(u, now: at(14, 0), calendar: cal)
    #expect(p.session == nil)
    #expect(p.week?.text == "week 30%")
    #expect(UsageWords.short(nil).session == nil && UsageWords.short(nil).week == nil)
    #expect(Snapshot(asOf: Date(), asking: [], working: 0, done: 0).usageLine == nil)
}

@Test func theUsageTravelsToTheWidgetAndOldDataStillReads() throws {
    let u = UsageLimits(sessionPercent: 62, sessionResets: at(17, 1), weekPercent: 24, weekResets: at(10, 0, day: 22), at: at(14, 0))
    let snap = Snapshot(asOf: at(14, 5), asking: [], working: 0, done: 0, usage: u)
    let back = try Snapshot.decoder.decode(Snapshot.self, from: Snapshot.encoder.encode(snap))
    #expect(back.usage == u)
    // A snapshot from an app older than this field: no usage key at all.
    var json = try JSONSerialization.jsonObject(with: Snapshot.encoder.encode(snap)) as! [String: Any]
    json.removeValue(forKey: "usage")
    let old = try Snapshot.decoder.decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.usage == nil)
}

@Test func aShortenedLineKeepsAFullWeek() {
    // T-50 (T-13 verifier F1): session 40%, week 100% beside "+11 more sessions" showed only "40% used".
    #expect(UsageWords.keepWeek(session: 40, week: 100))
    #expect(UsageWords.keepWeek(session: 40, week: 85))
    // An ordinary week stays out of the short line; the session leads when it is as full or fuller.
    #expect(!UsageWords.keepWeek(session: 40, week: 24))
    #expect(!UsageWords.keepWeek(session: 95, week: 90))
    #expect(!UsageWords.keepWeek(session: 100, week: 100))
    #expect(!UsageWords.keepWeek(session: 40, week: nil))
    #expect(UsageWords.keepWeek(session: nil, week: 30))
}
