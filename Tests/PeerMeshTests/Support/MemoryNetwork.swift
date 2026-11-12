//
//  MemoryNetwork.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
@testable import PeerMesh

/// Phones that exchange frames in memory instead of over Bluetooth.
///
/// Tests decide which phones are in range of each other, and can change, drop or repeat
/// frames on their way.
@MainActor
final class MemoryNetwork {

    /// Changes each frame on its way from one phone to another. Return no frames to drop it,
    /// or several to repeat it.
    var tamper: ((_ frame: Data, _ sender: MemoryTransport, _ receiver: MemoryTransport) -> [Data])?

    /// Called right after a phone has handled a frame.
    var onDelivered: ((_ frame: Data, _ receiver: MemoryTransport) -> Void)?

    private struct Connection: Hashable {
        let central: UUID
        let peripheral: UUID
    }

    private var transports: [UUID: MemoryTransport] = [:]
    /// Pairs in range: the phone that connects, and the phone it connects to.
    private var ranges: Set<Connection> = []
    /// Open connections, with the sides that stopped using them.
    private var connections: [Connection: Set<UUID>] = [:]
    private var deliveries: [() -> Void] = []
    private var isDelivering = false

    func addPhone(
        _ name: String,
        service: String = "test",
        identity: Identity = Identity(),
        defaults: UserDefaults = .fresh()
    ) -> Phone {
        let transport = addTransport()
        let mesh = Mesh(service: service, name: name, identity: identity, transport: transport, defaults: defaults, timing: .fast)
        return Phone(mesh: mesh, transport: transport, identity: identity, defaults: defaults)
    }

    /// A transport without a mesh, for tests that play the other end of a link themselves.
    func addTransport() -> MemoryTransport {
        let transport = MemoryTransport(network: self)
        transports[transport.device] = transport
        return transport
    }

    /// Phones in a row, each in range of the next one only, all started.
    func line(_ names: String...) -> [Phone] {
        let phones = names.map { addPhone($0) }
        for (first, second) in zip(phones, phones.dropFirst()) {
            putInRange(first, second)
        }
        for phone in phones {
            phone.mesh.start()
        }
        return phones
    }

    /// Lets the first phone find and connect to the second. With `bothConnect`, each phone
    /// connects to the other, as when they find each other at the same moment.
    func putInRange(_ first: Phone, _ second: Phone, bothConnect: Bool = false) {
        putInRange(first.transport, second.transport)
        if bothConnect {
            putInRange(second.transport, first.transport)
        }
    }

    /// Lets one transport find and connect to the other.
    func putInRange(_ central: MemoryTransport, _ peripheral: MemoryTransport) {
        ranges.insert(Connection(central: central.device, peripheral: peripheral.device))
        schedule { self.connectPhonesInRange() }
    }

    /// The connections between two phones that both still use.
    func openConnections(between first: Phone, and second: Phone) -> Int {
        openConnections(between: first.transport, and: second.transport)
    }

    func openConnections(between first: MemoryTransport, and second: MemoryTransport) -> Int {
        let devices: Set = [first.device, second.device]
        return connections.filter { connection, closedSides in
            closedSides.isEmpty && devices == [connection.central, connection.peripheral]
        }.count
    }

    /// Delivers a frame again, as a relay would when replaying a frame it recorded.
    func replay(_ frame: Data, from sender: Phone, to receiver: Phone) {
        let devices: Set = [sender.transport.device, receiver.transport.device]
        guard let connection = connections.keys.first(where: { devices == [$0.central, $0.peripheral] }) else { return }
        let role: LinkRole = connection.central == receiver.transport.device ? .central : .peripheral
        let link = LinkID(device: sender.transport.device, role: role)
        let transport = receiver.transport
        schedule { transport.delegate?.transport(transport, didReceive: frame, on: link) }
    }

    // MARK: - Calls from transports

    func transportDidStart(_ transport: MemoryTransport) {
        schedule {
            transport.update(.ready)
            self.connectPhonesInRange()
        }
    }

    func transportDidStop(_ transport: MemoryTransport) {
        for connection in connections.keys where [connection.central, connection.peripheral].contains(transport.device) {
            disconnect(connection, closedBy: transport.device)
        }
    }

    func send(_ frame: Data, from sender: MemoryTransport, on link: LinkID) {
        let connection = Self.connection(of: sender.device, on: link)
        guard let closedSides = connections[connection], !closedSides.contains(sender.device),
              let receiver = transports[link.device]
        else { return }
        let receiverLink = LinkID(device: sender.device, role: link.role == .central ? .peripheral : .central)
        for frame in tamper?(frame, sender, receiver) ?? [frame] {
            schedule {
                guard let closedSides = self.connections[connection], !closedSides.contains(receiver.device) else { return }
                receiver.delegate?.transport(receiver, didReceive: frame, on: receiverLink)
                self.onDelivered?(frame, receiver)
            }
        }
    }

