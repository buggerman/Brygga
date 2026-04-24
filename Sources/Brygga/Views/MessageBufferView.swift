// SPDX-License-Identifier: BSD-3-Clause
// Copyright (c) 2026 Brygga contributors

import AppKit
import BryggaCore
import SwiftUI

/// Non-editable message buffer backed by `NSTextView`, giving the chat
/// view native macOS drag-select across rows, ⌘A, ⌘C, Find, and a right-click
/// menu. Replaces the SwiftUI `LazyVStack { MessageRow }` rendering that
/// could only select text within a single message due to SwiftUI's
/// per-`Text` selection limit.
///
/// Feed the view a `[Message]` plus a few presentation options. On append
/// it scrolls to the bottom if the user was already pinned there (mIRC
/// behaviour); otherwise it leaves the scroll position alone so the user
/// can read history without being snatched back to live.
@MainActor
struct MessageBufferView: NSViewRepresentable {
	let messages: [Message]
	let lastReadMessageID: UUID?
	let nickColorsEnabled: Bool
	let timestampFormat: String

	func makeCoordinator() -> Coordinator {
		Coordinator()
	}

	func makeNSView(context: Context) -> NSScrollView {
		let textView = NSTextView(frame: .zero)
		textView.isEditable = false
		textView.isSelectable = true
		textView.isRichText = true
		textView.drawsBackground = false
		textView.allowsUndo = false
		textView.isAutomaticLinkDetectionEnabled = false
		textView.isAutomaticDataDetectionEnabled = false
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
		textView.isAutomaticTextCompletionEnabled = false
		textView.usesFontPanel = false
		textView.usesFindBar = true
		textView.isIncrementalSearchingEnabled = true
		textView.textContainerInset = NSSize(width: 12, height: 12)
		textView.textContainer?.lineFragmentPadding = 0
		textView.textContainer?.widthTracksTextView = true
		textView.autoresizingMask = [.width]
		textView.isVerticallyResizable = true
		textView.isHorizontallyResizable = false
		textView.linkTextAttributes = [
			.foregroundColor: NSColor.controlAccentColor,
			.underlineStyle: NSUnderlineStyle.single.rawValue,
			.cursor: NSCursor.pointingHand,
		]
		textView.delegate = context.coordinator

		let scroll = NSScrollView(frame: .zero)
		scroll.hasVerticalScroller = true
		scroll.hasHorizontalScroller = false
		scroll.drawsBackground = false
		scroll.documentView = textView
		scroll.contentView.postsBoundsChangedNotifications = true

		context.coordinator.textView = textView
		context.coordinator.scrollView = scroll
		return scroll
	}

	func updateNSView(_: NSScrollView, context: Context) {
		context.coordinator.apply(
			messages: messages,
			lastReadMessageID: lastReadMessageID,
			nickColorsEnabled: nickColorsEnabled,
			timestampFormat: timestampFormat,
		)
	}

	@MainActor
	final class Coordinator: NSObject, NSTextViewDelegate {
		weak var textView: NSTextView?
		weak var scrollView: NSScrollView?

		private var renderedIDs: [UUID] = []
		private var renderedLastReadID: UUID?
		private var messagesByID: [UUID: Message] = [:]
		private var nickColorsEnabled = true
		private var timestampFormat = "system"

		private let urlDetector = try? NSDataDetector(
			types: NSTextCheckingResult.CheckingType.link.rawValue,
		)

		func apply(
			messages: [Message],
			lastReadMessageID: UUID?,
			nickColorsEnabled: Bool,
			timestampFormat: String,
		) {
			guard let textView, let storage = textView.textStorage else { return }

			let optionsChanged = nickColorsEnabled != self.nickColorsEnabled
				|| timestampFormat != self.timestampFormat
				|| lastReadMessageID != renderedLastReadID
			self.nickColorsEnabled = nickColorsEnabled
			self.timestampFormat = timestampFormat

			let newIDs = messages.map(\.id)
			let canAppend = !optionsChanged
				&& newIDs.starts(with: renderedIDs)
				&& newIDs.count > renderedIDs.count

			let wasAtBottom = isScrolledToBottom()

			if canAppend {
				let tail = Array(messages.suffix(messages.count - renderedIDs.count))
				let appendText = NSMutableAttributedString()
				for message in tail {
					appendText.append(attributed(for: message, lastReadID: lastReadMessageID))
				}
				storage.append(appendText)
			} else {
				let full = NSMutableAttributedString()
				for message in messages {
					full.append(attributed(for: message, lastReadID: lastReadMessageID))
				}
				storage.setAttributedString(full)
			}

			messagesByID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
			renderedIDs = newIDs
			renderedLastReadID = lastReadMessageID

			if wasAtBottom || !canAppend {
				scrollToBottom()
			}
		}

