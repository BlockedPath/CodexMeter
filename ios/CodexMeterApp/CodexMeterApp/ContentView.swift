import SwiftUI

// MARK: - App Entry Point

@main
struct CodexMeterAppEntry: App {
    @StateObject private var vm = MeterViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
    }
}

// MARK: - Main Content View

struct ContentView: View {
    @EnvironmentObject var vm: MeterViewModel
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            DashboardView(showSettings: $showSettings)
                .navigationTitle("CodexMeter")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    SettingsView()
                }
        }
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var vm: MeterViewModel
    @Binding var showSettings: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Connection status
                HStack {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 10, height: 10)
                    Text(vm.statusLine)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if vm.isFetching {
                        ProgressView().scaleEffect(0.7)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Usage or prompt
                if vm.serverURL.isEmpty {
                    noServerView
                } else if let error = vm.errorMessage {
                    errorView(error)
                } else {
                    usageSection
                }

                // Update info
                if !vm.serverURL.isEmpty {
                    HStack {
                        Image(systemName: "clock").font(.caption).foregroundColor(.secondary)
                        Text("Updated \(vm.lastUpdateText)").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("Every 30s").font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
            .padding()
        }
        .refreshable { await vm.fetchUsage() }
    }

    var connectionColor: Color {
        switch vm.bleState {
        case .connected: return .green
        case .scanning, .connecting: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        }
    }

    var noServerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("No server configured")
                .font(.headline)
            Text("Tap the gear icon to enter your Mac's address.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { showSettings = true }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    func errorView(_ error: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text("Cannot reach server")
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var usageSection: some View {
        VStack(spacing: 12) {
            if vm.isOK {
                UsageCard(
                    title: "Today",
                    pct: vm.sessionPct,
                    resetMins: vm.sessionResetMins
                )
                UsageCard(
                    title: "This Week",
                    pct: vm.weeklyPct,
                    resetMins: vm.weeklyResetMins
                )
            }
            HStack {
                Image(systemName: "creditcard").foregroundColor(.secondary)
                Text(vm.statusText).font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var vm: MeterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String = ""
    @State private var saved = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://100.x.x.x:9595", text: $urlText)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("Mac Daemon Address")
                } footer: {
                    Text("Enter your Mac's Tailscale IP and port.\nExample: http://100.87.45.12:9595")
                }

                Section {
                    Button("Save & Connect") {
                        vm.stop()
                        vm.serverURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
                        vm.start()
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                            dismiss()
                        }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                urlText = vm.serverURL
            }
        }
    }
}

// MARK: - Usage Card

struct UsageCard: View {
    let title: String
    let pct: Double
    let resetMins: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(Int(pct.rounded()))% remaining")
                    .font(.title2).fontWeight(.bold)
                    .foregroundColor(barColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor.gradient)
                        .frame(width: geometry.size.width * pct / 100, height: 12)
                }
            }
            .frame(height: 12)

            HStack {
                Image(systemName: "timer").font(.caption).foregroundColor(.secondary)
                Text(resetText).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    var barColor: Color {
        if pct <= 20 { return .red }
        if pct <= 50 { return .orange }
        return .green
    }

    var resetText: String {
        if resetMins < 0 { return "--" }
        if resetMins < 60 { return "Resets in \(resetMins)m" }
        let h = resetMins / 60, m = resetMins % 60
        if h < 24 { return "Resets in \(h)h \(m)m" }
        return "Resets in \(h / 24)d \(h % 24)h"
    }
}
