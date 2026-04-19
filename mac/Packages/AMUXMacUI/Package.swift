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
        .package(path: "../../../ios/Packages/AMUXSharedUI"),
    ],
    targets: [
        .target(
            name: "AMUXMacUI",
            dependencies: [
                .product(name: "AMUXCore", package: "AMUXCore"),
                .product(name: "AMUXSharedUI", package: "AMUXSharedUI"),
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
