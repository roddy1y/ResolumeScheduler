// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ResolumeScheduler",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "Clibltc",
            path: "Vendor/libltc",
            sources: ["src"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("src"),
            ]
        ),
        .executableTarget(
            name: "ResolumeScheduler",
            dependencies: ["Clibltc"],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
            ]
        ),
    ]
)
