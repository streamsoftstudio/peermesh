//
//  RoutingTable.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// The phones this phone knows about, and which links lead to each of them.
///
/// Every phone announces itself on a regular interval, and every phone passes announcements on.
/// A phone learns a route to another by noting the link an announcement arrived on and how many
/// links it crossed.
struct RoutingTable {

    struct Entry {
        var publicKey: Data
        var name: String
        /// The newest announcement seen from the phone, or `nil` if it has only said hello.
        var sequence: UInt64?
        var interval: Duration
        /// The fewest hops with which the newest announcement was passed on.
        var forwardedHops: Int?
        var routes: [LinkID: Route] = [:]
    }

    struct Route {
        var hops: Int
        var heard: ContinuousClock.Instant
    }

    /// How long a route through other phones lasts after two missed announcements.
    let grace: Duration

    /// The interval assumed for a phone whose announcement hasn't arrived yet.
    let defaultInterval: Duration

    private(set) var entries: [PeerID: Entry] = [:]

    init(grace: Duration, defaultInterval: Duration) {
        self.grace = grace
        self.defaultInterval = defaultInterval
    }

    /// Records the phone at the other end of a link.
    mutating func recordNeighbor(_ id: PeerID, publicKey: Data, name: String, on link: LinkID, at now: ContinuousClock.Instant) {
        var entry = entries[id] ?? Entry(publicKey: publicKey, name: name, interval: defaultInterval)
        entry.routes[link] = Route(hops: 1, heard: now)
        entries[id] = entry
    }

    /// Records an announcement that arrived on `link` after crossing `hops` links.
    ///
    /// Returns whether to pass it on: yes for the first copy of a new announcement, and for a
    /// later copy that took a shorter way.
    mutating func record(
        _ announcement: Announcement,
        from origin: PeerID,
        hops: Int,
        on link: LinkID,
        at now: ContinuousClock.Instant
    ) -> Bool {
        var entry = entries[origin]
            ?? Entry(publicKey: announcement.publicKey, name: announcement.name, interval: announcement.interval)
        defer { entries[origin] = entry }

        if let sequence = entry.sequence, announcement.sequence < sequence {
            return false
        }
        entry.routes[link] = Route(hops: hops, heard: now)
        if entry.sequence == announcement.sequence {
            guard hops < entry.forwardedHops ?? .max else { return false }
            entry.forwardedHops = hops
            return true
        }
        entry.sequence = announcement.sequence
        entry.name = announcement.name
        entry.interval = announcement.interval
        entry.forwardedHops = hops
        return true
    }

    mutating func removeRoutes(on link: LinkID) {
        for id in entries.keys where entries[id]?.routes[link] != nil {
            entries[id]?.routes[link] = nil
            forgetSequenceIfUnreachable(id)
        }
    }

    /// Removes routes through other phones that weren't refreshed in time. A route to a phone
    /// in range lasts as long as its link.
    mutating func removeExpiredRoutes(at now: ContinuousClock.Instant) {
        for (id, entry) in entries {
            let lifetime = entry.interval * 2 + grace
            let routes = entry.routes.filter { $0.value.hops == 1 || now - $0.value.heard <= lifetime }
            guard routes.count != entry.routes.count else { continue }
            entries[id]?.routes = routes
            forgetSequenceIfUnreachable(id)
        }
    }

    /// Once a phone can't be reached, any announcement from it counts as new again. Otherwise a
    /// phone whose clock was set back, or a bogus announcement with a huge sequence, would keep
    /// it out of the mesh.
    private mutating func forgetSequenceIfUnreachable(_ id: PeerID) {
        guard entries[id]?.routes.isEmpty == true else { return }
        entries[id]?.sequence = nil
        entries[id]?.forwardedHops = nil
    }

    /// The best link towards a phone: the one with the fewest hops, then the one heard from last.
    func bestRoute(to id: PeerID, avoiding excludedLink: LinkID? = nil) -> (link: LinkID, hops: Int)? {
        entries[id]?.routes
            .filter { $0.key != excludedLink }
            .min { ($0.value.hops, $1.value.heard) < ($1.value.hops, $0.value.heard) }
            .map { (link: $0.key, hops: $0.value.hops) }
    }

    /// Every phone with at least one route, sorted by name.
    var peers: [Peer] {
        entries
            .compactMap { id, entry in
                entry.routes.values.map(\.hops).min().map { Peer(id: id, name: entry.name, hops: $0) }
            }
            .sorted { first, second in
                switch first.name.localizedStandardCompare(second.name) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: first.id.precedes(second.id)
                }
            }
    }
}

extension PeerID {
    /// Orders IDs byte by byte, so that two phones comparing the same pair agree.
    func precedes(_ other: PeerID) -> Bool {
        bytes.lexicographicallyPrecedes(other.bytes)
    }
}
