// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "imsgkit",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "imsgd", targets: ["imsgd"])
  ],
  targets: [
    .target(
      name: "ImsgProtocol"
    ),
    .executableTarget(
      name: "imsgd",
      dependencies: [
        "ImsgProtocol"
      ]
    ),
    .testTarget(
      name: "ImsgProtocolTests",
      dependencies: ["ImsgProtocol"]
    ),
  ]
)
