import SwiftUI
import ClockOfficeCore

/// The desktop widget's face: the questions first, then the quiet sessions if there is room. The smallest surface
/// shows the least. Everything starts on one left edge; a row is the session's project over one line about it,
/// the same shape as a quiet row in the dropdown, so nothing is cut after three words.
/// (First seen on a desktop: tiny dials in a wide gutter, lines cut short, a footer that only
/// repeated the rows above it.)
///
/// What a click does (a click first opened the big window, but the widget is meant to work like the
/// dropdown): a session's row opens its conversation in the dropdown; a question's answers are
/// clickable words that answer it on the spot; anywhere else opens the dropdown's list. A widget can hold no text
/// field and cannot change the pointer (macOS), so typing happens in the dropdown.
public struct WidgetCard: View {
    public enum Size: Sendable { case medium, large }
    let snapshot: Snapshot
    let now: Date
    let size: Size
    @Environment(\.theme) private var theme

    public init(snapshot: Snapshot, now: Date, size: Size) {
        self.snapshot = snapshot; self.now = now; self.size = size
    }

    /// How many questions and how many quiet rows fit, counted in points: a question is 63 high with the gap
    /// under it (87 when its answers show), a quiet row 46. The large size has 276 to fill, the medium 109.
    private var plan: (questions: Int, quiet: Int) {
        func fit(_ room: CGFloat) -> (questions: Int, quiet: Int) {
            var used: CGFloat = 0, shown = 0
            for item in snapshot.asking.prefix(size == .large ? 3 : 1) {
                let height: CGFloat = Self.answers(item).isEmpty ? 63 : 87
                if shown > 0 && used + height > room { break }
                used += height; shown += 1
            }
            return (shown, min(snapshot.quiet.count, max(0, Int((room - used) / 46))))
        }
        // The large size gives the usage line at the foot a line of its own (18 with the gap above it). The medium
        // size has room for one question and one row: there the usage line never costs a row (see `footer`).
        let room: CGFloat = size == .large ? 276 - (usageText != nil ? 18 : 0) : 109
        let all = fit(room)
        let hidden = (snapshot.asking.count - all.questions) + (max(snapshot.quiet.count, snapshot.working + snapshot.done) - all.quiet)
        // The closing line ("+3 more sessions") needs room of its own: without it the line was squeezed between
        // the last row and the widget's edge.
        return hidden > 0 ? fit(room - 24) : all
    }

    /// The answers to show under a question: all of them, or none. A question's answers are shown only when every
    /// one fits on the line, because half a choice is worse than a click through to the dropdown.
    static func answers(_ item: Snapshot.Item) -> [String] {
        guard !item.options.isEmpty, item.options.count <= 4 else { return [] }
        // About 6.9 points a character, 20 of padding per pill, 6 between pills, 268 of room beside the dial.
        let width = item.options.reduce(0.0) { $0 + Double($1.count) * 6.9 + 20 } + 6 * Double(item.options.count - 1)
        return width <= 268 ? item.options : []
    }

