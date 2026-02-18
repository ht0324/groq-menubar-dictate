// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "groq-menubar-dictate",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(
            name: "groq-menubar-dictate",
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
