// swift-tools-version: 6.0
import Foundation
import PackageDescription

// App Intents: the compiler records constant values the metadata processor in make-app.sh reads.
// Only the app target, so the CLI's build cache isn't affected.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let appIntentsFlags: [SwiftSetting] = [
    .unsafeFlags([
        "-emit-const-values",
        "-Xfrontend", "-const-gather-protocols-file",
        "-Xfrontend", "\(root)/Support/appintents-protocols.json",
    ])
]

let package = Package(
    name: "Toolbox",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Toolbox", targets: ["Toolbox"]),
        .executable(name: "toolbox-cli", targets: ["toolbox-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .target(name: "ToolboxCore", dependencies: ["Yams"]),
        .executableTarget(
            name: "Toolbox", dependencies: ["ToolboxCore"], swiftSettings: appIntentsFlags,
            linkerSettings: [.linkedFramework("AVKit")]),
        .executableTarget(name: "toolbox-cli", dependencies: ["ToolboxCore"]),
    ]
)
