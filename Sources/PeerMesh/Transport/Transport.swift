//
//  Transport.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// One connection between this phone and a phone in range.
struct LinkID: Hashable, Sendable {
    /// The other phone's Bluetooth identifier.
    let device: UUID
    /// This phone's side of the connection.
    let role: LinkRole
}

enum LinkRole: Hashable, Sendable {
    /// This phone connected to the other one.
    case central
    /// The other phone connected to this one.
    case peripheral
}

enum TransportState: Hashable, Sendable {
    case starting
    case ready
    case poweredOff
    case unauthorized
    case unsupported
}

/// Which frames go first when a link is busy.
enum FramePriority: Hashable, Sendable {
    /// Hellos, proofs, announcements and acknowledgements: small, and needed to keep the mesh
    /// working.
    case control
    /// Messages, which can be large.
    case message
}

/// Carries frames between this phone and the phones in range of it.
@MainActor
protocol Transport: AnyObject {
    var delegate: (any TransportDelegate)? { get set }
    var state: TransportState { get }

    func start()
    func stop()

    /// Sends a frame. Frames of the same priority sent on a link arrive in order, and none get
    /// lost while the link stays open. A frame that's identical to one still waiting to go out
    /// on the link may be dropped.
    func send(_ frame: Data, on link: LinkID, priority: FramePriority)

    /// Stops using a link. The delegate might still be told that it closed.
    func close(_ link: LinkID)
}

@MainActor
protocol TransportDelegate: AnyObject {
    func transportDidChangeState(_ transport: any Transport)
    func transport(_ transport: any Transport, didOpen link: LinkID)
    func transport(_ transport: any Transport, didReceive frame: Data, on link: LinkID)
    func transport(_ transport: any Transport, didClose link: LinkID)

    /// Asked before connecting to a phone that was found in range.
    func transport(_ transport: any Transport, shouldConnectTo device: UUID) -> Bool
}
