// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AMUXUI",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "AMUXUI", targets: ["AMUXUI"]),
    ],
    dependencies: [
        .package(path: "../AMUXCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.3"),
    ],
    targets: [
        .target(
            name: "AMUXUI",
            dependencies: [
                "AMUXCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
