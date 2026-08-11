//
//  MotionManager.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/09/08.
//

import SwiftUI
import CoreMotion

class MotionManager: ObservableObject {
    private var motion = CMMotionManager()
    private var queue = OperationQueue()
    private var arSessionManager: ARSessionManager?
    @Published var movingCircleOffset = CGSize.zero
    @Published var progress = 0.0
    @Published var isPhoto = false
    @Published var rotationCount = 0
    @Published var isCalibrating = false
    @Published var isCalibrationFinished = false
    @Published var isCapturing = false
    @Published var isCapturingFinished = false
    @Published var gravityZ: Double = 0.0
    @Published var horizontalRotation: Double = 0.0
    @Published var calibratedHRotation: Double = 0.0
    @Published var isDeviceStill: Bool = false
    @Published var trackingWarningMessage: String = ""
    @Published var isTrackingNormal: Bool = false
    private let verticalThreshold: Double = 0.1
    private var lastUpdateTime: TimeInterval = 0.0
    private var cameraController: CameraController?
    private var distance: CGFloat?
    private var initHRotation: Double = 0.0
    private var stillStartTime: TimeInterval = 0.0
    private let accelThreshold: Double = 0.020     // 並進加速度（0.01〜0.03あたりから調整）
    private let gyroThreshold: Double  = 0.10     // 角速度:rad/s（0.10〜0.30あたりから調整）
    private let stillHoldTime: TimeInterval = 0.40 // この秒数 “静止” が続いたらOK
    private var lastTrackingMessage: String = ""
    