    public var body: some View {
        let plan = plan
        let hiddenQuestions = snapshot.asking.count - plan.questions
        // Counted from the totals, not from the six rows the app sends: twelve sessions must not read as six.
        let hiddenQuiet = max(snapshot.quiet.count, snapshot.working + snapshot.done) - plan.quiet
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.body).fontWeight(.semibold).foregroundStyle(theme.ink)
                Spacer(minLength: 8)
                // The time the app last spoke, not the clock: a widget can be many minutes behind
                // (macOS decides when it may refresh), and then it says how far.
                if snapshot.live {
                    Text(asOf).font(Theme.small).foregroundStyle(theme.sub)
                }
            }
            .padding(.bottom, size == .large ? 14 : 10)

            if !snapshot.live {
                Text("Open ClockOffice to see your sessions.").font(Theme.small).foregroundStyle(theme.sub)
            } else if snapshot.asking.isEmpty && snapshot.quiet.isEmpty {
                Text("No sessions are running.").font(Theme.small).foregroundStyle(theme.sub)
            } else {
                VStack(alignment: .leading, spacing: size == .large ? 12 : 9) {
                    ForEach(snapshot.asking.prefix(plan.questions)) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Link(destination: WidgetLink.session(item.id).url) {
                                HStack(alignment: .center, spacing: 11) {
                                    DialView(.asking, size: 34, frozenAt: 1.6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        // One text, so both parts sit on the same left edge as the headline.
                                        Text("\(Text(Words.clip(item.project, 22) + " · ").foregroundStyle(theme.sub))\(Text(Words.age(since: item.since, now: now)).foregroundStyle(theme.accent).fontWeight(.semibold).monospacedDigit())")
                                            .font(Theme.small).lineLimit(1)
                                        Text(item.headline).font(Theme.small).fontWeight(.medium).foregroundStyle(theme.ink)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(Rectangle())
                            }
                            // The one-click answers, the same words as in the dropdown. Each types that answer.
                            let answers = Self.answers(item)
                            if !answers.isEmpty && !snapshot.runSecret.isEmpty {
                                // Measured, not guessed: if the words do not fit after all, none are drawn.
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 6) {
                                        ForEach(Array(answers.enumerated()), id: \.offset) { n, label in
                                            Link(destination: WidgetLink.answer(session: item.id, option: n, mark: item.mark,
                                                                                secret: snapshot.runSecret).url) {
                                                // The same pill as in the dropdown, a size down.
                                                Text(label).font(Theme.small).fontWeight(.semibold).foregroundStyle(theme.ink)
                                                    .lineLimit(1).fixedSize()
                                                    .padding(.horizontal, 10).frame(height: 24)
                                                    .background(theme.ink.opacity(0.10), in: Capsule())
                                                    .contentShape(Capsule())
                                            }
                                        }
                                    }
                                    Color.clear.frame(height: 0)
                                }
                                .padding(.leading, 45)
                            }
                        }
                    }
                    ForEach(snapshot.quiet.prefix(plan.quiet)) { q in
                        Link(destination: WidgetLink.session(q.id).url) {
                            HStack(alignment: .center, spacing: 11) {
                                // A widget cannot keep a dial turning (macOS animates a widget only when its data
                                // changes, for two seconds at most). So "working" is said by the sparkles the dial
                                // throws while it turns, held still and large enough to see; they change place
                                // each minute, when the widget's time moves on. A finished dial is grey.
                                // With the plan's limit used up a session that was working is stopped: a still
                                // dial under the red shine, no sparkles, as in the dropdown.
                                let stopped = q.stopped
                                DialView(stopped ? .blocked : (q.working ? .still : .faded), size: 26, frozenAt: 0)
                                    .overlay { if q.working && !stopped { WorkingSparkles(minute: Int(now.timeIntervalSince1970 / 60), size: 26) } }
                                    .frame(width: 34)
                                VStack(alignment: .leading, spacing: 1) {
                                    let old = !q.working && (q.since.map { now.timeIntervalSince($0) > 86400 } ?? false)
                                    // A long folder name is cut, never the state after it.
                                    if stopped {
                                        Text("\(Text(Words.clip(q.project, 22) + " · ").foregroundStyle(theme.sub))\(Text("out of limit").foregroundStyle(theme.limitText))")
                                    } else {
                                        Text(Words.clip(q.project, 22) + (q.working ? " · working" : " · done" + (q.since.map { " " + Words.age(since: $0, now: now) } ?? "")))
                                            .foregroundStyle(theme.sub)
                                    }
                                    // A report older than a day steps back, as in the dropdown.
                                    Text(q.line).foregroundStyle(old ? theme.sub : theme.ink)
                                }
                                .font(Theme.small).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            footer(hiddenQuestions: hiddenQuestions, hiddenQuiet: hiddenQuiet)
        }
    }

    /// The closing line, only for what is not shown above (it never repeats the rows), and the plan's usage in the
    /// dropdown foot's own quiet words ("62% used · resets 17:01 · week 24%"). The large size has a line for each.
    /// The medium size never gives up a row for the usage: it sits beside "+3 more sessions" when both fit, on
    /// its own when nothing else closes the card, and is left out when more questions are waiting.
    @ViewBuilder private func footer(hiddenQuestions: Int, hiddenQuiet: Int) -> some View {
        let more = hiddenQuiet > 0 ? Text("+\(hiddenQuiet) more session\(hiddenQuiet == 1 ? "" : "s")").foregroundStyle(theme.sub) : nil
        let questions = hiddenQuestions > 0
            ? Text("+\(hiddenQuestions) more question\(hiddenQuestions == 1 ? "" : "s")").foregroundStyle(theme.accent).fontWeight(.semibold) : nil
        let usage = usageText.map { $0.foregroundStyle(theme.sub).monospacedDigit() }
        Group {
            if size == .large || usage == nil || questions != nil {
                if more != nil || questions != nil {
                    HStack { if let more { more }; Spacer(); if let questions { questions } }
                }
                if size == .large, let usage { usage.lineLimit(1).padding(.top, 4) }
            } else if let usage {
                if let more {
                    ViewThatFits(in: .horizontal) {
                        HStack { more; Spacer(minLength: 12); usage.lineLimit(1).fixedSize() }
                        // Short of room: one part only, the session ("62% used · resets 17:01") unless the week is
                        // high and fuller ("week 100%").
                        if let one = usageText(onePart: true)?.foregroundStyle(theme.sub).monospacedDigit() {
                            HStack { more; Spacer(minLength: 12); one.lineLimit(1).fixedSize() }
                        }
                        more.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    usage.lineLimit(1)
                }
            }
        }
        .font(Theme.small)
    }

    /// The usage line, nil until Claude Code has reported (or once both windows have reset). A number of 80% or
    /// more is in ink, a used-up one in the limit's red, as in the dropdown.
    private var usageText: Text? { usageText(onePart: false) }

    private func usageText(onePart: Bool) -> Text? {
        guard snapshot.live else { return nil }
        var p = UsageWords.short(snapshot.usage, now: now)
        if onePart {
            guard p.session != nil, p.week != nil else { return nil } // one part is the full line already
            if UsageWords.keepWeek(session: p.session?.percent, week: p.week?.percent) { p.session = nil } else { p.week = nil }
        }
        func part(_ x: (percent: Double, text: String)) -> Text {
            let high = UsageWords.isHigh(x.percent)
            guard high else { return Text(x.text) }
            // Only the number takes the colour: "62%" in "62% used · resets 17:01", "24%" in "week 24%".
            let n = "\(Int(x.percent.rounded()))%"
            let r = x.text.range(of: n)!
            let number = Text(n).foregroundStyle(x.percent >= 99.5 ? theme.limitText : theme.ink).fontWeight(.medium)
            return Text("\(Text(String(x.text[..<r.lowerBound])))\(number)\(Text(String(x.text[r.upperBound...])))")
        }
        switch (p.session, p.week) {
        case let (s?, w?): return Text("\(part(s)) · \(part(w))")
        case let (s?, nil): return part(s)
        case let (nil, w?): return part(w)
        default: return nil
        }
    }

    /// "as of 16:15", and from five minutes on also how old that is: "as of 16:15 · 29 min old".
    private var asOf: String {
        let at = "as of \(snapshot.asOf.formatted(date: .omitted, time: .shortened))"
        let behind = now.timeIntervalSince(snapshot.asOf)
        return behind >= 300 ? at + " · " + Words.age(since: snapshot.asOf, now: now) + " old" : at
    }

    private var title: String {
        // An app that cannot be reached is not the same as "no questions".
        guard snapshot.live else { return "ClockOffice is not running" }
        switch snapshot.asking.count {
        case 0: return "No questions for you"
        case 1: return "1 question for you"
        default: return "\(snapshot.asking.count) questions for you"
        }
    }
}

/// The sparkles of a turning dial, held still: the widget's sign for "working". Three arrangements, one per minute,
/// so the dial is never caught looking exactly the same twice in a row.
struct WorkingSparkles: View {
    let minute: Int
    let size: CGFloat

    var body: some View {
        // x, y on the dial (0…1) and the sparkle's size as a share of the dial.
        let sets: [[(x: CGFloat, y: CGFloat, s: CGFloat)]] = [
            [(0.78, 0.20, 0.56), (0.24, 0.68, 0.34)],
            [(0.22, 0.24, 0.56), (0.74, 0.70, 0.34)],
            [(0.66, 0.78, 0.56), (0.30, 0.22, 0.34)],
        ]
        let spots = sets[((minute % sets.count) + sets.count) % sets.count]
        ZStack {
            ForEach(0..<spots.count, id: \.self) { i in
                Sparkle().fill(Color.white)
                    .frame(width: size * spots[i].s, height: size * spots[i].s)
                    // A thin warm edge, so the white reads on the pale dial and on a light widget alike.
                    .shadow(color: Color(red: 0.55, green: 0.30, blue: 0.38).opacity(0.55), radius: 0.8)
                    .position(x: size * spots[i].x, y: size * spots[i].y)
            }
        }
        .frame(width: size, height: size)
    }
}
