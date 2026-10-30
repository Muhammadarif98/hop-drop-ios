// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "HopCore", platforms: [.iOS(.v15), .macOS(.v12)], products: [.library(name: "HopCore", targets: ["HopCore"])], targets: [.target(name: "HopCore"), .testTarget(name: "HopCoreTests", dependencies: ["HopCore"])])
