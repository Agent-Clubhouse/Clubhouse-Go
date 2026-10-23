// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClubhouseTransport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ClubhouseTransport", targets: ["ClubhouseTransport"])],
    targets: [
        .target(name: "ClubhouseTransport", path: "Annex/Annex/Transport"),
        .testTarget(name: "ClubhouseTransportTests", dependencies: ["ClubhouseTransport"], path: "Tests/ClubhouseTransportTests")
    ]
)
