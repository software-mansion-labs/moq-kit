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
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.0.1-alpha/moqffi.xcframework.zip",
            checksum: "e5412ff477bd3470f2816c2ee5cf5258be2acc8a75a5b255a5697aa6645c53ae"
        ),
    ]
)
