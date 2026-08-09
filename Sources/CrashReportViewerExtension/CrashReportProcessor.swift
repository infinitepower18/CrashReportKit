import CrashReportExtension
import CrashReportViewer
import Darwin.Mach
import Foundation
import os

@available(iOS 27.0, *)
/// Converts system crash information into persistent, human-readable JSON reports.
///
/// Call ``process(_:configuration:logger:)`` from the `processCrashReport(process:)`
/// method of a type conforming to `CrashReporterExtension`.
public enum CrashReportProcessor {
    /// Captures, symbolicates, saves, and prunes a crash report.
    ///
    /// Reports are stored atomically in the app group's
    /// `Library/Application Support/Crash Reports` directory. Processing errors are
    /// written to the supplied logger because a crash reporter extension has no UI.
    ///
    /// - Parameters:
    ///   - process: The crashed process supplied by `CrashReportExtension`.
    ///   - configuration: The shared storage and retention configuration.
    ///   - logger: The logger used when report generation or persistence fails.
    public static func process(
        _ process: CrashedProcess,
        configuration: CrashReportConfiguration,
        logger: Logger = Logger(subsystem: "CrashReportViewer", category: "Crash Reports")
    ) {
        do {
            let report = CrashReportBuilder(process: process, appName: configuration.appName).build()
            let directory = try CrashReportStore.directoryURL(configuration: configuration)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let timestamp = formatter.string(from: report.capturedAt)
                .replacingOccurrences(of: ":", with: "-")
            let destination = directory.appendingPathComponent(
                "\(configuration.appName)-\(timestamp)-\(report.id.uuidString).json"
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: destination, options: .atomic)
            try CrashReportStore.prune(configuration: configuration)
        } catch {
            logger.error("Unable to save crash report: \(error.localizedDescription, privacy: .public)")
        }
    }
}

@available(iOS 27.0, *)
private struct CrashReportBuilder {
    let process: CrashedProcess
    let appName: String

    func build() -> StoredCrashReport {
        let snapshots = ThreadInspector(task: process.corpsePort).snapshots()
        let allAddresses = snapshots.flatMap(\.addresses)
        let symbolicated = process.symbolicateAddresses(allAddresses)
        var symbolIndex = 0

        let provisionalThreads = snapshots.enumerated().map { index, snapshot in
            let frames = snapshot.addresses.map { address in
                defer { symbolIndex += 1 }
                return ReportFrame(
                    address: address,
                    image: image(containing: address),
                    symbols: symbolicated.indices.contains(symbolIndex) ? symbolicated[symbolIndex] : []
                )
            }
            return ReportThread(
                index: index,
                id: snapshot.id,
                crashed: false,
                registers: snapshot.registers,
                frames: frames
            )
        }
        let faultingIndex = snapshots.firstIndex(where: isLikelyCrashingThread)
            ?? provisionalThreads.max(by: { crashScore($0) < crashScore($1) })?.index
        let threads = provisionalThreads.map {
            ReportThread(
                index: $0.index,
                id: $0.id,
                crashed: $0.index == faultingIndex,
                registers: $0.registers,
                frames: $0.frames
            )
        }
        let usedPaths = Set(threads.flatMap(\.frames).compactMap(\.image?.path))
        let usefulImages = process.binaryImages.filter {
            usedPaths.contains($0.path) || $0.path.contains("/\(appName).app/")
        }

        return StoredCrashReport(
            id: UUID(),
            capturedAt: Date(),
            process: ProcessMetadata.current(fallbackName: appName),
            exception: ReportException(reason: process.reason),
            faultingThread: faultingIndex,
            threads: threads,
            binaryImages: usefulImages
        )
    }

    private func image(containing address: UInt64) -> ReportImageReference? {
        guard let image = process.binaryImages
            .filter({ $0.baseAddress <= address })
            .max(by: { $0.baseAddress < $1.baseAddress }) else { return nil }
        return ReportImageReference(
            name: URL(fileURLWithPath: image.path).lastPathComponent,
            path: image.path,
            uuid: image.uuid,
            offset: address - image.baseAddress
        )
    }

    private func isLikelyCrashingThread(_ snapshot: ThreadSnapshot) -> Bool {
        process.reason.codes.contains(snapshot.registers.pc)
            || process.reason.codes.contains(snapshot.registers.lr)
    }

    private func crashScore(_ thread: ReportThread) -> Int {
        let symbols = thread.frames.flatMap(\.symbols).map(\.symbol)
        let markers = ["assertionFailure", "fatalError", "preconditionFailure",
                       "swift_unexpectedError", "objc_exception_throw", "abort"]
        let hasMarker = symbols.contains { symbol in markers.contains { symbol.contains($0) } }
        let hasAppFrame = thread.frames.contains { $0.image?.path.contains("/\(appName).app/") == true }
        let waiting = ["mach_msg", "semaphore_wait", "__psynch", "kevent", "poll"]
        let topIsWaiting = symbols.first.map { symbol in waiting.contains { symbol.contains($0) } } ?? false
        return (hasMarker ? 100 : 0) + (hasAppFrame ? 20 : 0) + (topIsWaiting ? 0 : 5)
    }
}

@available(iOS 27.0, *)
private struct ThreadInspector {
    let task: mach_port_t

