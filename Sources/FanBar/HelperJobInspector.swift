import Foundation

/// What launchd currently knows about the privileged helper.
///
/// 1.5.6 needs this because "registered" and "running" are different questions:
/// the reported bug was a registration that launchd kept (state = running at
/// install time) while the job was SIGKILLed at every boot. Reading the live
/// job is the only way to tell those apart without an administrator prompt.
struct HelperJobSnapshot: Equatable {
    /// launchd knows the label, so `launchctl print` succeeded.
    let isLoaded: Bool
    /// The job has a live process right now.
    let isRunning: Bool
    let pid: Int?
    /// `running`, `spawn scheduled`, `not running`, or nil when not loaded.
    let state: String?
    /// The program path launchd recorded, when the domain is a submitted one.
    let programIdentifier: String?

    static let notLoaded = HelperJobSnapshot(
        isLoaded: false,
        isRunning: false,
        pid: nil,
        state: nil,
        programIdentifier: nil
    )

    /// One line for the diagnostics bundle and for the user-facing error text.
    var summary: String {
        guard isLoaded else { return "not loaded" }
        let stateText = state ?? "unknown"
        let pidText = pid.map { "pid \($0)" } ?? "no pid"
        return "\(stateText), \(pidText)"
    }
}

/// Reads and nudges the helper's launchd job without ever asking for rights.
/// Everything that needs root (installing, replacing the job) lives in
/// `LegacyHelperDaemon` and runs through an administrator prompt instead.
enum HelperJobInspector {
    /// Parses `launchctl print system/<label>`. A missing job is a normal,
    /// expected answer — the helper is not installed on most launches — so it
    /// is reported as `notLoaded` rather than as an error.
    static func snapshot(label: String) -> HelperJobSnapshot {
        guard let output = runLaunchctl(["print", "system/\(label)"]) else {
            return .notLoaded
        }
        var state: String?
        var pid: Int?
        var programIdentifier: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("state = ") {
                state = String(trimmed.dropFirst("state = ".count))
            } else if trimmed.hasPrefix("pid = ") {
                pid = Int(trimmed.dropFirst("pid = ".count))
            } else if trimmed.hasPrefix("program identifier = ") {
                programIdentifier = String(trimmed.dropFirst("program identifier = ".count))
            }
        }
        return HelperJobSnapshot(
            isLoaded: true,
            isRunning: state == "running" && pid != nil,
            pid: pid,
            state: state,
            programIdentifier: programIdentifier
        )
    }

    /// Asks launchd to restart the job. Succeeds only when the caller may
    /// manage the system domain, so a `false` result here is not an error the
    /// app can fix on its own — it records it and leaves the fix to the
    /// administrator-authorized install path.
    @discardableResult
    static func kickstart(label: String) -> Bool {
        runLaunchctl(["kickstart", "-k", "system/\(label)"]) != nil
    }

    private static func runLaunchctl(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}
