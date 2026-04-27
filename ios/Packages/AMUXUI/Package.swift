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
        .package(path: "../AMUXSharedUI"),
    ],
    targets: [
        .target(
            name: "AMUXUI",
            dependencies: [
                "AMUXCore",
                "AMUXSharedUI",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AMUXUIPackageTests",
            dependencies: ["AMUXUI"]
        ),
    ]
)
