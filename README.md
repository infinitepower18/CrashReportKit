[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Finfinitepower18%2FCrashReportKit%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/infinitepower18/CrashReportKit)
![GitHub](https://img.shields.io/github/license/infinitepower18/CrashReportKit)

# CrashReportKit

CrashReportKit is a Swift package for capturing, storing, viewing, and sharing crash reports produced by Apple's [CrashReportExtension](https://developer.apple.com/documentation/CrashReportExtension) framework.

The package generates human-readable JSON reports containing stack traces, symbols available on the device, ARM64 register state, exception information, process metadata, and relevant binary images. Unsymbolicated frames retain the addresses and binary-image metadata needed for offline symbolication with a matching dSYM. It also provides a pure SwiftUI interface for inspecting and sharing reports.

> [!NOTE]
> Apps containing CrashReportExtension cannot currently be uploaded to App Store Connect. (FB24235202)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/F1F1K06VY)

<img height="800" alt="Screenshot" src="https://github.com/user-attachments/assets/1bb0c38e-1bc7-40bd-a032-023282403e62" />

## Requirements

- iOS 27 or later for crash reporting and the viewer
- Xcode 27 or later
- Swift 6
- An app group shared by the app and its crash reporter extension
- A Crash Report Extension target

`CrashReportExtension` currently only supports iOS.

## Package products

CrashReportKit provides three focused library products:

- `CrashReportKit` contains only the underlying configuration, storage, and ZIP creation APIs.
- `CrashReportKitUI` contains the SwiftUI viewer and depends on `CrashReportKit`.
- `CrashReportKitExtension` contains the low-level crash processing, depends on `CrashReportKit`, and links Apple's `CrashReportExtension` framework.

The app target should link `CrashReportKitUI`. The Crash Report Extension target should link `CrashReportKitExtension`. Link `CrashReportKit` directly when only the underlying APIs are needed.

## Installation

Add this package to the Xcode project and select the appropriate product for each target:

| Target | Package product |
| --- | --- |
| Main app | `CrashReportKitUI` |
| Crash Report Extension | `CrashReportKitExtension` |

Both targets must include the same app-group entitlement.

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

Keep the extension entry point in the extension target and delegate processing to the package:

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

## SwiftUI viewer

Present `CrashReportsView` inside a `NavigationStack`:

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

CrashReportKit does not upload or transmit reports automatically. Reports remain in the shared app-group container until the user explicitly shares them or they are removed by retention.

## Platform notes

Crash capture relies on low-level Mach APIs and currently supports ARM64 stack inspection. The SwiftUI viewer and storage APIs are isolated from the crash-processing implementation through separate package products.

## License

Available under the MIT license.
