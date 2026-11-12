// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PeerMesh",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PeerMesh",
            targets: ["PeerMesh"]
        ),
    ],
    targets: [
        .target(name: "PeerMesh"),
        .testTarget(
            name: "PeerMeshTests",
            dependencies: ["PeerMesh"]
        ),
    ]
)
