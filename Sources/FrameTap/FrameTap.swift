//
//  FrameTap
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT

import ArgumentParser
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct FrameTap: AsyncParsableCommand {

	// MARK: Internal

	static let configuration: CommandConfiguration = .init(
		commandName: "frametap",
		abstract: "Native macOS video frame extractor (AVFoundation, no ffmpeg)."
	)

	static func parseTime(_ value: String) throws -> Double {
		let parts = value.split(separator: ":").map(String.init)
		let numbers = parts.compactMap { Double($0) }
		guard numbers.count == parts.count, !numbers.isEmpty else {
			throw FrameTapError("invalid time '\(value)' (expected S, MM:SS, or HH:MM:SS)")
		}
		switch numbers.count {
		case 1:
			return numbers[0]
		case 2:
			return numbers[0] * 60 + numbers[1]
		case 3:
			return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
		default:
			throw FrameTapError("invalid time '\(value)' (too many ':' components)")
		}
	}

	static func printError(_ message: String) {
		FileHandle.standardError.write(Data((message + "\n").utf8))
	}

	@Argument(help: "Path to the video file (.mp4 / .mov, H.264 / HEVC).")
	var video: String

	@Option(help: "Start time: seconds, MM:SS, or HH:MM:SS.")
	var start: String?

	@Option(help: "End time: seconds, MM:SS, or HH:MM:SS.")
	var end: String?

	@Option(help: "Target frames per second.")
	var fps: Double = 30

	@Option(name: .customLong("max-frames"), help: "Hard cap; fps is lowered to fit if exceeded.")
	var maxFrames: Int = 100

	@Option(help: "Output width in pixels; height keeps the aspect ratio.")
	var width: Int = 512

	@Option(help: "Output image format.")
	var format: ImageFormat = .png

	@Option(help: "JPEG quality, between 0 and 1.")
	var quality: Double = 0.9

	@Option(help: "Output directory (default: <video>-frames).")
	var out: String?

	func run() async throws {
		let videoURL: URL = .init(fileURLWithPath: video)
		guard FileManager.default.fileExists(atPath: videoURL.path) else {
			throw FrameTapError("file not found: \(video)")
		}
		let asset: AVURLAsset = .init(url: videoURL)
		let duration = try await asset.load(.duration).seconds
		guard duration.isFinite, duration > 0 else {
			throw FrameTapError("cannot read duration — unsupported codec? AVFoundation has no VP9 / webm")
		}

		let plan = try makePlan(duration: duration)
		let outputDirectory = makeOutputDirectory(for: videoURL)
		try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

		let extracted = try await extractFrames(from: asset, plan: plan, into: outputDirectory)
		printSummary(extracted, plan: plan, outputDirectory: outputDirectory)
	}

	// MARK: Private

	private var imageProperties: CFDictionary? {
		guard format == .jpg else { return nil }
		return [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
	}

	private func makePlan(duration: Double) throws -> FramePlan {
		let startSeconds = try start.map(Self.parseTime) ?? 0
		let endSeconds = try min(end.map(Self.parseTime) ?? duration, duration)
		guard endSeconds > startSeconds else {
			throw FrameTapError("--end (\(endSeconds)s) must be greater than --start (\(startSeconds)s)")
		}
		let span = endSeconds - startSeconds
		let wanted = max(1, Int((span * fps).rounded()))
		let frameCount = min(wanted, maxFrames)
		let effectiveFps = Double(frameCount) / span
		if wanted > maxFrames {
			let lowered: String = .init(format: "%.1f", effectiveFps)
			let message = "[frametap] \(wanted) frames exceeds --max-frames \(maxFrames); "
				+ "lowering to \(lowered)fps (\(frameCount) frames)"
			Self.printError(message)
		}
		return FramePlan(
			start: startSeconds, end: endSeconds, span: span,
			frameCount: frameCount, effectiveFps: effectiveFps
		)
	}

	private func makeOutputDirectory(for videoURL: URL) -> URL {
		let defaultName = videoURL.deletingPathExtension().lastPathComponent + "-frames"
		return URL(fileURLWithPath: out ?? defaultName, isDirectory: true)
	}

	private func extractFrames(
		from asset: AVAsset, plan: FramePlan, into outputDirectory: URL
	) async throws -> (lines: [String], pixelSize: String) {
		let generator = makeGenerator(for: asset)
		let fileExtension = format == .jpg ? "jpg" : "png"
		var lines: [String] = []
		var pixelSize = ""
		for index in 0 ..< plan.frameCount {
			let timestamp = plan.start + Double(index) * (plan.span / Double(plan.frameCount))
			let requestedTime: CMTime = .init(seconds: timestamp, preferredTimescale: 600)
			do {
				let (image, _) = try await generator.image(at: requestedTime)
				if pixelSize.isEmpty {
					pixelSize = "\(image.width)x\(image.height)"
				}
				let name: String = .init(format: "frame_%04d_t%.3f.\(fileExtension)", index + 1, timestamp)
				let url = outputDirectory.appendingPathComponent(name)
				try write(image, to: url)
				lines.append("- \(url.path) (t=\(String(format: "%.3f", timestamp))s)")
			} catch {
				let stamp: String = .init(format: "%.3f", timestamp)
				Self.printError("[frametap] frame \(index + 1) t=\(stamp)s failed: \(error.localizedDescription)")
			}
		}
		return (lines, pixelSize)
	}

	private func printSummary(
		_ extracted: (lines: [String], pixelSize: String),
		plan: FramePlan, outputDirectory: URL
	) {
		let fpsText: String = .init(format: "%.1f", plan.effectiveFps)
		let startText: String = .init(format: "%.3f", plan.start)
		let endText: String = .init(format: "%.3f", plan.end)
		let fileExtension = format == .jpg ? "jpg" : "png"
		let summary = "# frames: \(extracted.lines.count)/\(plan.frameCount) @ \(fpsText)fps · "
			+ "\(extracted.pixelSize)px · \(fileExtension) · span \(startText)–\(endText)s"
		print(summary)
		print("# out: \(outputDirectory.path)")
		for line in extracted.lines {
			print(line)
		}
	}

	private func makeGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
		let generator: AVAssetImageGenerator = .init(asset: asset)
		// Respect track rotation and pull exact frames (no keyframe snapping).
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		generator.maximumSize = CGSize(width: CGFloat(width), height: .greatestFiniteMagnitude)
		return generator
	}

	private func write(_ image: CGImage, to url: URL) throws {
		let type = (format == .jpg ? UTType.jpeg : UTType.png).identifier as CFString
		guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
			throw FrameTapError("cannot create image destination for \(url.lastPathComponent)")
		}
		CGImageDestinationAddImage(destination, image, imageProperties)
		guard CGImageDestinationFinalize(destination) else {
			throw FrameTapError("failed to write \(url.lastPathComponent)")
		}
	}

}