    func snapshots() -> [ThreadSnapshot] {
        var threadList: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(task, &threadList, &count) == KERN_SUCCESS,
              let threadList else { return [] }
        defer {
            let byteCount = vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), byteCount)
        }
        return (0..<Int(count)).compactMap { snapshot(thread: threadList[$0]) }
    }

    private func snapshot(thread: thread_t) -> ThreadSnapshot? {
        let stateWordCount = MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        var words = [natural_t](repeating: 0, count: stateWordCount)
        var wordCount = mach_msg_type_number_t(stateWordCount)
        let result = words.withUnsafeMutableBufferPointer { buffer in
            thread_get_state(thread, ARM_THREAD_STATE64, buffer.baseAddress, &wordCount)
        }
        guard result == KERN_SUCCESS else { return nil }

        let registers = ARM64Registers(
            x: (0..<29).map { uint64(words, at: $0 * 2) },
            fp: uint64(words, at: 58),
            lr: uint64(words, at: 60),
            sp: uint64(words, at: 62),
            pc: uint64(words, at: 64),
            cpsr: UInt32(words[66])
        )
        return ThreadSnapshot(
            id: identifier(for: thread),
            registers: registers,
            addresses: unwind(registers: registers)
        )
    }

    private func uint64(_ words: [natural_t], at index: Int) -> UInt64 {
        UInt64(words[index]) | (UInt64(words[index + 1]) << 32)
    }

    private func identifier(for thread: thread_t) -> UInt64? {
        var info = thread_identifier_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_identifier_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.thread_id : nil
    }

    private func unwind(registers: ARM64Registers) -> [UInt64] {
        var addresses = [registers.pc]
        if registers.lr != 0, registers.lr != registers.pc { addresses.append(registers.lr) }
        var framePointer = registers.fp
        for _ in 0..<64 {
            guard framePointer != 0,
                  framePointer.isMultiple(of: 8),
                  let frame: StackFrame = read(address: framePointer),
                  frame.returnAddress != 0,
                  frame.previousFrame > framePointer,
                  frame.previousFrame - framePointer < 1_048_576 else { break }
            addresses.append(frame.returnAddress)
            framePointer = frame.previousFrame
        }
        return addresses
    }

    private func read<T>(address: UInt64) -> T? {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        var bytesRead: vm_size_t = 0
        let result = vm_read_overwrite(
            task,
            vm_address_t(address),
            vm_size_t(MemoryLayout<T>.size),
            vm_address_t(UInt(bitPattern: pointer)),
            &bytesRead
        )
        return result == KERN_SUCCESS && bytesRead == MemoryLayout<T>.size ? pointer.pointee : nil
    }
}

private struct StackFrame { let previousFrame: UInt64; let returnAddress: UInt64 }
private struct ThreadSnapshot { let id: UInt64?; let registers: ARM64Registers; let addresses: [UInt64] }

@available(iOS 27.0, *)
private struct StoredCrashReport: Encodable {
    let formatVersion = 1
    let id: UUID
    let capturedAt: Date
    let process: ProcessMetadata
    let exception: ReportException
    let faultingThread: Int?
    let threads: [ReportThread]
    let binaryImages: [BinaryImageInfo]
}

private struct ProcessMetadata: Encodable {
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let build: String?
    let operatingSystem: String
    let deviceModel: String

    static func current(fallbackName: String) -> ProcessMetadata {
        let appBundle = hostAppBundle()
        return ProcessMetadata(
            name: appBundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? fallbackName,
            bundleIdentifier: appBundle?.bundleIdentifier,
            version: appBundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            build: appBundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: deviceModel()
        )
    }

    private static func hostAppBundle() -> Bundle? {
        var url = Bundle.main.bundleURL
        while url.pathExtension != "app", url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        return url.pathExtension == "app" ? Bundle(url: url) : nil
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}

@available(iOS 27.0, *)
private struct ReportException: Encodable {
    let type: String
    let rawValue: Int32
    let codes: [UInt64]
    let hexadecimalCodes: [String]

    init(reason: CrashReason) {
        rawValue = reason.exception
        codes = reason.codes
        hexadecimalCodes = reason.codes.map { String(format: "0x%016llx", $0) }
        type = switch reason.exception {
        case EXC_BAD_ACCESS: "EXC_BAD_ACCESS"
        case EXC_BAD_INSTRUCTION: "EXC_BAD_INSTRUCTION"
        case EXC_ARITHMETIC: "EXC_ARITHMETIC"
        case EXC_EMULATION: "EXC_EMULATION"
        case EXC_SOFTWARE: "EXC_SOFTWARE"
        case EXC_BREAKPOINT: "EXC_BREAKPOINT"
        case EXC_SYSCALL: "EXC_SYSCALL"
        case EXC_MACH_SYSCALL: "EXC_MACH_SYSCALL"
        case EXC_RPC_ALERT: "EXC_RPC_ALERT"
        case EXC_CRASH: "EXC_CRASH"
        case EXC_RESOURCE: "EXC_RESOURCE"
        case EXC_GUARD: "EXC_GUARD"
        default: "UNKNOWN_EXCEPTION"
        }
    }
}

@available(iOS 27.0, *)
private struct ReportThread: Encodable {
    let index: Int; let id: UInt64?; let crashed: Bool
    let registers: ARM64Registers; let frames: [ReportFrame]
}

// swiftlint:disable identifier_name
private struct ARM64Registers: Encodable {
    let x: [UInt64]; let fp: UInt64; let lr: UInt64; let sp: UInt64; let pc: UInt64; let cpsr: UInt32
}
// swiftlint:enable identifier_name

@available(iOS 27.0, *)
private struct ReportFrame: Encodable {
    let address: UInt64; let image: ReportImageReference?; let symbols: [SymbolicatedFrame]
}
private struct ReportImageReference: Encodable {
    let name: String; let path: String; let uuid: UUID?; let offset: UInt64
}
