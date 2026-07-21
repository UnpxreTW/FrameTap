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

/// 原生 macOS 影片抽幀 CLI，只靠 `AVFoundation` 解 H.264 / HEVC、不依賴 ffmpeg 二進位。
///
/// 抽幀結果（影格清單、每幀時間戳）以 markdown 清單印到 stdout，診斷訊息（降 fps 提示、
/// 單幀失敗原因）一律走 stderr——讓依序讀取 stdout 的下游（含 agent）不用過濾雜訊。
@main
struct FrameTap: AsyncParsableCommand {

	// MARK: Internal

	/// ArgumentParser 的指令設定：CLI 名稱與 `--help` 摘要。
	static let configuration: CommandConfiguration = .init(
		commandName: "frametap",
		abstract: "Native macOS video frame extractor (AVFoundation, no ffmpeg)."
	)

	/// 把 `S` / `MM:SS` / `HH:MM:SS` 三種時間字串格式解析成秒數。
	///
	/// 依冒號分段數決定進位權重（1 段＝秒、2 段＝分:秒、3 段＝時:分:秒）；段數或任一段非數字
	/// 皆視為格式錯誤，拋 `FrameTapError` 而非回傳預設值——時間解析錯誤不該被靜默吞掉。
	static func parseTime(_ value: String) throws -> Double {
		let parts: [String] = value.split(separator: ":").map(String.init)
		let numbers: [Double] = parts.compactMap { Double($0) }
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

	/// 把診斷訊息印到 stderr，讓 stdout 全程只留給機器可讀的抽幀產物清單。
	static func printError(_ message: String) {
		FileHandle.standardError.write(Data((message + "\n").utf8))
	}

	/// 來源影片路徑，僅支援 AVFoundation 可解的 `.mp4` / `.mov`（H.264 / HEVC）；VP9 / webm 不受支援。
	@Argument(help: "Path to the video file (.mp4 / .mov, H.264 / HEVC).")
	var video: String

	/// 抽幀區間起點，接受 `parseTime(_:)` 的三種時間格式；未指定則從影片開頭起算。
	@Option(help: "Start time: seconds, MM:SS, or HH:MM:SS.")
	var start: String?

	/// 抽幀區間終點，格式同 `start`；未指定則到影片結尾。
	@Option(help: "End time: seconds, MM:SS, or HH:MM:SS.")
	var end: String?

	/// 目標每秒影格數；區間內實際幀數若超過 `maxFrames`，會被 `makePlan(duration:)` 自動降 fps。
	@Option(help: "Target frames per second.")
	var fps: Double = 30

	/// 影格數硬上限，防止長區間高 fps 組合把磁碟塞爆；必須為正值，見 `validate()`。
	@Option(name: .customLong("max-frames"), help: "Hard cap; fps is lowered to fit if exceeded.")
	var maxFrames: Int = 100

	/// 輸出影格寬度（像素），高度依原始長寬比自動縮放（見 `makeGenerator(for:)` 的 `maximumSize`）。
	@Option(help: "Output width in pixels; height keeps the aspect ratio.")
	var width: Int = 512

	/// 輸出影像格式，`png`（預設、無損）或 `jpg`（有損、可調 `quality`）。
	@Option(help: "Output image format.")
	var format: ImageFormat = .png

	/// JPEG 壓縮品質（0–1），僅在 `format == .jpg` 時生效。
	@Option(help: "JPEG quality, between 0 and 1.")
	var quality: Double = 0.9

	/// 輸出目錄；未指定則預設為 `<影片檔名（不含副檔名）>-frames`。
	@Option(help: "Output directory (default: <video>-frames).")
	var out: String?

	/// 在 parse 階段攔下不合法的 `--max-frames`——負值會讓後續 `Range` 建構崩潰、`0` 會靜默印出
	/// 0 幀後正常結束，此處統一提早失敗，兩種失效模式都不留給使用者自行踩到。
	mutating func validate() throws {
		guard maxFrames > 0 else {
			throw ValidationError("--max-frames must be positive (got \(maxFrames))")
		}
	}

	/// CLI 主流程：驗證來源檔存在、讀取影片長度、算出抽幀計畫、逐幀抽取並落盤、印出摘要。
	func run() async throws {
		let videoURL: URL = .init(fileURLWithPath: video)
		guard FileManager.default.fileExists(atPath: videoURL.path) else {
			throw FrameTapError("file not found: \(video)")
		}
		let asset: AVURLAsset = .init(url: videoURL)
		let duration: Double = try await asset.load(.duration).seconds
		guard duration.isFinite, duration > 0 else {
			throw FrameTapError("cannot read duration — unsupported codec? AVFoundation has no VP9 / webm")
		}

		let plan: FramePlan = try makePlan(duration: duration)
		let outputDirectory: URL = makeOutputDirectory(for: videoURL)
		try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

		let extracted: (lines: [String], pixelSize: String) = try await extractFrames(
			from: asset, plan: plan, into: outputDirectory
		)
		printSummary(extracted, plan: plan, outputDirectory: outputDirectory)
	}

	// MARK: Private

	/// JPEG 落盤時的壓縮品質字典；`png` 格式不需要壓縮參數，回傳 `nil`。
	private var imageProperties: CFDictionary? {
		guard format == .jpg else { return nil }
		return [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
	}

	/// 把 `--start` / `--end` / `--fps` / `--max-frames` 解析並收斂成一份抽幀計畫。
	///
	/// 核心邏輯是 frame budget 超量時的降 fps 演算法：期望幀數 `wanted` 超過 `maxFrames` 時，
	/// 不是截斷尾巴（丟掉超出範圍的幀），而是重算 `effectiveFps` 讓 `maxFrames` 幀數均勻鋪滿整個
	/// 區間——確保拿到的影格仍覆蓋完整時間跨度，只是取樣密度變低。
	private func makePlan(duration: Double) throws -> FramePlan {
		let startSeconds: Double = try start.map(Self.parseTime) ?? 0
		let endSeconds: Double = try min(end.map(Self.parseTime) ?? duration, duration)
		guard endSeconds > startSeconds else {
			throw FrameTapError("--end (\(endSeconds)s) must be greater than --start (\(startSeconds)s)")
		}
		let span: Double = endSeconds - startSeconds
		let wanted: Int = max(1, Int((span * fps).rounded()))
		let frameCount: Int = min(wanted, maxFrames)
		let effectiveFps: Double = .init(frameCount) / span
		if wanted > maxFrames {
			let lowered: String = .init(format: "%.1f", effectiveFps)
			let message: String = "[frametap] \(wanted) frames exceeds --max-frames \(maxFrames); "
				+ "lowering to \(lowered)fps (\(frameCount) frames)"
			Self.printError(message)
		}
		return FramePlan(
			start: startSeconds, end: endSeconds, span: span,
			frameCount: frameCount, effectiveFps: effectiveFps
		)
	}

	/// 決定輸出目錄：`--out` 未指定時，預設為 `<影片檔名>-frames`（相對於目前工作目錄，非影片
	/// 所在目錄——`lastPathComponent` 已砍掉路徑前綴，`URL(fileURLWithPath:)` 對相對路徑一律
	/// 依 process CWD 解析）。
	private func makeOutputDirectory(for videoURL: URL) -> URL {
		let defaultName: String = videoURL.deletingPathExtension().lastPathComponent + "-frames"
		return URL(fileURLWithPath: out ?? defaultName, isDirectory: true)
	}

	/// 依 `plan` 逐幀 `await` 抽取並落盤，單幀失敗只印診斷、不中止整體流程。
	///
	/// 影格命名 `frame_%04d_t<秒>.<副檔名>` 同時編入序號與原始影片時間戳，讓每張影格檔名自帶
	/// 時間語義；`lines` 依序累積 markdown 清單供 `printSummary` 印到 stdout。
	private func extractFrames(
		from asset: AVAsset, plan: FramePlan, into outputDirectory: URL
	) async throws -> (lines: [String], pixelSize: String) {
		let generator: AVAssetImageGenerator = makeGenerator(for: asset)
		let fileExtension: String = format == .jpg ? "jpg" : "png"
		var lines: [String] = []
		var pixelSize: String = ""
		for index in 0 ..< plan.frameCount {
			let timestamp: Double = plan.start + Double(index) * (plan.span / Double(plan.frameCount))
			let requestedTime: CMTime = .init(seconds: timestamp, preferredTimescale: 600)
			do {
				let (image, _): (image: CGImage, actualTime: CMTime) = try await generator.image(at: requestedTime)
				if pixelSize.isEmpty {
					pixelSize = "\(image.width)x\(image.height)"
				}
				let name: String = .init(format: "frame_%04d_t%.3f.\(fileExtension)", index + 1, timestamp)
				let url: URL = outputDirectory.appendingPathComponent(name)
				try write(image, to: url)
				lines.append("- \(url.path) (t=\(String(format: "%.3f", timestamp))s)")
			} catch {
				let stamp: String = .init(format: "%.3f", timestamp)
				Self.printError("[frametap] frame \(index + 1) t=\(stamp)s failed: \(error.localizedDescription)")
			}
		}
		return (lines, pixelSize)
	}

	/// 把抽幀結果彙整成一行摘要＋輸出目錄＋逐幀清單，依序印到 stdout。
	private func printSummary(
		_ extracted: (lines: [String], pixelSize: String),
		plan: FramePlan, outputDirectory: URL
	) {
		let fpsText: String = .init(format: "%.1f", plan.effectiveFps)
		let startText: String = .init(format: "%.3f", plan.start)
		let endText: String = .init(format: "%.3f", plan.end)
		let fileExtension: String = format == .jpg ? "jpg" : "png"
		let summary: String = "# frames: \(extracted.lines.count)/\(plan.frameCount) @ \(fpsText)fps · "
			+ "\(extracted.pixelSize)px · \(fileExtension) · span \(startText)–\(endText)s"
		print(summary)
		print("# out: \(outputDirectory.path)")
		for line in extracted.lines {
			print(line)
		}
	}

	/// 建立抽幀用的 `AVAssetImageGenerator`，鎖定精確逐格取樣（見下方各屬性）。
	///
	/// `requestedTimeToleranceBefore`／`After` 兩者皆須設 `.zero`——只設一邊仍可能 snap 到鄰近
	/// keyframe，逐格逆向動畫 / easing 這類需求需要兩者同時歸零才能保證取到指定時間點那一幀，
	/// 代價是強迫解碼器從最近 keyframe 重建，比容忍 snap 慢。
	private func makeGenerator(for asset: AVAsset) -> AVAssetImageGenerator {
		let generator: AVAssetImageGenerator = .init(asset: asset)
		// Respect track rotation and pull exact frames (no keyframe snapping).
		generator.appliesPreferredTrackTransform = true
		generator.requestedTimeToleranceBefore = .zero
		generator.requestedTimeToleranceAfter = .zero
		generator.maximumSize = CGSize(width: CGFloat(width), height: .greatestFiniteMagnitude)
		return generator
	}

	/// 用 `ImageIO` 的 `CGImageDestination` 把單一 `CGImage` 落盤，比 `NSBitmapImageRep` 更底層可控
	/// （直接控制壓縮參數與目的地類型，不經 AppKit 橋接層）。
	private func write(_ image: CGImage, to url: URL) throws {
		let type: CFString = (format == .jpg ? UTType.jpeg : UTType.png).identifier as CFString
		guard let destination: CGImageDestination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
			throw FrameTapError("cannot create image destination for \(url.lastPathComponent)")
		}
		CGImageDestinationAddImage(destination, image, imageProperties)
		guard CGImageDestinationFinalize(destination) else {
			throw FrameTapError("failed to write \(url.lastPathComponent)")
		}
	}

}
