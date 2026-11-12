//
//  PairwiseKeys.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import CryptoKit
import Foundation

/// The keys two phones share.
///
/// Each phone derives them from its own private key and the other phone's public key, so only
/// those two phones can. Each direction gets its own key.
struct PairwiseKeys {
    /// Seals what this phone sends to the other one.
    let sending: SymmetricKey
    /// Opens what the other phone sends to this one.
    let receiving: SymmetricKey

    init(identity: Identity, otherPublicKey: Data) throws {
        let otherKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: otherPublicKey)
        let secret = try identity.privateKey.sharedSecretFromKeyAgreement(with: otherKey)
        let other = PeerID(publicKey: otherPublicKey)
        sending = Self.key(from: secret, sender: identity.id, recipient: other)
        receiving = Self.key(from: secret, sender: other, recipient: identity.id)
    }

    private static func key(from secret: SharedSecret, sender: PeerID, recipient: PeerID) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("PeerMesh v1".utf8),
            sharedInfo: sender.bytes + recipient.bytes,
            outputByteCount: 32
        )
    }
}

// MARK: - Proving identity

extension PairwiseKeys {

    private static let proofLabel = Data("PeerMesh hello".utf8)

    /// Answers the nonce in the other phone's hello. Only a phone that holds this phone's
    /// private key can.
    func proof(answering otherNonce: Data, ownNonce: Data, service: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Self.proofLabel + service + otherNonce + ownNonce, using: sending))
    }

    /// Checks the other phone's answer to the nonce in this phone's hello.
    func isValidProof(_ proof: Data, answering ownNonce: Data, otherNonce: Data, service: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            proof,
            authenticating: Self.proofLabel + service + ownNonce + otherNonce,
            using: receiving
        )
    }
}

// MARK: - Sealing envelopes

extension Envelope {

    /// Creates an envelope whose contents only the recipient can read. The recipient can also
    /// tell if anything other than the time to live was changed on the way, or if the envelope
    /// comes from another service.
    static func seal(
        _ contents: Data,
        kind: Kind,
        from source: PeerID,
        to destination: PeerID,
        counter: UInt64,
        service: Data,
        using key: SymmetricKey
    ) throws -> Envelope {
        var envelope = Envelope(
            kind: kind,
            timeToLive: UInt8(Mesh.maximumHops),
            source: source,
            destination: destination,
            counter: counter,
            sealed: Data()
        )
        envelope.sealed = try ChaChaPoly.seal(
            contents,
            using: key,
            authenticating: envelope.authenticatedFields(service: service)
        ).combined
        return envelope
    }

    /// Returns the contents. Throws if the envelope wasn't sealed with `key` for `service`, or
    /// was changed.
    func open(using key: SymmetricKey, service: Data) throws -> Data {
        try ChaChaPoly.open(
            ChaChaPoly.SealedBox(combined: sealed),
            using: key,
            authenticating: authenticatedFields(service: service)
        )
    }
}

extension Data {
    /// Identifies a service in what phones authenticate, so that nothing sent in one service
    /// is accepted in another.
    init(serviceTag service: String) {
        self.init(SHA256.hash(data: Data("PeerMesh service \(service)".utf8)).prefix(16))
    }
}
