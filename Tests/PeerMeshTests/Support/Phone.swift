//
//  Phone.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
@testable import PeerMesh

/// A mesh in a ``MemoryNetwork``, with the messages it has received so far.
@MainActor
final class Phone {
    let mesh: Mesh
    let transport: MemoryTransport
    let identity: Identity
    let defaults: UserDefaults
    private(set) var messages: [Message] = []

    var id: PeerID {
        mesh.id
    }

    init(mesh: Mesh, transport: MemoryTransport, identity: Identity, defaults: UserDefaults) {
        self.mesh = mesh
        self.transport = transport
        self.identity = identity
        self.defaults = defaults
        let stream = mesh.messages
        Task { [weak self] in
            for await message in stream {
                self?.messages.append(message)
            }
        }
    }

    func canReach(_ other: Phone, hops: Int? = nil) -> Bool {
        mesh.peers.contains { $0.id == other.id && (hops == nil || $0.hops == hops) }
    }
}

extension Timing {
    static let fast = Timing(
        shortestAnnouncementInterval: .milliseconds(100),
        longestAnnouncementInterval: .milliseconds(200),
        routeGrace: .milliseconds(100),
        maintenanceInterval: .milliseconds(20),
        identificationTimeout: .milliseconds(500),
        firstRetransmission: .milliseconds(150),
        retransmissionPerHop: .milliseconds(30),
        longestRetransmission: .milliseconds(600),
        bytesPerSecond: 10_000_000
    )
}

extension UserDefaults {
    static func fresh() -> UserDefaults {
        UserDefaults(suiteName: "PeerMeshTests.\(UUID().uuidString)")!
    }
}

/// Waits until `condition` holds, checking every 10 milliseconds. Returns `false` if it
/// doesn't hold in time.
@MainActor
func eventually(within timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Keeps a private key in memory instead of the keychain.
final class MemoryKeyStore: KeyStore {
    var key: Data?

    func read() throws -> Data? {
        key
    }

    func write(_ key: Data) throws {
        self.key = key
    }
}
