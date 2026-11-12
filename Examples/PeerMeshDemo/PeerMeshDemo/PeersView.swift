//
//  PeersView.swift
//  PeerMeshDemo
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import PeerMesh
import SwiftUI

/// This phone, the phones in reach, and earlier conversations with phones out of reach.
struct PeersView: View {
    let chat: Chat
    @State private var isRenaming = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section("This phone") {
                    LabeledContent("Name", value: chat.name)
                    LabeledContent("ID", value: chat.id.map(Self.shortID) ?? "none")
                    Text(stateDescription)
                        .foregroundStyle(.secondary)
                }
                Section("In reach") {
                    if chat.peers.isEmpty {
                        Text("Looking for phones running PeerMesh Demo...")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(chat.peers) { peer in
                        NavigationLink(value: peer.id) {
                            PeerRow(
                                name: peer.name,
                                detail: "\(peer.hops == 1 ? "In range" : "\(peer.hops) hops away"), \(Self.shortID(peer.id))",
                                unread: chat.unread[peer.id] ?? 0
                            )
                        }
                    }
                }
                if !chat.peersOutOfReach.isEmpty {
                    Section("Out of reach") {
                        ForEach(chat.peersOutOfReach, id: \.self) { id in
                            NavigationLink(value: id) {
                                PeerRow(
                                    name: chat.names[id] ?? Self.shortID(id),
                                    detail: "Can't be reached right now",
                                    unread: chat.unread[id] ?? 0
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("PeerMesh Demo")
            .navigationDestination(for: PeerID.self) { id in
                ConversationView(chat: chat, peer: id)
            }
            .toolbar {
                Button("Rename") {
                    newName = chat.name
                    isRenaming = true
                }
            }
            .alert("Name", isPresented: $isRenaming) {
                TextField("Name", text: $newName)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                Button("Save") { chat.rename(to: newName) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The name other phones see for this one.")
            }
        }
    }

    private var stateDescription: String {
        if let problem = chat.problem {
            return problem
        }
        switch chat.state {
        case .stopped: return "Stopped"
        case .starting: return "Starting..."
        case .running: return "Running"
        case .bluetoothOff: return "Bluetooth is off. Turn it on in Control Center or Settings."
        case .bluetoothDenied: return "This app isn't allowed to use Bluetooth. Allow it in Settings."
        case .unsupported: return "This device can't use Bluetooth Low Energy."
        }
    }

    static func shortID(_ id: PeerID) -> String {
        String(id.description.prefix(8))
    }
}

private struct PeerRow: View {
    let name: String
    let detail: String
    let unread: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.tint, in: Capsule())
            }
        }
    }
}
