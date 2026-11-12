//
//  Counters.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Hands out a counter for each message this phone sends.
///
/// Counters follow the clock in milliseconds, so they keep growing across app restarts and
/// reinstalls. The last one is saved too, so they keep growing if the clock is set back.
struct MessageCounter {
    private static let key = "lastSentCounter"

    private let defaults: UserDefaults
    private var last: UInt64

    init(defaults: UserDefaults) {
        self.defaults = defaults
        last = UInt64(bitPattern: Int64(defaults.integer(forKey: Self.key)))
    }

    mutating func next(now: Date = Date()) -> UInt64 {
        last = max(last + 1, UInt64(now.timeIntervalSince1970 * 1000))
        defaults.set(Int64(bitPattern: last), forKey: Self.key)
        return last
    }
}

/// Remembers the newest message counter delivered from each sender in one service.
///
/// A message with a lower counter is one whose send already failed, and one with the same
/// counter is a repeat, so neither is delivered again. Saved across app restarts, separately
/// for each service, so that two meshes in one app don't overwrite each other's records.
struct DeliveryLog {

    enum Verdict: Equatable {
        /// Newer than anything delivered from the sender: deliver it.
        case new
        /// The message delivered last, sent again because its acknowledgement got lost.
        case repeated
        /// Older than the message delivered last.
        case stale
    }

    private let defaults: UserDefaults
    private let key: String
    private var newest: [PeerID: UInt64] = [:]

    init(defaults: UserDefaults, service: String) {
        self.defaults = defaults
        key = "deliveredCounters.\(service)"
        for (id, value) in defaults.dictionary(forKey: key) ?? [:] {
            guard let id = PeerID(id), let counter = value as? Int64 else { continue }
            newest[id] = UInt64(bitPattern: counter)
        }
    }

    func verdict(for counter: UInt64, from sender: PeerID) -> Verdict {
        guard let newest = newest[sender], counter <= newest else { return .new }
        return counter == newest ? .repeated : .stale
    }

    mutating func record(_ counter: UInt64, from sender: PeerID) {
        newest[sender] = counter
        let saved = newest.reduce(into: [String: Int64]()) { saved, entry in
            saved[entry.key.description] = Int64(bitPattern: entry.value)
        }
        defaults.set(saved, forKey: key)
    }
}
