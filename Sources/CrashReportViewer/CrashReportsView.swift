import SwiftUI

@available(iOS 27.0, *)
/// A SwiftUI interface for inspecting and sharing saved crash reports.
///
/// Embed this view in a `NavigationStack`. Users can open individual JSON reports,
/// share a single report, or bundle every report into a ZIP archive. Attachments
/// are presented using the system share sheet.
public struct CrashReportsView: View {
    private let configuration: CrashReportConfiguration
    @State private var reports: [CrashReportFile] = []
    @State private var reportsArchive: URL?

    /// Creates a crash-report viewer.
    ///
    /// - Parameter configuration: The shared storage and feedback-email configuration.
    public init(configuration: CrashReportConfiguration) {
        self.configuration = configuration
    }

    /// The crash-report list interface.
    public var body: some View {
        List {
            Section {
                Text("If you're experiencing an issue that's impacting your experience, please share these crash reports. These reports will be used to help make \(configuration.appName) better.")
                    .foregroundStyle(.secondary)
            }
            Section {
                if reports.isEmpty {
                    ContentUnavailableView("No Crash Reports", systemImage: "checkmark.circle")
                } else {
                    ForEach(reports) { report in
                        NavigationLink {
                            CrashReportDetailView(report: report)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(report.displayName)
                                Text(report.date, format: .dateTime.year().month().day().hour().minute().second())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Crash Reports")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let reportsArchive {
                    ShareLink(item: reportsArchive) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button("Share", systemImage: "square.and.arrow.up") {}
                        .disabled(true)
                }
            }
        }
        .task { reload() }
    }

    private func reload() {
        do {
            reports = try CrashReportStore.reports(configuration: configuration)
            reportsArchive = reports.isEmpty
                ? nil
                : try CrashReportStore.zip(reports, configuration: configuration)
        } catch {
            #if DEBUG
            print(error.localizedDescription)
            #endif
        }
    }
}

@available(iOS 27.0, *)
private struct CrashReportDetailView: View {
    let report: CrashReportFile

    var body: some View {
        ScrollView {
            Text(report.contents)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
            .navigationTitle(report.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: report.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
    }
}
