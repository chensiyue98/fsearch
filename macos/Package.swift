// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FSearchGUI",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FSearchGUI", targets: ["FSearchGUI"])],
    targets: [
        .executableTarget(name: "FSearchGUI"),
        .testTarget(name: "FSearchGUITests", dependencies: ["FSearchGUI"])
    ]
)
