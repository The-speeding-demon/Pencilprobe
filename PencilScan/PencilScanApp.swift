import SwiftUI
import CoreBluetooth
import AppKit

// PencilScan: a Bluetooth LE scanner for macOS.
// Lists every nearby device that is advertising, and can connect to one and
// dump every service, characteristic and readable value it exposes.

@main
struct PencilScanApp: App {
    var body: some Scene {
        WindowGroup("PencilScan") {
            ContentView()
                .frame(minWidth: 860, minHeight: 540)
        }
    }
}

struct Device: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var connectable: Bool
    var manufacturer: String
    var isApple: Bool
    var services: [String]
    var lastSeen: Date

    var hasName: Bool { name != Device.noName }
    var looksLikePencil: Bool { name.localizedCaseInsensitiveContains("pencil") }

    static let noName = "(no name)"
}

final class BLEScanner: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [Device] = []
    @Published var status = "Starting Bluetooth…"
    @Published var log = ""
    @Published var connectedID: UUID?
    @Published var autoConnect = true

    private var central: CBCentralManager!
    private var found: [UUID: Device] = [:]
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var refreshTimer: Timer?
    private var connectTimeout: Timer?
    private var pendingID: UUID?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.publish()
        }
    }

    // MARK: Scanning

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            status = "Scanning…"
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        case .poweredOff:
            status = "Bluetooth is turned off"
        case .unauthorized:
            status = "No Bluetooth permission. Allow PencilScan in System Settings > Privacy & Security > Bluetooth"
        case .unsupported:
            status = "This Mac does not support Bluetooth LE"
        default:
            status = "Waiting for Bluetooth…"
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = peripheral.name ?? advertisedName ?? Device.noName

        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let bytes = manufacturerData.map { [UInt8]($0) } ?? []
        let isApple = bytes.count >= 2 && bytes[0] == 0x4C && bytes[1] == 0x00

        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let connectable = (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? false

        let isNew = found[peripheral.identifier] == nil
        peripherals[peripheral.identifier] = peripheral
        defer {
            // The Pencil changes its Bluetooth identity often, so try the moment a new one shows up.
            if isNew, found[peripheral.identifier]?.looksLikePencil == true {
                write("Apple Pencil is broadcasting as \(peripheral.identifier.uuidString.prefix(8)) (\(RSSI.intValue) dBm)")
                if autoConnect && connectedID == nil {
                    connect(peripheral.identifier)
                }
            }
        }
        found[peripheral.identifier] = Device(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue,
            connectable: connectable,
            manufacturer: Self.hex(Data(bytes)),
            isApple: isApple,
            services: serviceUUIDs.map { "\($0)" },
            lastSeen: Date()
        )
    }

    private func publish() {
        let cutoff = Date().addingTimeInterval(-30)
        devices = found.values
            .filter { $0.lastSeen > cutoff || $0.id == connectedID }
            .sorted {
                if $0.looksLikePencil != $1.looksLikePencil { return $0.looksLikePencil }
                if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
                return $0.id.uuidString < $1.id.uuidString
            }
        if central.state == .poweredOn {
            status = "Scanning… \(devices.count) devices nearby"
        }
    }

    // MARK: Connecting

    func connect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        write("Connecting to \(found[id]?.name ?? "device") \(id.uuidString)…")
        if let old = pendingID, old != id, let stale = peripherals[old] {
            central.cancelPeripheralConnection(stale)
        }
        pendingID = id
        peripheral.delegate = self
        central.connect(peripheral)

        connectTimeout?.invalidate()
        connectTimeout = Timer.scheduledTimer(withTimeInterval: 12, repeats: false) { [weak self] _ in
            guard let self = self, self.connectedID != id, self.pendingID == id else { return }
            self.pendingID = nil
            self.central.cancelPeripheralConnection(peripheral)
            self.write("Timed out: the device did not accept a connection within 12 seconds.")
        }
    }

    func disconnect() {
        guard let id = connectedID, let peripheral = peripherals[id] else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectTimeout?.invalidate()
        pendingID = nil
        connectedID = peripheral.identifier
        write("Connected. Discovering services…")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        connectTimeout?.invalidate()
        write("Failed to connect: \(error?.localizedDescription ?? "no reason given")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if connectedID == peripheral.identifier { connectedID = nil }
        write("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ".")")
    }

    // MARK: Reading

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            write("Service discovery failed: \(error.localizedDescription)")
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            write("The device exposes no services.")
        }
        for service in services {
            write("Service \(service.uuid) [\(service.uuid.uuidString)]")
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            write("Characteristics of \(service.uuid) failed: \(error.localizedDescription)")
            return
        }
        for characteristic in service.characteristics ?? [] {
            let properties = characteristic.properties
            var flags: [String] = []
            if properties.contains(.read) { flags.append("read") }
            if properties.contains(.write) { flags.append("write") }
            if properties.contains(.writeWithoutResponse) { flags.append("write-no-response") }
            if properties.contains(.notify) { flags.append("notify") }
            if properties.contains(.indicate) { flags.append("indicate") }
            write("  \(service.uuid) > \(characteristic.uuid) [\(characteristic.uuid.uuidString)] (\(flags.joined(separator: ", ")))")

            if properties.contains(.read) {
                peripheral.readValue(for: characteristic)
            }
            if properties.contains(.notify) || properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            write("  \(characteristic.uuid): read failed: \(error.localizedDescription)")
            return
        }
        let data = characteristic.value ?? Data()
        var line = "  \(characteristic.uuid) = \(Self.hex(data))"
        if characteristic.uuid == CBUUID(string: "2A19"), let level = data.first {
            line += "  (battery \(level)%)"
        } else if let text = Self.printableText(data) {
            line += "  \"\(text)\""
        }
        write(line)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            write("  \(characteristic.uuid): subscribe failed: \(error.localizedDescription)")
        }
    }

    // MARK: Helpers

    func clearLog() {
        log = ""
    }

    private func write(_ line: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        log += "\(time)  \(line)\n"
    }

    private static func hex(_ data: Data) -> String {
        data.isEmpty ? "(empty)" : data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func printableText(_ data: Data) -> String? {
        guard !data.isEmpty,
              data.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }
}

