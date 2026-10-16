// swift-tools-version: 6.0
import PackageDescription

let vendorLib = Context.packageDirectory + "/Vendor/sherpa-onnx/lib"

let package = Package(
    name: "Tidytalk",
    platforms: [.macOS("26.0")],
    targets: [
        // sherpa-onnx C API（预编译动态库由 scripts/fetch-deps.sh 下载到 Vendor/）
        .systemLibrary(name: "CSherpaOnnx", path: "Sources/CSherpaOnnx"),

        // 与系统 API 无关的纯逻辑：按键状态机、整理提示词与校验、音频切分、模型清单
        .target(name: "TidytalkCore"),

        .executableTarget(
            name: "Tidytalk",
            dependencies: ["CSherpaOnnx", "TidytalkCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-L", vendorLib,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
                // 开发时 `swift run` 直接从 Vendor 加载动态库
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", vendorLib], .when(configuration: .debug)),
            ]
        ),

        .testTarget(name: "TidytalkCoreTests", dependencies: ["TidytalkCore"]),
    ]
)
