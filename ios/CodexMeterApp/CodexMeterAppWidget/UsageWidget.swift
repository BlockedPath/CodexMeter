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
        UsageEntry(date: Date(), sessionPct: 42, status: "120 credits", lastUpdated: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> ()) {
        let entry = loadEntry() ?? UsageEntry(date: Date(), sessionPct: 0, status: "Open the app to fetch usage", lastUpdated: nil)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> ()) {
        let entry = loadEntry() ?? UsageEntry(date: Date(), sessionPct: 0, status: "Open the app to fetch usage", lastUpdated: nil)
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
    @Environment(\.widgetFamily) private var family
    var entry: UsageProvider.Entry

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.14, green: 0.20, blue: 0.32)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("CodexMeter", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer()
                    Text("Today")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.10), in: Capsule())
                }

                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.14), lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: max(0.02, min(1.0, CGFloat(entry.sessionPct) / 100.0)))
                            .stroke(
                                AngularGradient(
                                    colors: [.mint, .cyan, .blue],
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        VStack(spacing: 2) {
                            Text("\(entry.sessionPct)%")
                                .font(.title2.weight(.bold))
                                .monospacedDigit()
                            Text("left")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .frame(width: family == .systemSmall ? 72 : 84, height: family == .systemSmall ? 72 : 84)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.status.isEmpty ? "Waiting for daemon" : entry.status)
                            .font(family == .systemSmall ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)

                        if let updated = entry.lastUpdated {
                            Text("Updated \(relative(updated))")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))
                        } else {
                            Text("No cached data yet")
                                .font(.caption2)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
        }
        .containerBackground(for: .widget) {
            Color.clear
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