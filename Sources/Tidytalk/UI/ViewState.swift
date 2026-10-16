import SwiftUI

/// SwiftUI 的 `@State` 在新 SDK 中由宏实现，而宏插件只随完整版 Xcode 提供。
/// 通过类型别名直接使用属性包装器本体，使项目只用 Command Line Tools 也能编译。
typealias ViewState = SwiftUI.State
