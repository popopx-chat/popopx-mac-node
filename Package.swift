// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PopopxMacNode",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "PopopxMacNode",
            targets: ["PopopxMacNode"]
        ),
        .executable(
            name: "PopopxMacNodeApp",
            targets: ["PopopxMacNodeApp"]
        )
    ],
    targets: [
        .target(
            name: "PopopxMacNode",
            path: "Sources/PopopxMacNode",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("CoreImage"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("EventKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .executableTarget(
            name: "PopopxMacNodeApp",
            dependencies: ["PopopxMacNode"],
            path: "Sources/PopopxMacNodeApp",
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("EventKit"),
                .linkedFramework("UserNotifications")
            ]
        ),
        .testTarget(
            name: "PopopxMacNodeTests",
            dependencies: ["PopopxMacNode"],
            path: "Tests/PopopxMacNodeTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
