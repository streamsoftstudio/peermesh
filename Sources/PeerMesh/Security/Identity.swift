//
//  Identity.swift
//  PeerMesh
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import CryptoKit
import Foundation
import Security

/// This phone's key pair. Other phones know it by its public key, and by the ID derived
/// from that key.
struct Identity {
    let privateKey: Curve25519.KeyAgreement.PrivateKey
    let publicKey: Data
    let id: PeerID

    init(privateKey: Curve25519.KeyAgreement.PrivateKey = .init()) {
        self.privateKey = privateKey
        publicKey = privateKey.publicKey.rawRepresentation
        id = PeerID(publicKey: publicKey)
    }

    /// Reads this phone's identity from `store`, creating and saving one on first use.
    static func load(from store: some KeyStore) throws -> Identity {
        guard let stored = try store.read() else {
            let identity = Identity()
            try store.write(identity.privateKey.rawRepresentation)
            return identity
        }
        guard let privateKey = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored) else {
            throw MeshError.identityUnavailable(status: errSecDecode)
        }
        return Identity(privateKey: privateKey)
    }
}

extension PeerID {
    /// The ID of the phone that holds the private key for `publicKey`.
    init(publicKey: Data) {
        var hash = SHA256()
        hash.update(data: Data("PeerMesh peer ID".utf8))
        hash.update(data: publicKey)
        self.init(bytes: Data(hash.finalize().prefix(PeerID.length)))
    }
}

/// Where this phone's private key is kept.
protocol KeyStore {
    func read() throws -> Data?
    func write(_ key: Data) throws
}

/// Keeps the private key in the keychain.
///
/// The key is readable once the phone has been unlocked after starting up, so the mesh can run
/// in the background. It never leaves the device: it isn't synced through iCloud Keychain or
/// restored onto another phone.
struct KeychainKeyStore: KeyStore {
    var service = "PeerMesh"
    var account = "identity"

    func read() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw MeshError.identityUnavailable(status: status)
        }
    }

    func write(_ key: Data) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw MeshError.identityUnavailable(status: status) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
