// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoQKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MoQKit", targets: ["MoQKit"])
    ],
    targets: [
        .target(name: "MoQKit", dependencies: ["moqFFI"], path: "Sources/MoQKit"),
        .binaryTarget(name: "moqFFI", path: "Frameworks/moqffi.xcframework"),
    ]
)
