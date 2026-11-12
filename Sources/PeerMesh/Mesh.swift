//
//  Mesh.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Sends messages between nearby phones over Bluetooth, without a Wi-Fi network, an
/// internet connection or pairing.
///
/// Phones whose apps create a mesh with the same service name find each other and
/// connect on their own. A message for a phone that's out of Bluetooth range is passed
/// along by other phones in the mesh, across at most ``maximumHops`` links. Messages are
/// encrypted end to end, so the phones that pass a message along can't read or change it.
///
/// ```swift
/// let mesh = try Mesh(service: "com.example.chess", name: "Andrija")
/// mesh.start()
///
/// // Everyone reachable: the current list first, then the new list after every change.
/// for await peers in mesh.peerUpdates {
///     print(peers.map(\.name))
/// }
///
/// // Returns once the opponent's phone confirms that it received the move.
/// try await mesh.send(move, to: opponent.id)
///
/// // Messages from other phones.
/// for await message in mesh.messages {
///     print(message.sender.name, message.data)
/// }
/// ```
///
/// The app's Info.plist needs `NSBluetoothAlwaysUsageDescription`. To keep working while
/// the app is in the background or the screen is locked, it also needs the
/// `bluetooth-central` and `bluetooth-peripheral` background modes.
@MainActor
public final class Mesh {

    /// The largest message, in bytes, that ``send(_:to:timeout:)`` accepts.
    public nonisolated static let maximumMessageSize = 16 * 1024

    /// The most links a message can cross on its way to its recipient.
    ///
    /// A message that crosses seven links passes through six other phones.
    public nonisolated static let maximumHops = 7

    /// The service name the mesh was created with.
    public nonisolated let service: String

    /// The name other phones see for this phone.
    public nonisolated let name: String

    /// This phone's identity, the one other phones see as ``Peer/id``.
    ///
    /// It's kept in the keychain and stays the same across app launches.
    public nonisolated let id: PeerID

    /// Whether the mesh is running and, if it isn't, why.
    public private(set) var state: State = .stopped

    /// Yields ``state`` straight away, then again each time it changes.
    ///
    /// Each access returns a new stream.
    public var stateUpdates: AsyncStream<State> {
        stateBroadcast.stream(startingWith: state)
    }

    /// Everyone reachable right now, in Bluetooth range or through other phones, sorted by
    /// name. This phone isn't included.
    public private(set) var peers: [Peer] = []

    /// Yields ``peers`` straight away, then again each time the list changes.
    ///
    /// Each access returns a new stream.
    public var peerUpdates: AsyncStream<[Peer]> {
        peerBroadcast.stream(startingWith: peers)
    }

    /// Messages that other phones sent to this phone.
    ///
    /// Read it from one place only. Messages that arrive before you start reading are kept
    /// until you do.
    public nonisolated let messages: AsyncStream<Message>

    private let node: Node
    private nonisolated let messageContinuation: AsyncStream<Message>.Continuation
    private nonisolated let stateBroadcast = Broadcast<State>()
    private nonisolated let peerBroadcast = Broadcast<[Peer]>()

    /// Creates a mesh for a service. Call ``start()`` to begin connecting to nearby phones.
    ///
    /// - Parameters:
    ///   - service: The name of your app's mesh, such as `"com.example.chess"`. Phones only
    ///     connect to phones that use exactly the same service name, so pick one that other
    ///     apps won't use by accident.
    ///   - name: The name other phones see, such as the player's name. Names longer than 64
    ///     bytes of UTF-8 are shortened. Anyone can choose any name, so use ``Peer/id`` to
    ///     recognize people.
    /// - Throws: ``MeshError/identityUnavailable(status:)`` if this phone's identity can't be
    ///   read from or saved to the keychain.
    public convenience init(service: String, name: String) throws {
        try self.init(
            service: service,
            name: name,
            identity: Identity.load(from: KeychainKeyStore()),
            transport: BluetoothTransport(service: service),
            defaults: UserDefaults(suiteName: "PeerMesh") ?? .standard,
            timing: .standard
        )
    }

    init(service: String, name: String, identity: Identity, transport: any Transport, defaults: UserDefaults, timing: Timing) {
        self.service = service
        self.name = name.truncated(toUTF8Length: Frame.maximumNameLength)
        id = identity.id
        let (messages, continuation) = AsyncStream.makeStream(of: Message.self)
        self.messages = messages
        messageContinuation = continuation
        node = Node(
            service: service,
            identity: identity,
            name: self.name,
            transport: transport,
            defaults: defaults,
            timing: timing
        )
        node.delegate = self
    }

    deinit {
        messageContinuation.finish()
        stateBroadcast.finish()
        peerBroadcast.finish()
    }

    /// Starts finding and connecting to nearby phones.
    ///
    /// The first call shows the system's Bluetooth permission prompt if the user hasn't
    /// answered it yet. Follow ``state`` to learn when the mesh is running, or why it isn't.
    /// Calling `start()` on a started mesh does nothing.
    public func start() {
        node.start()
    }

    /// Disconnects from every phone and stops the mesh.
    ///
    /// Sends that are still in progress throw ``MeshError/notRunning``. You can call
    /// ``start()`` again afterwards.
    public func stop() {
        node.stop()
    }

    /// Sends a message to a peer and waits until the peer's phone confirms that it received
    /// it.
    ///
    /// The message goes straight to the peer when it's in range, and through other phones
    /// when it isn't. If the peer can't be reached, the mesh keeps trying until the timeout,
    /// so a peer that comes back in range in time still gets the message.
    ///
    /// Messages to the same peer arrive in the order they were sent, and each arrives at
    /// most once.
    ///
    /// - Parameters:
    ///   - data: The message, at most ``maximumMessageSize`` bytes.
    ///   - peer: Who to send it to.
    ///   - timeout: How long to keep trying.
    /// - Throws: ``MeshError/messageTooLarge`` if `data` is larger than
    ///   ``maximumMessageSize``, ``MeshError/notRunning`` if the mesh is stopped or gets
    ///   stopped before the message is confirmed, ``MeshError/timedOut`` if no confirmation
    ///   arrives in time, and `CancellationError` if the calling task is cancelled. After a
    ///   timeout or a cancellation, the peer may or may not have received the message.
    public func send(_ data: Data, to peer: PeerID, timeout: Duration = .seconds(30)) async throws {
        try await node.send(data, to: peer, timeout: timeout)
    }
}

// MARK: - NodeDelegate

extension Mesh: NodeDelegate {

    func node(_ node: Node, didChangeState state: State) {
        guard state != self.state else { return }
        self.state = state
        stateBroadcast.yield(state)
    }

    func node(_ node: Node, didChangePeers peers: [Peer]) {
        self.peers = peers
        peerBroadcast.yield(peers)
    }

    func node(_ node: Node, didReceive message: Message) {
        messageContinuation.yield(message)
    }
}
