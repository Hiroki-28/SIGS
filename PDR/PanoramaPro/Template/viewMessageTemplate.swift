//
//  viewMessageTemplate.swift
//  PanoramaPro
//
//  Created by Guest  on 2024/10/19.
//

import SwiftUI

struct ViewMessageTemplate {
    static let initalSettingTitle: String = "撮影の準備を始めましょう！"
    static let initalSettingBody1: String = """
    このアプリでは、スマートフォンをぐるっと回して写真を撮影し、3Dのシーンを作成します。
    """
    static let initalSettingBody2: String = """
    まずは、1回転あたりの撮影枚数と、カメラの傾き（上向き・下向き）の角度を設定してください。
    """
    static let calibrationCompleteTitle1: String = "初期位置を記録しました。"
    static let calibrationCompleteTitle2: String = "ガイドに従って撮影しよう！\n"
    static let calibrationCompleteBody: String = """
    ①赤いオブジェクトにデバイスの中心を合わせてください。\n
    ②1秒間合わせると撮影が行われ、オブジェクトが緑に変わります。\n
    ③次の撮影位置に新しい赤いオブジェクトが表示されるので、①②を繰り返してください。\n
    """
}