struct ContentView: View {
    @StateObject private var scanner = BLEScanner()
    @State private var selection: UUID?
    @State private var namedOnly = false
    @State private var appleOnly = false

    private var shown: [Device] {
        scanner.devices.filter { (!namedOnly || $0.hasName) && (!appleOnly || $0.isApple) }
    }

    private var selected: Device? {
        scanner.devices.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            deviceList
                .frame(minWidth: 330, idealWidth: 360)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding()
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(scanner.status)
                .font(.headline)
            Text("Strongest signal first. Hold the Pencil against the Mac and look for a device near the top.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Toggle("Named only", isOn: $namedOnly)
                Toggle("Apple only", isOn: $appleOnly)
            }
            Toggle("Auto-connect to Apple Pencil the moment it appears", isOn: $scanner.autoConnect)
            List(shown, selection: $selection) { device in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .fontWeight(device.looksLikePencil ? .bold : .regular)
                            .foregroundColor(device.looksLikePencil ? .green : .primary)
                        Text(device.id.uuidString.prefix(8) + (device.isApple ? " · Apple" : "") + (device.connectable ? "" : " · not connectable"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text("\(device.rssi) dBm")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let device = selected {
                Text(device.name).font(.title3.bold())
                Group {
                    Text("ID: \(device.id.uuidString)")
                    Text("Signal: \(device.rssi) dBm, connectable: \(device.connectable ? "yes" : "no")")
                    Text("Manufacturer data: \(device.manufacturer)")
                    Text("Advertised services: \(device.services.isEmpty ? "none" : device.services.joined(separator: ", "))")
                }
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)

                HStack {
                    Button("Connect and read everything") { scanner.connect(device.id) }
                        .disabled(scanner.connectedID == device.id)
                    Button("Disconnect") { scanner.disconnect() }
                        .disabled(scanner.connectedID == nil)
                }
            } else {
                Text("Select a device on the left")
                    .foregroundColor(.secondary)
            }

            Divider()

            HStack {
                Text("Log").font(.headline)
                Spacer()
                Button("Copy log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(scanner.log, forType: .string)
                }
                Button("Clear") { scanner.clearLog() }
            }

            ScrollView {
                Text(scanner.log.isEmpty ? "Nothing yet." : scanner.log)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
