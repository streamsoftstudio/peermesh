//
//  BluetoothTransport.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import CoreBluetooth
import CryptoKit
import Foundation

/// Carries frames over Bluetooth Low Energy.
///
/// Every phone advertises the same service and scans for it at the same time. A phone that
/// finds another connects to it and subscribes to the service's only characteristic. From then
/// on it writes its frames to that characteristic, and the other phone sends frames back as
/// notifications.
@MainActor
final class BluetoothTransport: NSObject, Transport {

    weak var delegate: (any TransportDelegate)?
    private(set) var state: TransportState = .starting

    private let serviceUUID: CBUUID
    private let characteristicUUID = BluetoothTransport.uuid(named: "PeerMesh characteristic")
    private let maximumOutgoingConnections: Int

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var characteristic: CBMutableCharacteristic?
    private var isServiceAdded = false
    private var lastScan = ContinuousClock.now
    private var lastMaintenance = ContinuousClock.now
    private var maintenance: Task<Void, Never>?

    /// Connections this phone opened, by the other phone's Bluetooth identifier.
    private var outgoing: [UUID: OutgoingConnection] = [:]
    /// Connections other phones opened to this one.
    private var incoming: [UUID: IncomingConnection] = [:]

    init(service: String, maximumOutgoingConnections: Int = 6) {
        serviceUUID = Self.uuid(named: "PeerMesh service \(service)")
        self.maximumOutgoingConnections = maximumOutgoingConnections
        super.init()
    }

    /// A UUID derived from a name, so every phone arrives at the same one.
    nonisolated static func uuid(named name: String) -> CBUUID {
        var bytes = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return CBUUID(data: Data(bytes))
    }

    // MARK: - Transport

