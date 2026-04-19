// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AMUXSharedUI",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "AMUXSharedUI", targets: ["AMUXSharedUI"]),
    ],
    dependencies: [
        .package(path: "../AMUXCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.7.3"),
    ],
    targets: [
        .target(
            name: "AMUXSharedUI",
            dependencies: [
                "AMUXCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
