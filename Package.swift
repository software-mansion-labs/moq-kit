// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoQKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "MoQKit", targets: ["MoQKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5")
    ],
    targets: [
        .target(
            name: "MoQKit",
            dependencies: ["MoQKitFFI"],
            path: "ios/Sources/MoQKit"
        ),
        .target(
            name: "MoQKitFFI",
            dependencies: ["moqFFI"],
            path: "ios/Sources/MoQKitFFI"
        ),
        .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.0.1-alpha5/moqffi.xcframework.zip",
            checksum: "d74f5ec3fc740f3be804611a51cfeac1de3746637bc8783699dc8d94270b17d8"
        ),
    ]
)
