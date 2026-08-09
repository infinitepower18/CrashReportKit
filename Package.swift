// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "CrashReportKit",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "CrashReportKit", targets: ["CrashReportKit"]),
        .library(name: "CrashReportKitUI", targets: ["CrashReportKitUI"]),
        .library(name: "CrashReportKitExtension", targets: ["CrashReportKitExtension"])
    ],
    targets: [
        .target(name: "CrashReportKit"),
        .target(
            name: "CrashReportKitUI",
            dependencies: ["CrashReportKit"]
        ),
        .target(
            name: "CrashReportKitExtension",
            dependencies: ["CrashReportKit"],
            linkerSettings: [.linkedFramework("CrashReportExtension")]
        )
    ]
)
