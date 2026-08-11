//
//  ShotFileInfo.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/10/23.
//

import Combine
import Foundation
import SwiftUI
import UIKit

struct ShotFileInfo {
    let fileURL: URL
    let id: UInt32

    init?(url: URL) {
        fileURL = url
        guard let shotID = CaptureFolderManager.parseShotId(url: url) else {
            return nil
        }

        id = shotID
    }
}

extension ShotFileInfo: Identifiable { }
