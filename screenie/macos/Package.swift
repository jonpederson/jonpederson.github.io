// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Screenie",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Screenie",
            path: "Sources/Screenie",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
