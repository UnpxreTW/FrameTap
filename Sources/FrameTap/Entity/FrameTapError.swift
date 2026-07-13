//
//  FrameTap
//
//  Copyright © 2026 Unpxre (GitHub: UnpxreTW)
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT

import Foundation

struct FrameTapError: Error, CustomStringConvertible, LocalizedError {

	init(_ description: String) {
		self.description = description
	}

	let description: String

	var errorDescription: String? { description }
}