		// MARK: - Attributed building

		private func attributed(for message: Message, lastReadID: UUID?) -> NSAttributedString {
			let out = NSMutableAttributedString()
			let ts = timestampText(for: message.timestamp)
			let bodyFont = NSFont.monospacedSystemFont(
				ofSize: NSFont.systemFontSize,
				weight: .regular,
			)
			let tsFont = NSFont.monospacedSystemFont(
				ofSize: NSFont.smallSystemFontSize,
				weight: .regular,
			)

			out.append(.init(string: "[\(ts)]  ", attributes: [
				.font: tsFont,
				.foregroundColor: NSColor.secondaryLabelColor,
			]))

			switch message.kind {
			case .privmsg:
				out.append(.init(string: "<\(message.sender)> ", attributes: [
					.font: bodyFont,
					.foregroundColor: nickColor(for: message.sender),
				]))
				out.append(ircAttributed(
					message.content,
					baseFont: bodyFont,
					baseColor: NSColor.labelColor,
				))

			case .notice:
				out.append(.init(string: "-\(message.sender)- ", attributes: [
					.font: bodyFont,
					.foregroundColor: NSColor.systemOrange,
				]))
				out.append(ircAttributed(
					message.content,
					baseFont: bodyFont,
					baseColor: NSColor.systemOrange,
				))

			case .action:
				out.append(.init(string: "* ", attributes: [
					.font: bodyFont,
					.foregroundColor: NSColor.secondaryLabelColor,
				]))
				let italicBody = italicVariant(of: bodyFont)
				out.append(.init(string: "\(message.sender) ", attributes: [
					.font: italicBody,
					.foregroundColor: nickColor(for: message.sender),
				]))
				out.append(ircAttributed(
					message.content,
					baseFont: italicBody,
					baseColor: NSColor.labelColor,
				))

			default:
				out.append(.init(string: "* \(message.sender) \(message.content)", attributes: [
					.font: bodyFont,
					.foregroundColor: NSColor.secondaryLabelColor,
				]))
			}

			out.append(.init(string: "\n"))

			let fullRange = NSRange(location: 0, length: out.length)
			out.addAttribute(.bryggaMessageID, value: message.id, range: fullRange)

			if message.isHighlight {
				out.addAttribute(
					.backgroundColor,
					value: NSColor.controlAccentColor.withAlphaComponent(0.15),
					range: fullRange,
				)
			}

			// The "new" divider sits *after* the last-read message so it
			// visually separates read from unread.
			if let lastReadID, message.id == lastReadID {
				out.append(lineMarker())
			}

			return out
		}

		private func ircAttributed(
			_ text: String,
			baseFont: NSFont,
			baseColor: NSColor,
		) -> NSAttributedString {
			let runs = IRCFormatting.parse(text)
			let out = NSMutableAttributedString()
			for run in runs {
				var font = baseFont
				if run.style.bold {
					font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
				}
				if run.style.italic {
					font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
				}
				var attrs: [NSAttributedString.Key: Any] = [
					.font: font,
					.foregroundColor: baseColor,
				]
				if run.style.underline {
					attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
				}
				if run.style.strikethrough {
					attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
				}
				var fgIdx = run.style.foreground
				var bgIdx = run.style.background
				if run.style.reverse {
					(fgIdx, bgIdx) = (bgIdx ?? 0, fgIdx ?? 99)
				}
				if let fg = fgIdx, let rgb = IRCFormatting.color(for: fg) {
					attrs[.foregroundColor] = NSColor(
						srgbRed: CGFloat(rgb.red),
						green: CGFloat(rgb.green),
						blue: CGFloat(rgb.blue),
						alpha: 1.0,
					)
				}
				if let bg = bgIdx, let rgb = IRCFormatting.color(for: bg) {
					attrs[.backgroundColor] = NSColor(
						srgbRed: CGFloat(rgb.red),
						green: CGFloat(rgb.green),
						blue: CGFloat(rgb.blue),
						alpha: 1.0,
					)
				}
				out.append(NSAttributedString(string: run.text, attributes: attrs))
			}
			detectLinks(in: out)
			return out
		}

