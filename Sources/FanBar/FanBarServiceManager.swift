import AppKit
import FanBarShared
import Foundation
import ServiceManagement

enum FanBarServiceStatus: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case unavailable
}

/// Provides one service-management API for modern SMAppService and Big Sur's
/// launchd fallback. The helper protocol remains identical on every release.
@MainActor
final class FanBarServiceManager {
    private(set) var status: FanBarServiceStatus = .notRegistered
    /// True when the root-owned helper copy belongs to another build, so the
    /// fans may be steered by an older daemon until the user reinstalls.
    private(set) var installedBuildIsStale = false
    private var hasReportedStatus = false

    func refresh() {
        let previous = status
        defer {
            if !hasReportedStatus || previous != status {
                hasReportedStatus = true
                let outcome: RuntimeDiagnosticEvent.Outcome
                switch status {
                case .enabled: outcome = .enabled
                case .requiresApproval: outcome = .requiresApproval
                case .notRegistered: outcome = .notRegistered
                case .unavailable: outcome = .unavailable
                }
                RuntimeDiagnostics.shared.record(.service, .status, outcome)
            }
        }
        if #available(macOS 13.0, *) {
            let service = SMAppService.daemon(plistName: FanBarService.helperPlistName)
            switch service.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .requiresApproval
            case .notRegistered, .notFound:
                // Service Management refuses builds without a Team ID, so an
                // ad-hoc install lives in launchd instead.
                status = legacyStatus()
            @unknown default:
                status = .unavailable
            }
        } else {
            status = legacyStatus()
        }
    }

    /// The launchd install macOS 11 and 12 use, and the one macOS 13 and later
    /// fall back to when `SMAppService` will not take the build.
    private func legacyStatus() -> FanBarServiceStatus {
        // Nothing installed is the common case and needs no process: `launchctl
        // print` is a synchronous spawn, and this runs on the refresh timer.
        guard FileManager.default.fileExists(atPath: LegacyHelperDaemon.installedPlistPath) else {
            return .notRegistered
        }
        return LegacyHelperDaemon.isInstalled(
            plistExists: true,
            jobIsLoaded: LegacyLaunchd.jobIsLoaded(label: LegacyHelperDaemon.label)
        ) ? .enabled : .notRegistered
    }

    func register() throws {
        RuntimeDiagnostics.shared.record(.service, .register, .started)
        do {
            try registerService()
            RuntimeDiagnostics.shared.record(.service, .register, .succeeded)
        } catch {
            RuntimeDiagnostics.shared.record(.service, .register, .failed, code: (error as NSError).code)
            throw error
        }
    }

    private func registerService() throws {
        if #available(macOS 13.0, *), Self.serviceManagementCanAuthenticate {
            unregisterLaunchdDaemonIfPresent()
            if LegacyHelperDaemon.needsRemovalBeforeServiceManagement(
                on: ProcessInfo.processInfo.operatingSystemVersion,
                legacyPlistExists: FileManager.default.fileExists(atPath: LegacyHelperDaemon.installedPlistPath)
            ) {
                try LegacyLaunchd.removeHelper()
            }
            do {
                try SMAppService.daemon(plistName: FanBarService.helperPlistName).register()
            } catch {
                // Service Management refused a build it can authenticate; the
                // same job still runs as a root launchd daemon, and that path
                // authorizes with the administrator prompt.
                try LegacyLaunchd.installHelper()
            }
        } else {
            // This build has no signing team, so `SMAppService` would derive a
            // daemon launch constraint it can never satisfy. `launchctl print`
            // on a registration made that way shows
            //     LWCR = { reqs = { cdhash = { "$in" = [ ] } }  ccat = 0 }
            // — an empty cdhash set, which no code matches — and launchd then
            // SIGKILLs the helper at the next boot with
            // "Launch Constraint Violation". That is the 1.1.5 boot failure.
            // Remove such a registration and use launchd directly instead.
            unregisterServiceManagementDaemonBlocking()
            try LegacyLaunchd.installHelper()
        }
        refresh()
    }

    /// Whether `SMAppService` can describe this build at all. It derives the
    /// daemon's launch constraint from the parent app's code signature, which
    /// needs a signing team; a locally signed build (no Developer ID) has none,
    /// and registering anyway is what produced the unsatisfiable constraint.
    static var serviceManagementCanAuthenticate: Bool {
        LegacyHelperDaemon.installableTeam(OwnCodeSignature.teamIdentifier()) != nil
    }

    /// The launchd job this build installs itself. `SMAppService` owns a
    /// different domain record, so a build that stops using it must remove that
    /// record — a `launchctl bootout` alone would be re-submitted by Background
    /// Task Management at the next login.
    private func unregisterServiceManagementDaemonBlocking(timeout: TimeInterval = 15) {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.daemon(plistName: FanBarService.helperPlistName)
        switch service.status {
        case .notRegistered, .notFound:
            return
        default:
            break
        }
        let finished = DispatchSemaphore(value: 0)
        // The completion-handler form, not the async one: this call runs on the
        // main actor, and blocking it while an async unregister needs the same
        // actor would deadlock. The handler is delivered on another queue.
        service.unregister { error in
            if let error {
                NSLog("FanBar Pro: removing the Service Management registration failed: %@",
                      error.localizedDescription)
            }
            finished.signal()
        }
        // Deliberately blocking: the caller is a user-initiated install that
        // must not install the launchd job while a duplicate registration is
        // still being torn down. The wait is bounded, and a timeout is not
        // fatal — the install script boots the label out first regardless.
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            NSLog("FanBar Pro: timed out removing the Service Management registration")
        }
    }

    private func unregisterLaunchdDaemonIfPresent() {
        guard FileManager.default.fileExists(atPath: LegacyHelperDaemon.installedPlistPath)
                || HelperJobInspector.snapshot(label: LegacyHelperDaemon.label).isLoaded else {
            return
        }
        try? LegacyLaunchd.removeHelper()
    }

    /// Runs once per launch. Idempotent and silent — it never asks for
    /// authorization; anything that needs root stays in `register()`.
    ///
    /// This is the "every reboot keeps the helper" half of the 1.5.6 fix: the
    /// job now carries `RunAtLoad`, and if launchd still has the label while the
    /// process is gone, the app asks for one restart. A privilege failure here
    /// is expected and harmless: the next authorized install repairs it.
    func prepareAtLaunch() {
        refresh()
        guard status == .enabled else { return }
        let snapshot = HelperJobInspector.snapshot(label: LegacyHelperDaemon.label)
        if snapshot.isLoaded, !snapshot.isRunning {
            let restarted = HelperJobInspector.kickstart(label: LegacyHelperDaemon.label)
            NSLog("FanBar Pro: helper %@ at launch, kickstart %@",
                  snapshot.summary, restarted ? "succeeded" : "was not permitted")
        }
        if let installed = LegacyHelperDaemon.installedBundleVersion(),
           let running = Self.appBundleVersion,
           installed != running {
            // Not an error the app can fix without the administrator prompt the
            // user already approved once; surfaced so Settings can ask again.
            installedBuildIsStale = true
            NSLog("FanBar Pro: helper build %@ differs from app build %@", installed, running)
        } else {
            installedBuildIsStale = false
        }
    }

    private static var appBundleVersion: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    func unregister() async throws {
        RuntimeDiagnostics.shared.record(.service, .unregister, .started)
        do {
            try await unregisterService()
            RuntimeDiagnostics.shared.record(.service, .unregister, .succeeded)
        } catch {
            RuntimeDiagnostics.shared.record(.service, .unregister, .failed, code: (error as NSError).code)
            throw error
        }
    }

    private func unregisterService() async throws {
        if #available(macOS 13.0, *) {
            do {
                try await SMAppService.daemon(plistName: FanBarService.helperPlistName).unregister()
            } catch {
                // Either nothing was ever registered with Service Management
                // (the ad-hoc build used launchd) or removal failed: take the
                // launchd job away too, and keep the original error if there
                // was nothing installed there.
                guard legacyStatus() != .notRegistered else { throw error }
                try LegacyLaunchd.removeHelper()
            }
        } else {
            try LegacyLaunchd.removeHelper()
        }
        refresh()
    }

    func openSettings() {
        RuntimeDiagnostics.shared.record(.service, .openSettings, .started)
        Self.openLoginItemsSettings()
    }

    static func openLoginItemsSettings() {
        if #available(macOS 13.0, *) {
            SMAppService.openSystemSettingsLoginItems()
            return
        }

        // Big Sur's Login Items pane uses the older preference-pane URL.
        let urls = [
            "x-apple.systempreferences:com.apple.preference.users?path=LoginItems",
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ]
        for rawURL in urls {
            if let url = URL(string: rawURL), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

@MainActor
final class FanBarLoginItemManager {
    enum Status: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
    }

    private(set) var status: Status = .notRegistered

    func refresh() {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled:
                status = .enabled
            case .requiresApproval:
                status = .requiresApproval
            case .notRegistered, .notFound:
                // An ad-hoc build registers the login item as a LaunchAgent.
                status = legacyIsInstalled ? .enabled : .notRegistered
            @unknown default:
                status = .notRegistered
            }
        } else {
            status = legacyIsInstalled ? .enabled : .notRegistered
        }
    }

    func register() throws {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
            } catch {
                // Service Management refuses builds without a Team ID, so fall
                // back to the LaunchAgent a login item has always been: it needs
                // no administrator rights and launchd loads it at login.
                try LegacyLaunchd.installLoginItem(at: Self.legacyLaunchAgentURL)
            }
        } else {
            try LegacyLaunchd.installLoginItem(at: Self.legacyLaunchAgentURL)
        }
        refresh()
    }

    func unregister() throws {
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.unregister()
            } catch {
                guard legacyIsInstalled else { throw error }
            }
        }
        // A build may have written the login item both ways across upgrades.
        if legacyIsInstalled {
            try LegacyLaunchd.removeLoginItem(at: Self.legacyLaunchAgentURL)
        }
        refresh()
    }

    private var legacyIsInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.legacyLaunchAgentURL.path)
    }

    private static var legacyLaunchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/local.fanbar.app.plist")
    }
}

