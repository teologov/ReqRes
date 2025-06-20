// swift-tools-version:5.8
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "AppServices",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Utils",
            targets: ["Utils"]
        )
    ],
    dependencies: [
        .package(name: "Sentry", url: "https://github.com/getsentry/sentry-cocoa", from: "8.41.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.7.0"),
    ],
    targets: [
        .target(
            name: "Utils",
            dependencies: [
                "Sentry",
                "Sparkle"
            ]
        ),
    ],
)
