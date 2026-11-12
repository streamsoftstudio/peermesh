//
//  FrameTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Testing
@testable import PeerMesh

struct FrameTests {

    private let publicKey = Data(repeating: 7, count: 32)
    private let nonce = Data(repeating: 5, count: 16)
    private let ana = PeerID(bytes: Data(repeating: 1, count: 16))
    private let bea = PeerID(bytes: Data(repeating: 2, count: 16))

    @Test func framesSurviveEncoding() throws {
        let frames: [Frame] = [
            .hello(Hello(publicKey: publicKey, nonce: nonce, name: "Ana")),
            .proof(Data(repeating: 3, count: 32)),
            .announcement(Announcement(
                timeToLive: 5,
                publicKey: publicKey,
                sequence: 1_762_950_000_123,
                interval: .milliseconds(3_300),
                name: "Bea"
            )),
            .envelope(Envelope(kind: .message, timeToLive: 7, source: ana, destination: bea, counter: 42, sealed: Data(repeating: 9, count: 40))),
            .envelope(Envelope(kind: .acknowledgement, timeToLive: 1, source: bea, destination: ana, counter: 42, sealed: Data(repeating: 9, count: 28))),
        ]

        for frame in frames {
            #expect(try Frame(decoding: frame.encoded()) == frame)
        }
    }

    @Test func malformedFramesAreRejected() {
        let hello = Frame.hello(Hello(publicKey: publicKey, nonce: nonce, name: "Ana")).encoded()
        var otherVersion = hello
        otherVersion[otherVersion.startIndex] = 2

        for data in [Data(), otherVersion, Data(hello.dropLast()), hello + [0], Data([1, 9])] {
            #expect(throws: MalformedData.self) { try Frame(decoding: data) }
        }
    }

    @Test(arguments: [0, 8] as [UInt8])
    func timeToLiveMustBeOneToSeven(_ timeToLive: UInt8) {
        var data = Frame.announcement(Announcement(
            timeToLive: 1,
            publicKey: publicKey,
            sequence: 1,
            interval: .seconds(3),
            name: "Ana"
        )).encoded()
        data[data.startIndex + 2] = timeToLive

        #expect(throws: MalformedData.self) { try Frame(decoding: data) }
    }

    @Test func longNamesAreShortened() throws {
        let frame = Frame.hello(Hello(publicKey: publicKey, nonce: nonce, name: String(repeating: "a", count: 100)))

        let decoded = try Frame(decoding: frame.encoded())

        #expect(decoded == .hello(Hello(publicKey: publicKey, nonce: nonce, name: String(repeating: "a", count: 64))))
    }

    // MARK: - Chunks

    @Test(arguments: [1, 20, 182, 512])
    func framesAreRebuiltFromChunks(maximumChunkLength: Int) throws {
        let frames = [Data([42]), Data((0..<1_000).map { UInt8(truncatingIfNeeded: $0) }), Data(repeating: 1, count: 3)]
        var assembler = FrameAssembler()
        var received: [Data] = []

        for chunk in frames.flatMap({ FrameAssembler.chunks(of: $0, maximumChunkLength: maximumChunkLength) }) {
            received += try assembler.append(chunk)
        }

        #expect(received == frames)
    }

    @Test func oneChunkCanCompleteSeveralFrames() throws {
        let chunk = FrameAssembler.chunks(of: Data([1]), maximumChunkLength: 100)[0]
            + FrameAssembler.chunks(of: Data([2, 3]), maximumChunkLength: 100)[0]
        var assembler = FrameAssembler()

        #expect(try assembler.append(chunk) == [Data([1]), Data([2, 3])])
    }

    @Test func emptyFramesAreRejected() {
        #expect(throws: MalformedData.self) {
            var assembler = FrameAssembler()
            _ = try assembler.append(Data([0, 0]))
        }
    }
}
