// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import XCTest
@testable import BryggaCore

final class SCRAMSHA256Tests: XCTestCase {

	func testRFC7677Exchange() throws {
		// RFC 7677 §3 SCRAM-SHA-256 example.
		let clientNonce = "rOprNGfwEbeRWgbNEkqO"
		let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," +
			"s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
		let expectedFinal = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," +
			"p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ="
		let serverFinal = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="

		var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: clientNonce)

		XCTAssertEqual(client.clientFirstMessage(), "n,,n=user,r=\(clientNonce)")

		let final = try client.clientFinalMessage(serverFirst: serverFirst)
		XCTAssertEqual(final, expectedFinal)

		XCTAssertNoThrow(try client.verifyServerFinal(serverFinal))
		XCTAssertTrue(client.isFinished)
	}

	func testNonceMismatchFails() {
		var client = SCRAMSHA256Client(username: "u", password: "p", clientNonce: "ABC")
		_ = client.clientFirstMessage()
		XCTAssertThrowsError(try client.clientFinalMessage(
			serverFirst: "r=ZZZ,s=QUJD,i=4096"
		)) { error in
			XCTAssertEqual(error as? SCRAMSHA256Client.SCRAMError, .nonceMismatch)
		}
	}

	func testServerSignatureMismatchFails() throws {
		let clientNonce = "rOprNGfwEbeRWgbNEkqO"
		let serverFirst = "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0," +
			"s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"
		let bogusServerFinal = "v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

		var client = SCRAMSHA256Client(username: "user", password: "pencil", clientNonce: clientNonce)
		_ = client.clientFirstMessage()
		_ = try client.clientFinalMessage(serverFirst: serverFirst)
		XCTAssertThrowsError(try client.verifyServerFinal(bogusServerFinal)) { error in
			XCTAssertEqual(error as? SCRAMSHA256Client.SCRAMError, .serverSignatureMismatch)
		}
	}

	func testParseAttributesHandlesBase64WithPadding() {
		let attrs = SCRAMSHA256Client.parseAttributes("s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096,r=abc")
		XCTAssertEqual(attrs["s"], "W22ZaJ0SNY7soEsUEjb6gQ==")
		XCTAssertEqual(attrs["i"], "4096")
		XCTAssertEqual(attrs["r"], "abc")
	}

	func testPBKDF2ProducesDerivedKey() {
		let salt = Data(base64Encoded: "W22ZaJ0SNY7soEsUEjb6gQ==")!
		let derived = SCRAMSHA256Client.pbkdf2SHA256(
			password: "pencil",
			salt: salt,
			iterations: 4096,
			keyLength: 32
		)
		XCTAssertEqual(derived.count, 32)
		XCTAssertFalse(derived.allSatisfy { $0 == 0 })
	}
}
