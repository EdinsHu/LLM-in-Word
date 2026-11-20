// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WordMath",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "WordMath", targets: ["WordMathApp"]),
        .library(name: "WordMathCore", targets: ["WordMathCore"])
    ],
    targets: [
        .target(name: "WordMathCore"),
        .executableTarget(name: "WordMathApp", dependencies: ["WordMathCore"], resources: [.copy("Resources/Panel")]),
        .testTarget(name: "WordMathCoreTests", dependencies: ["WordMathCore"]),
        .testTarget(name: "WordIntegrationTests", dependencies: ["WordMathApp", "WordMathCore"])
    ]
)
