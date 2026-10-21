// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "brightness",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "brightness", targets: ["brightness"]),
        .executable(name: "BrightBar", targets: ["BrightBar"]),
    ],
    targets: [
        .target(name: "BrightnessKit", path: "Sources/BrightnessKit"),
        .executableTarget(name: "brightness", dependencies: ["BrightnessKit"], path: "Sources/brightness"),
        .executableTarget(name: "BrightBar", dependencies: ["BrightnessKit"], path: "Sources/BrightBar"),
    ]
)
