// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "wpr",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    .package(url: "https://github.com/LebJe/TOMLKit", from: "0.6.0"),
  ],
  targets: [
    .executableTarget(
      name: "wpr",
      dependencies: [
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "TOMLKit", package: "TOMLKit"),
      ],
      path: "Sources/wpr"
    ),
  ]
)
