// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessManager",
    platforms: [.macOS("14.4")],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
        .executable(name: "HarnessManager", targets: ["HarnessManager"]),
        .executable(name: "harness-manager-check", targets: ["HarnessCheck"])
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", exact: "2.1.0"),
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .target(name: "HarnessCore", dependencies: [
            .product(name: "TOML", package: "swift-toml"),
            .product(name: "Yams", package: "Yams")
        ]),
        .executableTarget(name: "HarnessManager", dependencies: ["HarnessCore"]),
        .executableTarget(name: "HarnessCheck", dependencies: ["HarnessCore"]),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"]),
        .testTarget(name: "HarnessUITests", dependencies: ["HarnessManager", "HarnessCore"])
    ]
)