    func start() {
        guard centralManager == nil else { return }
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false]
        )
        peripheralManager = CBPeripheralManager(
            delegate: self,
            queue: nil,
            options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
        )
        lastMaintenance = .now
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.maintain()
            }
        }
    }

    func stop() {
        maintenance?.cancel()
        maintenance = nil
        if let centralManager {
            centralManager.stopScan()
            for connection in outgoing.values {
                centralManager.cancelPeripheralConnection(connection.peripheral)
            }
            centralManager.delegate = nil
        }
        if let peripheralManager {
            peripheralManager.stopAdvertising()
            peripheralManager.removeAllServices()
            peripheralManager.delegate = nil
        }
        centralManager = nil
        peripheralManager = nil
        characteristic = nil
        isServiceAdded = false
        outgoing = [:]
        incoming = [:]
        state = .starting
    }

    func send(_ frame: Data, on link: LinkID, priority: FramePriority) {
        switch link.role {
        case .central:
            guard let connection = outgoing[link.device], connection.isOpen else { return }
            connection.queue.append(frame, priority: priority)
            write(connection)
        case .peripheral:
            guard let connection = incoming[link.device], !connection.isClosed else { return }
            connection.queue.append(frame, priority: priority)
            notifySubscribers()
        }
    }

    func close(_ link: LinkID) {
        switch link.role {
        case .central:
            guard let connection = outgoing[link.device] else { return }
            // Keep the connection until it's gone, so the phone isn't found and connected to
            // again in the meantime.
            connection.isOpen = false
            connection.isClosing = true
            connection.queue.removeAll()
            centralManager?.cancelPeripheralConnection(connection.peripheral)
        case .peripheral:
            // A peripheral can't disconnect a central. It ignores the connection instead,
            // until the central disconnects or subscribes again.
            incoming[link.device]?.close()
        }
    }

    // MARK: - Sending

    private func write(_ connection: OutgoingConnection) {
        guard let characteristic = connection.characteristic else { return }
        let chunkLength = connection.peripheral.maximumWriteValueLength(for: .withoutResponse)
        while connection.peripheral.canSendWriteWithoutResponse,
              let chunk = connection.queue.nextChunk(maximumLength: chunkLength) {
            connection.peripheral.writeValue(chunk, for: characteristic, type: .withoutResponse)
            connection.queue.removeChunk()
        }
    }

    /// Sends notifications to the phones connected to this one, a chunk at a time to each in
    /// turn, so that one busy connection doesn't hold up the others.
    private func notifySubscribers() {
        guard let peripheralManager, let characteristic else { return }
        var hasSent = true
        while hasSent {
            hasSent = false
            for connection in incoming.values {
                let chunkLength = connection.central.maximumUpdateValueLength
                guard let chunk = connection.queue.nextChunk(maximumLength: chunkLength) else { continue }
                // A full queue makes the manager call peripheralManagerIsReady(toUpdateSubscribers:).
                guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [connection.central]) else {
                    return
                }
                connection.queue.removeChunk()
                hasSent = true
            }
        }
    }

    // MARK: - Housekeeping

    /// Runs on a timer, and from Bluetooth callbacks, because the timer doesn't fire while the
    /// app is in the background.
    private func maintainIfDue() {
        if ContinuousClock.now - lastMaintenance >= .seconds(5) {
            maintain()
        }
    }

    /// Gives up on connections that don't complete, retries publishing the service, and
    /// restarts scanning now and then: a scan reports each phone only once, so phones that
    /// weren't connected to need a new scan.
    private func maintain() {
        let now = ContinuousClock.now
        lastMaintenance = now
        for (device, connection) in outgoing
        where !connection.isOpen && !connection.isClosing && now - connection.started > .seconds(15) {
            outgoing[device] = nil
            centralManager?.cancelPeripheralConnection(connection.peripheral)
        }
        if peripheralManager?.state == .poweredOn, !isServiceAdded {
            addService()
        }
        if now - lastScan > .seconds(20) {
            scan()
        }
    }

    private func scan() {
        guard let centralManager, centralManager.state == .poweredOn else { return }
        centralManager.stopScan()
        centralManager.scanForPeripherals(withServices: [serviceUUID])
        lastScan = .now
    }

    private func updateState() {
        let managerStates = [centralManager?.state, peripheralManager?.state].compactMap { $0 }
        let newState: TransportState
        if managerStates.contains(.unsupported) {
            newState = .unsupported
        } else if managerStates.contains(.unauthorized) || [.denied, .restricted].contains(CBManager.authorization) {
            newState = .unauthorized
        } else if managerStates.contains(.poweredOff) {
            newState = .poweredOff
        } else if managerStates.count == 2, managerStates.allSatisfy({ $0 == .poweredOn }) {
            newState = .ready
        } else {
            newState = .starting
        }
        guard newState != state else { return }
        state = newState
        delegate?.transportDidChangeState(self)
    }

    private func dropOutgoing(_ device: UUID) {
        guard let connection = outgoing.removeValue(forKey: device), connection.isOpen else { return }
        delegate?.transport(self, didClose: LinkID(device: device, role: .central))
    }

    private func dropIncoming(_ device: UUID) {
        guard let connection = incoming.removeValue(forKey: device), !connection.isClosed else { return }
        delegate?.transport(self, didClose: LinkID(device: device, role: .peripheral))
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothTransport: @preconcurrency CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        } else {
            for device in outgoing.keys {
                dropOutgoing(device)
            }
        }
        updateState()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        maintainIfDue()
        let device = peripheral.identifier
        guard outgoing[device] == nil,
              outgoing.count < maximumOutgoingConnections,
              delegate?.transport(self, shouldConnectTo: device) ?? false
        else { return }
        outgoing[device] = OutgoingConnection(peripheral: peripheral)
        peripheral.delegate = self
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        maintainIfDue()
        guard let connection = outgoing[peripheral.identifier], !connection.isClosing else {
            return central.cancelPeripheralConnection(peripheral)
        }
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        dropOutgoing(peripheral.identifier)
        scan()
        maintainIfDue()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        dropOutgoing(peripheral.identifier)
        scan()
        maintainIfDue()
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothTransport: @preconcurrency CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            return disconnect(peripheral)
        }
        peripheral.discoverCharacteristics([characteristicUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard let connection = outgoing[peripheral.identifier],
              let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID })
        else { return disconnect(peripheral) }
        connection.characteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard let connection = outgoing[peripheral.identifier], !connection.isOpen, !connection.isClosing else { return }
        guard error == nil, characteristic.isNotifying else { return disconnect(peripheral) }
        connection.isOpen = true
        delegate?.transport(self, didOpen: LinkID(device: peripheral.identifier, role: .central))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        maintainIfDue()
        guard let connection = outgoing[peripheral.identifier], connection.isOpen, let chunk = characteristic.value else {
            return
        }
        let link = LinkID(device: peripheral.identifier, role: .central)
        do {
            for frame in try connection.assembler.append(chunk) {
                delegate?.transport(self, didReceive: frame, on: link)
            }
        } catch {
            disconnect(peripheral)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let connection = outgoing[peripheral.identifier] else { return }
        write(connection)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == serviceUUID }) {
            disconnect(peripheral)
        }
    }

    private func disconnect(_ peripheral: CBPeripheral) {
        centralManager?.cancelPeripheralConnection(peripheral)
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BluetoothTransport: @preconcurrency CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            addService()
        } else {
            isServiceAdded = false
            for device in incoming.keys {
                dropIncoming(device)
            }
        }
        updateState()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: (any Error)?) {
        guard error == nil else {
            isServiceAdded = false
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        maintainIfDue()
        let device = central.identifier
        dropIncoming(device)
        incoming[device] = IncomingConnection(central: central)
        delegate?.transport(self, didOpen: LinkID(device: device, role: .peripheral))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        dropIncoming(central.identifier)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        maintainIfDue()
        for request in requests {
            let device = request.central.identifier
            guard let connection = incoming[device], !connection.isClosed, let chunk = request.value else { continue }
            let link = LinkID(device: device, role: .peripheral)
            do {
                for frame in try connection.assembler.append(chunk) {
                    delegate?.transport(self, didReceive: frame, on: link)
                }
            } catch {
                connection.close()
                delegate?.transport(self, didClose: link)
            }
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        notifySubscribers()
    }

    private func addService() {
        guard let peripheralManager, !isServiceAdded else { return }
        // Services published before Bluetooth was turned off are still there when it comes
        // back on, so start over rather than publish the service twice.
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()
        let characteristic = CBMutableCharacteristic(
            type: characteristicUUID,
            properties: [.writeWithoutResponse, .notify],
            value: nil,
            permissions: [.writeable]
        )
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]
        self.characteristic = characteristic
        isServiceAdded = true
        peripheralManager.add(service)
    }
}

// MARK: - Connections

/// A connection this phone opened to another phone.
@MainActor
private final class OutgoingConnection {
    let peripheral: CBPeripheral
    let started = ContinuousClock.now
    var characteristic: CBCharacteristic?
    var isOpen = false
    /// Set when this phone ends the connection, until Core Bluetooth confirms it's gone.
    var isClosing = false
    var assembler = FrameAssembler()
    var queue = LinkQueue()

    init(peripheral: CBPeripheral) {
        self.peripheral = peripheral
    }
}

/// A connection another phone opened to this one.
@MainActor
private final class IncomingConnection {
    let central: CBCentral
    var assembler = FrameAssembler()
    var queue = LinkQueue()
    private(set) var isClosed = false

    init(central: CBCentral) {
        self.central = central
    }

    func close() {
        isClosed = true
        queue.removeAll()
    }
}
