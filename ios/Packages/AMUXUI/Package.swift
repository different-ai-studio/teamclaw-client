// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AMUXUI",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "AMUXUI", targets: ["AMUXUI"]),
    ],
    dependencies: [
        .package(path: "../AMUXCore"),
        .package(url: "https://github.com/apple/swift-markdown.git", from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "AMUXUI",
            dependencies: [
                "AMUXCore",
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
    ]
)
