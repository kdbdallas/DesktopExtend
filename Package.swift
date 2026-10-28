// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DesktopExtend",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CVirtualDisplay"),
        .executableTarget(
            name: "DesktopExtend",
            dependencies: ["CVirtualDisplay"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