    func startUpdates(cameraController: CameraController, arSessionManager: ARSessionManager) {
        self.cameraController = cameraController
        self.arSessionManager = arSessionManager
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates(to: queue) { [weak self] (data, error) in
                guard let data = data else { return }
                DispatchQueue.main.async {
                    self?.updateAlignmentStatus(with: data)
                }
            }
        }
    }
    
    func stopUpdates() {
        motion.stopDeviceMotionUpdates()
    }
    
    func resetParameters(){
        rotationCount = 0
        lastUpdateTime = 0
    }
    
    private func updateStillness(with data: CMDeviceMotion, currentTime: TimeInterval) {
        let a = data.userAcceleration
        let w = data.rotationRate

        // userAcceleration は重力を除いた加速度（g単位）
        let accelMag = sqrt(a.x*a.x + a.y*a.y + a.z*a.z)

        // rotationRate は rad/s
        let gyroMag  = sqrt(w.x*w.x + w.y*w.y + w.z*w.z)

        let isInstantStill = (accelMag < accelThreshold) && (gyroMag < gyroThreshold)

        if isInstantStill {
            if stillStartTime == 0 { stillStartTime = currentTime }
            isDeviceStill = (currentTime - stillStartTime) >= stillHoldTime
        } else {
            stillStartTime = 0
            isDeviceStill = false
        }
    }
    
    private func updateTrackingStatus() -> Bool {
        guard let currentFrame = arSessionManager?.session.currentFrame else {
            isTrackingNormal = false
            trackingWarningMessage = "ARセッション初期化中です"
            logIfChanged("currentFrame is nil")
            return false
        }

        // --- trackingState 判定 ---
        switch currentFrame.camera.trackingState {
        case .normal:
            // ここでは return しない（mappingも見る）
            break

        case .notAvailable:
            isTrackingNormal = false
            trackingWarningMessage = "トラッキング情報を取得できません"
            logIfChanged("trackingState: notAvailable")
            return false

        case .limited(let reason):
            isTrackingNormal = false

            switch reason {
            case .initializing:
                trackingWarningMessage = "トラッキング初期化中です"
                logIfChanged("trackingState: limited(initializing)")

            case .excessiveMotion:
                trackingWarningMessage = "端末を動かしすぎています"
                logIfChanged("trackingState: limited(excessiveMotion)")

            case .insufficientFeatures:
                trackingWarningMessage = "特徴点が不足しています。模様の少ない壁や暗所を避けてください"
                logIfChanged("trackingState: limited(insufficientFeatures)")

            case .relocalizing:
                trackingWarningMessage = "位置を再特定中です"
                logIfChanged("trackingState: limited(relocalizing)")

            @unknown default:
                trackingWarningMessage = "トラッキング状態が不安定です"
                logIfChanged("trackingState: limited(unknown)")
            }

            return false
        }

        // --- worldMappingStatus 判定 ---
        switch currentFrame.worldMappingStatus {
        case .extending:
            isTrackingNormal = true
            trackingWarningMessage = ""
            logIfChanged("OK: tracking=normal, mapping=extending")
            return true

        case .mapped:
            isTrackingNormal = true
            trackingWarningMessage = ""
            logIfChanged("OK: tracking=normal, mapping=mapped")
            return true

        case .notAvailable:
            isTrackingNormal = false
            trackingWarningMessage = "空間マッピングがまだ利用できません"
            logIfChanged("worldMappingStatus: notAvailable")
            return false

        case .limited:
            isTrackingNormal = true
            trackingWarningMessage = "空間マッピングはまだ不十分です"
            logIfChanged("worldMappingStatus: limited")
            return true

        @unknown default:
            isTrackingNormal = false
            trackingWarningMessage = "空間マッピング状態が不明です"
            logIfChanged("worldMappingStatus: unknown")
            return false
        }
    }

    private func updateAlignmentStatus(with data: CMDeviceMotion) {
        guard let cameraController = self.cameraController else { return }

        let currentTime = Date().timeIntervalSince1970
        let isTrackingNormal = updateTrackingStatus()
        updateStillness(with: data, currentTime: currentTime)

        self.gravityZ = data.gravity.z
        var angle = atan2(data.attitude.rotationMatrix.m31, data.attitude.rotationMatrix.m32) * 180.0 / .pi
        if angle < 0 {
            angle += 360
        }
        angle = fmod(angle + 180, 360)
        self.horizontalRotation = angle
        self.calibratedHRotation = fmod((self.horizontalRotation - self.initHRotation) + 360, 360)

        let horizontalCount = cameraController.horizontalCaptureCount
        let upwardEnabled = cameraController.upwardAngle > 0
        let downwardEnabled = cameraController.downwardAngle > 0

        let upwardEnd = horizontalCount + (upwardEnabled ? horizontalCount : 0)
        let downwardEnd = upwardEnd + (downwardEnabled ? horizontalCount : 0)

        if rotationCount == 0 {
            let isVertical = (sin(-5 * .pi / 180)...sin(5 * .pi / 180)).contains(self.gravityZ)
            handleFirstCapture(isVertical: isVertical, gravityZ: self.gravityZ, isTrackingNormal: isTrackingNormal)

        } else if rotationCount <= horizontalCount && isCapturing {
            let isVertical = (sin(-5 * .pi / 180)...sin(5 * .pi / 180)).contains(self.gravityZ)
            handleSubsequentCaptures(isCheck: isVertical, isTrackingNormal: isTrackingNormal)

        } else if upwardEnabled && rotationCount <= upwardEnd {
            let isUpwardTilted = (sin((Double(cameraController.upwardAngle) - 5) * .pi / 180)...sin((Double(cameraController.upwardAngle) + 5) * .pi / 180)).contains(self.gravityZ)
            handleSubsequentCaptures(isCheck: isUpwardTilted, isTrackingNormal: isTrackingNormal)

        } else if downwardEnabled && rotationCount <= downwardEnd {
            let isDownwardTilted = (sin((Double(-cameraController.downwardAngle) - 5) * .pi / 180)...sin((Double(-cameraController.downwardAngle) + 5) * .pi / 180)).contains(self.gravityZ)
            handleSubsequentCaptures(isCheck: isDownwardTilted, isTrackingNormal: isTrackingNormal)

        } else if rotationCount == downwardEnd + 1 {
            isCapturing = false
            isCapturingFinished = true
            stopUpdates()
        }
    }
