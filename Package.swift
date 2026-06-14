// swift-tools-version: 5.9
import PackageDescription

let package = Package(
	name: "FrameTap",
	platforms: [.macOS(.v13)],
	products: [
		.executable(name: "frametap", targets: ["FrameTap"]),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
		.package(url: "https://github.com/UnpxreTW/SwiftStyleKit.git", from: "2.0.0"),
	],
	targets: [
		.executableTarget(
			name: "FrameTap",
			dependencies: [
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			],
			plugins: [
				.plugin(name: "SwiftStyleLint", package: "SwiftStyleKit"),
			]
		),
	]
)
