import Foundation

/// Configuration shared by the crash reporter extension and the report viewer.
///
/// Use the same configuration values in both targets. In particular, the app and
/// its crash reporter extension must have access to `appGroupIdentifier` so they
/// can read and write the same report directory.
public struct CrashReportConfiguration: Sendable {
    /// The application group used to exchange reports between the extension and app.
    public let appGroupIdentifier: String

    /// The user-facing app name used in filenames and viewer copy.
    public let appName: String

    /// The maximum number of reports retained in Application Support.
    public let maximumReportCount: Int

    /// Creates a crash-report configuration.
    ///
    /// - Parameters:
    ///   - appGroupIdentifier: An application-group identifier available to both targets.
    ///   - appName: The name shown in report filenames and viewer text.
    ///   - maximumReportCount: The number of newest reports to retain. Values below one become one.
    public init(
        appGroupIdentifier: String,
        appName: String,
        maximumReportCount: Int = 10
    ) {
        self.appGroupIdentifier = appGroupIdentifier
        self.appName = appName
        self.maximumReportCount = max(1, maximumReportCount)
    }
}

/// A crash-report file that can be displayed or shared.
public struct CrashReportFile: Identifiable, Sendable {
    /// The file's location in the shared app-group container.
    public let url: URL

    /// The file's last modification date.
    public let date: Date

    /// The report's UTF-8 JSON text.
    public let contents: String

    /// The file URL used as the report's stable identity.
    public var id: URL { url }

    /// The filename without its extension.
    public var displayName: String { url.deletingPathExtension().lastPathComponent }
}

/// Reads, archives, and prunes crash reports in the shared app-group container.
public enum CrashReportStore {
    /// Returns the Application Support directory used for crash reports.
    ///
    /// The directory is created when necessary and excluded from device backups.
    ///
    /// - Parameter configuration: The app-group and retention configuration.
    /// - Returns: The `Library/Application Support/Crash Reports` directory URL.
    public static func directoryURL(configuration: CrashReportConfiguration) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: configuration.appGroupIdentifier
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        var directory = container.appendingPathComponent(
            "Library/Application Support/Crash Reports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directory.setResourceValues(resourceValues)
        return directory
    }

    /// Loads all readable UTF-8 crash-report files with a `.json` extension, newest first.
    ///
    /// Files that are not regular JSON files or cannot be decoded as UTF-8 are ignored.
    ///
    /// - Parameter configuration: The configuration identifying the shared container.
    /// - Returns: The available crash-report files sorted by modification date.
    public static func reports(configuration: CrashReportConfiguration) throws -> [CrashReportFile] {
        let directory = try directoryURL(configuration: configuration)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys)
        )
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let data = try? Data(contentsOf: url),
                  let contents = String(data: data, encoding: .utf8) else { return nil }
            return CrashReportFile(
                url: url,
                date: values.contentModificationDate ?? .distantPast,
                contents: contents
            )
        }.sorted { $0.date > $1.date }
    }

    /// Removes old reports beyond the configured retention limit.
    ///
    /// - Parameter configuration: The configuration containing the maximum report count.
    public static func prune(configuration: CrashReportConfiguration) throws {
        let reports = try reports(configuration: configuration)
        for report in reports.dropFirst(configuration.maximumReportCount) {
            try? FileManager.default.removeItem(at: report.url)
        }
    }

    /// Creates an uncompressed ZIP archive containing the supplied reports.
    ///
    /// The archive is written to the process's temporary directory and may replace
    /// an earlier archive created for the same app.
    ///
    /// - Parameters:
    ///   - reports: The reports to include in the archive.
    ///   - configuration: The configuration used to name the archive.
    /// - Returns: The URL of the generated ZIP file.
    public static func zip(
        _ reports: [CrashReportFile],
        configuration: CrashReportConfiguration
    ) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(configuration.appName) Crash Reports.zip")
        let archive = try ZIPArchive(files: reports.map {
            ($0.url.lastPathComponent, try Data(contentsOf: $0.url))
        })
        try archive.data.write(to: destination, options: .atomic)
        return destination
    }
}

private struct ZIPArchive {
    let data: Data

    init(files: [(name: String, data: Data)]) throws {
        var output = Data()
        var centralDirectory = Data()
        var offset: UInt32 = 0

        for file in files {
            let name = Data(file.name.utf8)
            let crc = Self.crc32(file.data)
            let size = UInt32(file.data.count)
            let nameLength = UInt16(name.count)

            output.appendLE(UInt32(0x04034b50)); output.appendLE(UInt16(20)); output.appendLE(UInt16(0))
            output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
            output.appendLE(crc); output.appendLE(size); output.appendLE(size); output.appendLE(nameLength)
            output.appendLE(UInt16(0)); output.append(name); output.append(file.data)

            centralDirectory.appendLE(UInt32(0x02014b50)); centralDirectory.appendLE(UInt16(20)); centralDirectory.appendLE(UInt16(20))
            centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(crc); centralDirectory.appendLE(size); centralDirectory.appendLE(size); centralDirectory.appendLE(nameLength)
            centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0)); centralDirectory.appendLE(UInt16(0))
            centralDirectory.appendLE(UInt32(0)); centralDirectory.appendLE(offset); centralDirectory.append(name)
            offset = UInt32(output.count)
        }

        output.append(centralDirectory)
        output.appendLE(UInt32(0x06054b50)); output.appendLE(UInt16(0)); output.appendLE(UInt16(0))
        output.appendLE(UInt16(files.count)); output.appendLE(UInt16(files.count))
        output.appendLE(UInt32(centralDirectory.count)); output.appendLE(offset); output.appendLE(UInt16(0))
        data = output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        data.reduce(UInt32.max) { current, byte in
            (0..<8).reduce(current ^ UInt32(byte)) { crc, _ in
                (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0)
            }
        } ^ UInt32.max
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
