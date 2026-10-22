// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DogMonitor",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [
        // The characters' art, packs, voice and setup file checks, shared by the Mac app and the iPhone app (ios/).
        .library(name: "CharaCore", targets: ["CharaCore"]),
    ],
    targets: [
        .target(name: "CharaCore", path: "Sources/CharaCore"),
        .executableTarget(
            name: "DogMonitor",
            dependencies: ["CharaCore"],
            path: "Sources/DogMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "DogMonitorTests", dependencies: ["DogMonitor", "CharaCore"], path: "Tests/DogMonitorTests"),
    ]
)
