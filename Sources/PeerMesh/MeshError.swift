//
//  MeshError.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Errors that ``Mesh`` throws.
public enum MeshError: Error, Hashable, Sendable {

    /// The mesh is stopped: ``Mesh/start()`` wasn't called, or ``Mesh/stop()`` was called
    /// before the message was confirmed.
    case notRunning

    /// The message is larger than ``Mesh/maximumMessageSize``.
    case messageTooLarge

    /// The recipient didn't confirm the message before the timeout. It may still have
    /// received it.
    case timedOut

    /// This phone's identity couldn't be read from or saved to the keychain. `status` is the
    /// keychain's result code.
    case identityUnavailable(status: OSStatus)
}
