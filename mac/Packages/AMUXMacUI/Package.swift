// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AMUXMacUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AMUXMacUI", targets: ["AMUXMacUI"]),
    ],
    dependencies: [
        .package(path: "../../../ios/Packages/AMUXCore"),
    ],
    targets: [
        .target(
            name: "AMUXMacUI",
            dependencies: [
                .product(name: "AMUXCore", package: "AMUXCore"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AMUXMacUITests",
            dependencies: ["AMUXMacUI"],
            path: "Tests/AMUXMacUITests"
        ),
    ]
)
