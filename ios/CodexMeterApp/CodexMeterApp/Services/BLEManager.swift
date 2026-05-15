import Foundation
import CoreBluetooth

/// CoreBluetooth central manager that connects to the CodexMeter ESP32
/// peripheral and writes usage JSON to its RX characteristic.
///
/// The ESP32 advertises as "Codex Controller" with a custom GATT service:
///   Service: 434f4445-584d-4554-4552-000000000001
///     RX:     ...0002  (WRITE | WRITE_NR) — host writes compact JSON here
///     TX:     ...0003  (READ | NOTIFY)    — device sends ack/nack
///     REQ:    ...0004  (NOTIFY)           — device requests refresh
@MainActor
final class BLEManager: NSObject, ObservableObject {
    static let serviceUUID = CBUUID(string: "434f4445-584d-4554-4552-000000000001")
    static let rxCharUUID  = CBUUID(string: "434f4445-584d-4554-4552-000000000002")
    static let reqCharUUID = CBUUID(string: "434f4445-584d-4554-4552-000000000004")
    static let deviceName  = "Codex Controller"

    @Published var state: BLEState = .disconnected
    @Published var lastPayload: String = ""

    enum BLEState: Equatable {
        case disconnected
        case scanning
        case connecting
        case connected
        case failed(String)
    }

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var reqCharacteristic: CBCharacteristic?

    private var shouldAutoReconnect = true
    private var pendingPayload: String?

    // Callback when a refresh is requested by the ESP32
    var onRefreshRequested: (() -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        switch central.state {
        case .poweredOn:
            break
        case .unknown, .resetting:
            // Wait for poweredOn callback
            state = .scanning
            return
        case .unsupported:
            state = .failed("BLE not supported")
            return
        case .unauthorized:
            state = .failed("Bluetooth permission denied")
            return
        case .poweredOff:
            state = .failed("Bluetooth is off")
            return
        @unknown default:
            state = .failed("Bluetooth not available")
            return
        }
        shouldAutoReconnect = true
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stop() {
        shouldAutoReconnect = false
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        central.stopScan()
        state = .disconnected
    }

    /// Write a usage JSON payload to the ESP32's RX characteristic.
    func send(payload: String) {
        guard let peripheral, let rxCharacteristic else {
            pendingPayload = payload
            return
        }
        guard peripheral.state == .connected else {
            pendingPayload = payload
            return
        }
        guard let data = payload.data(using: .utf8) else { return }

        let type: CBCharacteristicWriteType = rxCharacteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: rxCharacteristic, type: type)
        lastPayload = payload
    }

    /// Flush any pending payload after (re)connection.
    private func flushPending() {
        guard let payload = pendingPayload else { return }
        pendingPayload = nil
        send(payload: payload)
    }
}

// MARK: - CBCentralManagerDelegate

@MainActor extension BLEManager: @MainActor CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            if shouldAutoReconnect {
                // Actually start scanning now that we're powered on
                state = .scanning
                central.scanForPeripherals(withServices: [Self.serviceUUID],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        case .poweredOff:
            state = .failed("Bluetooth is off")
        case .unauthorized:
            state = .failed("Bluetooth permission denied")
        case .unsupported:
            state = .failed("BLE not supported on this device")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name == Self.deviceName else { return }

        central.stopScan()
        self.peripheral = peripheral
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        state = .failed(error?.localizedDescription ?? "Connection failed")
        if shouldAutoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.startScanning()
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        rxCharacteristic = nil
        reqCharacteristic = nil
        state = .disconnected
        if shouldAutoReconnect {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.startScanning()
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

@MainActor extension BLEManager: @MainActor CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(
                [Self.rxCharUUID, Self.reqCharUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case Self.rxCharUUID:
                rxCharacteristic = characteristic
                flushPending()
            case Self.reqCharUUID:
                reqCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == Self.reqCharUUID else { return }
        // ESP32 set the REQ characteristic value — request a refresh
        onRefreshRequested?()
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            print("[BLE] Write error: \(error.localizedDescription)")
        }
    }
}

