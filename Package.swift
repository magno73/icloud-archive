// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iCloudArchive",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArchiveCore", targets: ["ArchiveCore"]),
        .executable(name: "iCloudArchive", targets: ["ArchiveApp"]),
        .executable(name: "icloud-archive", targets: ["ArchiveCLI"]),
    ],
    targets: [
        .target(name: "ArchiveCore"),
        .executableTarget(name: "ArchiveApp", dependencies: ["ArchiveCore"]),
        .executableTarget(name: "ArchiveCLI", dependencies: ["ArchiveCore"]),
        .testTarget(name: "ArchiveCoreTests", dependencies: ["ArchiveCore"]),
    ]
)
