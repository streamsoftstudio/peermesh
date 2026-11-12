//
//  FrameAssembler.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Cuts frames into chunks small enough for one Bluetooth write, and joins received chunks
/// back into frames.
///
/// Each frame goes out preceded by its length in two bytes. That's enough to find where frames
/// end, because a link delivers chunks in order and doesn't lose any while it stays open.
struct FrameAssembler {

    /// The longest frame a link can carry.
    static let maximumFrameLength = Int(UInt16.max)

    private var buffer = Data()

    static func chunks(of frame: Data, maximumChunkLength: Int) -> [Data] {
        precondition(frame.count <= maximumFrameLength, "A frame can't be longer than \(maximumFrameLength) bytes")
        let chunkLength = max(maximumChunkLength, 1)
        var bytes = Data(capacity: frame.count + 2)
        bytes.append(UInt8(frame.count >> 8))
        bytes.append(UInt8(frame.count & 0xFF))
        bytes.append(frame)
        return stride(from: 0, to: bytes.count, by: chunkLength).map { start in
            bytes.subdata(in: start..<min(start + chunkLength, bytes.count))
        }
    }

    /// Adds a received chunk and returns the frames it completes.
    ///
    /// Throws if the chunks don't form valid frames, after which the link can't be trusted.
    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 2 {
            let start = buffer.startIndex
            let length = Int(buffer[start]) << 8 | Int(buffer[start + 1])
            guard length > 0 else { throw MalformedData() }
            guard buffer.count >= 2 + length else { break }
            frames.append(buffer.subdata(in: start + 2..<start + 2 + length))
            buffer = buffer.subdata(in: start + 2 + length..<buffer.endIndex)
        }
        return frames
    }
}
