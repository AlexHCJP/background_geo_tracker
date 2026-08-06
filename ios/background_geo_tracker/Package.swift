// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "background_geo_tracker",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "background-geo-tracker", targets: ["background_geo_tracker"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "background_geo_tracker",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Required, not optional: this plugin collects precise location
                // and reads UserDefaults, a required-reason API. Apple rejects
                // submissions where an SDK touching those ships no manifest.
                .process("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
