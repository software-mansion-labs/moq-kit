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
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.0.1-alpha3/moqffi.xcframework.zip",
            checksum: "4c04a8b32917c6c79b37b872dc0a8851711cceae1510477277b8449e8d646158"
        ),
    ]
)
