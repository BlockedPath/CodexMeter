import Foundation
import WidgetKit

enum SharedUsageStore {
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

    static func lastUsageUpdatedAt() -> Date? {
        guard let timestamp = sharedDefaults()?.object(forKey: lastUsageUpdatedAtKey) as? Double else {
            return nil
        }
        return Date(timeIntervalSince1970: timestamp)
    }
}

/// App-wide state — completely OAuth-free. Just fetches from the Mac daemon.
@MainActor
final class MeterViewModel: ObservableObject {
    @Published var usageJSON: String = "{}"
    @Published var bleState: BLEManager.BLEState = .disconnected
    @Published var lastUpdate: Date?
    @Published var isFetching = false
    @Published var errorMessage: String?
    @Published var daemonSource: String = "starting"
    @Published var daemonLastSuccess: String = "--"
    @Published var daemonLastError: String = ""
    @Published var daemonPayloadAge: Int?
    @Published var daemonUptime: Int?
    struct DiscoveredService: Identifiable, Equatable {
        let id: String // use url as id
        let name: String
        let url: String
    }
    @Published var discoveredServices: [DiscoveredService] = []

    // Parsed fields for display
    @Published var sessionPct: Double = 0
    @Published var sessionResetMins: Int = -1
    @Published var weeklyPct: Double = 0
    @Published var weeklyResetMins: Int = -1
    @Published var statusText: String = "waiting"
    @Published var isOK: Bool = false

    private let ble = BLEManager()
    private var fetchTimer: Timer?
    private var bleTimer: Timer?
    private var mdnsTask: Task<Void, Never>?

