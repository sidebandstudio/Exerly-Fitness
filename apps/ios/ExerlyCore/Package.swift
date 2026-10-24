// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ExerlyCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "ExerlyCore", targets: ["ExerlyCore"]),
    ],
    targets: [
        .target(
            name: "ExerlyCore",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "ExerlyCoreTests",
            dependencies: ["ExerlyCore"],
            // Synthetic codes for the scanner benchmark; see BarcodeBenchmarkTests.
            resources: [.copy("BarcodeFixtures")]
        ),
    ]
)
