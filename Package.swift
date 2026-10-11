// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "CutPlay",
    defaultLocalization: "zh-Hant",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CutPlayCore", targets: ["CutPlayCore"]),
        .library(name: "CutPlayMedia", targets: ["CutPlayMedia"]),
        .executable(name: "CutPlayApp", targets: ["CutPlayApp"]),
    ],
    targets: [
        .target(name: "CutPlayCore"),
        .target(name: "CutPlayMedia", dependencies: ["CutPlayCore"]),
        .executableTarget(name: "CutPlayApp", dependencies: ["CutPlayCore", "CutPlayMedia"]),
        .testTarget(name: "CutPlayCoreTests", dependencies: ["CutPlayCore"]),
        .testTarget(name: "CutPlayMediaTests", dependencies: ["CutPlayMedia"]),
    ]
)