    // URL of the Mac daemon (stored in UserDefaults)
    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "server_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "server_url") }
    }

    init() {
        ble.onRefreshRequested = { [weak self] in
            Task { @MainActor [weak self] in await self?.fetchUsage() }
        }
        // Start an async task to consume async discoveries stream
        mdnsTask = Task { [weak self] in
            guard let self else { return }
            for await pair in MDNSServiceBrowser.shared.discoveriesAsync() {
                let (url, name) = pair
                // process discovery on MainActor (self is @MainActor)
                self.processDiscovery(url: url, name: name)
            }
        }
    }

    @MainActor
    private func processDiscovery(url: String, name: String) {
        guard name.lowercased().contains("codexmeter") else { return }
        let svc = DiscoveredService(id: url, name: name, url: url)
        if !self.discoveredServices.contains(svc) {
            self.discoveredServices.append(svc)
        }
        let wasEmpty = self.serverURL.isEmpty
        if wasEmpty {
            self.serverURL = url
            // Auto-start: this was an mDNS discovery, kick off fetch + timers
            beginUsagePolling()
        }
    }

    func start() {
        restoreCachedUsage()

        // If no server configured, start mDNS discovery to auto-find the daemon.
        if serverURL.isEmpty {
            MDNSServiceBrowser.shared.startBrowsing()
        }
        beginDisplayScanning()
        guard !serverURL.isEmpty else { return }
        beginUsagePolling()
    }

    /// Start usage fetch + refresh timer. Called from start() or after mDNS discovery.
    private func beginUsagePolling() {
        // Avoid double-starting
        guard fetchTimer == nil else { return }

        Task { await fetchUsage() }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchUsage() }
        }
    }

    /// BLE display scanning should not depend on HTTP daemon discovery.
    private func beginDisplayScanning() {
        guard bleTimer == nil else { return }

        ble.startScanning()
        bleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendToBLE() }
        }
    }

    func stop() {
        fetchTimer?.invalidate()
        bleTimer?.invalidate()
        ble.stop()
        MDNSServiceBrowser.shared.stopBrowsing()
        mdnsTask?.cancel()
        mdnsTask = nil
    }

    deinit {
        mdnsTask?.cancel()
    }

    func fetchUsage() async {
        guard !serverURL.isEmpty else { return }
        guard !isFetching else { return }

        isFetching = true
        defer { isFetching = false }

        do {
            guard let requestURL = endpointURL("usage") else {
                setFetchError("Invalid URL")
                return
            }
            let json = try await Self.fetchUsageJSONString(from: requestURL)
            usageJSON = json
            SharedUsageStore.persistUsageJSON(json, serverURL: self.serverURL)
            // Ask the system to reload widget timelines — non-blocking request
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            lastUpdate = Date()
            errorMessage = nil

            parseJSON(json)
            await fetchDaemonStatus()
            sendToBLE()
        } catch {
            if !isCancellation(error) {
                setFetchError(error.localizedDescription)
            }
            await fetchDaemonStatus()
        }
    }

    private func restoreCachedUsage() {
        guard let json = SharedUsageStore.cachedUsageJSON(), usageJSON == "{}" else { return }
        usageJSON = json
        parseJSON(json)
        lastUpdate = SharedUsageStore.lastUsageUpdatedAt()
        if hasUsableUsage {
            errorMessage = nil
        }
    }

    private var hasUsableUsage: Bool {
        lastUpdate != nil || isOK || usageJSON != "{}"
    }

    private func setFetchError(_ message: String) {
        if hasUsableUsage {
            errorMessage = nil
        } else {
            errorMessage = message
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    nonisolated static func refreshSharedUsage(serverURL: String) async throws -> String {
        guard let requestURL = SharedUsageStore.endpointURL(from: serverURL, path: "usage") else {
            throw URLError(.badURL)
        }

        let json = try await fetchUsageJSONString(from: requestURL)
        SharedUsageStore.persistUsageJSON(json, serverURL: serverURL)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
        return json
    }

    private nonisolated static func fetchUsageJSONString(from requestURL: URL) async throws -> String {
        var request = URLRequest(url: requestURL)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        return String(data: data, encoding: .utf8) ?? "{}"
    }

    private func endpointURL(_ path: String) -> URL? {
        SharedUsageStore.endpointURL(from: serverURL, path: path)
    }

    private func fetchDaemonStatus() async {
        guard let requestURL = endpointURL("status") else { return }
        do {
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }
            parseDaemonStatus(data)
        } catch {
            daemonLastError = error.localizedDescription
        }
    }

    private func parseDaemonStatus(_ data: Data) {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        daemonSource = (dict["source"] as? String) ?? "unknown"
        daemonLastSuccess = (dict["last_success_at"] as? String) ?? "--"
        daemonLastError = (dict["last_error"] as? String) ?? ""
        daemonPayloadAge = (dict["payload_age_seconds"] as? Int) ?? (dict["payload_age_seconds"] as? Double).map(Int.init)
        daemonUptime = (dict["uptime_seconds"] as? Int) ?? (dict["uptime_seconds"] as? Double).map(Int.init)
    }

    private func parseJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        sessionPct = (dict["s"] as? Double) ?? Double(dict["s"] as? Int ?? 0)
        sessionResetMins = (dict["sr"] as? Int) ?? -1
        weeklyPct = (dict["w"] as? Double) ?? Double(dict["w"] as? Int ?? 0)
        weeklyResetMins = (dict["wr"] as? Int) ?? -1
        statusText = (dict["st"] as? String) ?? "unknown"
        isOK = (dict["ok"] as? Bool) ?? false
    }

    private func sendToBLE() {
        ble.send(payload: usageJSON)
        bleState = ble.state
    }

    var statusLine: String {
        switch bleState {
        case .connected: return "Connected to display"
        case .scanning: return "Scanning for display..."
        case .connecting: return "Connecting..."
        case .disconnected: return "Not connected"
        case .failed(let msg): return msg
        }
    }

    var lastUpdateText: String {
        guard let date = lastUpdate else { return "--" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var daemonSourceText: String {
        switch daemonSource {
        case "codex_oauth": return "Codex OAuth"
        case "openai_costs": return "OpenAI costs"
        case "local_fallback": return "Local fallback"
        case "starting": return "Starting"
        default: return daemonSource
        }
    }

    var daemonFreshnessText: String {
        guard let daemonPayloadAge else { return "--" }
        if daemonPayloadAge < 60 { return "\(daemonPayloadAge)s old" }
        if daemonPayloadAge < 3600 { return "\(daemonPayloadAge / 60)m old" }
        return "\(daemonPayloadAge / 3600)h old"
    }

    var daemonUptimeText: String {
        guard let daemonUptime else { return "--" }
        if daemonUptime < 60 { return "\(daemonUptime)s" }
        if daemonUptime < 3600 { return "\(daemonUptime / 60)m" }
        return "\(daemonUptime / 3600)h"
    }
}
