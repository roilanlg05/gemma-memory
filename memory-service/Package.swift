// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MemoryService",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "memory-service", targets: ["MemoryService"]),
        .library(name: "MemoryCore", targets: ["MemoryCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.4.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.23.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "MemoryCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]),
        .executableTarget(
            name: "MemoryService",
            dependencies: [
                "MemoryCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
            ]),
        .testTarget(
            name: "MemoryCoreTests",
            dependencies: ["MemoryCore"]),
        .testTarget(
            name: "MemoryServiceTests",
            dependencies: [
                "MemoryService",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ]),
    ]
)
