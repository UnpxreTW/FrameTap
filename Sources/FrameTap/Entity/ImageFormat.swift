//
//  FrameTap
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT

import ArgumentParser

/// `--format` 選項接受的輸出影像格式。`ExpressibleByArgument` 讓 ArgumentParser 直接從
/// `RawValue`（`"png"` / `"jpg"`）解析，CLI 端不需另寫 parser。
enum ImageFormat: String, ExpressibleByArgument {

	/// 無損 PNG，預設格式。
	case png

	/// 有損 JPEG，壓縮品質由 `--quality` 控制。
	case jpg
}
