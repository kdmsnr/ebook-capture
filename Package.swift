// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ebook-capture",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ebook-capture", targets: ["ebook-capture"])
    ],
    targets: [
        .executableTarget(
            name: "ebook-capture",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)
