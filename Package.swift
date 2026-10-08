// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MailMind",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MailMind", targets: ["MailMind"]),
    ],
    targets: [
        .executableTarget(
            name: "MailMind",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "MailMindTests",
            dependencies: ["MailMind"]
        ),
    ]
)
