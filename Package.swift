// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "VoiceKey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "VoiceKey", targets: ["VoiceKey"])
    ],
    targets: [
        .target(
            name: "VoiceKeyObjCShield"
        ),
        .executableTarget(
            name: "VoiceKey",
            dependencies: ["VoiceKeyObjCShield"],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("Security"),
                .linkedFramework("WebKit")
            ]
        ),
        .testTarget(
            name: "VoiceKeyTests",
            dependencies: ["VoiceKey"],
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        )
    ]
)
