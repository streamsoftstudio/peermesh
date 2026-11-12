//
//  RoutingTableTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Testing
@testable import PeerMesh

struct RoutingTableTests {

    private let first = LinkID(device: UUID(), role: .central)
    private let second = LinkID(device: UUID(), role: .peripheral)
    private let third = LinkID(device: UUID(), role: .central)
    private let origin = Identity()
    private let start = ContinuousClock.now

    @Test func bestRouteHasTheFewestHops() {
        var table = RoutingTable(grace: .seconds(1), defaultInterval: .seconds(3))
        let announcement = announcement(sequence: 1)

        let firstCopy = table.record(announcement, from: origin.id, hops: 3, on: first, at: start)
        let shorterCopy = table.record(announcement, from: origin.id, hops: 2, on: second, at: start)
        let longerCopy = table.record(announcement, from: origin.id, hops: 4, on: third, at: start)

        #expect(firstCopy)
        #expect(shorterCopy)
        #expect(!longerCopy)
        #expect(table.bestRoute(to: origin.id)?.link == second)
        #expect(table.bestRoute(to: origin.id, avoiding: second)?.link == first)
        #expect(table.peers == [Peer(id: origin.id, name: "Ana", hops: 2)])
    }

    @Test func olderAnnouncementsAreIgnored() {
        var table = RoutingTable(grace: .seconds(1), defaultInterval: .seconds(3))
        _ = table.record(announcement(sequence: 2), from: origin.id, hops: 3, on: first, at: start)

        let olderCopy = table.record(announcement(sequence: 1), from: origin.id, hops: 1, on: second, at: start)

        #expect(!olderCopy)
        #expect(table.bestRoute(to: origin.id)?.link == first)
    }

    @Test func routesThroughOtherPhonesExpireButNeighborsStay() {
        var table = RoutingTable(grace: .seconds(1), defaultInterval: .seconds(3))
        let neighbor = Identity()
        table.recordNeighbor(neighbor.id, publicKey: neighbor.publicKey, name: "Bea", on: first, at: start)
        _ = table.record(announcement(sequence: 1), from: origin.id, hops: 2, on: first, at: start)

        table.removeExpiredRoutes(at: start + .seconds(6.5))
        #expect(table.peers.count == 2)

        table.removeExpiredRoutes(at: start + .seconds(7.5))
        #expect(table.peers.map(\.id) == [neighbor.id])
    }

    @Test func announcementsCountAsNewOnceAPhoneIsUnreachable() {
        var table = RoutingTable(grace: .seconds(1), defaultInterval: .seconds(3))
        _ = table.record(announcement(sequence: 500), from: origin.id, hops: 2, on: first, at: start)
        table.removeExpiredRoutes(at: start + .seconds(10))

        // The phone's clock was set back while it was away.
        let afterReturn = table.record(announcement(sequence: 3), from: origin.id, hops: 2, on: second, at: start + .seconds(11))

        #expect(afterReturn)
        #expect(table.bestRoute(to: origin.id)?.link == second)
    }

    @Test func closingALinkRemovesItsRoutes() {
        var table = RoutingTable(grace: .seconds(1), defaultInterval: .seconds(3))
        _ = table.record(announcement(sequence: 1), from: origin.id, hops: 2, on: first, at: start)

        table.removeRoutes(on: first)

        #expect(table.peers.isEmpty)
        #expect(table.bestRoute(to: origin.id) == nil)
    }

    private func announcement(sequence: UInt64) -> Announcement {
        Announcement(timeToLive: 5, publicKey: origin.publicKey, sequence: sequence, interval: .seconds(3), name: "Ana")
    }
}
