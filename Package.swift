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
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/ios/v1.0.1/moqffi.xcframework.zip",
            checksum: "36feab14d516c8dde5d320a48925924bf88702da17bc26f5f1062d9d4869c65c"
        )
    : .binaryTarget(
            name: "moqFFI",
            url: "https://github.com/software-mansion-labs/moq-kit/releases/download/ios/v1.0.1/moqffi.xcframework.zip",
            checksum: "36feab14d516c8dde5d320a48925924bf88702da17bc26f5f1062d9d4869c65c"
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
