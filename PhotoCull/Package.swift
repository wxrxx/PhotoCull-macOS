// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "PhotoCull",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "PhotoCull", targets: ["PhotoCull"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "PhotoCull",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "PhotoCull",
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