private enum LegacyLaunchd {
    static func installHelper() throws {
        // A locally signed build has no team and still installs: the job's
        // signature requirement pins the leaf certificate instead. See
        // `LegacyHelperDaemon.helperRequirement(teamID:certificateSHA1:)`.
        let command = try LegacyHelperDaemon.installCommand(
            appBundlePath: Bundle.main.bundleURL.path,
            teamID: LegacyHelperDaemon.installableTeam(OwnCodeSignature.teamIdentifier()),
            certificateSHA1: OwnCodeSignature.leafCertificateSHA1(),
            jobPlist: LegacyHelperDaemon.jobPlistText()
        )
        try runAsAdministrator(command, describedAs: "launchctl bootstrap system \(LegacyHelperDaemon.installedPlistPath)")
    }

    static func removeHelper() throws {
        try runAsAdministrator(
            LegacyHelperDaemon.removeCommand(),
            describedAs: "launchctl bootout system/\(LegacyHelperDaemon.label)"
        )
    }

    static func jobIsLoaded(label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func installLoginItem(at url: URL) throws {
        let executablePath = Bundle.main.executableURL?.path ?? ""
        let plist: [String: Any] = [
            "Label": "local.fanbar.app",
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "ProcessType": "Interactive"
        ]
        try write(plist, to: url)
        try runLaunchctl(["load", "-w", url.path])
    }

    static func removeLoginItem(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try runLaunchctl(["unload", "-w", url.path])
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func write(_ plist: [String: Any], to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private static func runLaunchctl(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LegacyLaunchdError.commandFailed(arguments.joined(separator: " "))
        }
    }

    private static func runAsAdministrator(_ command: String, describedAs description: String) throws {
        let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LegacyLaunchdError.commandFailed(description)
        }
    }

    private static func appleScriptQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

private enum LegacyLaunchdError: LocalizedError {
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command): fanBarFormat(
            "无法执行系统服务命令：%@",
            "Unable to run the system service command: %@",
            command
        )
        }
    }
}
