// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AMUXCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AMUXCore", targets: ["AMUXCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/emqx/CocoaMQTT.git", from: "2.2.3"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.1"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.3"),
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.43.1"),
    ],
    targets: [
        .target(
            name: "AMUXCore",
            dependencies: [
                .product(name: "CocoaMQTT", package: "CocoaMQTT"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "Markdown", package: "swift-markdown"),
                .product(name: "Supabase", package: "supabase-swift"),
            ],
            // Pinned to Swift 5 mode: ConnectionMonitor & MQTTService are not yet Sendable-clean for Swift 6 strict concurrency. Migrate after audit.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AMUXCoreTests",
            dependencies: ["AMUXCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
