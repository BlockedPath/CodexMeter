import Foundation

/// App-wide state — completely OAuth-free. Just fetches from the Mac daemon.
@MainActor
final class MeterViewModel: ObservableObject {
    @Published var usageJSON: String = "{}"
    @Published var bleState: BLEManager.BLEState = .disconnected
    @Published var lastUpdate: Date?
    @Published var isFetching = false
    @Published var errorMessage: String?

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

    // URL of the Mac daemon (stored in UserDefaults)
    var serverURL: String {
        get { UserDefaults.standard.string(forKey: "server_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "server_url") }
    }

    init() {
        ble.onRefreshRequested = { [weak self] in
            Task { @MainActor [weak self] in await self?.fetchUsage() }
        }
    }

    func start() {
        guard !serverURL.isEmpty else { return }
        Task { await fetchUsage() }

        fetchTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fetchUsage() }
        }

        ble.startScanning()
        bleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sendToBLE() }
        }
    }

    func stop() {
        fetchTimer?.invalidate()
        bleTimer?.invalidate()
        ble.stop()
    }

    func fetchUsage() async {
        guard !serverURL.isEmpty else { return }
        let url = serverURL.hasSuffix("/usage") ? serverURL : "\(serverURL)/usage"

        isFetching = true
        defer { isFetching = false }

        do {
            guard let requestURL = URL(string: url) else {
                errorMessage = "Invalid URL"
                return
            }
            var request = URLRequest(url: requestURL)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                errorMessage = "Server returned \((response as? HTTPURLResponse)?.statusCode ?? 0)"
                return
            }

            let json = String(data: data, encoding: .utf8) ?? "{}"
            usageJSON = json
            lastUpdate = Date()
            errorMessage = nil

            parseJSON(json)
            sendToBLE()
        } catch {
            errorMessage = error.localizedDescription
        }
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
}
