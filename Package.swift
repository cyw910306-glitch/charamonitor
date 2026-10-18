// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DogMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DogMonitor",
            path: "Sources/DogMonitor",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Security"),
            ]
        ),
        .testTarget(name: "DogMonitorTests", dependencies: ["DogMonitor"], path: "Tests/DogMonitorTests"),
    ]
)
