// swift-tools-version: 5.9

import PackageDescription

// Local build tasks regenerate ios/Frameworks/moqffi.xcframework and set this
// flag so generated Swift bindings compile against the matching binary.
let moqFFITarget: Target = Context.environment["MOQKIT_USE_LOCAL_FFI"] == "1"
    ? .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.1.0/moqffi.xcframework.zip",
            checksum: "4ae7c531e4a48b1f56561a1f54ef08564a93006da57816e0f82851ba1d09e1e2"
        )
    : .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.1.0/moqffi.xcframework.zip",
            checksum: "4ae7c531e4a48b1f56561a1f54ef08564a93006da57816e0f82851ba1d09e1e2"
        )

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
        .testTarget(
            name: "MoQKitTests",
            dependencies: ["MoQKit"],
            path: "ios/Tests/MoQKitTests"
        ),
        moqFFITarget,
    ]
)
