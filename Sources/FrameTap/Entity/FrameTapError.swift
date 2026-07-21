//
//  FrameTap
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT

import Foundation

/// FrameTap 所有自訂錯誤的統一型別，攜帶一句可直接印給使用者／agent 讀的診斷訊息。
///
/// 同時 conform `LocalizedError`（`errorDescription` 轉發 `description`）——若只 conform
/// `CustomStringConvertible`，`error.localizedDescription` 在不 conform `LocalizedError` 時會走
/// NSError 橋接的通用 fallback、不會顯示這裡寫的實質訊息，讓 per-frame 失敗診斷（見
/// `FrameTap.extractFrames`）失真。
struct FrameTapError: Error, CustomStringConvertible, LocalizedError {

	/// 建立一個帶指定診斷訊息的錯誤。
	init(_ description: String) {
		self.description = description
	}

	/// 轉發 `description`，讓 `error.localizedDescription` 顯示實質訊息而非通用 fallback 文字。
	var errorDescription: String? { description }

	/// 給人／agent 讀的錯誤說明；經 stderr 印出或作為 `errorDescription` 轉發。
	let description: String
}
