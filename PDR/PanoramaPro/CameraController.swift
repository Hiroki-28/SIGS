/*
See LICENSE folder for this sample’s licensing information.

Abstract:
An object that configures and manages the capture pipeline to stream video and LiDAR depth data.
*/

import ARKit
import CoreImage
import Photos
import UIKit
import MetalKit
import RealityKit

protocol CaptureDataReceiver: AnyObject {
    func onNewPhotoData(capturedData: CameraCapturedData)
}

class CameraController: NSObject, ObservableObject, ARSessionDelegate {
    private var arSessionManager: ARSessionManager?
    weak var delegate: CaptureDataReceiver?
    private var captureFolderManager: CaptureFolderManager?
    private var textureCache: CVMetalTextureCache!
    private var initialCameraTransform: simd_float4x4?
    private var targetWorldPosition: SIMD3<Float>?
    private var previousTargetWorldPosition: SIMD3<Float>?  // 1つ前のターゲットポジション。撮影ガイド（矢印）を出す際に使用。
    private var targetsByCount: [Int: ModelEntity] = [:]
    private let maxPointCloudDepth: Float = 5.0
    var initialCameraPosition: SIMD3<Float>?
    var initialHorizontalForward: SIMD3<Float>?
    @Published var horizontalCaptureCount = 0
    @Published var upwardAngle = 0
    @Published var downwardAngle = 0

    override init() {
        super.init()
        setupTextureCache()
        captureFolderManager = CaptureFolderManager()
    }

    // 後からARSessionManagerを設定するためのメソッドを追加
    func setARSessionManager(_ arSessionManager: ARSessionManager) {
        self.arSessionManager = arSessionManager
    }

    func resetCaptureFolderManager() {
        captureFolderManager = CaptureFolderManager()
    }

