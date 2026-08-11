//
//  ARViewContainer.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/09/08.
//

import SwiftUI
import RealityKit
import ARKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var arSessionManager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session = arSessionManager.session
        arSessionManager.arView = arView // ARViewをARSessionManagerに設定
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {
        if arSessionManager.isSessionActive {
            uiView.session.run(arSessionManager.session.configuration ?? ARWorldTrackingConfiguration())
        } else {
            uiView.session.pause()
        }
    }
}
