// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MoodleDownloader",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "MoodleDownloader", targets: ["MoodleDownloader"])
    ],
    targets: [
        .executableTarget(
            name: "MoodleDownloader",
            path: "Sources/MoodleDownloader"
        ),
        .testTarget(
            name: "MoodleDownloaderTests",
            dependencies: ["MoodleDownloader"]
        )
    ]
)
