// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TermKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TermCore", targets: ["TermCore"]),
        .library(name: "TermSSH", targets: ["TermSSH"]),
    ],
    dependencies: [
        // Pinned: 0.12.x moved its swift-nio-ssh dependency to a third-party fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", exact: "0.11.1"),
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.50.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "TermCore"),
        .target(
            name: "TermSSH",
            dependencies: [
                "TermCore",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(name: "TermCoreTests", dependencies: ["TermCore"]),
        .testTarget(name: "TermSSHTests", dependencies: ["TermSSH"]),
    ],
    swiftLanguageVersions: [.v5]
)