		private func detectLinks(in attributed: NSMutableAttributedString) {
			guard let detector = urlDetector else { return }
			let plain = attributed.string
			let range = NSRange(plain.startIndex..., in: plain)
			detector.enumerateMatches(in: plain, options: [], range: range) { match, _, _ in
				guard let match, let url = match.url else { return }
				let scheme = url.scheme?.lowercased()
				guard scheme == "http" || scheme == "https" || scheme == "mailto" else { return }
				attributed.addAttribute(.link, value: url, range: match.range)
			}
		}

		private func lineMarker() -> NSAttributedString {
			let para = NSMutableParagraphStyle()
			para.alignment = .center
			para.paragraphSpacing = 2
			para.paragraphSpacingBefore = 2
			return NSAttributedString(string: "── new ──\n", attributes: [
				.font: NSFont.systemFont(ofSize: 10, weight: .medium),
				.foregroundColor: NSColor.controlAccentColor,
				.paragraphStyle: para,
			])
		}

		private func italicVariant(of font: NSFont) -> NSFont {
			NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
		}

		private func nickColor(for nick: String) -> NSColor {
			if !nickColorsEnabled { return NSColor.controlAccentColor }
			return NSColor(NickColor.color(for: nick))
		}

		private func timestampText(for date: Date) -> String {
			switch timestampFormat {
			case "12h":
				let f = DateFormatter()
				f.dateFormat = "h:mm a"
				f.locale = Locale(identifier: "en_US_POSIX")
				return f.string(from: date)
			case "24h":
				let f = DateFormatter()
				f.dateFormat = "HH:mm"
				f.locale = Locale(identifier: "en_US_POSIX")
				return f.string(from: date)
			default:
				return date.formatted(date: .omitted, time: .shortened)
			}
		}

		// MARK: - Scroll

		private func isScrolledToBottom() -> Bool {
			guard let scrollView, let doc = scrollView.documentView else { return true }
			let visible = scrollView.contentView.documentVisibleRect
			let threshold: CGFloat = 40
			return visible.maxY >= doc.frame.height - threshold
		}

		private func scrollToBottom() {
			guard let textView, let scrollView else { return }
			if let container = textView.textContainer {
				textView.layoutManager?.ensureLayout(for: container)
			}
			let docHeight = textView.frame.height
			let visibleHeight = scrollView.contentView.bounds.height
			let y = max(0, docHeight - visibleHeight)
			scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
			scrollView.reflectScrolledClipView(scrollView.contentView)
		}

		// MARK: - NSTextViewDelegate

		func textView(
			_ view: NSTextView,
			menu: NSMenu,
			for _: NSEvent,
			at charIndex: Int,
		) -> NSMenu? {
			guard let storage = view.textStorage, charIndex < storage.length else {
				return menu
			}
			let attrs = storage.attributes(at: charIndex, effectiveRange: nil)
			guard
				let id = attrs[.bryggaMessageID] as? UUID,
				let message = messagesByID[id]
			else { return menu }

			menu.addItem(.separator())

			let copyMessage = NSMenuItem(
				title: "Copy Message",
				action: #selector(copyAction(_:)),
				keyEquivalent: "",
			)
			copyMessage.target = self
			copyMessage.representedObject = plainLogLine(for: message)
			menu.addItem(copyMessage)

			let copyText = NSMenuItem(
				title: "Copy Text",
				action: #selector(copyAction(_:)),
				keyEquivalent: "",
			)
			copyText.target = self
			copyText.representedObject = IRCFormatting.stripControlCodes(message.content)
			menu.addItem(copyText)

			let copyNick = NSMenuItem(
				title: "Copy Nickname",
				action: #selector(copyAction(_:)),
				keyEquivalent: "",
			)
			copyNick.target = self
			copyNick.representedObject = message.sender
			menu.addItem(copyNick)

			return menu
		}

		@objc private func copyAction(_ sender: NSMenuItem) {
			guard let text = sender.representedObject as? String else { return }
			let pb = NSPasteboard.general
			pb.clearContents()
			pb.setString(text, forType: .string)
		}

		private func plainLogLine(for message: Message) -> String {
			let body = IRCFormatting.stripControlCodes(message.content)
			let ts = timestampText(for: message.timestamp)
			switch message.kind {
			case .privmsg: return "[\(ts)] <\(message.sender)> \(body)"
			case .notice: return "[\(ts)] -\(message.sender)- \(body)"
			case .action: return "[\(ts)] * \(message.sender) \(body)"
			default: return "[\(ts)] * \(message.sender) \(body)"
			}
		}
	}
}

private extension NSAttributedString.Key {
	/// Marker attribute placed across the entire paragraph range of a
	/// message so the right-click handler can recover which `Message` the
	/// click landed inside.
	static let bryggaMessageID = NSAttributedString.Key("brygga.messageID")
}
