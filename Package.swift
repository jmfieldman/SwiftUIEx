// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "SwiftUIEx",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "SwiftUIEx", targets: ["SwiftUIEx"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftUIEx",
            dependencies: [],
            path: "Sources/SwiftUIEx"
        ),
        .testTarget(
            name: "SwiftUIExTests",
            dependencies: ["SwiftUIEx"],
            path: "Tests/SwiftUIExTests"
        ),
    ]
)
