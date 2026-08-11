//
//  ARSessionManager.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/09/08.
//

import RealityKit
import ARKit

class ARSessionManager: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isSessionActive: Bool = false
    
    var session: ARSession
    var arView: ARView? // RealityKitのARViewに変更

    // カメラの位置と向き情報を保持するプロパティ
    @Published var cameraPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 0)
    @Published var cameraOrientation: simd_float4x4 = matrix_identity_float4x4
    
    override init() {
        self.session = ARSession()
        super.init()
        self.session.delegate = self
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isAutoFocusEnabled = true
        configuration.environmentTexturing = .none
        
        if let hiResFormat = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
            configuration.videoFormat = hiResFormat
        }
        
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        
        self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    func startSession() {
        DispatchQueue.main.async {
            self.isSessionActive = true
            print("ARSession started")
        }
    }

    func stopSession() {
        DispatchQueue.main.async {
            self.session.pause()
            self.isSessionActive = false
            print("ARSession paused")
        }
    }
    
    @discardableResult
    func addTargetObject(at position: SIMD3<Float>) -> ModelEntity? {
        guard let arView = arView else { return nil }

        // RealityKitでターゲットオブジェクト（例えば赤い球）を追加
        let targetSphere = MeshResource.generateSphere(radius: 0.05)
        let material = SimpleMaterial(color: .red, isMetallic: true)
        let modelEntity = ModelEntity(mesh: targetSphere, materials: [material])
        
        // 指定された位置にアンカーを追加
        let anchorEntity = AnchorEntity(world: position)
        anchorEntity.addChild(modelEntity)
        arView.scene.anchors.append(anchorEntity)
        
        return modelEntity
    }
    
    func resetObjects() {
        guard let arView = arView else { return }
        arView.scene.anchors.removeAll()  // シーンからすべてのアンカーを削除
    }

    // ARセッションのフレーム更新時に呼び出されるデリゲートメソッド
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // カメラの位置と向きを取得してプロパティに保存
        let cameraTransform = frame.camera.transform
        cameraPosition = SIMD3<Float>(cameraTransform.columns.3.x,
                                      cameraTransform.columns.3.y,
                                      cameraTransform.columns.3.z)
        cameraOrientation = cameraTransform
    }
}
