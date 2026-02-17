// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MoQKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "MoQKit", targets: ["MoQKit"]),
    ],
    targets: [
        .binaryTarget(name: "Clibmoq", path: "Frameworks/Clibmoq.xcframework"),
        .target(name: "MoQKit", dependencies: ["Clibmoq"], path: "Sources/MoQKit"),
    ]
)
