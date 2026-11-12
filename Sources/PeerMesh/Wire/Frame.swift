//
//  Frame.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation

/// What phones send each other over a Bluetooth link.
enum Frame: Equatable {

    /// Introduces the phone at one end of a link. Both ends send one when the link opens.
    case hello(Hello)

    /// Answers the other end's hello, proving that this phone holds the private key for the
    /// public key in its own hello.
    case proof(Data)

    /// Tells the mesh that a phone is reachable. Every phone passes it on, so it reaches the
    /// whole mesh.
    case announcement(Announcement)

    /// A message or an acknowledgement on its way to one phone.
    case envelope(Envelope)
}

struct Hello: Equatable {
    var publicKey: Data
    /// A random value the other end's proof has to answer, so that a proof can't be replayed.
    var nonce: Data
    var name: String
}

struct Announcement: Equatable {
    /// How many more links the announcement may cross, including the next one.
    var timeToLive: UInt8
    var publicKey: Data
    /// Grows with every announcement the phone makes.
    var sequence: UInt64
    /// How often the phone announces itself.
    var interval: Duration
    var name: String
}

struct Envelope: Equatable {

    enum Kind: UInt8 {
        case message = 3
        case acknowledgement = 4
    }

    var kind: Kind
    /// How many more links the envelope may cross, including the next one.
    var timeToLive: UInt8
    var source: PeerID
    var destination: PeerID
    /// Orders the sender's messages. An acknowledgement repeats the counter of the message it
    /// confirms.
    var counter: UInt64
    /// The encrypted contents, with their nonce and authentication tag.
    var sealed: Data

    /// The fields the sender authenticates along with the contents: all but the time to live,
    /// which each relay lowers, plus the service, so that an envelope only opens in the mesh it
    /// was sent in.
    func authenticatedFields(service: Data) -> Data {
        var writer = ByteWriter()
        writer.append(Frame.version)
        writer.append(kind.rawValue)
        writer.append(service)
        writer.append(source.bytes)
        writer.append(destination.bytes)
        writer.append(counter)
        return writer.data
    }
}

// MARK: - Encoding

extension Frame {

    static let version: UInt8 = 1
    static let publicKeyLength = 32
    static let nonceLength = 16
    static let proofLength = 32
    static let maximumNameLength = 64

    private enum Tag: UInt8 {
        case hello = 1
        case announcement = 2
        case proof = 5
    }

    /// Messages wait behind everything else, which is small and keeps the mesh working.
    var priority: FramePriority {
        if case .envelope(let envelope) = self, envelope.kind == .message {
            return .message
        }
        return .control
    }

    func encoded() -> Data {
        var writer = ByteWriter()
        writer.append(Self.version)
        switch self {
        case .hello(let hello):
            writer.append(Tag.hello.rawValue)
            writer.append(hello.publicKey)
            writer.append(hello.nonce)
            writer.appendName(hello.name)
        case .proof(let proof):
            writer.append(Tag.proof.rawValue)
            writer.append(proof)
        case .announcement(let announcement):
            writer.append(Tag.announcement.rawValue)
            writer.append(announcement.timeToLive)
            writer.append(announcement.publicKey)
            writer.append(announcement.sequence)
            writer.append(UInt16(clamping: announcement.interval.milliseconds))
            writer.appendName(announcement.name)
        case .envelope(let envelope):
            writer.append(envelope.kind.rawValue)
            writer.append(envelope.timeToLive)
            writer.append(envelope.source.bytes)
            writer.append(envelope.destination.bytes)
            writer.append(envelope.counter)
            writer.append(envelope.sealed)
        }
        return writer.data
    }

    init(decoding data: Data) throws {
        var reader = ByteReader(data)
        guard try reader.readUInt8() == Self.version else { throw MalformedData() }
        let tag = try reader.readUInt8()
        switch tag {
        case Tag.hello.rawValue:
            let publicKey = try reader.readBytes(Self.publicKeyLength)
            let nonce = try reader.readBytes(Self.nonceLength)
            let name = try reader.readName()
            self = .hello(Hello(publicKey: publicKey, nonce: nonce, name: name))
        case Tag.proof.rawValue:
            self = try .proof(reader.readBytes(Self.proofLength))
        case Tag.announcement.rawValue:
            let timeToLive = try reader.readTimeToLive()
            let publicKey = try reader.readBytes(Self.publicKeyLength)
            let sequence = try reader.readUInt64()
            let interval = try Duration.milliseconds(reader.readUInt16())
            let name = try reader.readName()
            self = .announcement(Announcement(
                timeToLive: timeToLive,
                publicKey: publicKey,
                sequence: sequence,
                interval: interval,
                name: name
            ))
        default:
            guard let kind = Envelope.Kind(rawValue: tag) else { throw MalformedData() }
            let timeToLive = try reader.readTimeToLive()
            let source = try PeerID(bytes: reader.readBytes(PeerID.length))
            let destination = try PeerID(bytes: reader.readBytes(PeerID.length))
            let counter = try reader.readUInt64()
            self = .envelope(Envelope(
                kind: kind,
                timeToLive: timeToLive,
                source: source,
                destination: destination,
                counter: counter,
                sealed: reader.readRemainingBytes()
            ))
        }
        guard reader.isAtEnd else { throw MalformedData() }
    }
}

private extension ByteWriter {
    mutating func appendName(_ name: String) {
        let bytes = Data(name.truncated(toUTF8Length: Frame.maximumNameLength).utf8)
        append(UInt8(bytes.count))
        append(bytes)
    }
}

private extension ByteReader {
    mutating func readName() throws -> String {
        let length = try Int(readUInt8())
        guard length <= Frame.maximumNameLength else { throw MalformedData() }
        return try String(decoding: readBytes(length), as: UTF8.self)
    }

    mutating func readTimeToLive() throws -> UInt8 {
        let timeToLive = try readUInt8()
        guard (1...Mesh.maximumHops).contains(Int(timeToLive)) else { throw MalformedData() }
        return timeToLive
    }
}

private extension Duration {
    var milliseconds: Int64 {
        components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }
}

extension String {
    /// The longest beginning of the string that fits in `limit` bytes of UTF-8, cut between
    /// characters.
    func truncated(toUTF8Length limit: Int) -> String {
        var length = 0
        return String(prefix { character in
            length += character.utf8.count
            return length <= limit
        })
    }
}
