import SwiftUI
import WidgetKit

// MARK: - Entry

struct UsageEntry: TimelineEntry {
    let date: Date
    let sessionPct: Int
    let weeklyPct: Int
    let sessionResetMins: Int
    let weeklyResetMins: Int
    let status: String
    let isOk: Bool
    let lastUpdated: Date?
}

// MARK: - Provider

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), sessionPct: 72, weeklyPct: 45, sessionResetMins: 240, weeklyResetMins: 3600, status: "$2.31 today", isOk: true, lastUpdated: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let entry = loadEntry() ?? placeholder(in: context)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = loadEntry() ?? UsageEntry(date: Date(), sessionPct: 0, weeklyPct: 0, sessionResetMins: -1, weeklyResetMins: -1, status: "Open app to sync", isOk: false, lastUpdated: nil)
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func loadEntry() -> UsageEntry? {
        guard
            let shared = UserDefaults(suiteName: "group.com.codexmeter"),
            let json = shared.string(forKey: "last_usage_json"),
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let s = (dict["s"] as? Int) ?? (dict["s"] as? Double).map { Int($0) } ?? 0
        let w = (dict["w"] as? Int) ?? (dict["w"] as? Double).map { Int($0) } ?? 0
        let sr = (dict["sr"] as? Int) ?? (dict["sr"] as? Double).map { Int($0) } ?? -1
        let wr = (dict["wr"] as? Int) ?? (dict["wr"] as? Double).map { Int($0) } ?? -1
        let st = (dict["st"] as? String) ?? ""
        let ok = (dict["ok"] as? Bool) ?? false

        return UsageEntry(date: Date(), sessionPct: s, weeklyPct: w, sessionResetMins: sr, weeklyResetMins: wr, status: st, isOk: ok, lastUpdated: Date())
    }
}

// MARK: - Atom Formatting

private func formatResetTime(mins: Int) -> String {
    if mins < 0 { return "--" }
    if mins < 60 { return "\(mins)m" }
    let h = mins / 60
    let m = mins % 60
    if m == 0 { return "\(h)h" }
    return "\(h)h \(m)m"
}

private func remainingColor(for pct: Int) -> Color {
    if pct <= 20 { return Color.red }
    if pct <= 50 { return Color.orange }
    return Color.green
}

private let atomDim = Color(white: 0.55) // 0x8C71 equivalent vaguely
private let atomText = Color(white: 0.85) // 0xD69A
private let atomRule = Color(red: 0.16, green: 0.39, blue: 0.39) // 0x2965 loosely? Actually let's use a subtle blue-grey
private let barBg = Color(white: 0.15)
private let barBorder = Color(red: 0.35, green: 0.92, blue: 0.92) // 0x5AEB approx
private let dimBorder = Color(white: 0.25)

struct AtomProgressBar: View {
    let pct: Int
    let active: Bool
    
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(active ? barBorder : dimBorder, lineWidth: 1)
                
                RoundedRectangle(cornerRadius: 2)
                    .fill(barBg)
                    .padding(1)
                
                if active && pct > 0 {
                    let clamped = min(max(pct, 0), 100)
                    let fillWidth = (geo.size.width - 2) * CGFloat(clamped) / 100.0
                    if fillWidth > 0 {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(remainingColor(for: pct))
                            .frame(width: fillWidth)
                            .padding(1)
                    }
                }
            }
        }
    }
}

// MARK: - Small Widget (Atom Style)

struct AtomWidgetStyleView: View {
    let entry: UsageEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image("CodexIcon")
                    .resizable()
                    .interpolation(.none)
                    .frame(width: 22, height: 22)
                
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("Codex")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(atomText)
                        .fixedSize(horizontal: true, vertical: false)
                    Text("usage")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(atomDim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)

            if !entry.isOk && entry.status.starts(with: "Open app") {
                Spacer()
                Text("waiting for host")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(atomDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                
                // Session (Today)
                Text(entry.isOk ? "5H LEFT" : "TODAY")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(atomDim)
                
                Text(entry.isOk ? "\(entry.sessionPct)%" : "--")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(atomText)
                
                AtomProgressBar(pct: entry.sessionPct, active: entry.isOk)
                    .frame(height: 10)
                    .padding(.vertical, 2)
                
                Text(entry.isOk ? "reset \(formatResetTime(mins: entry.sessionResetMins))" : entry.status)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(atomDim)
                    .lineLimit(1)
                
                Spacer(minLength: 4)
                
                // Weekly
                HStack(alignment: .bottom, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.isOk ? "WK LEFT" : "WEEK")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(atomDim)
                        
                        Text(entry.isOk ? "\(entry.weeklyPct)%" : "--")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(atomText)
                    }
                    
                    Spacer()
                    
                    if !entry.isOk {
                        Text("needs login")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.orange)
                            .padding(.bottom, 2)
                    } else {
                        AtomProgressBar(pct: entry.weeklyPct, active: entry.isOk)
                            .frame(width: 50, height: 8)
                            .padding(.bottom, 4)
                    }
                }
            }
        }
        .padding(12)
        .containerBackground(for: .widget) { Color.black }
    }
}

// MARK: - Medium Widget

struct MediumWidgetView: View {
    let entry: UsageEntry

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            // Left: The exact Atom UI
            AtomWidgetStyleView(entry: entry)
                .frame(width: 140)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
            
            // Right: Detailed status
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.status.isEmpty ? "Waiting for sync" : entry.status)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                
                if entry.isOk {
                    Text("Session Reset: \(formatResetTime(mins: entry.sessionResetMins))")
                        .font(.caption)
                        .foregroundStyle(atomDim)
                    Text("Weekly Reset: \(formatResetTime(mins: entry.weeklyResetMins))")
                        .font(.caption)
                        .foregroundStyle(atomDim)
                }
                
                Spacer(minLength: 0)
                
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(entry.lastUpdated.map { relativeTime($0) } ?? "Never synced")
                }
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.vertical, 8)
            Spacer()
        }
        .padding(16)
        .containerBackground(for: .widget) { Color(white: 0.1) }
    }
}

private func relativeTime(_ date: Date) -> String {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - Lock Screen

struct AccessoryCircularView: View {
    let entry: UsageEntry
    private var fraction: Double { max(0.01, Double(entry.sessionPct) / 100.0) }

    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.30), lineWidth: 4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -1) {
                Text("\(entry.sessionPct)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .widgetAccentable()
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct AccessoryRectangularView: View {
    let entry: UsageEntry

    var body: some View {
        HStack(spacing: 8) {
            Image("CodexIcon")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("CODEX")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .tracking(1.2)
                Text("\(entry.sessionPct)% left")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if !entry.status.isEmpty {
                    Text(entry.status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct UsageWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageProvider.Entry

    var body: some View {
        switch family {
        case .systemSmall:
            AtomWidgetStyleView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .accessoryCircular:
            AccessoryCircularView(entry: entry)
        case .accessoryRectangular:
            AccessoryRectangularView(entry: entry)
        default:
            MediumWidgetView(entry: entry)
        }
    }
}

@main
struct UsageWidget: Widget {
    let kind = "UsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("CodexMeter")
        .description("Quick glance at today's Codex usage.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}
