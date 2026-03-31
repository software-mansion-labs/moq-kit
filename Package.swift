// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoQKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MoQKit", targets: ["MoQKit"])
    ],
    targets: [
        .target(name: "MoQKit", dependencies: ["moqFFI"], path: "ios/Sources/MoQKit"),
        .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.0.1-alpha2/moqffi.xcframework.zip",
            checksum: "38511df01fa2f5710b5b13a7df8baea78bca7cfa29fd1c49ba5dae28a0287573"
        ),
    ]
)
