//
//  CameraViewModel.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/07/06.
//

import Foundation

class CameraViewModel: ObservableObject {
    var capturePanoramaAction: (() -> Void)?
    
    func capturePanorama() {
        capturePanoramaAction?()
    }
}
