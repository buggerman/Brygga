// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "Brygga",
	platforms: [
		// macOS 15 Sequoia is the real floor:
		// - `.containerBackground(_:for: .window)` requires macOS 15.
		// - `@Observable`, `@Bindable`, `.inspector`, `.onKeyPress`,
		//   `ContentUnavailableView` all ship from macOS 14, but one newer
		//   API pulls the whole floor up.
		// Policy: build for latest, raise the floor as needed, no
		// `@available` guards.
		.macOS(.v15),
	],
	products: [
		.executable(name: "Brygga", targets: ["Brygga"]),
		.library(name: "BryggaCore", targets: ["BryggaCore"]),
	],
	targets: [
		// Domain logic (IRC protocol, models) — testable
		.target(
			name: "BryggaCore",
			path: "Sources/BryggaCore",
		),
		// App executable (SwiftUI views, @main)
		.executableTarget(
			name: "Brygga",
			dependencies: ["BryggaCore"],
			path: "Sources/Brygga",
		),
		.testTarget(
			name: "BryggaCoreTests",
			dependencies: ["BryggaCore"],
			path: "Tests",
		),
	],
)
