//
//  Mesh+State.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

extension Mesh {

    /// Whether a mesh is running and, if it isn't, why.
    public enum State: Hashable, Sendable {

        /// The mesh isn't running. Call ``Mesh/start()``.
        case stopped

        /// Waiting for Bluetooth to be ready, or for the user to answer the Bluetooth
        /// permission prompt.
        case starting

        /// Finding nearby phones, connecting to them and passing messages.
        case running

        /// Bluetooth is turned off. The mesh starts again by itself when it's turned back on.
        case bluetoothOff

        /// The user didn't allow this app to use Bluetooth, or a restriction such as Screen
        /// Time blocks it. The user can allow it in Settings.
        case bluetoothDenied

        /// This device can't use Bluetooth Low Energy, for example the Simulator.
        case unsupported
    }
}
