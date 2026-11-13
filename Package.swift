// swift-tools-version: 6.0
import PackageDescription

// The product name lives in Sources/AerialKit/Brand.swift. The CLI product name
// below ("lockloop") is the only other place in code that spells it.
let package = Package(
    name: "Lockloop",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lockloop", targets: ["AerialCLI"]),
        .executable(name: "AerialApp", targets: ["AerialApp"]),
        .library(name: "AerialKit", targets: ["AerialKit"]),
    ],
    targets: [
        .target(
            name: "AerialKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AerialCLI",
            dependencies: ["AerialKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AerialApp",
            dependencies: ["AerialKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AerialKitTests",
            dependencies: ["AerialKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
