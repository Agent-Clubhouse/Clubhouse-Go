// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Framebriar",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Framebriar", targets: ["Framebriar"]),
        .library(name: "FramebriarUI", targets: ["FramebriarUI"])
    ],
    targets: [
        .target(name: "Framebriar"),
        .target(name: "FramebriarUI", dependencies: ["Framebriar"]),
        .testTarget(name: "FramebriarTests", dependencies: ["Framebriar"], resources: [.copy("Fixtures")])
    ]
)
