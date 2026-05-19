import SwiftUI
import WidgetKit

private enum WidgetSharedUsageStore {
    static let appGroupIdentifier = "group.com.codexmeter"
    static let usageJSONKey = "last_usage_json"
    static let serverURLKey = "server_url"
    static let lastUsageUpdatedAtKey = "last_usage_updated_at"

    static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupIdentifier)
    }

    static func normalizedBaseURL(from rawValue: String) -> String {
        var base = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/usage") {
            base = String(base.dropLast(6))
        } else if base.hasSuffix("/status") {
            base = String(base.dropLast(7))
        }
        if base.hasSuffix("/") {
            base.removeLast()
        }
        return base
    }

    static func endpointURL(from serverURL: String, path: String) -> URL? {
        let base = normalizedBaseURL(from: serverURL)
        guard !base.isEmpty else { return nil }
        return URL(string: "\(base)/\(path)")
    }

    static func persistUsageJSON(_ json: String, serverURL: String) {
        guard let shared = sharedDefaults() else { return }
        shared.set(json, forKey: usageJSONKey)
        shared.set(normalizedBaseURL(from: serverURL), forKey: serverURLKey)
        shared.set(Date().timeIntervalSince1970, forKey: lastUsageUpdatedAtKey)
        shared.synchronize()
    }

    static func cachedUsageJSON() -> String? {
        sharedDefaults()?.string(forKey: usageJSONKey)
    }

    static func sharedServerURL() -> String? {
        sharedDefaults()?.string(forKey: serverURLKey)
    }
}

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
        Task {
            let entry = await loadEntry() ?? placeholder(in: context)
            completion(entry)
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        Task {
            let entry = await loadEntry() ?? UsageEntry(date: Date(), sessionPct: 0, weeklyPct: 0, sessionResetMins: -1, weeklyResetMins: -1, status: "Open app to sync", isOk: false, lastUpdated: nil)
            let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }

    private func loadEntry() async -> UsageEntry? {
        if let serverURL = WidgetSharedUsageStore.sharedServerURL(),
           !serverURL.isEmpty,
           let freshEntry = await fetchLiveEntry(serverURL: serverURL) {
            return freshEntry
        }

        guard
            let json = WidgetSharedUsageStore.cachedUsageJSON()
        else { return nil }

        return parseEntry(from: json, fallbackDate: Date())
    }

    private func fetchLiveEntry(serverURL: String) async -> UsageEntry? {
        do {
            guard let requestURL = WidgetSharedUsageStore.endpointURL(from: serverURL, path: "usage") else {
                return nil
            }
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }
            let json = String(data: data, encoding: .utf8) ?? "{}"
            WidgetSharedUsageStore.persistUsageJSON(json, serverURL: serverURL)
            return parseEntry(from: json, fallbackDate: Date())
        } catch {
            return nil
        }
    }

    private func parseEntry(from json: String, fallbackDate: Date) -> UsageEntry? {
        guard
            let shared = WidgetSharedUsageStore.sharedDefaults(),
            let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let s = (dict["s"] as? Int) ?? (dict["s"] as? Double).map { Int($0) } ?? 0
        let w = (dict["w"] as? Int) ?? (dict["w"] as? Double).map { Int($0) } ?? 0
        let sr = (dict["sr"] as? Int) ?? (dict["sr"] as? Double).map { Int($0) } ?? -1
        let wr = (dict["wr"] as? Int) ?? (dict["wr"] as? Double).map { Int($0) } ?? -1
        let st = (dict["st"] as? String) ?? ""
        let ok = (dict["ok"] as? Bool) ?? false
        let storedTimestamp = shared.object(forKey: WidgetSharedUsageStore.lastUsageUpdatedAtKey) as? Double
        let lastUpdated = storedTimestamp.map(Date.init(timeIntervalSince1970:)) ?? fallbackDate

        return UsageEntry(date: fallbackDate, sessionPct: s, weeklyPct: w, sessionResetMins: sr, weeklyResetMins: wr, status: st, isOk: ok, lastUpdated: lastUpdated)
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

            if !entry.isOk {
                Spacer()
                Text("waiting for host")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(atomDim)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                
                // Session (Today)
                Text(entry.isOk ? "\(formatResetTime(mins: entry.sessionResetMins).uppercased()) LEFT" : "TODAY")
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

// MARK: - Pet State

private let petNames = ["sukuna", "boba", "gojo", "itachi", "goblin", "apupepe", "elephant", "frirencodex", "nezha"]

private func selectedPet() -> String {
    UserDefaults(suiteName: "group.com.codexmeter")?.string(forKey: "selected_pet") ?? "sukuna"
}

private func petImageName(entry: UsageEntry) -> String {
    let pet = selectedPet()
    let state: String
    if !entry.isOk { state = "review" }
    else if entry.sessionPct <= 20 { state = "running" }
    else if entry.sessionPct <= 50 { state = "waving" }
    else { state = "idle" }
    return "pet_\(pet)_\(state)"
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
            
            // Right: Pet + status
            VStack(spacing: 6) {
                Image(petImageName(entry: entry))
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 52, height: 80)

                Text(entry.status.isEmpty ? " " : entry.status)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(atomDim)
                    .lineLimit(1)

                if entry.isOk {
                    Text("\(formatResetTime(mins: entry.sessionResetMins))")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(atomText)
                }

                if entry.lastUpdated != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "clock")
                        Text(relativeTime(entry.lastUpdated!))
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
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
    private var fraction: Double {
        let value = Double(entry.sessionPct) / 100.0
        guard entry.isOk else { return max(0, value) }
        return max(0.01, value)
    }

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
