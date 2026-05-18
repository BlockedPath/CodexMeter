import SwiftUI
import BackgroundTasks
import WidgetKit

// MARK: - App Entry Point

private enum BackgroundRefreshConstants {
    static let taskIdentifier = "com.codexmeter.ios.app-refresh"
}

@main
struct CodexMeterAppEntry: App {
    @StateObject private var vm = MeterViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vm)
        }
        .backgroundTask(.appRefresh(BackgroundRefreshConstants.taskIdentifier)) {
            await runBackgroundRefresh()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: BackgroundRefreshConstants.taskIdentifier)
            case .inactive:
                break
            case .background:
                scheduleBackgroundRefresh()
            @unknown default:
                break
            }
        }
    }

    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: BackgroundRefreshConstants.taskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            #if DEBUG
            print("Failed to schedule background refresh: \(error.localizedDescription)")
            #endif
        }
    }

    private func runBackgroundRefresh() async {
        scheduleBackgroundRefresh()
        guard let serverURL = SharedUsageStore.sharedServerURL(), !serverURL.isEmpty else { return }
        _ = try? await MeterViewModel.refreshSharedUsage(serverURL: serverURL)
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

                if !vm.serverURL.isEmpty {
                    daemonSection
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

    var daemonSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Daemon", systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer()
                Text(vm.daemonSourceText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 12) {
                StatusPill(title: "Fresh", value: vm.daemonFreshnessText)
                StatusPill(title: "Uptime", value: vm.daemonUptimeText)
            }

            if !vm.daemonLastError.isEmpty {
                Label(vm.daemonLastError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .lineLimit(3)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var vm: MeterViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String = ""
    @State private var saved = false
    @AppStorage("selected_pet", store: UserDefaults(suiteName: "group.com.codexmeter"))
    private var selectedPet: String = "sukuna"
    @State private var showPetPicker = false
    @State private var pendingPet: String = ""

    private let pets = ["sukuna", "boba", "gojo", "itachi", "goblin", "apupepe", "elephant", "frirencodex", "nezha"]

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

                Section("Display Pet") {
                    Button {
                        pendingPet = selectedPet
                        showPetPicker = true
                    } label: {
                        HStack {
                            if let uiImage = petUIImage("pet_\(selectedPet)_idle") {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .interpolation(.none)
                                    .scaledToFit()
                                    .frame(width: 32, height: 48)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(petDisplayName(selectedPet))
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text("Tap to change")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .sheet(isPresented: $showPetPicker) {
                    PetCarouselView(
                        pets: pets,
                        selected: $pendingPet,
                        onApply: {
                            selectedPet = pendingPet
                            WidgetCenter.shared.reloadAllTimelines()
                            showPetPicker = false
                        },
                        onCancel: { showPetPicker = false }
                    )
                }

                if !vm.discoveredServices.isEmpty {
                    Section(header: HStack {
                        Text("Discovered on Local Network")
                        Spacer()
                        Button("Refresh") {
                            // restart discovery
                            vm.discoveredServices.removeAll()
                            MDNSServiceBrowser.shared.startBrowsing()
                        }
                    }) {
                        ForEach(vm.discoveredServices) { svc in
                            Button(action: {
                                vm.stop()
                                vm.serverURL = svc.url
                                vm.start()
                                dismiss()
                            }) {
                                HStack {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                    VStack(alignment: .leading) {
                                        Text(svc.name).font(.subheadline).lineLimit(1)
                                        Text(svc.url).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }
                        }
                    }
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

// MARK: - Pet Carousel

private func petDisplayName(_ id: String) -> String {
    switch id {
    case "sukuna": return "Sukuna"
    case "boba": return "Boba"
    case "gojo": return "Gojo"
    case "itachi": return "Itachi"
    case "goblin": return "Goblin"
    case "apupepe": return "Pepe"
    case "elephant": return "Elephant"
    case "frirencodex": return "Friren"
    case "nezha": return "Nezha"
    default: return id.capitalized
    }
}

/// Loads an image from the embedded widget extension bundle, since the
/// main app target has no asset catalog of its own.
private func petUIImage(_ name: String) -> UIImage? {
    guard let widgetURL = Bundle.main.builtInPlugInsURL?
        .appendingPathComponent("CodexMeterAppWidget.appex"),
          let widgetBundle = Bundle(url: widgetURL)
    else { return nil }
    return UIImage(named: name, in: widgetBundle, compatibleWith: nil)
}

struct PetCarouselView: View {
    let pets: [String]
    @Binding var selected: String
    let onApply: () -> Void
    let onCancel: () -> Void

    @State private var index: Int = 0

    private func spriteImage(_ name: String) -> AnyView {
        if let uiImage = petUIImage(name) {
            return AnyView(
                Image(uiImage: uiImage)
                    .resizable()
                    .interpolation(.none)
            )
        } else {
            return AnyView(
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "questionmark"))
            )
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Pet display area
                VStack(spacing: 20) {
                    // Left/Right arrows + sprite
                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                index = (index - 1 + pets.count) % pets.count
                                selected = pets[index]
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(index > 0 ? .accentColor : .gray.opacity(0.3))
                                .frame(width: 44, height: 44)
                        }
                        .disabled(index == 0)

                        Spacer()

                        spriteImage("pet_\(selected)_idle")
                            .scaledToFit()
                            .frame(width: 104, height: 160)
                            .id(selected)
                            .transition(.asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            ))

                        Spacer()

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                index = (index + 1) % pets.count
                                selected = pets[index]
                            }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 28, weight: .medium))
                                .foregroundColor(index < pets.count - 1 ? .accentColor : .gray.opacity(0.3))
                                .frame(width: 44, height: 44)
                        }
                        .disabled(index == pets.count - 1)
                    }
                    .padding(.horizontal, 16)

                    Text(petDisplayName(selected))
                        .font(.title2.weight(.semibold))

                    HStack(spacing: 8) {
                        ForEach(0..<pets.count, id: \.self) { i in
                            Circle()
                                .fill(i == index ? Color.accentColor : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                VStack(spacing: 12) {
                    Button(action: onApply) {
                        Text("Apply")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onCancel) {
                        Text("OK")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationTitle("Choose Pet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { onCancel() }
                }
            }
            .onAppear {
                if let i = pets.firstIndex(of: selected) {
                    index = i
                }
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

struct StatusPill: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.subheadline)
                .fontWeight(.semibold)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
