//
//  FrameTap
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT

/// 一次抽幀執行的完整計畫——區間、跨度與最終幀數／fps 都在此收斂成不可變快照。
///
/// 由 `FrameTap.makePlan(duration:)` 算出；`frameCount`／`effectiveFps` 可能已被 frame budget
/// 降採樣調整過，不等於使用者原始輸入的 `--fps`／`(--end - --start) * --fps`。
struct FramePlan {

	/// 抽幀區間起點（秒），對齊原始影片時間軸。
	let start: Double

	/// 抽幀區間終點（秒），對齊原始影片時間軸；恆大於 `start`。
	let end: Double

	/// 區間跨度（秒），即 `end - start`，快取起來避免重複計算。
	let span: Double

	/// 實際會抽取的幀數；超過 `--max-frames` 時已被降 fps 收斂到上限內。
	let frameCount: Int

	/// 實際生效的每秒幀數；未超過 `--max-frames` 時等於使用者輸入的 `--fps`，超過時已降低。
	let effectiveFps: Double
}
