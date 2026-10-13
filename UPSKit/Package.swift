// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UPSKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UPSKit", targets: ["UPSKit"]),
        .executable(name: "upsctl", targets: ["upsctl"]),
    ],
    targets: [
        .target(
            name: "UPSKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "upsctl", dependencies: ["UPSKit"]),
        .testTarget(name: "UPSKitTests", dependencies: ["UPSKit"]),
    ]
)
