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
    .target(
      name: "ContactsResolver"
    ),
    .target(
      name: "MessagesStore",
      linkerSettings: [
        .linkedLibrary("sqlite3")
      ]
    ),
    .executableTarget(
      name: "imsgd",
      dependencies: [
        "ContactsResolver",
        "ImsgProtocol",
        "MessagesStore",
      ]
    ),
    .testTarget(
      name: "ImsgProtocolTests",
      dependencies: ["ImsgProtocol"]
    ),
    .testTarget(
      name: "MessagesStoreTests",
      dependencies: ["MessagesStore"]
    ),
  ]
)
