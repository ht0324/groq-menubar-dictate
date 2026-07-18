// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Bolt",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "Bolt",
            targets: ["GroqMenuBarDictate"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "GroqMenuBarDictate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .testTarget(
            name: "GroqMenuBarDictateTests",
            dependencies: ["GroqMenuBarDictate"]
        ),
    ]
)
