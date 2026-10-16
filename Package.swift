// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Toolbox",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Toolbox", targets: ["Toolbox"]),
        .executable(name: "toolbox-cli", targets: ["toolbox-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3"),
    ],
    targets: [
        .target(name: "ToolboxCore", dependencies: ["Yams"], swiftSettings: swift5),
        .executableTarget(name: "Toolbox", dependencies: ["ToolboxCore"], swiftSettings: swift5,
                          linkerSettings: [.linkedFramework("AVKit")]),
        .executableTarget(name: "toolbox-cli", dependencies: ["ToolboxCore"], swiftSettings: swift5),
    ]
)
