//
//  LinkQueue.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Frames waiting to go out on one link.
///
/// Control frames go before messages, which can be large. A frame that's already waiting, or
/// still being sent, isn't queued a second time, so a retransmission doesn't repeat a copy
/// that hasn't left yet. A frame is cut into chunks when its turn comes, using the link's
/// write size at that moment.
struct LinkQueue {
    private var control: [Data] = []
    private var messages: [Data] = []
    private var current: Data?
    private var chunks: [Data] = []

    var isEmpty: Bool {
        chunks.isEmpty && control.isEmpty && messages.isEmpty
    }

    mutating func append(_ frame: Data, priority: FramePriority) {
        let isBeingSent = !chunks.isEmpty && frame == current
        guard !isBeingSent, !control.contains(frame), !messages.contains(frame) else { return }
        switch priority {
        case .control: control.append(frame)
        case .message: messages.append(frame)
        }
    }

    /// The next chunk to send, or `nil` when there's nothing left. Call ``removeChunk()`` once
    /// the chunk has been handed over.
    mutating func nextChunk(maximumLength: Int) -> Data? {
        if chunks.isEmpty {
            guard let frame = control.first ?? messages.first else {
                current = nil
                return nil
            }
            if control.isEmpty {
                messages.removeFirst()
            } else {
                control.removeFirst()
            }
            current = frame
            chunks = FrameAssembler.chunks(of: frame, maximumChunkLength: maximumLength)
        }
        return chunks.first
    }

    mutating func removeChunk() {
        chunks.removeFirst()
    }

    mutating func removeAll() {
        control.removeAll()
        messages.removeAll()
        chunks.removeAll()
        current = nil
    }
}
