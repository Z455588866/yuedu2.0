// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CatVodNodeRuntime",
    platforms: [.iOS(.v17)],
    products: [.library(name: "YueduNodeRuntime", targets: ["YueduNodeRuntime"])],
    targets: [
        .binaryTarget(
            name: "NodeMobile",
            // 24.21.0 在 iOS 27 上 V8 MinorGC 向已关闭的 uv 句柄投递任务会 SIGABRT，
            // 崩溃栈 uv__async_close → PerIsolatePlatformData::PostTaskImpl → MinorGCJob。
            // 24.22.1 是同一 Node 24 LTS 线的最新补丁，API 兼容且仍为 jitless V8 + polywasm。
            url: "https://github.com/fogtape/nodejs-mobile/releases/download/v24.22.1-0/nodejs-mobile-ios-24.22.1-0.zip",
            checksum: "3fa1b8fb0720768b01c2e0dae3a17e788476e8c1613a1d9a54e206793b45326e"
        ),
        .target(name: "YueduNodeRuntime", dependencies: ["NodeMobile"],
                exclude: ["NodeAPI/README.md"], publicHeadersPath: "include")
    ]
)
