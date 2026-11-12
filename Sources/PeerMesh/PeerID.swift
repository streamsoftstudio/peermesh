//
//  PeerID.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// A phone's identity in the mesh.
///
/// It's derived from a key that only that phone holds, so no other phone can use it, and
/// it stays the same across app launches. Store it as the string from ``description`` and
/// read it back with ``init(_:)``, or encode it with `Codable`, which uses the same string.
public struct PeerID: Hashable, Sendable {

    static let length = 16

    /// The identity's bytes.
    let bytes: Data

    init(bytes: Data) {
        precondition(bytes.count == Self.length, "A peer ID is \(Self.length) bytes long")
        self.bytes = bytes
    }
}

extension PeerID: LosslessStringConvertible {

    /// The identity as 32 lowercase hexadecimal characters.
    public var description: String {
        var characters: [UInt8] = []
        characters.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            characters.append(Self.hexDigits[Int(byte >> 4)])
            characters.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    /// Reads an identity from a string made by ``description``.
    ///
    /// Returns `nil` if the string isn't 32 hexadecimal characters.
    public init?(_ description: String) {
        let characters = Array(description.utf8)
        guard characters.count == Self.length * 2 else { return nil }

        var bytes = Data(capacity: Self.length)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = Self.value(ofHexDigit: characters[index]),
                  let low = Self.value(ofHexDigit: characters[index + 1])
            else { return nil }
            bytes.append(high << 4 | low)
        }
        self.init(bytes: bytes)
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func value(ofHexDigit character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

extension PeerID: Codable {

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let id = PeerID(string) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "\"\(string)\" isn't a peer ID"
            )
        }
        self = id
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