    func close(_ link: LinkID, of transport: MemoryTransport) {
        let connection = Self.connection(of: transport.device, on: link)
        switch link.role {
        case .central:
            disconnect(connection, closedBy: transport.device)
            schedule { self.connectPhonesInRange() }
        case .peripheral:
            // Like a Bluetooth peripheral, the phone can only stop using the connection.
            connections[connection]?.insert(transport.device)
        }
    }

    // MARK: - Connections

    private static func connection(of device: UUID, on link: LinkID) -> Connection {
        switch link.role {
        case .central: Connection(central: device, peripheral: link.device)
        case .peripheral: Connection(central: link.device, peripheral: device)
        }
    }

    private func connectPhonesInRange() {
        for range in ranges where connections[range] == nil {
            guard let central = transports[range.central],
                  let peripheral = transports[range.peripheral],
                  central.isRunning, peripheral.isRunning,
                  central.delegate?.transport(central, shouldConnectTo: peripheral.device) ?? false
            else { continue }
            connections[range] = []
            peripheral.delegate?.transport(peripheral, didOpen: LinkID(device: central.device, role: .peripheral))
            central.delegate?.transport(central, didOpen: LinkID(device: peripheral.device, role: .central))
        }
    }

    /// Ends a connection and tells the phones at its ends, except the one that ended it.
    private func disconnect(_ connection: Connection, closedBy closer: UUID) {
        guard let closedSides = connections.removeValue(forKey: connection) else { return }
        let ends = [
            (device: connection.central, link: LinkID(device: connection.peripheral, role: .central)),
            (device: connection.peripheral, link: LinkID(device: connection.central, role: .peripheral)),
        ]
        for end in ends where end.device != closer && !closedSides.contains(end.device) {
            guard let transport = transports[end.device] else { continue }
            schedule { transport.delegate?.transport(transport, didClose: end.link) }
        }
    }

    /// Runs deliveries one after another, after the current call returns, the way Bluetooth
    /// callbacks arrive.
    private func schedule(_ delivery: @escaping () -> Void) {
        deliveries.append(delivery)
        guard !isDelivering else { return }
        isDelivering = true
        Task {
            while !self.deliveries.isEmpty {
                self.deliveries.removeFirst()()
            }
            self.isDelivering = false
        }
    }
}

/// A transport whose phones are connected by a ``MemoryNetwork``.
@MainActor
final class MemoryTransport: Transport {
    weak var delegate: (any TransportDelegate)?
    private(set) var state: TransportState = .starting
    let device = UUID()
    private(set) var isRunning = false
    private weak var network: MemoryNetwork?

    init(network: MemoryNetwork) {
        self.network = network
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        network?.transportDidStart(self)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        state = .starting
        network?.transportDidStop(self)
    }

    func send(_ frame: Data, on link: LinkID, priority: FramePriority) {
        network?.send(frame, from: self, on: link)
    }

    func close(_ link: LinkID) {
        network?.close(link, of: self)
    }

    /// Changes the Bluetooth state, as when the user turns Bluetooth off.
    func update(_ state: TransportState) {
        guard isRunning else { return }
        self.state = state
        delegate?.transportDidChangeState(self)
    }
}

/// The other end of a link that claims to be another phone: it sends that phone's public key
/// in its hello, but can't prove that it holds the matching private key.
@MainActor
final class Impostor: TransportDelegate {
    let transport: MemoryTransport
    private let claimedPublicKey: Data

    init(network: MemoryNetwork, claiming publicKey: Data) {
        transport = network.addTransport()
        claimedPublicKey = publicKey
        transport.delegate = self
        transport.start()
    }

    func transportDidChangeState(_ transport: any Transport) {}

    func transport(_ transport: any Transport, didOpen link: LinkID) {
        let hello = Hello(publicKey: claimedPublicKey, nonce: Data(repeating: 1, count: Frame.nonceLength), name: "Bea")
        transport.send(Frame.hello(hello).encoded(), on: link, priority: .control)
    }

    func transport(_ transport: any Transport, didReceive frame: Data, on link: LinkID) {
        guard case .hello? = try? Frame(decoding: frame) else { return }
        transport.send(Frame.proof(Data(repeating: 2, count: Frame.proofLength)).encoded(), on: link, priority: .control)
    }

    func transport(_ transport: any Transport, didClose link: LinkID) {}

    func transport(_ transport: any Transport, shouldConnectTo device: UUID) -> Bool {
        true
    }
}
