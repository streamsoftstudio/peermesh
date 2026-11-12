//
//  LinkQueueTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Testing
@testable import PeerMesh

struct LinkQueueTests {

    private let message = Data(repeating: 7, count: 100)
    private let announcement = Data([2, 2, 2])

    @Test func controlFramesGoBeforeMessages() throws {
        var queue = LinkQueue()
        queue.append(message, priority: .message)
        queue.append(announcement, priority: .control)

        #expect(try send(&queue) == [announcement, message])
    }

    @Test func waitingFrameIsNotQueuedTwice() throws {
        var queue = LinkQueue()
        queue.append(message, priority: .message)
        queue.append(message, priority: .message)

        #expect(try send(&queue) == [message])
    }

    @Test func frameBeingSentIsNotQueuedAgain() throws {
        var queue = LinkQueue()
        queue.append(message, priority: .message)
        _ = queue.nextChunk(maximumLength: 20)
        queue.removeChunk()

        queue.append(message, priority: .message)

        var assembler = FrameAssembler()
        _ = try assembler.append(FrameAssembler.chunks(of: message, maximumChunkLength: 20)[0])
        var frames: [Data] = []
        while let chunk = queue.nextChunk(maximumLength: 20) {
            frames += try assembler.append(chunk)
            queue.removeChunk()
        }
        #expect(frames == [message])
    }

    @Test func sentFrameCanBeQueuedAgain() throws {
        var queue = LinkQueue()
        queue.append(message, priority: .message)
        _ = try send(&queue)

        queue.append(message, priority: .message)

        #expect(try send(&queue) == [message])
    }

    @Test func chunksRespectTheWriteSize() {
        var queue = LinkQueue()
        queue.append(message, priority: .message)

        while let chunk = queue.nextChunk(maximumLength: 20) {
            #expect(chunk.count <= 20)
            queue.removeChunk()
        }
        #expect(queue.isEmpty)
    }

    /// Sends everything in the queue and returns the frames the other end puts back together.
    private func send(_ queue: inout LinkQueue) throws -> [Data] {
        var assembler = FrameAssembler()
        var frames: [Data] = []
        while let chunk = queue.nextChunk(maximumLength: 20) {
            frames += try assembler.append(chunk)
            queue.removeChunk()
        }
        return frames
    }
}
