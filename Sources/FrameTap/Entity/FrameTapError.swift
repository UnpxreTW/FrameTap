//
//  FrameTap
//
//  Copyright © 2026 Unpxre
//  Licensed under the MIT License. See LICENSE for details.
//
//  SPDX-License-Identifier: MIT

struct FrameTapError: Error, CustomStringConvertible {

	init(_ description: String) {
		self.description = description
	}

	let description: String
}
