// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gitthat",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "gitthat", targets: ["gitthat"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "gitthat",
            dependencies: [
                "GitThatKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .target(
            name: "GitThatKit",
            dependencies: [
                .product(name: "TOMLKit", package: "TOMLKit")
            ]
        ),
        .testTarget(
            name: "GitThatKitTests",
            dependencies: ["GitThatKit"]
        ),
    ]
)
