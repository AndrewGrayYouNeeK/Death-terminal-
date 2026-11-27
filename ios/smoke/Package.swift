// swift-tools-version:5.9
import PackageDescription
let package = Package(
  name: "check",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
    .package(url: "https://github.com/apple/swift-nio", from: "2.81.0"),
    .package(url: "https://github.com/Wellz26/swift-nio-ssh", "0.3.4"..<"0.4.0"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
  ],
  targets: [
    .target(name: "Combine"),
    .target(name: "Core", dependencies: ["Combine",
      .product(name: "Citadel", package: "Citadel"),
      .product(name: "NIOCore", package: "swift-nio"),
      .product(name: "NIOPosix", package: "swift-nio"),
      .product(name: "NIOSSH", package: "swift-nio-ssh"),
      .product(name: "Crypto", package: "swift-crypto"),
    ], swiftSettings: [.unsafeFlags(["-swift-version", "5", "-enable-testing"])]),
    .executableTarget(name: "smoke", dependencies: ["Core"], swiftSettings: [.unsafeFlags(["-swift-version", "5", "-enable-testing"])]),
  ])
