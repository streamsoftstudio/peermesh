//
//  Node.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import CryptoKit
import Foundation

@MainActor
protocol NodeDelegate: AnyObject {
    func node(_ node: Node, didChangeState state: Mesh.State)
    func node(_ node: Node, didChangePeers peers: [Peer])
    func node(_ node: Node, didReceive message: Message)
}

/// This phone's part of the mesh.
///
/// It checks who is at the other end of each link, keeps track of which link leads to which
/// phone, passes frames on for other phones, and sends and receives messages.
@MainActor
final class Node {

    weak var delegate: (any NodeDelegate)?

    let identity: Identity
    let name: String

    private let serviceTag: Data
    private let transport: any Transport
    private let timing: Timing
    private var table: RoutingTable
    private var counter: MessageCounter
    private var deliveries: DeliveryLog

    private var isRunning = false
    /// Changes on every start and stop, so a send can tell that the mesh stopped while it waited.
    private var generation = 0
    private var maintenance: Task<Void, Never>?
    private var lastMaintenance = ContinuousClock.now

    private var links: [LinkID: Link] = [:]
    /// The phones behind the Bluetooth devices this phone has had links with, so it doesn't
    /// connect to a phone it's already linked to.
    private var devices: [UUID: PeerID] = [:]
    private var pairwiseKeys: [PeerID: PairwiseKeys] = [:]

    private var ownAnnouncement: Announcement?
    private var nextAnnouncement = ContinuousClock.now
    /// The best copy of each phone's newest announcement and when it arrived, for bringing new
    /// neighbors up to date.
    private var announcements: [PeerID: (announcement: Announcement, received: ContinuousClock.Instant)] = [:]
    private var peers: [Peer] = []

    private var turnstiles: [PeerID: Turnstile] = [:]
    /// The message being sent to each peer. There's at most one per peer, which keeps messages
    /// in order.
    private var outgoing: [PeerID: Outgoing] = [:]

    init(service: String, identity: Identity, name: String, transport: any Transport, defaults: UserDefaults, timing: Timing) {
        serviceTag = Data(serviceTag: service)
        self.identity = identity
        self.name = name
        self.transport = transport
        self.timing = timing
        table = RoutingTable(grace: timing.routeGrace, defaultInterval: timing.shortestAnnouncementInterval)
        counter = MessageCounter(defaults: defaults)
        deliveries = DeliveryLog(defaults: defaults, service: service)
        transport.delegate = self
    }

    // MARK: - Starting and stopping

