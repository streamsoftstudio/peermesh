//
//  Chat.swift
//  PeerMeshDemo
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Observation
import PeerMesh
import UIKit
import UserNotifications

/// Runs the mesh for the app and keeps the conversations with other phones.
@MainActor
@Observable
final class Chat {

    struct Entry: Identifiable {
        enum Status: Equatable {
            case sending
            case delivered(Duration)
            case failed(String)
        }

        let id = UUID()
        let text: String
        let date = Date()
        /// The phone that sent the message, or `nil` if this phone sent it.
        let sender: Peer?
        var status: Status?
    }

    static let service = "rs.streamsoft.peermesh.demo"

    private(set) var name: String
    private(set) var id: PeerID?
    private(set) var state: Mesh.State = .stopped
    private(set) var problem: String?
    private(set) var peers: [Peer] = []
    private(set) var conversations: [PeerID: [Entry]] = [:]
    /// The names of everyone this phone has talked to, including phones out of reach.
    private(set) var names: [PeerID: String] = [:]
    private(set) var unread: [PeerID: Int] = [:]
    private(set) var openConversation: PeerID?

    @ObservationIgnored private var mesh: Mesh?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init() {
        name = UserDefaults.standard.string(forKey: "name") ?? UIDevice.current.name
        startMesh()
    }

    /// Phones this phone has talked to that can't be reached right now.
    var peersOutOfReach: [PeerID] {
        let reachable = Set(peers.map(\.id))
        return conversations.keys
            .filter { !reachable.contains($0) }
            .sorted { (names[$0] ?? "") < (names[$1] ?? "") }
    }

    func rename(to newName: String) {
        let newName = newName.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty, newName != name else { return }
        name = newName
        UserDefaults.standard.set(newName, forKey: "name")
        startMesh()
    }

    func send(_ text: String, to peer: PeerID) {
        guard let mesh else { return }
        let entry = Entry(text: text, sender: nil, status: .sending)
        conversations[peer, default: []].append(entry)
        Task {
            let start = ContinuousClock.now
            let status: Entry.Status
            do {
                try await mesh.send(Data(text.utf8), to: peer)
                status = .delivered(ContinuousClock.now - start)
            } catch {
                status = .failed(Self.describe(error))
            }
            if let index = conversations[peer]?.firstIndex(where: { $0.id == entry.id }) {
                conversations[peer]?[index].status = status
            }
        }
    }

    func conversationAppeared(_ peer: PeerID) {
        openConversation = peer
        unread[peer] = nil
    }

    func conversationDisappeared(_ peer: PeerID) {
        if openConversation == peer {
            openConversation = nil
        }
    }

    /// Starts a new mesh. A mesh keeps the name it was created with, so renaming needs one.
    private func startMesh() {
        tasks.forEach { $0.cancel() }
        mesh?.stop()
        do {
            let mesh = try Mesh(service: Self.service, name: name)
            self.mesh = mesh
            id = mesh.id
            problem = nil
            tasks = [
                Task { [weak self] in
                    for await state in mesh.stateUpdates {
                        self?.state = state
                    }
                },
                Task { [weak self] in
                    for await peers in mesh.peerUpdates {
                        self?.update(peers)
                    }
                },
                Task { [weak self] in
                    for await message in mesh.messages {
                        self?.receive(message)
                    }
                },
            ]
            mesh.start()
        } catch {
            problem = "Couldn't start: \(Self.describe(error))"
        }
    }

    private func update(_ peers: [Peer]) {
        self.peers = peers
        for peer in peers {
            names[peer.id] = peer.name
        }
    }

    private func receive(_ message: Message) {
        let sender = message.sender
        let text = String(decoding: message.data, as: UTF8.self)
        names[sender.id] = sender.name
        conversations[sender.id, default: []].append(Entry(text: text, sender: sender))
        let isInBackground = UIApplication.shared.applicationState != .active
        if isInBackground || openConversation != sender.id {
            unread[sender.id, default: 0] += 1
        }
        if isInBackground {
            notify(from: sender.name, text: text)
        }
    }

    private func notify(from name: String, text: String) {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = text
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func describe(_ error: any Error) -> String {
        switch error as? MeshError {
        case .timedOut: "not confirmed in time"
        case .notRunning: "the mesh stopped"
        case .messageTooLarge: "too long"
        case .identityUnavailable(let status): "keychain error \(status)"
        case nil: error is CancellationError ? "cancelled" : error.localizedDescription
        }
    }
}
