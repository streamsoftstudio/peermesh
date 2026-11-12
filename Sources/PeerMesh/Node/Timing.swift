//
//  Timing.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// How often a phone announces itself, and how long it waits for things.
struct Timing: Sendable {

    /// How often a phone announces itself in a small mesh.
    var shortestAnnouncementInterval: Duration = .seconds(3)

    /// How often a phone announces itself in a mesh of 50 phones or more.
    var longestAnnouncementInterval: Duration = .seconds(6)

    /// How long a route through other phones lasts after two announcements in a row are missed.
    var routeGrace: Duration = .seconds(2)

    /// How often expired routes are removed and announcements checked.
    var maintenanceInterval: Duration = .seconds(1)

    /// How long the phone at the other end of a new link has to say who it is.
    var identificationTimeout: Duration = .seconds(10)

    /// How long to wait for an acknowledgement from a peer in range before sending again.
    var firstRetransmission: Duration = .seconds(1)

    /// How much longer to wait for each further link.
    var retransmissionPerHop: Duration = .milliseconds(300)

    /// The longest wait between two attempts.
    var longestRetransmission: Duration = .seconds(10)

    /// The throughput assumed for a link, to allow time for large messages.
    var bytesPerSecond: Double = 10_000

    static let standard = Timing()
}
