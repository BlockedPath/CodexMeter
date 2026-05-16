import re

# We are currently IN the ios/CodexMeterApp directory so we don't need the prefix.
with open("CodexMeterAppWidget/UsageWidget.swift", "r") as f:
    content = f.read()

replacement = """struct AccessoryRectangularView: View {
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
                Text("\\(entry.sessionPct)% left")
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
}"""

content = re.sub(
    r"struct AccessoryRectangularView: View \{.*?(?=\nstruct UsageWidgetEntryView)",
    replacement + "\n",
    content,
    flags=re.DOTALL,
)

with open("CodexMeterAppWidget/UsageWidget.swift", "w") as f:
    f.write(content)
