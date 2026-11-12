//
//  CountersTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Testing
@testable import PeerMesh

struct CountersTests {

    @Test func countersKeepGrowingWhenTheClockIsSetBack() {
        let defaults = UserDefaults.fresh()
        var counter = MessageCounter(defaults: defaults)
        let first = counter.next(now: Date(timeIntervalSince1970: 2_000_000_000))

        var restarted = MessageCounter(defaults: defaults)
        let second = restarted.next(now: Date(timeIntervalSince1970: 1_000_000_000))

        #expect(second > first)
    }

    @Test func deliveryLogTellsNewRepeatedAndStaleMessagesApart() {
        var log = DeliveryLog(defaults: .fresh(), service: "chess")
        let sender = Identity().id

        #expect(log.verdict(for: 5, from: sender) == .new)
        log.record(5, from: sender)

        #expect(log.verdict(for: 5, from: sender) == .repeated)
        #expect(log.verdict(for: 4, from: sender) == .stale)
        #expect(log.verdict(for: 6, from: sender) == .new)
        #expect(log.verdict(for: 1, from: Identity().id) == .new)
    }

    @Test func deliveryLogSurvivesRestarts() {
        let defaults = UserDefaults.fresh()
        let sender = Identity().id
        var log = DeliveryLog(defaults: defaults, service: "chess")
        log.record(5, from: sender)

        let restarted = DeliveryLog(defaults: defaults, service: "chess")

        #expect(restarted.verdict(for: 5, from: sender) == .repeated)
        #expect(restarted.verdict(for: 6, from: sender) == .new)
    }

    @Test func eachServiceKeepsItsOwnRecord() {
        let defaults = UserDefaults.fresh()
        let sender = Identity().id
        var chess = DeliveryLog(defaults: defaults, service: "chess")
        var chat = DeliveryLog(defaults: defaults, service: "chat")
        chess.record(5, from: sender)
        chat.record(9, from: Identity().id)

        let restartedChess = DeliveryLog(defaults: defaults, service: "chess")

        #expect(restartedChess.verdict(for: 5, from: sender) == .repeated)
    }
}
