//
//  Broadcast.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import os

/// Gives each subscriber its own stream of a value that changes over time.
///
/// A new stream starts with the current value. A subscriber that falls behind gets only the
/// newest value.
final class Broadcast<Value: Sendable>: Sendable {

    private struct Subscribers: Sendable {
        var continuations: [Int: AsyncStream<Value>.Continuation] = [:]
        var nextID = 0
    }

    private let subscribers = OSAllocatedUnfairLock(initialState: Subscribers())

    func stream(startingWith value: Value) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(value)
        let id = subscribers.withLock { subscribers in
            defer { subscribers.nextID += 1 }
            subscribers.continuations[subscribers.nextID] = continuation
            return subscribers.nextID
        }
        continuation.onTermination = { [weak self] _ in
            self?.subscribers.withLock { _ = $0.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ value: Value) {
        for continuation in subscribers.withLock({ Array($0.continuations.values) }) {
            continuation.yield(value)
        }
    }

    func finish() {
        let continuations = subscribers.withLock { subscribers in
            defer { subscribers.continuations = [:] }
            return Array(subscribers.continuations.values)
        }
        for continuation in continuations {
            continuation.finish()
        }
    }
}