    private func setupTextureCache() {
        CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            MetalEnvironment.shared.metalDevice,
            nil,
            &textureCache
        )
    }

    func startARSession() {
        // ARSessionManagerにセッションの開始を委譲
        arSessionManager?.startSession()
    }

    func stopARSession() {
        // ARSessionManagerにセッションの停止を委譲
        arSessionManager?.stopSession()
    }
    
    func getCameraTransform() {
        guard let arSessionManager = arSessionManager else { return }
        guard let currentFrame = arSessionManager.session.currentFrame else { return }
        let transform = currentFrame.camera.transform
        print("transform: ")
        print(transform)
        print("translation: ")
        print(transform.columns.3)
        for rowIndex in 0..<4 {
            let row = transform[rowIndex]
            print("Row \(rowIndex): \(row.x), \(row.y), \(row.z), \(row.w)")
        }
        // XYZ方向の回転角度（オイラー角）を計算
        let rotationMatrix = simd_float3x3(
            simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )

        // XYZ順 (Roll → Pitch → Yaw) のオイラー角を計算
        let roll = atan2(rotationMatrix[2][1], rotationMatrix[2][2]) // X軸回転 (Roll)
        let pitch = asin(-rotationMatrix[2][0]) // Y軸回転 (Pitch)
        let yaw = atan2(rotationMatrix[1][0], rotationMatrix[0][0]) // Z軸回転 (Yaw)

        // ラジアンを度に変換
        let rollDegrees = roll * 180 / .pi
        let pitchDegrees = pitch * 180 / .pi
        let yawDegrees = yaw * 180 / .pi

        // 出力
        print("Roll (X軸回転): \(rollDegrees)度")
        print("Pitch (Y軸回転): \(pitchDegrees)度")
        print("Yaw (Z軸回転): \(yawDegrees)度")
    }

    func capturePhoto() {
        guard let arSessionManager = arSessionManager else { return }
        guard let currentFrame = arSessionManager.session.currentFrame else { return }

        // 深度データを取得
        if let sceneDepth = currentFrame.sceneDepth {
            let depthPixelBuffer = sceneDepth.depthMap

            // RGBカメラ画像の取得
            let capturedImage = CIImage(cvPixelBuffer: currentFrame.capturedImage)

            // カメラ画像、深度画像をそれぞれ保存
            saveCapturedImage(capturedImage: capturedImage)
            saveDepthMapImage(depthPixelBuffer: depthPixelBuffer)
            
            // カメラパラメータの取得
            let camera = currentFrame.camera
            // カメラのTransformデータを保存
            saveCameraTransformData(transform: camera.transform)

            // 点群の計算
            let pointCloud = generateColoredPointCloud(from: depthPixelBuffer, colorImage: capturedImage,camera: camera)
            // 点群データを保存
            saveColoredPointCloud(pointCloud)
            
            // カメラの視野角（FOV）の保存
            saveFOV(camera: camera)

            // トラッキングのステータスの保存
            saveTrackingStatus(currentFrame: currentFrame)
            
            // データのパッケージ化
            let data = CameraCapturedData(
                depth: depthPixelBuffer.texture(withFormat: .r16Float, planeIndex: 0, addToCache: textureCache),
                colorY: capturedImage.toMTLTexture(),
                colorCbCr: nil,
                cameraIntrinsics: currentFrame.camera.intrinsics,
                cameraReferenceDimensions: currentFrame.camera.imageResolution
            )

            delegate?.onNewPhotoData(capturedData: data)
        }
    }
    
    // 点群生成（色つき）
    func generateColoredPointCloud(from depthPixelBuffer: CVPixelBuffer, colorImage: CIImage, camera: ARCamera) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {

        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer)!
        let depthPointer = baseAddress.assumingMemoryBound(to: Float32.self)
        
        let intrinsics = camera.intrinsics

        // 深度マップの解像度に合わせた補正
        let referenceDimensions = camera.imageResolution  // ARCamera の基準解像度（実際の画像の解像度）
        let ratioX = Float(referenceDimensions.width) / Float(width)   // 基準解像度と深度マップの解像度の比率
        let ratioY = Float(referenceDimensions.height) / Float(height)
        
        let fx = intrinsics.columns.0.x / ratioX
        let fy = intrinsics.columns.1.y / ratioY
        let cx = intrinsics.columns.2.x / ratioX
        let cy = intrinsics.columns.2.y / ratioY

        var pointCloudWithColor = [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]()  // 点の位置、色、法線をペアにする
        let colorContext = CIContext(options: nil)
        let colorBuffer = colorContext.createCGImage(colorImage, from: CGRect(x: 0, y: 0, width: CGFloat(referenceDimensions.width), height: CGFloat(referenceDimensions.height)))


        // Z軸周りに90度回転
        let thetaZ: Float = Float.pi / 2 // 90度
        let rotationMatrixZ = simd_float3x3(
            SIMD3(cos(thetaZ), -sin(thetaZ), 0),
            SIMD3(sin(thetaZ), cos(thetaZ), 0),
            SIMD3(0, 0, 1)
        )

        // Y軸周りに180度回転
        let thetaY: Float = Float.pi // 180度
        let rotationMatrixY = simd_float3x3(
            SIMD3(cos(thetaY), 0, sin(thetaY)),
            SIMD3(0, 1, 0),
            SIMD3(-sin(thetaY), 0, cos(thetaY))
        )

        // 両方の回転を適用する回転行列を計算
        let rotationMatrix = rotationMatrixY * rotationMatrixZ
        
        for y in 0..<height {
            for x in 0..<width {
                let depth = depthPointer[y * width + x]
                if depth > 0 && depth <= maxPointCloudDepth && depth.isFinite {
                    let X = (Float(x) - cx) * depth / fx
                    let Y = (Float(y) - cy) * depth / fy
                    let Z = depth
                    
                    // カメラ座標系
                    let pointInCameraSpace = SIMD3(X, Y, Z)
                    
                    // 出力時の軸方向に合わせるため、カメラ座標系の点を回転
                    let rotatedPoint = rotationMatrix * pointInCameraSpace

                    // 色情報の取得 (色の座標にも解像度の比率を適用)
                    let pixelColor = getPixelColor(from: colorBuffer!, x: Int(Float(x) * ratioX), y: Int(Float(y) * ratioY))
                    
                    // 法線ベクトルの計算 (簡略化)
                    let normal = normalize(SIMD3<Float>(X, Y, Z))

                    // 点群に位置と色を追加 (カメラ座標系)
                    pointCloudWithColor.append((SIMD3(rotatedPoint.x, rotatedPoint.y, rotatedPoint.z), pixelColor, normal))

                }
            }
        }
        
        CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
        return pointCloudWithColor
    }

    // ピクセルから色情報を取得するヘルパー関数
    func getPixelColor(from image: CGImage, x: Int, y: Int) -> SIMD3<Float> {
        let data = image.dataProvider!.data
        let ptr = CFDataGetBytePtr(data)
        let bytesPerPixel = image.bitsPerPixel / 8
        let pixelIndex = (y * image.bytesPerRow) + (x * bytesPerPixel)

        let r = Float(ptr![pixelIndex]) / 255.0
        let g = Float(ptr![pixelIndex + 1]) / 255.0
        let b = Float(ptr![pixelIndex + 2]) / 255.0

        return SIMD3(r, g, b)
    }

    func addObjectAtTargetPosition(Count: Int) {
        guard let pos = targetWorldPosition else { return }
        if let entity = arSessionManager?.addTargetObject(at: pos) {
            targetsByCount[Count] = entity
        }
    }
    
    func changeARObjectColor(Count: Int) {
        guard let entity = targetsByCount[Count] else {
            return
        }
        DispatchQueue.main.async {
            entity.model?.materials = [SimpleMaterial(color: .green, isMetallic: true)]
        }
    }
    
    func initializeCameraTransform() {
        guard let arSessionManager = arSessionManager else { return }
        guard let currentFrame = arSessionManager.session.currentFrame else { return }

        let transform = currentFrame.camera.transform
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        var forward = SIMD3<Float>(
            -transform.columns.2.x,
            -transform.columns.2.y,
            -transform.columns.2.z
        )

        // ワールドYを鉛直とみなして水平化
        forward.y = 0
        forward = simd_normalize(forward)
        self.initialCameraPosition = position
        self.initialHorizontalForward = forward
    }
    
    func calculateRotatedPosition(Count: Int) {
        // ①initialPosition, initialForwardVectorを取得
        guard let initialPosition = self.initialCameraPosition,
              let initialForwardVector = self.initialHorizontalForward else { return }
        
        // ②前向きベクトルを長さ2に正規化
        let normalizedForwardVector = initialForwardVector * 2

        // ③回転角度ラジアンで計算
        let N = horizontalCaptureCount
        let idx = Count % N                  // <- 誤差を蓄積させない
        let angleInDegrees: Float = 360.0 / Float(N) * Float(idx)
        let angleInRadians = angleInDegrees * .pi / 180.0

        // ④回転処理
        var rotatedVector = normalizedForwardVector
        
        let upwardEnabled = upwardAngle > 0
        let downwardEnabled = downwardAngle > 0
        let upwardStart = horizontalCaptureCount
        let upwardEnd = upwardStart + (upwardEnabled ? horizontalCaptureCount : 0)
        let downwardStart = upwardEnd
        let downwardEnd = downwardStart + (downwardEnabled ? horizontalCaptureCount : 0)

        // 上向き・下向き撮影なら、まずX軸周り回転（垂直回転）
        if upwardEnabled && Count >= upwardStart && Count < upwardEnd {
            let tiltAngle: Float = Float(-upwardAngle) * .pi / 180
            rotatedVector = rotateVectorAroundXAxis(vector: rotatedVector, angle: tiltAngle)

        } else if downwardEnabled && Count >= downwardStart && Count < downwardEnd {
            let tiltAngle: Float = Float(downwardAngle) * .pi / 180
            rotatedVector = rotateVectorAroundXAxis(vector: rotatedVector, angle: tiltAngle)
        }
//        if Count >= horizontalCaptureCount && Count < horizontalCaptureCount * 2 {
//            let tiltAngle: Float = Float(-upwardAngle) * .pi / 180
//            rotatedVector = rotateVectorAroundXAxis(vector: rotatedVector, angle: tiltAngle)
//        } else if Count >= horizontalCaptureCount * 2 && Count < horizontalCaptureCount * 3 {
//            let tiltAngle: Float = Float(downwardAngle) * .pi / 180
//            rotatedVector = rotateVectorAroundXAxis(vector: rotatedVector, angle: tiltAngle)
//        }

        // 次にY軸周り回転（水平回転）
        rotatedVector = rotateVectorAroundYAxis(vector: rotatedVector, angle: angleInRadians)
    
        // ⑤次のターゲット座標を決定
        if let currentTargetPosition = self.targetWorldPosition {
            self.previousTargetWorldPosition = currentTargetPosition
        }
        self.targetWorldPosition = initialPosition + rotatedVector
    }

    // Y軸周りにベクトルを回転させる関数
    func rotateVectorAroundYAxis(vector: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(cos(angle), 0, sin(angle)),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(-sin(angle), 0, cos(angle))
        )
        return rotationMatrix * vector
    }

    // X軸周りにベクトルを回転させる関数(上向き・下向き)
    func rotateVectorAroundXAxis(vector: SIMD3<Float>, angle: Float) -> SIMD3<Float> {
        let rotationMatrix = simd_float3x3(
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, cos(angle), -sin(angle)),
            SIMD3<Float>(0, sin(angle), cos(angle))
        )
        return rotationMatrix * vector
    }
    
    func calculateObjectDistance() -> CGFloat? {
        guard let arView = arSessionManager?.arView else { return nil }
        guard let targetWorldPosition = self.targetWorldPosition else { return nil }
        // カメラの視点を考慮してワールド座標をスクリーン座標に変換
        if let screenPosition = arView.project(targetWorldPosition) {
            let centerX = arView.bounds.midX
            let centerY = arView.bounds.midY
            let centerPoint = CGPoint(x: centerX, y: centerY)
            // スクリーン座標上での距離の計算
            let distance = hypot(screenPosition.x - centerPoint.x, screenPosition.y - centerPoint.y)
            return distance
        }
        return nil
    }

    // カメラの transform を保存する
    func saveCameraTransformData(transform: simd_float4x4) {
        guard let captureFolderManager = captureFolderManager else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let cameraTransformName = "CameraTransform_\(timestamp).json"
        let cameraTransformURL = captureFolderManager.cameraTransformFolder.appendingPathComponent(cameraTransformName)
        
        // Rotation (3x3部分)
        var rotationMatrix = simd_float3x3(
            simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        )
        // Z軸周りに-90度回転
        let rotationMatrixZ = simd_float3x3(
            SIMD3(0, 1, 0),
            SIMD3(-1, 0, 0),
            SIMD3(0, 0, 1)
        )
        // RotationをOpen3Dの座標系に対応させる
        rotationMatrix = rotationMatrix * rotationMatrixZ
        
        // Translation (4列目の x, y, z 成分)
        let translation = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        
        // Transform全体を直接保存
        let transformData = [
            "rotation": [
                [rotationMatrix.columns.0.x, rotationMatrix.columns.0.y, rotationMatrix.columns.0.z],
                [rotationMatrix.columns.1.x, rotationMatrix.columns.1.y, rotationMatrix.columns.1.z],
                [rotationMatrix.columns.2.x, rotationMatrix.columns.2.y, rotationMatrix.columns.2.z]
            ],
            "translation": [translation.x, translation.y, translation.z],
            "transform": [
                [rotationMatrix.columns.0.x, rotationMatrix.columns.0.y, rotationMatrix.columns.0.z, translation.x],
                [rotationMatrix.columns.1.x, rotationMatrix.columns.1.y, rotationMatrix.columns.1.z, translation.y],
                [rotationMatrix.columns.2.x, rotationMatrix.columns.2.y, rotationMatrix.columns.2.z, translation.z],
                [[0.0, 0.0, 0.0, 1.0]]
            ]
        ]
        
        // JSONとして保存
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: transformData, options: .prettyPrinted)
            try jsonData.write(to: cameraTransformURL)
            print("Transformデータが保存されました: \(cameraTransformURL)")
        } catch {
            print("Transformデータの保存に失敗: \(error.localizedDescription)")
        }
    }
    
    private func saveCapturedImage(capturedImage: CIImage) {
        guard let captureFolderManager = captureFolderManager else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let imageName = "IMG_\(timestamp).jpg"
        let imageURL = captureFolderManager.imagesFolder.appendingPathComponent(imageName)
        // 画像の回転を補正
        let rotatedImage = capturedImage.oriented(forExifOrientation: 6) // 6は右に90度回転させる方向
        let imageData = UIImage(ciImage: rotatedImage).jpegData(compressionQuality: 1.0)

        do {
            try imageData?.write(to: imageURL)
        } catch {
            print("Error saving image: \(error.localizedDescription)")
        }
    }

    private func saveDepthMapImage(depthPixelBuffer: CVPixelBuffer) {
        guard let captureFolderManager = captureFolderManager else {
            print("CaptureFolderManager is not initialized")
            return
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let depthMapName = "DEPTHMAP_\(timestamp).png"
        let depthMapURL = captureFolderManager.depthMapsFolder.appendingPathComponent(depthMapName)

        // 深度データのロック
        CVPixelBufferLockBaseAddress(depthPixelBuffer, CVPixelBufferLockFlags.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthPixelBuffer, CVPixelBufferLockFlags.readOnly) }

        // 深度データの基本情報を取得
        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer)!.assumingMemoryBound(to: Float32.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthPixelBuffer)

        // 深度データの範囲を設定（0〜5メートル）
        let minDistance: Float32 = 0.0
        let maxDistance: Float32 = 5.0 // 5メートルの範囲

        // Jetカラーマップに基づいて色を変換するためのバッファ（RGBA）
        var depthImageBuffer = [UInt8](repeating: 0, count: width * height * 4)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow / MemoryLayout<Float32>.stride + x
                let depthValue = baseAddress[pixelIndex]

                // 指定範囲内にクランプ（クリップ）
                let clampedDepth = max(min(depthValue, maxDistance), minDistance)

                // 正規化して0.0〜1.0の範囲に変換
                let normalizedDepth = (clampedDepth - minDistance) / (maxDistance - minDistance)

                // JetカラーマップでRGB値を取得
                var (r, g, b) = jetColorMap(normalizedValue: normalizedDepth)
                if normalizedDepth == 1.0 {
                    r = 0
                    g = 0
                    b = 0
                }

                // RGBAの各バッファにセット（Aは255で不透明）
                let bufferIndex = (y * width + x) * 4
                depthImageBuffer[bufferIndex] = r
                depthImageBuffer[bufferIndex + 1] = g
                depthImageBuffer[bufferIndex + 2] = b
                depthImageBuffer[bufferIndex + 3] = 255 // Alpha値
            }
        }

        // バッファをCGImageに変換
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &depthImageBuffer,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )

        guard let cgImage = context?.makeImage() else { return }
        let depthMapUIImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

        // 変換した深度マップをPNGデータとして保存
        guard let depthMapData = depthMapUIImage.pngData() else { return }

        do {
            // 深度マップをファイルに保存
            try depthMapData.write(to: depthMapURL)
        } catch {
            print("Error saving depth map: \(error.localizedDescription)")
        }
    }

    // Jetカラーマップに基づいて正規化値をRGBに変換する関数
    func jetColorMap(normalizedValue: Float) -> (UInt8, UInt8, UInt8) {
        // Appleのサンプルコードに基づいて色成分を計算
        let r = 1.5 - abs(4.0 * normalizedValue - 3.0)
        let g = 1.5 - abs(4.0 * normalizedValue - 2.0)
        let b = 1.5 - abs(4.0 * normalizedValue - 1.0)

        // 各色成分をclampして0.0〜1.0に制限
        let clampedR = max(0.0, min(1.0, r))
        let clampedG = max(0.0, min(1.0, g))
        let clampedB = max(0.0, min(1.0, b))

        // 0〜255の範囲に変換してUInt8型で返す
        return (UInt8(clampedR * 255.0), UInt8(clampedG * 255.0), UInt8(clampedB * 255.0))
    }
    
    // 点群データを保存する関数（色つき）
    private func saveColoredPointCloud(_ pointCloud: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) {
        guard let captureFolderManager = captureFolderManager else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = "ColoredPointCloud_\(timestamp).ply"
        let fileURL = captureFolderManager.pointCloudFolder.appendingPathComponent(fileName)

        // PLYファイルのヘッダーを作成
        var fileContent = """
        ply
        format ascii 1.0
        element vertex \(pointCloud.count)
        property float x
        property float y
        property float z
        property float nx
        property float ny
        property float nz
        property uchar red
        property uchar green
        property uchar blue
        end_header
        \n
        """

        // 各点の座標と色を追加
        for (point, color, normal) in pointCloud {
            let r = Int(color.x * 255)
            let g = Int(color.y * 255)
            let b = Int(color.z * 255)
            fileContent.append("\(point.x) \(point.y) \(point.z) \(normal.x) \(normal.y) \(normal.z) \(r) \(g) \(b)\n")
        }

        // ファイルに書き込む
        do {
            try fileContent.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving PLY file: \(error.localizedDescription)")
        }
    }
    
    // FOVを計算するための関数
    func calculateFOV(camera: ARCamera) -> (x: Float, y: Float) {
        let intrinsics = camera.intrinsics
        let imageResolution = camera.imageResolution

        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y

        let FOV_x = 2 * atan(Float(imageResolution.width) / (2 * fx))
        let FOV_y = 2 * atan(Float(imageResolution.height) / (2 * fy))

        return (x: FOV_x, y: FOV_y)
    }

    // FOVを保存するための関数
    func saveFOV(camera: ARCamera) {
        guard let captureFolderManager = captureFolderManager else { return }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = "FOVData_\(timestamp).json"
        let fovURL = captureFolderManager.fovFolder.appendingPathComponent(fileName)
        
        let FOV = calculateFOV(camera: camera)

        // Arrayを使用するとJSON形式に変換しても順序が保たれる
        let fovData: [[String: Float]] = [
            ["FOV_x": FOV.x],
            ["FOV_y": FOV.y]
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: fovData, options: .prettyPrinted)
            try jsonData.write(to: fovURL)
            print("FOV saved to \(fovURL)")
        } catch {
            print("Error saving FOV: \(error)")
        }
    }
    
    func saveTrackingStatus(currentFrame: ARFrame) {
        guard let captureFolderManager = captureFolderManager else { return }

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = "TrackingStatus_\(timestamp).json"
        let statusURL = captureFolderManager.trackingStatusFolder.appendingPathComponent(fileName)

        let trackingState: String
        let trackingReason: String?

        switch currentFrame.camera.trackingState {
        case .normal:
            trackingState = "normal"
            trackingReason = nil

        case .notAvailable:
            trackingState = "notAvailable"
            trackingReason = nil

        case .limited(let reason):
            trackingState = "limited"
            switch reason {
            case .initializing:
                trackingReason = "initializing"
            case .excessiveMotion:
                trackingReason = "excessiveMotion"
            case .insufficientFeatures:
                trackingReason = "insufficientFeatures"
            case .relocalizing:
                trackingReason = "relocalizing"
            @unknown default:
                trackingReason = "unknown"
            }
        }

        let worldMappingStatus: String
        switch currentFrame.worldMappingStatus {
        case .notAvailable:
            worldMappingStatus = "notAvailable"
        case .limited:
            worldMappingStatus = "limited"
        case .extending:
            worldMappingStatus = "extending"
        case .mapped:
            worldMappingStatus = "mapped"
        @unknown default:
            worldMappingStatus = "unknown"
        }

        let statusData: [String: Any] = [
            "trackingState": trackingState,
            "trackingReason": trackingReason ?? "",
            "worldMappingStatus": worldMappingStatus
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: statusData, options: .prettyPrinted)
            try jsonData.write(to: statusURL)
            print("Tracking status saved to \(statusURL)")
        } catch {
            print("Error saving tracking status: \(error)")
        }
    }
}

// Utility Extensions
extension CIImage {
    func toMTLTexture() -> MTLTexture? {
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(self, from: self.extent) else { return nil }
        let textureLoader = MTKTextureLoader(device: MTLCreateSystemDefaultDevice()!)
        return try? textureLoader.newTexture(cgImage: cgImage, options: nil)
    }
}
