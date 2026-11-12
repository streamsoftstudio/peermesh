//
//  PeerIDTests.swift
//  PeerMeshTests
//
//  Created by Andrija Milovanovic on 12.11.2026.
//

import Foundation
import Testing
@testable import PeerMesh

struct PeerIDTests {

    private let id = PeerID(bytes: Data((0..<16).map { UInt8($0 * 17) }))

    @Test func describesItselfAsLowercaseHex() {
        #expect(id.description == "00112233445566778899aabbccddeeff")
    }

    @Test func readsBackItsDescription() {
        #expect(PeerID(id.description) == id)
        #expect(PeerID("00112233445566778899AABBCCDDEEFF") == id)
    }

    @Test(arguments: [
        "",
        "00112233445566778899aabbccddeef",
        "00112233445566778899aabbccddeeff00",
        "00112233445566778899aabbccddeefg",
    ])
    func rejectsStringsThatAreNotIDs(_ string: String) {
        #expect(PeerID(string) == nil)
    }

    @Test func encodesAsItsDescription() throws {
        let data = try JSONEncoder().encode([id])
        #expect(String(decoding: data, as: UTF8.self) == #"["00112233445566778899aabbccddeeff"]"#)
        #expect(try JSONDecoder().decode([PeerID].self, from: data) == [id])
    }

    @Test func refusesToDecodeOtherStrings() {
        let data = Data(#"["not a peer ID"]"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([PeerID].self, from: data)
        }
    }
}
