// swift-tools-version: 5.9
import PackageDescription

// No remote dependencies. The same mathematical code is compiled into the iOS target.
let package = Package(
    name: "DepthCore",
    products: [.library(name: "DepthCore", targets: ["DepthCore"])],
    targets: [
        .target(name: "DepthCore", path: "PGYDepthDemo/Core"),
        .testTarget(name: "DepthCoreTests", dependencies: ["DepthCore"], path: "Tests/DepthCoreTests")
    ]
)
