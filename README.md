[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Finfinitepower18%2FCrashReportKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/infinitepower18/CrashReportKit)
![GitHub](https://img.shields.io/github/license/infinitepower18/CrashReportKit)

# CrashReportKit

CrashReportKit is a Swift package for creating and managing crash reports with Apple's [CrashReportExtension](https://developer.apple.com/documentation/CrashReportExtension) framework.

When an app crashes, its Crash Report Extension uses CrashReportKit to inspect the crashed process and save a human-readable JSON report in a shared app-group container. Because this happens in the extension, the report can be persisted and acted on without waiting for the main app to launch again.

Reports include thread backtraces, symbols available on the device, ARM64 register state, exception information, process metadata, and relevant binary images. Unsymbolicated frames retain their addresses and binary-image metadata for offline symbolication with a matching dSYM.

Use the storage APIs to build a custom workflow, or add the optional SwiftUI product to let users inspect and share reports from the app. Crash reports can also be symbolicated locally with the [CrashReportKit Inspector](https://github.com/infinitepower18/CrashReportKit-Inspector) macOS app.

> [!NOTE]
> Apps containing CrashReportExtension cannot currently be uploaded to App Store Connect. (FB24235202)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/F1F1K06VY)

## Why CrashReportKit?

CrashReportKit is intended for apps that want control over crash processing without embedding a third-party crash reporter or depending on a hosted crash-monitoring service.

- Crash handling runs out-of-process in Apple's Crash Report Extension.
- Reports are saved locally and are not uploaded automatically.
- The extension can process stored reports immediately, even if the main app is not reopened.
- Apps control how reports are retained, presented, shared, or transmitted.
- The core APIs, optional SwiftUI viewer, and extension integration are separate products.

CrashReportKit is not an analytics dashboard or a replacement for every hosted crash service. It provides the local capture, storage, and presentation building blocks for developers who want to own that workflow.

## Requirements

- iOS 27 or later for crash reporting and the optional viewer
- Xcode 27 or later
- Swift 6
- An app group shared by the app and its crash reporter extension
- A Crash Report Extension target

`CrashReportExtension` currently only supports iOS.

## Package products

CrashReportKit provides three focused library products:

- `CrashReportKit` provides configuration, report storage, retention, and ZIP creation for custom integrations.
- `CrashReportKitUI` provides an optional SwiftUI report viewer and depends on `CrashReportKit`.
- `CrashReportKitExtension` creates reports from a crashed process, depends on `CrashReportKit`, and links Apple's `CrashReportExtension` framework.

Choose only the products needed by each target. An app can link `CrashReportKit` directly and provide its own interface, or link `CrashReportKitUI` to use the included viewer. The Crash Report Extension target should link `CrashReportKitExtension`.

## Installation

Add this package to the Xcode project and select the appropriate product for each target:

| Use case | Package product |
| --- | --- |
| Configuration, storage, and custom handling | `CrashReportKit` |
| Included SwiftUI viewer | `CrashReportKitUI` |
| Crash Report Extension target | `CrashReportKitExtension` |

The app and Crash Report Extension targets must include the same app-group entitlement.

```xml
<key>com.apple.security.application-groups</key>
<array>
    <string>group.com.example.MyApp</string>
</array>
```

## Configuration

Create matching configurations in the app and extension targets:

```swift
import CrashReportKit

let crashReportConfiguration = CrashReportConfiguration(
    appGroupIdentifier: "group.com.example.MyApp",
    appName: "MyApp",
    maximumReportCount: 10
)
```

`maximumReportCount` is clamped to at least one. After saving a new report, the package removes the oldest reports beyond this limit.

## Crash reporter extension

Keep the extension entry point in the extension target and delegate report creation to CrashReportKit:

```swift
import CrashReportExtension
import CrashReportKit
import CrashReportKitExtension
import ExtensionFoundation
import os

@main
struct MyCrashReporter: CrashReporterExtension {
    private let configuration = CrashReportConfiguration(
        appGroupIdentifier: "group.com.example.MyApp",
        appName: "MyApp",
        maximumReportCount: 10
    )

    func processCrashReport(process: CrashedProcess) {
        CrashReportProcessor.process(
            process,
            configuration: configuration,
            logger: Logger(
                subsystem: "com.example.MyApp.CrashReporter",
                category: "Crash Reports"
            )
        )
    }
}
```

The extension must use the same app-group identifier as the main app.

`CrashReportProcessor.process` completes its storage work synchronously. Extension code can then read the shared store and perform additional handling without waiting for the main app to open:

```swift
CrashReportProcessor.process(process, configuration: crashReportConfiguration)

let reports = try CrashReportStore.reports(configuration: crashReportConfiguration)
// Apply your own export, redaction, or transmission policy.
```

Keep additional extension work within the system's execution, memory, entitlement, and networking constraints.

## Working with stored reports

Both the main app and the Crash Report Extension can access reports using `CrashReportStore`. The UI product is not required:

```swift
import CrashReportKit

let reports = try CrashReportStore.reports(configuration: crashReportConfiguration)
let archive = try CrashReportStore.zip(reports, configuration: crashReportConfiguration)
```

## Optional SwiftUI viewer

To use the included interface, add `CrashReportKitUI` to the app target and present `CrashReportsView` inside a `NavigationStack`:

```swift
import CrashReportKit
import CrashReportKitUI
import SwiftUI

struct DiagnosticsView: View {
    private let configuration = CrashReportConfiguration(
        appGroupIdentifier: "group.com.example.MyApp",
        appName: "MyApp",
        maximumReportCount: 10
    )

    var body: some View {
        NavigationStack {
            CrashReportsView(configuration: configuration)
        }
    }
}
```

The viewer supports:

- A newest-first list of saved reports
- Selectable, monospaced JSON report details
- Sharing an individual JSON report
- Sharing all reports as a ZIP archive

Sharing uses SwiftUI's system `ShareLink`. The receiving app determines how the attachment is handled.

## Storage

Reports are stored in the shared app-group container at:

```text
Library/Application Support/Crash Reports
```

The directory is excluded from device backups. Reports persist across app launches and remain available until they are pruned, deleted, or the app is uninstalled.

ZIP archives created for sharing are written to the system temporary directory.

## Report contents

Each JSON report includes:

- Capture date and report format version
- App name, bundle identifier, version, and build
- Operating-system and device information
- Mach exception type and codes
- The likely faulting thread
- ARM64 register state
- Unwound stack frames
- Symbol names, offsets, inline status, and source locations when available
- Addresses and binary-image metadata for unsymbolicated frames
- Relevant binary-image UUIDs and load addresses

Symbol availability depends on the crashed binary. Debug builds may provide readable app symbols directly, while release builds commonly contain unsymbolicated addresses. Release-build frames can be symbolicated offline using the matching dSYM. Source filenames, line numbers, exception messages, and other diagnostic details may not always be available.

## Privacy

CrashReportKit does not upload or transmit reports automatically. Reports stay in the shared app-group container until application or extension code shares, transmits, or removes them, or retention pruning removes them.

## Platform notes

Crash capture relies on low-level Mach APIs and currently supports ARM64 stack inspection. The SwiftUI viewer and storage APIs are isolated from the crash-processing implementation through separate package products.

## License

Available under the MIT license.
