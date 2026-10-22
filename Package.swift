// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Comet",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Comet", targets: ["Runner"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0")
    ],
    targets: [
        .target(name: "RunnerCore"),
        .executableTarget(name: "Runner", dependencies: ["RunnerCore", .product(name: "Sparkle", package: "Sparkle"),
                          .product(name: "MCP", package: "swift-sdk"),
                          .product(name: "NIOCore", package: "swift-nio"),
                          .product(name: "NIOPosix", package: "swift-nio"),
                          .product(name: "NIOHTTP1", package: "swift-nio")],
                          resources: [.process("Resources")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "RunnerCoreTests", dependencies: ["RunnerCore", "Runner"])
    ]
)
