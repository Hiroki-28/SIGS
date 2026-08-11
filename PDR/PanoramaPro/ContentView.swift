//
//  ContentView.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/06/30.
//

import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var arSessionManager = ARSessionManager()
    @StateObject private var cameraController = CameraController()
    @StateObject private var motionManager = MotionManager()
    @State private var isInitialSetting = true
    @State private var isBeforeCalibration = false
    @State private var showCompletionMessage = true
    @State private var selectedPhotoCount = 24
    @State private var upwardAngle = ""
    @State private var downwardAngle = ""
    
    var body: some View {
        ZStack {
            ARViewContainer(arSessionManager: arSessionManager)
                .edgesIgnoringSafeArea(.all)
                .onAppear {
                    // ARセッションを開始
                    arSessionManager.startSession()
                    // cameraControllerにarSessionManagerを設定
                    cameraController.setARSessionManager(arSessionManager)
                }
            
            // 初期設定のビュー
            if isInitialSetting {
                VStack(spacing: 25) {
                    VStack(alignment: .leading) {
                        Text(ViewMessageTemplate.initalSettingTitle)
                            .font(.title3)
                            .fontWeight(.bold)
                            .padding(.top, 20)
                            .padding(.bottom, 15)
                            .frame(maxWidth: .infinity, alignment: .center)
                        
                        Text(ViewMessageTemplate.initalSettingBody1)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.leading)
                            .padding(.bottom, 10)
                        
                        Text(ViewMessageTemplate.initalSettingBody2)
                            .fontWeight(.bold)
                            .multilineTextAlignment(.leading)
                            .padding(.bottom, 20)
                    }
                    .padding(.leading, 30)
                    .padding(.trailing, 25)
                    .frame(maxWidth: .infinity)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .shadow(radius: 8)
                    .padding(.top, 10)
                    .padding(.horizontal, 40)

                    
                    VStack(alignment: .leading, spacing: 12) {

                        // 撮影枚数
                        VStack(alignment: .leading, spacing: 12) {
                            Text("1回転あたりの撮影枚数")
                                .font(.headline)
                            Picker("撮影枚数", selection: $cameraController.horizontalCaptureCount) {
                                ForEach([1, 12, 24, 36], id: \.self) { count in
                                    Text("\(count) 枚")
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("上向き撮影")
                                .font(.headline)
                            Picker("上向き撮影", selection: $cameraController.upwardAngle) {
                                Text("なし").tag(0)
                                ForEach([20, 30, 40], id: \.self) { degree in
                                    Text("\(degree)°").tag(degree)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 12) {
                            Text("下向き撮影")
                                .font(.headline)
                            Picker("下向き撮影", selection: $cameraController.downwardAngle) {
                                Text("なし").tag(0)
                                ForEach([20, 30, 40], id: \.self) { degree in
                                    Text("\(degree)°").tag(degree)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .padding(.horizontal)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 40)
//                    .background(Color.green)
//                    .foregroundColor(.white)
//                    .cornerRadius(12)
//                    .shadow(radius: 8)
//                    .padding(.horizontal, 40)
                    
                    // スペース
//                    Spacer()
                    
                    VStack {
                        Button(action: {
                            isInitialSetting = false
                            isBeforeCalibration = true
                        }) {
                            Text("次へ")
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.vertical, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(radius: 8)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 50)
                    }
                    .disabled(cameraController.horizontalCaptureCount == 0)
                    .opacity(cameraController.horizontalCaptureCount == 0 ? 0.5 : 1.0)
                }
            }
            
            // キャリブレーション前のビュー
            if isBeforeCalibration {
                VStack {
                    Button(action: {
                        isBeforeCalibration = false
                        motionManager.isCalibrating = true
                        motionManager.startUpdates(cameraController: cameraController, arSessionManager: arSessionManager) // カメラコントローラを渡す
                    }) {
                        Text("初期位置調整スタート！")
                            .font(.title2)
                            .fontWeight(.bold)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(radius: 8) // 影を追加
                            .padding(.horizontal, 40)
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // キャリブレーション中のビュー
            if motionManager.isCalibrating {
                VStack {
                    VStack {
                        Text("○と●を重ね合わせて撮影")
                            .font(.title3)
                            .fontWeight(.bold)
                            .padding(.vertical, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .background(Color.white)
                    .foregroundColor(.black)
                    .cornerRadius(12)
                    .shadow(radius: 8)
                    .padding(.horizontal, 40)
                    .padding(.top, 50)
                    Spacer()
                }
                
                // 画面全体に対して中央に固定されたZStack
                ZStack {
                    // 常に画面の中央に固定された円
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 90, height: 90)
                    
                    // プログレスバー
                    Circle()
                        .trim(from: 0.0, to: CGFloat(motionManager.progress))
                        .stroke(Color.red, lineWidth: 5)
                        .frame(width: 90, height: 90)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear, value: motionManager.progress) // アニメーションを修正
                    
                    if motionManager.rotationCount == 0 {
                        // デバイスの傾きに応じて動的に変わる塗りつぶされた円
                        Circle()
                            .fill(Color.white)
                            .frame(width: 75, height: 75)
                            .offset(x: motionManager.movingCircleOffset.width, y: motionManager.movingCircleOffset.height)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // キャリブレーション完了時のビュー
            if motionManager.isCalibrationFinished {
                ZStack {
                    // グレーの背景
                    Color.gray.opacity(0.6)
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack(spacing: 20) {
                        // メッセージ表示部分（完了メッセージが表示される場合）
                        if showCompletionMessage {
                            VStack {
                                Text(ViewMessageTemplate.calibrationCompleteTitle1)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.vertical, 20)
                            }
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(radius: 8)
                            .padding(.horizontal, 40)
                            .padding(.top, 50)
                            
                            // スペースと撮影スタートボタン
                            Spacer()
                            
                            VStack {
                                Button(action: {
                                    // 完了メッセージを消して次に進む
                                    showCompletionMessage = false
                                }) {
                                    Text("次へ")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .padding(.vertical, 16)
                                }
                                .frame(maxWidth: .infinity)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .shadow(radius: 8)
                                .padding(.horizontal, 40)
                                .padding(.bottom, 50)
                            }
                            
                        } else {
                            // 撮影ガイド部分（完了メッセージが非表示になったら表示）
                            VStack {
                                Text(ViewMessageTemplate.calibrationCompleteTitle2)
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .padding(.top, 30)
                                
                                Text(ViewMessageTemplate.calibrationCompleteBody)
                                    .lineSpacing(4)
                                    .fontWeight(.bold)
                                    .padding(.horizontal, 30)
                                    .padding(.bottom, 10)
                            }
                            .frame(maxWidth: .infinity)
                            .background(Color.green)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(radius: 8)
                            .padding(.top, 50)
                            .padding(.horizontal, 40)
                        
                            // スペース追加
                            Spacer()
                            
                            VStack {
                                Button(action: {
                                    motionManager.isCapturing = true // 撮影を開始
                                    cameraController.addObjectAtTargetPosition(Count: motionManager.rotationCount) // 1個目の赤いオブジェクトを追加
                                    motionManager.isCalibrationFinished = false // 完了ビューを閉じる
                                }) {
                                    Text("撮影スタート！")
                                        .font(.title2)
                                        .fontWeight(.bold)
                                        .padding(.vertical, 16)
                                }
                                .frame(maxWidth: .infinity)
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                                .shadow(radius: 8)
                                .padding(.horizontal, 40)
                                .padding(.bottom, 50)
                            }
                        }
                    }
                }
            }

            // 撮影中のビュー
            if motionManager.isCapturing {
                ZStack(alignment: .top) {
                    
                    VStack {
                        let upwardCount = cameraController.upwardAngle > 0 ? cameraController.horizontalCaptureCount : 0
                        let downwardCount = cameraController.downwardAngle > 0 ? cameraController.horizontalCaptureCount : 0
                        let totalShots = cameraController.horizontalCaptureCount + upwardCount + downwardCount

                        VStack {
                            Text("Shots: \(motionManager.rotationCount - 1) / \(totalShots)")
                                .font(.system(size: 26))
                                .fontWeight(.bold)
                                .padding()
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.black)
                        .background(Color.white.opacity(0.8))
                        .cornerRadius(8)
                        .padding(.horizontal, 50)
                        .padding(.top, 50)
                        
                        Spacer()
                        
                        // 2つのボックスを横並びに表示するHStack
                        HStack {
                            // 垂直の角度
                            HStack {
                                Text("Tilt: \(Int(round(asin(motionManager.gravityZ) * 180.0 / .pi)))°")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .frame(width: 125)
                            .padding()
                            .background(Color.white.opacity(0.9))
                            .cornerRadius(12)
                            .shadow(radius: 3)
                            
                            // 水平の角度
                            HStack {
                                Text("Pan: \((Int(round(motionManager.calibratedHRotation)) % 360 == 0 ? 0 : Int(round(motionManager.calibratedHRotation))))°")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundColor(.black)
                            .frame(width: 125)
                            .padding()
                            .background(Color.white.opacity(0.9))
                            .cornerRadius(12)
                            .shadow(radius: 3)
                            
                        }
                        .padding(.bottom, 50)
                    }
                }
                
                // 画面全体に対して中央に固定されたZStack
                ZStack {
                    // 常に画面の中央に固定された円
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 90, height: 90)
                    
                    // プログレスバー
                    Circle()
                        .trim(from: 0.0, to: CGFloat(motionManager.progress))
                        .stroke(Color.red, lineWidth: 5)
                        .frame(width: 90, height: 90)
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.08), value: motionManager.progress)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // 撮影完了時のビュー
            if motionManager.isCapturingFinished {
                ZStack {
                    // グレーの背景
                    Color.gray.opacity(1.0)
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack {
                        // メッセージ表示部分
                        VStack {
                            Text("お疲れ様でした！\n撮影が完了し、データはファイルアプリに保存されました。")
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding()
                        }
                        .frame(maxWidth: .infinity)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .shadow(radius: 8)
                        .padding(.horizontal, 40)
                        .padding(.top, 50)

                        Spacer()

                        // シーン撮影継続ボタン
                        VStack {
                            Button(action: {
                                print("Before: \(isBeforeCalibration)")
                                print("motionManager.isCalibrating_Before: \(motionManager.isCalibrating)")
                                print("motionManager.isCalibrationFinished_Before: \(motionManager.isCalibrationFinished)")
                                arSessionManager.resetObjects() // オブジェクトを全て消去
                                motionManager.resetParameters()
                                motionManager.isCapturingFinished = false // 完了ビューを閉じる
                                isBeforeCalibration = true
                                showCompletionMessage = true
                                print("After: \(isBeforeCalibration)")
                                print("motionManager.isCalibrating_After: \(motionManager.isCalibrating)")
                                print("motionManager.isCalibrationFinished_After: \(motionManager.isCalibrationFinished)")
                            }) {
                                Text("シーン撮影を継続")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .padding(.vertical, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(radius: 8)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 10)
                            
                            // 終了ボタン
                            Button(action: {
                                // 終了処理をここに記述
                                exit(0) // アプリを終了させる例（環境に応じて適切な終了処理を行ってください）
                            }) {
                                Text("終了")
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .padding(.vertical, 16)
                            }
                            .frame(maxWidth: .infinity)
                            .background(Color.pink)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                            .shadow(radius: 8)
                            .padding(.horizontal, 40)
                            .padding(.bottom, 50)
                        }
                    }
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View{
        ContentView()
    }
}
