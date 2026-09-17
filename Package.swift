// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DrainScopeKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "DrainScope", targets: ["DrainScope"]),
        .library(name: "DrainScopeUI", targets: ["DrainScopeUI"])
    ],
    targets: [
        .target(name: "DrainScope"),
        .target(name: "DrainScopeUI", dependencies: ["DrainScope"]),
        .testTarget(name: "DrainScopeTests", dependencies: ["DrainScope"])
    ],
    swiftLanguageModes: [.v6]
)
