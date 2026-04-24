// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import Foundation

/// A single visual row in the message buffer. Either a real `Message`,
/// or a folded run of consecutive presence traffic (joins, parts, quits,
/// nick changes) that the view renders as one compacted line with a
/// disclosure triangle.
public enum ChatEntry: Identifiable {
	case message(Message)
	case presenceRun(id: UUID, messages: [Message])

	public var id: UUID {
		switch self {
		case let .message(m): m.id
		case let .presenceRun(id, _): id
		}
	}
}

/// Fold `messages` into a sequence of `ChatEntry` by collapsing runs of
/// consecutive presence messages (JOIN / PART / QUIT / NICK) into a
/// single `.presenceRun` entry. Any non-presence message breaks the run
/// and passes through as `.message`.
///
/// Runs are stable across appends: the run's id is the id of its first
/// message, so extending a run with further presence messages leaves the
/// id intact. That lets the view's "expanded runs" set survive appends
/// without the user's expand state being reset.
public func foldPresenceRuns(_ messages: [Message]) -> [ChatEntry] {
	var entries: [ChatEntry] = []
	var buffer: [Message] = []

	func flush() {
		if !buffer.isEmpty {
			entries.append(.presenceRun(id: buffer[0].id, messages: buffer))
			buffer.removeAll(keepingCapacity: true)
		}
	}

	for message in messages {
		if isPresence(message.kind) {
			buffer.append(message)
		} else {
			flush()
			entries.append(.message(message))
		}
	}
	flush()
	return entries
}

private func isPresence(_ kind: Message.Kind) -> Bool {
	switch kind {
	case .join, .part, .quit, .nick: true
	default: false
	}
}

/// Human-readable summary of the messages inside a presence run, suitable
/// for the collapsed row. Users who both joined and left in the same run
/// are deduped into a single "joined and left" clause. Beyond three unique
/// nicks per bucket the names collapse into a count ("5 users joined").
///
/// Returned segments are joined with " · " so the renderer can split on
/// that delimiter if it wants to colorize each segment independently.
public func presenceRunSummary(_ messages: [Message]) -> String {
	var joinNicks: [String] = []
	var leaveNicks: [String] = []
	var nickChanges: [(old: String, new: String)] = []

	for message in messages {
		switch message.kind {
		case .join:
			joinNicks.append(message.sender)
		case .part, .quit:
			leaveNicks.append(message.sender)
		case .nick:
			nickChanges.append((old: message.sender, new: message.content))
		default:
			break
		}
	}

	let joinSet = Set(joinNicks)
	let leaveSet = Set(leaveNicks)
	let transient = joinSet.intersection(leaveSet)

	let onlyJoined = dedupePreservingOrder(joinNicks).filter { !transient.contains($0) }
	let onlyLeft = dedupePreservingOrder(leaveNicks).filter { !transient.contains($0) }
	let inAndOut = dedupePreservingOrder(joinNicks).filter { transient.contains($0) }

	var parts: [String] = []
	if !onlyJoined.isEmpty {
		parts.append("\(usersPhrase(onlyJoined)) joined")
	}
	if !onlyLeft.isEmpty {
		parts.append("\(usersPhrase(onlyLeft)) left")
	}
	if !inAndOut.isEmpty {
		parts.append("\(usersPhrase(inAndOut)) joined and left")
	}
	for change in nickChanges where !change.new.isEmpty {
		parts.append("\(change.old) is now \(change.new)")
	}

	return parts.joined(separator: " · ")
}

private func dedupePreservingOrder(_ names: [String]) -> [String] {
	var seen: Set<String> = []
	return names.filter { seen.insert($0).inserted }
}

private func usersPhrase(_ uniqueNames: [String]) -> String {
	if uniqueNames.count <= 3 {
		return uniqueNames.joined(separator: ", ")
	}
	let count = uniqueNames.count
	return "\(count) users"
}
