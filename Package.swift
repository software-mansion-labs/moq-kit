// swift-tools-version: 5.9

import PackageDescription

// Local build tasks regenerate ios/Frameworks/moqffi.xcframework and set this
// flag so generated Swift bindings compile against the matching binary.
let moqFFITarget: Target = Context.environment["MOQKIT_USE_LOCAL_FFI"] == "1"
    ? .binaryTarget(
        name: "moqFFI",
        path: "ios/Frameworks/moqffi.xcframework"
    )
    : .binaryTarget(
        name: "moqFFI",
        url: "https://github.com/software-mansion-labs/moq-kit/releases/download/v0.0.1-alpha5/moqffi.xcframework.zip",
        checksum: "d74f5ec3fc740f3be804611a51cfeac1de3746637bc8783699dc8d94270b17d8"
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