//    private func updateAlignmentStatus(with data: CMDeviceMotion) {
//        guard let cameraController = self.cameraController else { return }
//        let currentTime = Date().timeIntervalSince1970
//        let isTrackingNormal = updateTrackingStatus()
//        updateStillness(with: data, currentTime: currentTime)
//        
//        self.gravityZ = data.gravity.z
//        var angle = atan2(data.attitude.rotationMatrix.m31, data.attitude.rotationMatrix.m32) * 180.0 / .pi
//        if angle < 0 {
//            angle += 360
//        }
//        angle = fmod(angle + 180, 360)
//        self.horizontalRotation = angle
//        self.calibratedHRotation = fmod((self.horizontalRotation - self.initHRotation) + 360, 360)
//
//        if rotationCount == 0 {
//            // キャリブレーション時の撮影
//            let isVertical = (sin(-5 * .pi / 180)...sin(5 * .pi / 180)).contains(self.gravityZ) // -5度以上5度以下
//            handleFirstCapture(isVertical: isVertical, gravityZ: self.gravityZ, isTrackingNormal: isTrackingNormal)
//        } else if (rotationCount <= cameraController.horizontalCaptureCount) && isCapturing {
//            // 12枚目までの撮影（垂直）
//            let isVertical = (sin(-5 * .pi / 180)...sin(5 * .pi / 180)).contains(self.gravityZ) // -5度以上5度以下
//            handleSubsequentCaptures(isCheck: isVertical, isTrackingNormal: isTrackingNormal)
//        } else if rotationCount <= cameraController.horizontalCaptureCount * 2 {
//            // 24枚目までの撮影（上向き）
//            let isUpwardTilted = (sin((Double(cameraController.upwardAngle) - 5) * .pi / 180)...sin((Double(cameraController.upwardAngle) + 5) * .pi / 180)).contains(self.gravityZ)
//            handleSubsequentCaptures(isCheck: isUpwardTilted, isTrackingNormal: isTrackingNormal)
//        } else if rotationCount <= cameraController.horizontalCaptureCount * 3 {
//            // 36枚目までの撮影（下向き）
//            let isDownwardTilted = (sin((Double(-cameraController.downwardAngle) - 5) * .pi / 180)...sin((Double(-cameraController.downwardAngle) + 5) * .pi / 180)).contains(self.gravityZ)
//            handleSubsequentCaptures(isCheck: isDownwardTilted, isTrackingNormal: isTrackingNormal)
//        } else if rotationCount == cameraController.horizontalCaptureCount * 3 + 1 {
//            isCapturing = false
//            isCapturingFinished = true
//            stopUpdates()
//        }
//    }
    
    private func logIfChanged(_ message: String) {
        guard message != lastTrackingMessage else { return }
        lastTrackingMessage = message
        print("[Tracking] \(message)")
    }

    private func handleFirstCapture(isVertical: Bool, gravityZ: Double, isTrackingNormal: Bool) {
        let currentTime = Date().timeIntervalSince1970
        if isVertical && isDeviceStill && isTrackingNormal {
            captureProgress(currentTime: currentTime)
        } else {
            resetProgress()
        }
        // 1回目の撮影時の円位置更新
        DispatchQueue.main.async {
            self.updateCirclePosition(gravityZ: gravityZ)
        }
    }

    private func handleSubsequentCaptures(isCheck: Bool, isTrackingNormal: Bool) {
        let currentTime = Date().timeIntervalSince1970
        guard let distance = self.cameraController?.calculateObjectDistance() else { return }
        if distance <= 40 && isCheck && isDeviceStill && isTrackingNormal {
            captureProgress(currentTime: currentTime)
        } else {
            resetProgress()
        }
    }
    
    private func captureProgress(currentTime: TimeInterval) {
        // ARオブジェクトと中心円が重なっている場合
        if lastUpdateTime == 0.0 {
            lastUpdateTime = currentTime
        }
        let deltaTime = currentTime - lastUpdateTime
        progress = min(progress + deltaTime / 1.0, 1.0)
        lastUpdateTime = currentTime

        if progress >= 1.0 && !isPhoto {
            if rotationCount == 0 {
                isCalibrating = false
                isCalibrationFinished = true
            }
            progress = 1.0
            isPhoto = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.capturePhoto()
            }
        }
    }

    private func resetProgress() {
        withAnimation(.none) {
            progress = 0.0
        }
        isPhoto = false
        lastUpdateTime = 0.0
    }
    
    func updateCirclePosition(gravityZ: Double) {
        let screenHeight = UIScreen.main.bounds.height
        movingCircleOffset = CGSize(
            width: 0,
            height: (screenHeight / 2) * CGFloat(gravityZ)
        )
    }
    
    private func capturePhoto() {
        // キャリブレーションまたは写真を撮影
        if rotationCount == 0 {
            // キャリブレーション時の初回の水平角度を基準点として設定
            self.initHRotation = self.horizontalRotation
            cameraController?.initializeCameraTransform()
        } else {
            cameraController?.capturePhoto()
            // 撮影したARオブジェクトの色を変更
            cameraController?.changeARObjectColor(Count: rotationCount)
        }
        
        // 次のターゲット位置を計算 (rotationCount == 0のときも必要)
        cameraController?.calculateRotatedPosition(Count: rotationCount)
        
        // 次のターゲット位置にオブジェクトを作成
        if rotationCount > 0 {
            cameraController?.addObjectAtTargetPosition(Count: rotationCount + 1)
        }
        rotationCount += 1
        isPhoto = false
        progress = 0.0
    }
}
