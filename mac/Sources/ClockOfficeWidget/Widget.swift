import WidgetKit
import SwiftUI
import ClockOfficeCore
import ClockOfficeUI

// The desktop widget. It runs in Apple's sandbox, so it cannot read session files; it asks the running app
// (on 127.0.0.1 only) for one small snapshot. macOS decides how often a widget may refresh, so it always says
// "as of <time>": for the live picture, the menu-bar icon is the surface to trust.

struct Entry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot
}

struct Provider: TimelineProvider {
    static let sample = Snapshot(asOf: Date(), asking: [
        .init(id: "1", project: "Website", headline: "Merge to main now, or wait for your look?", since: Date().addingTimeInterval(-14 * 60)),
    ], working: 2, done: 1)

    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snapshot: Self.sample) }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        if context.isPreview { completion(Entry(date: Date(), snapshot: Self.sample)); return }
        fetch { completion(Entry(date: Date(), snapshot: $0)) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        fetch { snap in
            // One entry a minute for the next half hour keeps "34 min" honest between refreshes.
            let start = Date()
            let entries = (0..<30).map { Entry(date: start.addingTimeInterval(Double($0) * 60), snapshot: snap) }
            completion(Timeline(entries: entries, policy: .after(start.addingTimeInterval(15 * 60))))
        }
    }

    private func fetch(_ done: @escaping (Snapshot) -> Void) {
        var req = URLRequest(url: Snapshot.url, timeoutInterval: 4)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data, let snap = try? Snapshot.decoder.decode(Snapshot.self, from: data) {
                done(snap)
            } else {
                done(Snapshot(asOf: Date(), asking: [], working: 0, done: 0, live: false))
            }
        }.resume()
    }
}

struct QuestionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    let entry: Entry

    var body: some View {
        Themed {
            // The snapshot's own time is when the app last spoke; the entry's date moves the ages forward.
            WidgetCard(snapshot: entry.snapshot, now: entry.date, size: family == .systemLarge ? .large : .medium)
        }
        .containerBackground(Theme.of(scheme).panel, for: .widget)
        // Anywhere outside a row or an answer: the dropdown's list.
        .widgetURL(WidgetLink.open.url)
    }
}

struct QuestionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.github.marykovziridze.clockoffice.questions", provider: Provider()) { entry in
            QuestionsWidgetView(entry: entry)
        }
        .configurationDisplayName("ClockOffice")
        .description("Which coding sessions have a question for you.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

@main
struct ClockOfficeWidgets: WidgetBundle {
    var body: some Widget { QuestionsWidget() }
}
