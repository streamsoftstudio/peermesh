//
//  Bytes.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// Builds a byte buffer, writing integers in network byte order.
struct ByteWriter {
    private(set) var data = Data()

    mutating func append(_ value: UInt8) {
        data.append(value)
    }

    mutating func append(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }

    mutating func append(_ bytes: Data) {
        data.append(bytes)
    }
}

/// Reads what a ``ByteWriter`` wrote.
struct ByteReader {
    private let data: Data
    private var position: Data.Index

    init(_ data: Data) {
        self.data = data
        position = data.startIndex
    }

    var isAtEnd: Bool {
        position == data.endIndex
    }

    mutating func readUInt8() throws -> UInt8 {
        guard position < data.endIndex else { throw MalformedData() }
        defer { position += 1 }
        return data[position]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = try UInt16(readUInt8())
        let low = try UInt16(readUInt8())
        return high << 8 | low
    }

    mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = try value << 8 | UInt64(readUInt8())
        }
        return value
    }

    mutating func readBytes(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - position >= count else { throw MalformedData() }
        defer { position += count }
        return Data(data[position..<position + count])
    }

    mutating func readRemainingBytes() -> Data {
        defer { position = data.endIndex }
        return Data(data[position...])
    }
}

/// Thrown when received bytes aren't in the expected format.
struct MalformedData: Error {}