    func start() {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        nextAnnouncement = .now
        lastMaintenance = .now
        transport.start()
        delegate?.node(self, didChangeState: Self.state(for: transport.state))
        maintenance = Task { [weak self, interval = timing.maintenanceInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.maintain()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        generation += 1
        maintenance?.cancel()
        maintenance = nil
        transport.stop()
        links = [:]
        table = RoutingTable(grace: timing.routeGrace, defaultInterval: timing.shortestAnnouncementInterval)
        ownAnnouncement = nil
        announcements = [:]
        for pending in outgoing.values {
            pending.waiter.wake()
        }
        routesChanged()
        delegate?.node(self, didChangeState: .stopped)
    }

    private static func state(for transportState: TransportState) -> Mesh.State {
        switch transportState {
        case .starting: .starting
        case .ready: .running
        case .poweredOff: .bluetoothOff
        case .unauthorized: .bluetoothDenied
        case .unsupported: .unsupported
        }
    }

    // MARK: - Sending

    func send(_ data: Data, to destination: PeerID, timeout: Duration) async throws {
        guard data.count <= Mesh.maximumMessageSize else { throw MeshError.messageTooLarge }
        guard isRunning else { throw MeshError.notRunning }
        let deadline = ContinuousClock.now + timeout
        let currentGeneration = generation
        let turnstile = turnstile(for: destination)
        try await turnstile.enter(before: deadline)
        defer { turnstile.leave() }
        try await deliver(data, to: destination, deadline: deadline, generation: currentGeneration)
    }

    private func turnstile(for peer: PeerID) -> Turnstile {
        if let turnstile = turnstiles[peer] {
            return turnstile
        }
        let turnstile = Turnstile()
        turnstiles[peer] = turnstile
        return turnstile
    }

    /// Sends a message, and sends it again until it's acknowledged or the deadline passes.
    private func deliver(_ data: Data, to destination: PeerID, deadline: ContinuousClock.Instant, generation: Int) async throws {
        let pending = Outgoing(counter: counter.next())
        outgoing[destination] = pending
        defer { outgoing[destination] = nil }

        var envelope: Envelope?
        var attempt = 0
        while true {
            // A confirmed message counts as sent, even if the mesh stopped or the task was
            // cancelled before this task got to run again.
            if pending.isAcknowledged { return }
            try Task.checkCancellation()
            guard isRunning, generation == self.generation else { throw MeshError.notRunning }
            let now = ContinuousClock.now
            guard now < deadline else { throw MeshError.timedOut }

            guard let route = table.bestRoute(to: destination), let keys = keys(for: destination) else {
                pending.isWaitingForRoute = true
                await pending.waiter.wait(until: deadline)
                continue
            }
            pending.isWaitingForRoute = false
            let sealed = try envelope ?? Envelope.seal(
                data,
                kind: .message,
                from: identity.id,
                to: destination,
                counter: pending.counter,
                service: serviceTag,
                using: keys.sending
            )
            envelope = sealed
            send(.envelope(sealed), on: route.link)
            let delay = retransmissionDelay(hops: route.hops, size: data.count, attempt: attempt)
            attempt += 1
            await pending.waiter.wait(until: min(deadline, now + delay))
        }
    }

    /// How long to wait for an acknowledgement: longer for distant peers and large messages,
    /// and longer with every attempt.
    private func retransmissionDelay(hops: Int, size: Int, attempt: Int) -> Duration {
        let transfer = Duration.seconds(Double(size) / timing.bytesPerSecond)
        let delay = (timing.firstRetransmission + (timing.retransmissionPerHop + transfer) * hops) * pow(1.5, Double(min(attempt, 10)))
        return min(delay, timing.longestRetransmission)
    }

    private func keys(for peer: PeerID, publicKey: Data? = nil) -> PairwiseKeys? {
        if let keys = pairwiseKeys[peer] {
            return keys
        }
        guard let publicKey = publicKey ?? table.entries[peer]?.publicKey,
              let keys = try? PairwiseKeys(identity: identity, otherPublicKey: publicKey)
        else { return nil }
        pairwiseKeys[peer] = keys
        return keys
    }

    // MARK: - Links

    /// Answers the hello from the other end of a link with proof that this phone holds the
    /// private key for its own public key.
    private func answer(_ hello: Hello, on link: LinkID) {
        guard let state = links[link], state.claim == nil,
              hello.publicKey.count == Frame.publicKeyLength,
              hello.nonce.count == Frame.nonceLength
        else { return }
        let peer = PeerID(publicKey: hello.publicKey)
        guard peer != identity.id, let keys = keys(for: peer, publicKey: hello.publicKey) else {
            return close(link)
        }
        links[link]?.claim = hello
        send(.proof(keys.proof(answering: hello.nonce, ownNonce: state.nonce, service: serviceTag)), on: link)
    }

    /// Checks that the phone at the other end of a link holds the private key for the public
    /// key in its hello, and sets the link up if it does.
    private func check(_ proof: Data, on link: LinkID) {
        guard let state = links[link], state.peer == nil, let hello = state.claim else { return }
        let peer = PeerID(publicKey: hello.publicKey)
        guard let keys = keys(for: peer),
              keys.isValidProof(proof, answering: state.nonce, otherNonce: hello.nonce, service: serviceTag)
        else { return close(link) }
        identify(link, as: peer, by: hello)
    }

    private func identify(_ link: LinkID, as peer: PeerID, by hello: Hello) {
        devices[link.device] = peer
        // Two phones that find each other at the same moment both connect, which leaves them
        // with two links. Both keep the one opened by the phone with the smaller ID. Two links
        // of the same kind mean the other phone was found again under a new Bluetooth
        // address, and both keep the older link.
        let duplicate = links.first { $0.key != link && $0.value.peer == peer }?.key
        if let duplicate {
            let keptRole: LinkRole = identity.id.precedes(peer) ? .central : .peripheral
            if duplicate.role == link.role || link.role != keptRole {
                return close(link)
            }
        }
        links[link]?.peer = peer
        table.recordNeighbor(peer, publicKey: hello.publicKey, name: hello.name, on: link, at: .now)
        if let duplicate {
            close(duplicate)
        }
        catchUp(link, excluding: peer)
        routesChanged()
    }

    /// Tells a new neighbor about this phone and the phones it heard from recently, so the
    /// neighbor doesn't wait for the next round of announcements. Older announcements might be
    /// from phones that have left.
    private func catchUp(_ link: LinkID, excluding peer: PeerID) {
        let now = ContinuousClock.now
        if let ownAnnouncement {
            send(.announcement(ownAnnouncement), on: link)
        }
        for (origin, stored) in announcements
        where origin != peer
            && stored.announcement.timeToLive > 1
            && now - stored.received <= stored.announcement.interval * 1.5 {
            var forwarded = stored.announcement
            forwarded.timeToLive -= 1
            send(.announcement(forwarded), on: link)
        }
    }

    private func close(_ link: LinkID) {
        guard links.removeValue(forKey: link) != nil else { return }
        transport.close(link)
        table.removeRoutes(on: link)
        routesChanged()
    }

    // MARK: - Receiving

    private func receive(_ announcement: Announcement, on link: LinkID) {
        guard links[link]?.peer != nil, announcement.publicKey.count == Frame.publicKeyLength else { return }
        let origin = PeerID(publicKey: announcement.publicKey)
        guard origin != identity.id else { return }
        let hops = Mesh.maximumHops - Int(announcement.timeToLive) + 1
        let now = ContinuousClock.now
        if table.record(announcement, from: origin, hops: hops, on: link, at: now) {
            announcements[origin] = (announcement, now)
            if announcement.timeToLive > 1 {
                var forwarded = announcement
                forwarded.timeToLive -= 1
                sendToNeighbors(.announcement(forwarded), except: link)
            }
        }
        routesChanged()
    }

    private func receive(_ envelope: Envelope, on link: LinkID) {
        guard links[link]?.peer != nil else { return }
        guard envelope.destination == identity.id else {
            return relay(envelope, from: link)
        }
        guard let keys = keys(for: envelope.source),
              let contents = try? envelope.open(using: keys.receiving, service: serviceTag)
        else { return }
        switch envelope.kind {
        case .message:
            accept(contents, of: envelope, keys: keys)
        case .acknowledgement:
            guard let pending = outgoing[envelope.source], pending.counter == envelope.counter else { return }
            pending.isAcknowledged = true
            pending.waiter.wake()
        }
    }

    private func accept(_ contents: Data, of envelope: Envelope, keys: PairwiseKeys) {
        switch deliveries.verdict(for: envelope.counter, from: envelope.source) {
        case .stale:
            return
        case .repeated:
            break
        case .new:
            deliveries.record(envelope.counter, from: envelope.source)
            let sender = Peer(
                id: envelope.source,
                name: table.entries[envelope.source]?.name ?? "",
                hops: Mesh.maximumHops - Int(envelope.timeToLive) + 1
            )
            delegate?.node(self, didReceive: Message(sender: sender, data: contents))
        }
        acknowledge(envelope, keys: keys)
    }

    private func acknowledge(_ message: Envelope, keys: PairwiseKeys) {
        guard let route = table.bestRoute(to: message.source),
              let acknowledgement = try? Envelope.seal(
                Data(),
                kind: .acknowledgement,
                from: identity.id,
                to: message.source,
                counter: message.counter,
                service: serviceTag,
                using: keys.sending
              )
        else { return }
        send(.envelope(acknowledgement), on: route.link)
    }

    private func relay(_ envelope: Envelope, from link: LinkID) {
        guard envelope.timeToLive > 1, let route = table.bestRoute(to: envelope.destination, avoiding: link) else { return }
        var forwarded = envelope
        forwarded.timeToLive -= 1
        send(.envelope(forwarded), on: route.link)
    }

    // MARK: - Housekeeping

    /// Runs on a timer, and whenever a frame arrives. While the app is in the background its
    /// timers stop, but arriving frames still wake it.
    private func maintain() {
        guard isRunning else { return }
        let now = ContinuousClock.now
        // A long gap since the last run means the app was suspended. Links being quiet during
        // that time says nothing about them, so their quiet time starts over.
        if now - lastMaintenance > timing.maintenanceInterval * 3 {
            for link in links.keys {
                links[link]?.lastHeard = now
            }
        }
        lastMaintenance = now
        for (link, state) in links {
            if let peer = state.peer {
                // A phone in the mesh announces itself on its interval, so a link that stays
                // quiet much longer than that leads nowhere. The other end may have stopped
                // using it, or its app may be suspended.
                if now - state.lastHeard > quietLimit(for: peer) {
                    close(link)
                }
            } else if now - state.opened > timing.identificationTimeout {
                close(link)
            }
        }
        table.removeExpiredRoutes(at: now)
        routesChanged()
        if now >= nextAnnouncement {
            announce(at: now)
        }
    }

    private func quietLimit(for peer: PeerID) -> Duration {
        (table.entries[peer]?.interval ?? timing.shortestAnnouncementInterval) * 3 + timing.routeGrace
    }

    private func announce(at now: ContinuousClock.Instant) {
        let interval = announcementInterval
        let milliseconds = UInt64(Date().timeIntervalSince1970 * 1000)
        let announcement = Announcement(
            timeToLive: UInt8(Mesh.maximumHops),
            publicKey: identity.publicKey,
            sequence: max((ownAnnouncement?.sequence ?? 0) + 1, milliseconds),
            interval: interval,
            name: name
        )
        ownAnnouncement = announcement
        sendToNeighbors(.announcement(announcement))
        nextAnnouncement = now + interval * Double.random(in: 0.9...1.1)
    }

    /// Phones announce themselves less often in a bigger mesh, to leave room for messages.
    private var announcementInterval: Duration {
        let share = min(Double(peers.count) / 50, 1)
        return timing.shortestAnnouncementInterval
            + (timing.longestAnnouncementInterval - timing.shortestAnnouncementInterval) * share
    }

    private func send(_ frame: Frame, on link: LinkID) {
        transport.send(frame.encoded(), on: link, priority: frame.priority)
    }

    private func sendToNeighbors(_ frame: Frame, except excludedLink: LinkID? = nil) {
        let data = frame.encoded()
        for (link, state) in links where link != excludedLink && state.peer != nil {
            transport.send(data, on: link, priority: frame.priority)
        }
    }

    /// Publishes the peer list if it changed, and wakes the sends that are waiting for a route.
    private func routesChanged() {
        let current = table.peers
        if current != peers {
            peers = current
            delegate?.node(self, didChangePeers: current)
        }
        for pending in outgoing.values where pending.isWaitingForRoute {
            pending.waiter.wake()
        }
    }
}

// MARK: - TransportDelegate

extension Node: TransportDelegate {

    func transportDidChangeState(_ transport: any Transport) {
        guard isRunning else { return }
        delegate?.node(self, didChangeState: Self.state(for: transport.state))
    }

    func transport(_ transport: any Transport, didOpen link: LinkID) {
        guard isRunning else { return }
        let now = ContinuousClock.now
        let nonce = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        links[link] = Link(opened: now, nonce: nonce, lastHeard: now)
        send(.hello(Hello(publicKey: identity.publicKey, nonce: nonce, name: name)), on: link)
    }

    func transport(_ transport: any Transport, didReceive frame: Data, on link: LinkID) {
        guard isRunning, links[link] != nil, let frame = try? Frame(decoding: frame) else { return }
        links[link]?.lastHeard = .now
        switch frame {
        case .hello(let hello):
            answer(hello, on: link)
        case .proof(let proof):
            check(proof, on: link)
        case .announcement(let announcement):
            receive(announcement, on: link)
        case .envelope(let envelope):
            receive(envelope, on: link)
        }
        maintain()
    }

    func transport(_ transport: any Transport, didClose link: LinkID) {
        guard links.removeValue(forKey: link) != nil else { return }
        table.removeRoutes(on: link)
        routesChanged()
    }

    func transport(_ transport: any Transport, shouldConnectTo device: UUID) -> Bool {
        guard let peer = devices[device] else { return true }
        return !links.values.contains { $0.peer == peer }
    }
}

// MARK: - Supporting types

private extension Node {

    struct Link {
        let opened: ContinuousClock.Instant
        /// Sent in this phone's hello, for the other end's proof to answer.
        let nonce: Data
        var lastHeard: ContinuousClock.Instant
        /// The other end's hello, until its proof arrives.
        var claim: Hello?
        /// The phone at the other end, once its proof checks out.
        var peer: PeerID?
    }

    /// A message waiting for its acknowledgement.
    @MainActor
    final class Outgoing {
        let counter: UInt64
        let waiter = Waiter()
        var isAcknowledged = false
        var isWaitingForRoute = false

        init(counter: UInt64) {
            self.counter = counter
        }
    }
}
