import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let sessionPct: Int
    let status: String
    let lastUpdated: Date?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), sessionPct: 50, status: "--", lastUpdated: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> ()) {
        let entry = loadEntry() ?? UsageEntry(date: Date(), sessionPct: 0, status: "No data", lastUpdated: nil)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> ()) {
        let entry = loadEntry() ?? UsageEntry(date: Date(), sessionPct: 0, status: "No data", lastUpdated: nil)
        // Request the system refresh in 15 minutes; WidgetKit may adjust this.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(60*15)
        let timeline = Timeline(entries: [entry], policy: .after(next))
        completion(timeline)
    }

    private func loadEntry() -> UsageEntry? {
        guard let shared = UserDefaults(suiteName: "group.com.codexmeter"),
              let json = shared.string(forKey: "last_usage_json") else {
            return nil
        }
        if let data = json.data(using: .utf8) {
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let s = (dict["s"] as? Int) ?? ((dict["s"] as? Double).map { Int($0) } ?? 0)
                let st = (dict["st"] as? String) ?? ""
                let entry = UsageEntry(date: Date(), sessionPct: s, status: st, lastUpdated: Date())
                return entry
            }
        }
        return nil
    }
}

struct UsageWidgetEntryView : View {
    var entry: UsageProvider.Entry

    var body: some View {
        ZStack {
            Color(.systemBackground)
            VStack(alignment: .leading) {
                HStack {
                    Text("Today")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(entry.sessionPct)%")
                        .font(.title2)
                        .fontWeight(.semibold)
                }
                Text(entry.status)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                if let updated = entry.lastUpdated {
                    Text("Updated \(relative(updated))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

@main
struct UsageWidget: Widget {
    let kind: String = "UsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("CodexMeter")
        .description("Quick glance at today usage percentage and status.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
*** End Patch