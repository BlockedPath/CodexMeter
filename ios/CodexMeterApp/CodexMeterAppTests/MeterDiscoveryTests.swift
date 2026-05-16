import XCTest
import Combine
@testable import CodexMeterApp

final class MeterDiscoveryTests: XCTestCase {
    func testViewModelReceivesDiscovery() async throws {
        // Create the VM on the main actor since it's @MainActor-isolated
        let vm: MeterViewModel = await MainActor.run { MeterViewModel() }

        // Ensure initial state (read on main actor)
        await MainActor.run { XCTAssertTrue(vm.discoveredServices.isEmpty) }

        // Publish a fake discovery
        let url = "http://127.0.0.1:9595"
        let name = "codexmeter"
        MDNSServiceBrowser.shared.discoveryPublisher.send((url, name))

        // Wait briefly for main-queue update
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        await MainActor.run {
            XCTAssertTrue(vm.discoveredServices.contains { $0.url == url && $0.name == name })
        }
    }
}
