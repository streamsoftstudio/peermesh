//
//  Message.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// A message that another phone sent to this phone.
public struct Message: Sendable {

    /// The phone that sent the message.
    public let sender: Peer

    /// The message, exactly as the sender passed it to ``Mesh/send(_:to:timeout:)``.
    public let data: Data
}
