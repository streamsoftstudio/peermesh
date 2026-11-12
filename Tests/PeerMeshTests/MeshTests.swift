//
//  MeshTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Testing
@testable import PeerMesh

@Suite(.serialized)
@MainActor
struct MeshTests {

    private let network = MemoryNetwork()

    // MARK: - Finding peers

    @Test func phonesInRangeSeeEachOther() async {
        let phones = network.line("Ana", "Bea")
        let ana = phones[0], bea = phones[1]

        #expect(await eventually { ana.mesh.peers == [Peer(id: bea.id, name: "Bea", hops: 1)] })
        #expect(await eventually { bea.mesh.peers == [Peer(id: ana.id, name: "Ana", hops: 1)] })
        #expect(ana.mesh.state == .running)
    }

    @Test func phonesOutOfRangeSeeEachOtherThroughOthers() async {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], bea = phones[1], cai = phones[2]

        #expect(await eventually { ana.canReach(bea, hops: 1) && ana.canReach(cai, hops: 2) })
        #expect(ana.mesh.peers.map(\.name) == ["Bea", "Cai"])
    }

    @Test func peersMoreThanSevenLinksAwayAreOutOfReach() async {
        let phones = network.line("1", "2", "3", "4", "5", "6", "7", "8", "9")
        let first = phones[0]

        #expect(await eventually { first.canReach(phones[7], hops: 7) })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(!first.canReach(phones[8]))
        #expect(first.mesh.peers.count == 7)
    }

    @Test func peerDisappearsWhenItLeaves() async {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], bea = phones[1], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })

        cai.mesh.stop()

        #expect(await eventually(within: .seconds(2)) { !ana.canReach(cai) })
        #expect(ana.canReach(bea))
    }

    @Test func phonesThatConnectToEachOtherKeepOneConnection() async throws {
        let ana = network.addPhone("Ana")
        let bea = network.addPhone("Bea")
        network.putInRange(ana, bea, bothConnect: true)
        ana.mesh.start()
        bea.mesh.start()

        #expect(await eventually { network.openConnections(between: ana, and: bea) == 1 })
        #expect(await eventually { ana.canReach(bea, hops: 1) && bea.canReach(ana, hops: 1) })
        try await ana.mesh.send(Data("hi".utf8), to: bea.id)
        try await bea.mesh.send(Data("hi".utf8), to: ana.id)
    }

    @Test func quietConnectionIsClosedAndComesBack() async {
        let phones = network.line("Ana", "Bea")
        let ana = phones[0], bea = phones[1]
        #expect(await eventually { ana.canReach(bea) })
        var isBeaQuiet = true
        network.tamper = { frame, sender, _ in
            sender === bea.transport && isBeaQuiet ? [] : [frame]
        }

        #expect(await eventually(within: .seconds(2)) { !ana.canReach(bea) })

        isBeaQuiet = false
        #expect(await eventually(within: .seconds(3)) { ana.canReach(bea, hops: 1) })
    }

    @Test func newNeighborDoesNotHearAboutPhonesThatLeft() async throws {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })

        // Ana still has a route to Cai for a little while after Cai leaves. A phone that joins
        // through Ana in that time shouldn't be told about Cai.
        cai.mesh.stop()
        try await Task.sleep(for: .milliseconds(170))
        let dee = network.addPhone("Dee")
        network.putInRange(dee, ana)
        dee.mesh.start()

        var heardAboutCai = false
        for _ in 0..<60 {
            heardAboutCai = heardAboutCai || dee.canReach(cai)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(dee.canReach(ana))
        #expect(!heardAboutCai)
    }

    @Test func peerUpdatesStartWithTheCurrentList() async {
        let phones = network.line("Ana", "Bea")
        let ana = phones[0], bea = phones[1]
        #expect(await eventually { ana.canReach(bea) })

        var updates = ana.mesh.peerUpdates.makeAsyncIterator()

        #expect(await updates.next() == ana.mesh.peers)
    }

    // MARK: - Sending

    @Test func messageReachesPeerInRange() async throws {
        let phones = network.line("Ana", "Bea")
        let ana = phones[0], bea = phones[1]
        #expect(await eventually { ana.canReach(bea) })

        try await ana.mesh.send(Data("e2e4".utf8), to: bea.id)

        #expect(await eventually { bea.messages.count == 1 })
        #expect(bea.messages.first?.data == Data("e2e4".utf8))
        #expect(bea.messages.first?.sender == Peer(id: ana.id, name: "Ana", hops: 1))
    }

    @Test func messageTravelsThroughOtherPhones() async throws {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })

        try await ana.mesh.send(Data("e2e4".utf8), to: cai.id)

        #expect(await eventually { cai.messages.count == 1 })
        #expect(cai.messages.first?.sender == Peer(id: ana.id, name: "Ana", hops: 2))
    }

    @Test func messageTravelsSevenLinks() async throws {
        let phones = network.line("1", "2", "3", "4", "5", "6", "7", "8")
        let first = phones[0], last = phones[7]
        #expect(await eventually { first.canReach(last, hops: 7) })

        try await first.mesh.send(Data("far".utf8), to: last.id)

        #expect(await eventually { last.messages.first?.sender.hops == 7 })
    }

    @Test func largestMessageArrivesIntact() async throws {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })
        let message = Data((0..<Mesh.maximumMessageSize).map { UInt8(truncatingIfNeeded: $0) })

        try await ana.mesh.send(message, to: cai.id)

        #expect(await eventually { cai.messages.first?.data == message })
    }

    @Test func messagesArriveInOrder() async throws {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })

        for number in 0..<10 {
            try await ana.mesh.send(Data([UInt8(number)]), to: cai.id)
        }

        #expect(await eventually { cai.messages.count == 10 })
        #expect(cai.messages.map(\.data) == (0..<10).map { Data([UInt8($0)]) })
    }

    @Test func sendsMadeAtTheSameTimeAllArrive() async throws {
        let phones = network.line("Ana", "Bea")
        let ana = phones[0], bea = phones[1]
        #expect(await eventually { ana.canReach(bea) })
        let mesh = ana.mesh, recipient = bea.id

        let sends = (0..<5).map { number in
            Task { try await mesh.send(Data([UInt8(number)]), to: recipient) }
        }
        for send in sends {
            try await send.value
        }

        #expect(await eventually { bea.messages.count == 5 })
        #expect(Set(bea.messages.map(\.data)) == Set((0..<5).map { Data([UInt8($0)]) }))
    }

    @Test func messageTakesAnotherRouteWhenARelayLeaves() async throws {
        let ana = network.addPhone("Ana")
        let bea = network.addPhone("Bea")
        let cai = network.addPhone("Cai")
        let dee = network.addPhone("Dee")
        network.putInRange(ana, bea)
        network.putInRange(bea, cai)
        network.putInRange(ana, dee)
        network.putInRange(dee, cai)
        for phone in [ana, bea, cai, dee] {
            phone.mesh.start()
        }
        #expect(await eventually { ana.canReach(cai, hops: 2) })

        bea.mesh.stop()
        try await ana.mesh.send(Data("e2e4".utf8), to: cai.id)

        #expect(await eventually { cai.messages.first?.sender.id == ana.id })
    }

    @Test func messageWaitsForPeerThatComesBackInRange() async throws {
        let ana = network.addPhone("Ana")
        let bea = network.addPhone("Bea")
        network.putInRange(ana, bea)
        ana.mesh.start()
        let mesh = ana.mesh, recipient = bea.id

        let send = Task { @MainActor in
            try await mesh.send(Data("e2e4".utf8), to: recipient, timeout: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(300))
        bea.mesh.start()

        try await send.value
        #expect(await eventually { bea.messages.count == 1 })
    }

    // MARK: - Failures

    @Test func sendTimesOutWhenPeerIsUnreachable() async {
        let ana = network.line("Ana")[0]
        let start = ContinuousClock.now

        await #expect(throws: MeshError.timedOut) {
            try await ana.mesh.send(Data("e2e4".utf8), to: Identity().id, timeout: .milliseconds(300))
        }
        #expect(ContinuousClock.now - start >= .milliseconds(300))
    }

    @Test func sendRejectsMessagesThatAreTooLarge() async {
        let ana = network.line("Ana")[0]

        await #expect(throws: MeshError.messageTooLarge) {
            try await ana.mesh.send(Data(count: Mesh.maximumMessageSize + 1), to: Identity().id)
        }
    }

    @Test func sendNeedsAStartedMesh() async {
        let ana = network.addPhone("Ana")

        await #expect(throws: MeshError.notRunning) {
            try await ana.mesh.send(Data("e2e4".utf8), to: Identity().id)
        }
    }

    @Test func stoppingEndsSendsInProgress() async throws {
        let mesh = network.line("Ana")[0].mesh
        let send = Task { @MainActor in
            try await mesh.send(Data("e2e4".utf8), to: Identity().id, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))

        mesh.stop()

        await #expect(throws: MeshError.notRunning) { try await send.value }
        #expect(mesh.state == .stopped)
        #expect(mesh.peers.isEmpty)
    }

    @Test func confirmedSendSucceedsEvenIfTheMeshStopsRightAfter() async throws {
        let phones = network.line("Ana", "Bea")
        let ana = phones[0], bea = phones[1]
        #expect(await eventually { ana.canReach(bea) })
        network.onDelivered = { frame, receiver in
            guard receiver === ana.transport,
                  case .envelope(let envelope)? = try? Frame(decoding: frame),
                  envelope.kind == .acknowledgement
            else { return }
            ana.mesh.stop()
        }

        try await ana.mesh.send(Data("e2e4".utf8), to: bea.id)

        #expect(ana.mesh.state == .stopped)
    }

    @Test func cancellingEndsASend() async throws {
        let mesh = network.line("Ana")[0].mesh
        let send = Task { @MainActor in
            try await mesh.send(Data("e2e4".utf8), to: Identity().id, timeout: .seconds(30))
        }
        try await Task.sleep(for: .milliseconds(100))

        send.cancel()

        await #expect(throws: CancellationError.self) { try await send.value }
    }

    // MARK: - Security

    @Test func phoneCannotPassItselfOffAsAnother() async throws {
        let ana = network.line("Ana")[0]
        let bea = Identity()
        let impostor = Impostor(network: network, claiming: bea.publicKey)
        network.putInRange(impostor.transport, ana.transport)

        var listedBea = false
        for _ in 0..<40 {
            listedBea = listedBea || ana.mesh.peers.contains { $0.id == bea.id }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(!listedBea)
        #expect(network.openConnections(between: impostor.transport, and: ana.transport) == 0)
    }

    @Test func impostorDoesNotDisturbTheRealPhone() async throws {
        // When Ana has the larger ID, she keeps links that other phones open to her over ones
        // she opened herself, which is what an impostor would take advantage of.
        var anaIdentity = Identity()
        let beaIdentity = Identity()
        while anaIdentity.id.precedes(beaIdentity.id) {
            anaIdentity = Identity()
        }
        let ana = network.addPhone("Ana", identity: anaIdentity)
        let bea = network.addPhone("Bea", identity: beaIdentity)
        network.putInRange(ana, bea)
        ana.mesh.start()
        bea.mesh.start()
        #expect(await eventually { ana.canReach(bea, hops: 1) })

        let impostor = Impostor(network: network, claiming: beaIdentity.publicKey)
        network.putInRange(impostor.transport, ana.transport)
        try await Task.sleep(for: .milliseconds(300))

        #expect(network.openConnections(between: ana, and: bea) == 1)
        try await ana.mesh.send(Data("e2e4".utf8), to: bea.id, timeout: .seconds(2))
        #expect(await eventually { bea.messages.count == 1 })
    }

    @Test func messageForOneServiceIsNotDeliveredInAnother() async throws {
        let anaIdentity = Identity(), beaIdentity = Identity()
        let beaDefaults = UserDefaults.fresh()
        let anaChess = network.addPhone("Ana", service: "chess", identity: anaIdentity)
        let beaChess = network.addPhone("Bea", service: "chess", identity: beaIdentity, defaults: beaDefaults)
        let anaChat = network.addPhone("Ana", service: "chat", identity: anaIdentity)
        let beaChat = network.addPhone("Bea", service: "chat", identity: beaIdentity, defaults: beaDefaults)
        network.putInRange(anaChess, beaChess)
        network.putInRange(anaChat, beaChat)
        for phone in [anaChess, beaChess, anaChat, beaChat] {
            phone.mesh.start()
        }
        #expect(await eventually { anaChess.canReach(beaChess) && beaChat.canReach(anaChat) })
        var recorded: [Data] = []
        network.tamper = { frame, sender, _ in
            if sender === anaChess.transport, case .envelope(let envelope)? = try? Frame(decoding: frame), envelope.kind == .message {
                recorded.append(frame)
            }
            return [frame]
        }

        try await anaChess.mesh.send(Data("e2e4".utf8), to: beaChess.id)
        network.replay(try #require(recorded.first), from: anaChat, to: beaChat)
        try await Task.sleep(for: .milliseconds(200))

        #expect(beaChess.messages.count == 1)
        #expect(beaChat.messages.isEmpty)
    }

    @Test func relaysCannotReadMessages() async throws {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], bea = phones[1], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })
        var relayed: [Data] = []
        network.tamper = { frame, sender, _ in
            if sender === bea.transport {
                relayed.append(frame)
            }
            return [frame]
        }
        let secret = Data("Meet me at row 31".utf8)

        try await ana.mesh.send(secret, to: cai.id)

        #expect(await eventually { cai.messages.first?.data == secret })
        #expect(!relayed.isEmpty)
        #expect(relayed.allSatisfy { $0.range(of: secret) == nil })
    }

    @Test func recipientRejectsMessagesChangedOnTheWay() async {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], bea = phones[1], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })
        network.tamper = { frame, sender, _ in
            guard sender === bea.transport,
                  case .envelope(var envelope)? = try? Frame(decoding: frame),
                  envelope.kind == .message
            else { return [frame] }
            envelope.sealed[envelope.sealed.startIndex + 20] ^= 1
            return [Frame.envelope(envelope).encoded()]
        }

        await #expect(throws: MeshError.timedOut) {
            try await ana.mesh.send(Data("e2e4".utf8), to: cai.id, timeout: .milliseconds(800))
        }
        #expect(cai.messages.isEmpty)
    }

    @Test func repeatedFramesAreDeliveredOnce() async throws {
        let phones = network.line("Ana", "Bea", "Cai")
        let ana = phones[0], cai = phones[2]
        #expect(await eventually { ana.canReach(cai) })
        network.tamper = { frame, _, _ in [frame, frame] }

        for number in 0..<3 {
            try await ana.mesh.send(Data([UInt8(number)]), to: cai.id)
        }
        try await Task.sleep(for: .milliseconds(300))

        #expect(cai.messages.map(\.data) == [Data([0]), Data([1]), Data([2])])
    }

    @Test func replayedMessageIsNotDeliveredAgainAfterARestart() async throws {
        let ana = network.addPhone("Ana")
        let bea = network.addPhone("Bea")
        network.putInRange(ana, bea)
        ana.mesh.start()
        bea.mesh.start()
        #expect(await eventually { ana.canReach(bea) })
        var recorded: [Data] = []
        network.tamper = { frame, sender, _ in
            if sender === ana.transport, case .envelope(let envelope)? = try? Frame(decoding: frame), envelope.kind == .message {
                recorded.append(frame)
            }
            return [frame]
        }
        try await ana.mesh.send(Data("e2e4".utf8), to: bea.id)

        // Bea's app starts again, with the same identity and saved state.
        bea.mesh.stop()
        let restarted = network.addPhone("Bea", identity: bea.identity, defaults: bea.defaults)
        network.putInRange(ana, restarted)
        restarted.mesh.start()
        #expect(await eventually { ana.canReach(restarted) && restarted.canReach(ana) })
        network.replay(try #require(recorded.first), from: ana, to: restarted)
        try await ana.mesh.send(Data("d7d5".utf8), to: restarted.id)

        #expect(await eventually { restarted.messages.count == 1 })
        try await Task.sleep(for: .milliseconds(200))
        #expect(restarted.messages.map(\.data) == [Data("d7d5".utf8)])
    }

    // MARK: - State

    @Test func stateFollowsBluetooth() async {
        let ana = network.addPhone("Ana")
        #expect(ana.mesh.state == .stopped)

        ana.mesh.start()
        #expect(await eventually { ana.mesh.state == .running })

        ana.transport.update(.poweredOff)
        #expect(ana.mesh.state == .bluetoothOff)

        ana.transport.update(.unauthorized)
        #expect(ana.mesh.state == .bluetoothDenied)

        ana.transport.update(.unsupported)
        #expect(ana.mesh.state == .unsupported)

        ana.mesh.stop()
        #expect(ana.mesh.state == .stopped)
    }

    @Test func stateUpdatesStartWithTheCurrentState() async {
        let ana = network.line("Ana")[0]
        #expect(await eventually { ana.mesh.state == .running })
        var updates = ana.mesh.stateUpdates.makeAsyncIterator()

        #expect(await updates.next() == .running)
        ana.transport.update(.poweredOff)
        #expect(await updates.next() == .bluetoothOff)
    }

    @Test func longNamesAreShortened() {
        let ana = network.addPhone(String(repeating: "ž", count: 40))

        #expect(ana.mesh.name == String(repeating: "ž", count: 32))
    }
}
