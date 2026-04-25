// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

@testable import BryggaCore
import XCTest

final class BouncerNetworkTests: XCTestCase {
	// MARK: - Attribute string parsing

	func testParseSimpleAttributes() {
		let attrs = IRCLineParser.parseAttributeString("name=Libera;state=connected")
		XCTAssertEqual(attrs["name"], "Libera")
		XCTAssertEqual(attrs["state"], "connected")
	}

	func testParseAttributeWithEscapedSpace() {
		// soju example from the spec: `My\sAwesome\sNetwork`
		let attrs = IRCLineParser.parseAttributeString("name=My\\sAwesome\\sNetwork;state=disconnected")
		XCTAssertEqual(attrs["name"], "My Awesome Network")
		XCTAssertEqual(attrs["state"], "disconnected")
	}

	func testParseAttributeWithEscapedSeparator() {
		// `\:` decodes to `;` so an attribute value can contain semicolons.
		let attrs = IRCLineParser.parseAttributeString("error=connect\\:foo")
		XCTAssertEqual(attrs["error"], "connect;foo")
	}

	func testParseAttributeWithBareKey() {
		// A bare key with no `=` becomes an empty-string value.
		let attrs = IRCLineParser.parseAttributeString("flag;name=foo")
		XCTAssertEqual(attrs["flag"], "")
		XCTAssertEqual(attrs["name"], "foo")
	}

	// MARK: - BouncerNetwork construction

	func testInitFromAttributes() {
		let net = BouncerNetwork(id: "42", attributes: [
			"name": "Libera",
			"host": "irc.libera.chat",
			"state": "connected",
		])
		XCTAssertEqual(net.id, "42")
		XCTAssertEqual(net.name, "Libera")
		XCTAssertEqual(net.host, "irc.libera.chat")
		XCTAssertEqual(net.state, .connected)
		XCTAssertNil(net.errorMessage)
	}

	func testInitFromAttributesUnknownStateBecomesUnknown() {
		let net = BouncerNetwork(id: "1", attributes: ["state": "weird"])
		XCTAssertEqual(net.state, .unknown)
	}

	// MARK: - BouncerNetwork merge semantics

	func testMergeUpdatesProvidedFields() {
		var net = BouncerNetwork(id: "1", name: "Old", host: "old.example", state: .disconnected)
		net.merge(["name": "New", "state": "connected"])
		XCTAssertEqual(net.name, "New")
		XCTAssertEqual(net.host, "old.example", "host wasn't in the update; should be unchanged")
		XCTAssertEqual(net.state, .connected)
	}

	func testMergeEmptyValueClearsField() {
		// Per the spec: "An attribute without a value means that the
		// attribute has been removed."
		var net = BouncerNetwork(id: "1", name: "Foo")
		net.merge(["name": ""])
		XCTAssertNil(net.name)
	}

	func testMergeIgnoresUnknownKeys() {
		var net = BouncerNetwork(id: "1", name: "Foo", state: .connected)
		net.merge(["weird-future-attr": "bar"])
		XCTAssertEqual(net.name, "Foo")
		XCTAssertEqual(net.state, .connected)
	}
}
