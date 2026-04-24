// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import AppKit
import Foundation

/// User-report affordance routed at the project's GitHub issue tracker.
/// Invoked from `UserListView`'s right-click menu — opens the
/// `user-report.yml` Issue Form with `network`, `channel`, and
/// `nickname` pre-filled from the click context. Satisfies App Store
/// Review Guideline 1.2 (UGC apps must offer a way to flag abusive
/// users) without standing up a mailbox or backend.
@MainActor
enum ReportLink {
	/// Repo whose issue tracker receives the report. Hard-coded
	/// because Brygga is a single-repo project; would become a build
	/// setting if that ever changed.
	private static let issueTrackerBase = "https://github.com/buggerman/Brygga/issues/new"

	/// Open the user-report Issue Form in the user's default browser.
	/// `network` and `channel` are best-effort — pass `nil` when the
	/// surrounding context doesn't have one.
	static func openUserReport(
		nickname: String,
		network: String?,
		channel: String?,
	) {
		guard let url = userReportURL(
			nickname: nickname,
			network: network,
			channel: channel,
		) else { return }
		NSWorkspace.shared.open(url)
	}

	/// Build the pre-filled URL. Exposed alongside `openUserReport`
	/// so it can be inspected during local manual testing without
	/// actually firing `NSWorkspace.open`.
	static func userReportURL(
		nickname: String,
		network: String?,
		channel: String?,
	) -> URL? {
		guard var components = URLComponents(string: issueTrackerBase) else { return nil }
		var items: [URLQueryItem] = [
			URLQueryItem(name: "template", value: "user-report.yml"),
			URLQueryItem(name: "labels", value: "user-report"),
			URLQueryItem(name: "title", value: "[Report] \(nickname)"),
			URLQueryItem(name: "nickname", value: nickname),
		]
		if let network, !network.isEmpty {
			items.append(URLQueryItem(name: "network", value: network))
		}
		if let channel, !channel.isEmpty {
			items.append(URLQueryItem(name: "channel", value: channel))
		}
		components.queryItems = items
		return components.url
	}
}
