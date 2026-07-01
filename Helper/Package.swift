// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "FriendShellHelper",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "Helper", targets: ["Helper"])
  ],
  targets: [
    .executableTarget(name: "Helper")
  ]
)
