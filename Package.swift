// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tidytalk",
    platforms: [.macOS("26.0")],
    targets: [
        // sherpa-onnx C API 和它依赖的 ONNX Runtime（预编译动态库）。
        // scripts/fetch-deps.sh 下载官方发布的文件、按固定哈希校验后组装成这两个 xcframework
        .binaryTarget(name: "CSherpaOnnx", path: "Vendor/CSherpaOnnx.xcframework"),
        .binaryTarget(name: "OnnxRuntime", path: "Vendor/OnnxRuntime.xcframework"),

        // 与系统 API 无关的纯逻辑：按键状态机、整理提示词与校验、音频切分、模型清单
        .target(name: "TidytalkCore"),

        // 应用本身：说话输入、实时字幕、文件转写、设置界面。做成库是为了能被单元测试直接引用
        .target(name: "TidytalkApp", dependencies: ["TidytalkCore", "CSherpaOnnx", "OnnxRuntime"]),

        // 可执行文件只有 main.swift，调用 TidytalkApp 的入口
        .executableTarget(name: "Tidytalk", dependencies: ["TidytalkApp"]),

        .testTarget(name: "TidytalkCoreTests", dependencies: ["TidytalkCore"]),
        .testTarget(name: "TidytalkAppTests", dependencies: ["TidytalkApp", "TidytalkCore"]),
    ]
)
