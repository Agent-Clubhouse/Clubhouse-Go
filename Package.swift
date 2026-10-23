// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClubhouseTransport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ClubhouseTransport", targets: ["ClubhouseTransport"])],
    targets: [
        .target(name: "ClubhouseTransport", path: "Annex/Annex/Transport"),
        .target(name: "CompanionDomain", dependencies: ["ClubhouseTransport"], path: "Annex/Annex/Companion", sources: ["Domain", "Adapters"]),
        .testTarget(name: "CompanionDomainTests", dependencies: ["CompanionDomain", "ClubhouseTransport"], path: "Tests/CompanionDomainTests"),
        .testTarget(name: "ClubhouseTransportTests", dependencies: ["ClubhouseTransport"], path: "Tests/ClubhouseTransportTests", resources: [.copy("Fixtures")])
    ]
)
