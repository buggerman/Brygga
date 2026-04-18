// swift-tools-version: 6.2
import PackageDescription

let package = Package(
	name: "Brygga",
	platforms: [
		.macOS(.v26)
	],
	products: [
		.executable(name: "Brygga", targets: ["Brygga"]),
		.library(name: "BryggaCore", targets: ["BryggaCore"])
	],
	targets: [
		// Domain logic (IRC protocol, models) — testable
		.target(
			name: "BryggaCore",
			path: "Sources/BryggaCore"
		),
		// App executable (SwiftUI views, @main)
		.executableTarget(
			name: "Brygga",
			dependencies: ["BryggaCore"],
			path: "Sources/Brygga"
		),
		.testTarget(
			name: "BryggaCoreTests",
			dependencies: ["BryggaCore"],
			path: "Tests"
		)
	]
)
