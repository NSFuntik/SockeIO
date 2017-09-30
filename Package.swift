// swift-tools-version:4.0

import PackageDescription

let package = Package(
    name: "SocketIO",
    products: [
        .library(name: "SocketIO", targets: ["SocketIO"])
    ],
    dependencies: [
        .package(url: "https://github.com/nuclearace/Starscream", .upToNextMajor(from: "9.0.0")),
    ],
    targets: [
        .target(name: "SocketIO", dependencies: ["StarscreamSocketIO"], exclude: ["Sources/Starscream"])
    ]
)
