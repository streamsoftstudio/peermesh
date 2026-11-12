//
//  SecurityTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Security
import Testing
@testable import PeerMesh

struct SecurityTests {

    private let ana = Identity()
    private let bea = Identity()
    private let cai = Identity()
    private let move = Data("e2e4".utf8)
    private let chess = Data(serviceTag: "chess")

    // MARK: - Identity

    @Test func identityIsCreatedOnceAndThenLoaded() throws {
        let store = MemoryKeyStore()

        let first = try Identity.load(from: store)
        let second = try Identity.load(from: store)

        #expect(store.key != nil)
        #expect(first.id == second.id)
    }

    @Test func damagedStoredKeyIsReported() {
        let store = MemoryKeyStore()
        store.key = Data([1, 2, 3])

        #expect(throws: MeshError.identityUnavailable(status: errSecDecode)) {
            try Identity.load(from: store)
        }
    }

    @Test func peerIDComesFromThePublicKey() {
        #expect(ana.id == PeerID(publicKey: ana.publicKey))
        #expect(ana.id != bea.id)
    }

    // MARK: - Proofs

    @Test func proofFromTheKeyHolderIsAccepted() throws {
        let anaNonce = Data(repeating: 1, count: 16)
        let beaNonce = Data(repeating: 2, count: 16)

        let proof = try keys(of: bea, with: ana).proof(answering: anaNonce, ownNonce: beaNonce, service: chess)

        #expect(try keys(of: ana, with: bea).isValidProof(proof, answering: anaNonce, otherNonce: beaNonce, service: chess))
    }

    @Test func proofWithoutThePrivateKeyIsRejected() throws {
        let anaNonce = Data(repeating: 1, count: 16)
        let beaNonce = Data(repeating: 2, count: 16)
        // Cai claims to be Bea, but only has Cai's own private key.
        let proof = try keys(of: cai, with: ana).proof(answering: anaNonce, ownNonce: beaNonce, service: chess)

        #expect(try !keys(of: ana, with: bea).isValidProof(proof, answering: anaNonce, otherNonce: beaNonce, service: chess))
    }

    @Test func proofForAnotherNonceIsRejected() throws {
        let beaNonce = Data(repeating: 2, count: 16)
        let proof = try keys(of: bea, with: ana).proof(answering: Data(repeating: 1, count: 16), ownNonce: beaNonce, service: chess)

        #expect(try !keys(of: ana, with: bea).isValidProof(proof, answering: Data(repeating: 9, count: 16), otherNonce: beaNonce, service: chess))
    }

    // MARK: - Envelopes

    @Test func onlyTheRecipientCanOpenAnEnvelope() throws {
        let envelope = try sealedMove()

        #expect(try envelope.open(using: keys(of: bea, with: ana).receiving, service: chess) == move)
        #expect(throws: (any Error).self) { try envelope.open(using: keys(of: cai, with: ana).receiving, service: chess) }
        #expect(throws: (any Error).self) { try envelope.open(using: keys(of: bea, with: ana).sending, service: chess) }
    }

    @Test func envelopeChangedOnTheWayDoesNotOpen() throws {
        let envelope = try sealedMove()
        let key = try keys(of: bea, with: ana).receiving
        var otherCounter = envelope
        otherCounter.counter += 1
        var otherDestination = envelope
        otherDestination.destination = cai.id
        var otherContents = envelope
        otherContents.sealed[otherContents.sealed.startIndex + 12] ^= 1

        #expect(throws: (any Error).self) { try otherCounter.open(using: key, service: chess) }
        #expect(throws: (any Error).self) { try otherDestination.open(using: key, service: chess) }
        #expect(throws: (any Error).self) { try otherContents.open(using: key, service: chess) }
    }

    @Test func envelopeDoesNotOpenInAnotherService() throws {
        let envelope = try sealedMove()

        #expect(throws: (any Error).self) {
            try envelope.open(using: keys(of: bea, with: ana).receiving, service: Data(serviceTag: "chat"))
        }
    }

    @Test func relaysMayLowerTheTimeToLive() throws {
        var envelope = try sealedMove()
        envelope.timeToLive = 3

        #expect(try envelope.open(using: keys(of: bea, with: ana).receiving, service: chess) == move)
    }

    private func keys(of identity: Identity, with other: Identity) throws -> PairwiseKeys {
        try PairwiseKeys(identity: identity, otherPublicKey: other.publicKey)
    }

    private func sealedMove() throws -> Envelope {
        try Envelope.seal(
            move,
            kind: .message,
            from: ana.id,
            to: bea.id,
            counter: 1,
            service: chess,
            using: keys(of: ana, with: bea).sending
        )
    }
}
