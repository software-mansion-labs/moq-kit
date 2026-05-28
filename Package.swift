// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoQKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "MoQKit", targets: ["MoQKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5"),
        .package(url: "https://github.com/apple/swift-atomics", from: "1.2.0"),
        .package(url: "https://github.com/moq-dev/moq-swift", from: "0.2.15")
    ],
    targets: [
        .target(
            name: "MoQKit",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Moq", package: "moq-swift")
            ],
            path: "ios/Sources/MoQKit"
        ),
        .testTarget(
            name: "MoQKitTests",
            dependencies: [
                "MoQKit",
                .product(name: "Moq", package: "moq-swift")
            ],
            path: "ios/Tests/MoQKitTests"
        )
    ]
)
