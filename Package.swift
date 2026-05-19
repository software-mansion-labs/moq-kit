// swift-tools-version: 5.9

import Foundation
import PackageDescription

// Local checkouts, including the demo Xcode project, use the generated
// XCFramework when present. Release consumers fall back to the remote binary
// because ios/Frameworks/moqffi.xcframework is not tracked.
let localMoqFFIPath = "ios/Frameworks/moqffi.xcframework"
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let localMoqFFIExists = FileManager.default.fileExists(
    atPath: packageRoot.appendingPathComponent(localMoqFFIPath).path
)
let localMoqFFISetting = Context.environment["MOQKIT_USE_LOCAL_FFI"]
let useLocalMoqFFI = localMoqFFISetting == "1"
    || (localMoqFFISetting != "0" && localMoqFFIExists)

let moqFFITarget: Target = useLocalMoqFFI
    ? .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/ios/v0.1.1/moqffi.xcframework.zip",
            checksum: "99e552fb9f0c09296cb49361a86b6cdd3651e87277e70e3f98403a32da8c708b"
        )
    : .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/ios/v0.1.1/moqffi.xcframework.zip",
            checksum: "99e552fb9f0c09296cb49361a86b6cdd3651e87277e70e3f98403a32da8c708b"
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
