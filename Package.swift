// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "CrashReportViewer",
    platforms: [.iOS(.v27)],
    products: [
        .library(name: "CrashReportViewer", targets: ["CrashReportViewer"]),
        .library(name: "CrashReportViewerExtension", targets: ["CrashReportViewerExtension"])
    ],
    targets: [
        .target(name: "CrashReportViewer"),
        .target(
            name: "CrashReportViewerExtension",
            dependencies: ["CrashReportViewer"],
            linkerSettings: [.linkedFramework("CrashReportExtension")]
        )
    ]
)
