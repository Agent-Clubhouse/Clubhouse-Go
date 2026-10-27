// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ClubhouseTransport",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ClubhouseTransport", targets: ["ClubhouseTransport"])],
    dependencies: [
        .package(url: "https://github.com/open-telemetry/opentelemetry-swift-core.git", exact: "2.6.0"),
        // cmark-gfm block parsing (tables, task lists) for agent replies; see CompanionMarkdown.swift.
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.9.0")
    ],
    targets: [
        .target(name: "ClubhouseTransport", dependencies: [.product(name: "OpenTelemetryApi", package: "opentelemetry-swift-core"), .product(name: "OpenTelemetrySdk", package: "opentelemetry-swift-core")], path: "Annex/Annex/Transport"),
        .target(name: "CompanionDomain", dependencies: ["ClubhouseTransport", .product(name: "Markdown", package: "swift-markdown")], path: "Annex/Annex/Companion", exclude: ["Views"], sources: ["Domain", "Adapters"]),
        .testTarget(name: "CompanionDomainTests", dependencies: ["CompanionDomain", "ClubhouseTransport"], path: "Tests/CompanionDomainTests"),
        .testTarget(name: "ClubhouseTransportTests", dependencies: ["ClubhouseTransport"], path: "Tests/ClubhouseTransportTests", resources: [.copy("Fixtures")])
    ]
)
