// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import AppKit
import Foundation

/// Custom About-panel content. Surfaces Brygga's BSD-3-Clause notice in
/// the `credits` field of `NSApplication.orderFrontStandardAboutPanel`
/// so the binary-redistribution clause of the license is satisfied in a
/// discoverable place — App menu → About Brygga.
///
/// Brygga has zero third-party Swift package dependencies, so the
/// license body covers the entire surface that needs attribution.
@MainActor
enum Acknowledgements {
	/// Open the standard macOS About panel with Brygga's license text
	/// rendered into the credits area. Bundle metadata
	/// (`CFBundleName`, `CFBundleShortVersionString`, `CFBundleVersion`,
	/// `CFBundleIconFile`) drives the rest of the panel.
	static func showAboutPanel() {
		NSApp.orderFrontStandardAboutPanel(options: [
			.credits: creditsAttributedString,
		])
	}

	private static let creditsAttributedString: NSAttributedString = {
		let paragraph = NSMutableParagraphStyle()
		paragraph.alignment = .left
		paragraph.lineSpacing = 2
		paragraph.paragraphSpacing = 6

		return NSAttributedString(string: licenseText, attributes: [
			.font: NSFont.systemFont(ofSize: 11),
			.foregroundColor: NSColor.labelColor,
			.paragraphStyle: paragraph,
		])
	}()

	/// BSD 3-Clause License text for Brygga, mirrored verbatim from
	/// `LICENSE.md` at the repo root. Update both when the license
	/// changes (which should be approximately never).
	private static let licenseText = """
	BSD 3-Clause License

	Copyright (c) 2026 Brygga contributors

	Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

	1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

	2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

	3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

	THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
	"""
}
