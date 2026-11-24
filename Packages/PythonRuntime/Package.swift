// swift-tools-version: 5.9
import PackageDescription

// 只做一件事：把预编译的 CPython 链接进来，外加一层 Objective-C 外壳。
// 用的是 beeware/Python-Apple-support 的官方 iOS 构建（内含设备与模拟器两个 slice），
// 不在本机编译 CPython —— 那需要在 macOS 上跑一整套交叉编译脚本，构建机扛不住。
//
// Vendor/ 由 scripts/fetch_python_runtime.sh 准备（CI 里在 resolve 之前跑一次）。
let package = Package(
    name: "PythonRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "YueduPythonRuntime", targets: ["YueduPythonRuntime"])],
    targets: [
        .binaryTarget(name: "Python", path: "Vendor/Python.xcframework"),
        .target(
            name: "YueduPythonRuntime",
            dependencies: ["Python"],
            publicHeadersPath: "include"
        )
    ]
)
