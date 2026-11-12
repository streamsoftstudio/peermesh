//
//  ConversationView.swift
//  PeerMeshDemo
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import PeerMesh
import SwiftUI

/// The messages exchanged with one phone, and a field to send more.
struct ConversationView: View {
    let chat: Chat
    let peer: PeerID
    @State private var draft = ""

    var body: some View {
        ScrollViewReader { proxy in
            List(chat.conversations[peer] ?? []) { entry in
                EntryRow(entry: entry)
                    .id(entry.id)
            }
            .listStyle(.plain)
            .onChange(of: chat.conversations[peer]?.last?.id) { _, id in
                if let id {
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
            .background(.bar)
        }
        .navigationTitle(chat.names[peer] ?? PeersView.shortID(peer))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A short message whose delivery time is the round trip to the other phone.
            Button("Ping") { chat.send("Ping", to: peer) }
        }
        .onAppear { chat.conversationAppeared(peer) }
        .onDisappear { chat.conversationDisappeared(peer) }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        chat.send(text, to: peer)
        draft = ""
    }
}

private struct EntryRow: View {
    let entry: Chat.Entry

    var body: some View {
        let isOwn = entry.sender == nil
        VStack(alignment: isOwn ? .trailing : .leading, spacing: 2) {
            Text(entry.text)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: isOwn ? .trailing : .leading)
    }

    private var detail: String {
        let time = entry.date.formatted(date: .omitted, time: .standard)
        if let sender = entry.sender {
            return "\(time), \(sender.hops == 1 ? "in range" : "\(sender.hops) hops")"
        }
        switch entry.status {
        case .delivered(let duration):
            return "\(time), delivered in \(Int(duration / .milliseconds(1))) ms"
        case .failed(let reason):
            return "\(time), not delivered: \(reason)"
        case .sending, nil:
            return "\(time), sending..."
        }
    }
}
