// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Jeep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Jeep", targets: ["Jeep"])
    ],
    targets: [
        .executableTarget(
            name: "Jeep",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "JeepTests",
            dependencies: ["Jeep"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
