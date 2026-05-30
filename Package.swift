// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ngate2VPN",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Ngate2VPN", targets: ["Ngate2VPNApp"])
    ],
    targets: [
        .executableTarget(
            name: "Ngate2VPNApp",
            path: "Sources/Ngate2VPNApp"
        ),
        .testTarget(
            name: "Ngate2VPNAppTests",
            dependencies: ["Ngate2VPNApp"],
            path: "Tests/Ngate2VPNAppTests"
        )
    ]
)
