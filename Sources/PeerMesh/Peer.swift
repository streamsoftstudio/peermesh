//
//  Peer.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

/// Another phone in the mesh.
public struct Peer: Identifiable, Hashable, Sendable {

    /// The phone's identity. It stays the same across app launches, so you can store it to
    /// recognize the same person later.
    public let id: PeerID

    /// The name the other phone's app passed to ``Mesh/init(service:name:)``.
    ///
    /// Anyone can choose any name. Use ``id`` to tell people apart.
    public let name: String

    /// How many links a message crosses to reach this peer. `1` means the peer is in
    /// Bluetooth range of this phone.
    public let hops: Int
}
