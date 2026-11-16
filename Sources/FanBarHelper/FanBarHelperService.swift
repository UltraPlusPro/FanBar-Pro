import FanBarShared
import Foundation
import os
import Security

final class FanBarHelperService: NSObject, NSXPCListenerDelegate, FanBarHelperProtocol,
    @unchecked Sendable {
    private static let log = Logger(subsystem: FanBarService.helperBundleID, category: "service")
    private let listener = NSXPCListener(machServiceName: FanBarService.helperBundleID)
    private let hardwareQueue = DispatchQueue(label: "local.fanbar.helper.hardware")
    private let makeDriver: () throws -> SMCFanDriver
    private var driver: SMCFanDriver?
    private var activeConnections = 0
    /// Set between the system's will-sleep and has-powered-on messages.
    private var isSystemSleeping = false
    /// Exits the process when one hardware call never returns, so launchd's
    /// KeepAlive can restart a wedged daemon instead of leaving it mute.
    private let watchdog = HelperWatchdog()
    private let launchBuild: String

    init(
        makeDriver: @escaping () throws -> SMCFanDriver = { try SMCFanDriver() },
        launchBuild: String = HelperLaunchBuild.read(
            executableURL: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        )
    ) {
        self.makeDriver = makeDriver
        self.launchBuild = HelperLaunchBuild.sanitized(launchBuild)
        super.init()
        listener.delegate = self
    }

    func run() {
        RuntimeDiagnostics.shared.record(.helper, .startup, .succeeded)
        watchdog.start()
        listener.resume()
        RunLoop.current.run()
    }

    func restoreForShutdown() {
        hardwareQueue.sync {
            RuntimeDiagnostics.shared.record(.helper, .shutdown, .started)
            do {
                if let driver {
                    try driver.restoreAutomatic()
                    RuntimeDiagnostics.shared.record(.helper, .restoreAutomatic, .succeeded)
                }
                RuntimeDiagnostics.shared.record(.helper, .shutdown, .succeeded)
            } catch {
                RuntimeDiagnostics.shared.record(.helper, .restoreAutomatic, .failed, code: Self.diagnosticCode(error))
                RuntimeDiagnostics.shared.record(.helper, .shutdown, .failed)
            }
            driver = nil
        }
    }

    /// Runs before the system sleeps; sleep waits for it to return. A fan held in
    /// manual mode through sleep and dark wakes can leave the SMC refusing every
    /// mode write until a restart (issue 114), so macOS gets the fans back first.
    /// The app re-applies its mode after wake.
    func prepareForSleep() {
        hardwareQueue.sync {
            isSystemSleeping = true
            // Never open the SMC just to go to sleep.
            guard let driver else { return }
            Self.log.notice("System will sleep; restoring automatic fan control")
            RuntimeDiagnostics.shared.record(.helper, .recovery, .started)
            do {
                try driver.restoreAutomatic()
                RuntimeDiagnostics.shared.record(.helper, .recovery, .succeeded)
            } catch {
                RuntimeDiagnostics.shared.record(.helper, .recovery, .failed, code: Self.diagnosticCode(error))
            }
        }
    }

    func systemDidWake() {
        hardwareQueue.sync {
            isSystemSleeping = false
            // The SMC handle does not survive every sleep. Keeping the stale one
            // is what made every later write fail with an SMC error until the
            // daemon was restarted; dropping it makes the next call reopen.
            if driver != nil {
                driver = nil
                Self.log.notice("Wake: dropped the cached SMC session")
            }
        }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard Self.isAuthorizedClient(connection) else {
            RuntimeDiagnostics.shared.record(.helper, .authorize, .rejected)
            Self.log.error("Rejected XPC client pid \(connection.processIdentifier)")
            return false
        }
        RuntimeDiagnostics.shared.record(.helper, .connect, .accepted)
        clientDidConnect()
        connection.exportedInterface = NSXPCInterface(with: FanBarHelperProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in
            self?.clientDidDisconnect()
        }
        connection.resume()
        return true
    }

    func clientDidConnect() {
        hardwareQueue.sync {
            activeConnections += 1
        }
    }

    /// Without a client nobody can steer the fans, so hand them back to macOS.
    func clientDidDisconnect() {
        hardwareQueue.async {
            self.activeConnections = max(0, self.activeConnections - 1)
            if self.activeConnections == 0, let driver = self.driver {
                Self.log.notice("Last client disconnected; restoring automatic fan control")
                RuntimeDiagnostics.shared.record(.helper, .recovery, .started)
                do {
                    try driver.restoreAutomatic()
                    RuntimeDiagnostics.shared.record(.helper, .recovery, .succeeded)
                } catch {
                    RuntimeDiagnostics.shared.record(.helper, .recovery, .failed, code: Self.diagnosticCode(error))
                }
            }
        }
    }

    func getFanCount(reply: @escaping @Sendable (Bool, Int, String?) -> Void) {
        hardwareQueue.async {
            self.watchdog.begin("getFanCount")
            defer { self.watchdog.end() }
            do {
                reply(true, try self.connectedDriver().fans().count, nil)
            } catch {
                self.forgetStaleDriver(after: error)
                RuntimeDiagnostics.shared.record(.helper, .fanCount, .failed, code: Self.diagnosticCode(error))
                reply(false, 0, Self.failureReply(error))
            }
        }
    }

    func getFan(
        _ index: Int,
        reply: @escaping @Sendable (Bool, Float, Float, Float, Bool, String?) -> Void
    ) {
        hardwareQueue.async {
            self.watchdog.begin("getFan")
            defer { self.watchdog.end() }
            do {
                let fans = try self.connectedDriver().fans()
                guard let fan = fans.first(where: { $0.index == index }) else {
                    reply(false, 0, 0, 0, false, fanBarFormat("未找到风扇 %d", "Fan %d was not found", index + 1))
                    return
                }
                reply(true, fan.actual, fan.minimum, fan.maximum, fan.isManual, nil)
            } catch {
                self.forgetStaleDriver(after: error)
                RuntimeDiagnostics.shared.record(.helper,
                    .fanRead, .failed, code: Self.diagnosticCode(error), fanIndex: (0...7).contains(index) ? index : nil)
                reply(false, 0, 0, 0, false, Self.failureReply(error))
            }
        }
    }

    func setAllFans(
        rpm: Float,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        // NaN survives min/max clamping and would reach the SMC unchanged.
        guard rpm.isFinite, rpm >= 0 else {
            reply(false, Self.invalidRequest(fanBarText("转速必须是有效的非负数", "RPM must be a finite, non-negative number")))
            return
        }
        performWrite("setAllFans", reply: reply) { driver in
            try driver.setAllFans(rpm: rpm)
        }
    }

    func setCoolingPreset(
        _ rawValue: Int,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        guard let preset = FanCoolingPreset(rawValue: rawValue) else {
            reply(false, Self.invalidRequest(fanBarText("未知的散热预设", "Unknown cooling preset")))
            return
        }
        performWrite("setCoolingPreset", reply: reply) { driver in
            try driver.setCoolingPreset(preset)
        }
    }

    func setCoolingFraction(
        _ fraction: Float,
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        // Keep the root API bounded even if a compromised client sends malformed input.
        // 0% is allowed so smart cooling can idle below the low-temp knee.
        guard fraction.isFinite, (0...1.00).contains(fraction) else {
            reply(false, Self.invalidRequest(fanBarText("散热比例必须在 0% 到 100% 之间", "Cooling fraction must be between 0% and 100%")))
            return
        }
        performWrite("setCoolingFraction", reply: reply) { driver in
            try driver.setCoolingFraction(fraction)
        }
    }

    func setAllFansToEightyPercent(
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        performWrite("setAllFansToEightyPercent", reply: reply) { driver in
            try driver.setAllFansToEightyPercent()
        }
    }

    func getBuildVersion(reply: @escaping @Sendable (String) -> Void) {
        reply(launchBuild)
    }

    var launchBuildForTesting: String { launchBuild }

    func restoreAutomatic(
        reply: @escaping @Sendable (Bool, String?) -> Void
    ) {
        performWrite("restoreAutomatic", reply: reply) { driver in
            try driver.restoreAutomatic()
        }
    }

    /// Serializes a hardware write and records its duration and real error, which
    /// the client cannot see once its reply timeout has already fired.
    private func performWrite(
        _ operation: StaticString,
        reply: @escaping @Sendable (Bool, String?) -> Void,
        _ body: @escaping @Sendable (SMCFanDriver) throws -> Void
    ) {
        hardwareQueue.async {
            let start = Date()
            let action: RuntimeDiagnosticEvent.Action
            switch String(describing: operation) {
            case "setAllFans": action = .fixedRPM
            case "setCoolingPreset": action = .preset
            case "setCoolingFraction", "setAllFansToEightyPercent": action = .curve
            default: action = .restoreAutomatic
            }
            let requestID = UUID().uuidString.lowercased()
            // Handing back is always allowed; taking control waits until the Mac is awake.
            if self.isSystemSleeping, action != .restoreAutomatic {
                RuntimeDiagnostics.shared.record(.helper, action, .rejected, requestID: requestID, code: Self.systemSleepingCode)
                reply(false, HelperControlFailure(
                    code: .systemSleeping,
                    message: fanBarText("Mac 正在进入睡眠，风扇已交回 macOS", "The Mac is going to sleep; macOS has the fans")
                ).encodedReply())
                return
            }
            RuntimeDiagnostics.shared.record(.helper, action, .started, requestID: requestID)
            self.watchdog.begin(String(describing: operation))
            defer { self.watchdog.end() }
            do {
                try self.writeWithRetry(body)
                let elapsed = Date().timeIntervalSince(start)
                RuntimeDiagnostics.shared.record(.helper, action, .succeeded, requestID: requestID, durationMS: elapsed * 1000)
                Self.log.notice("\(operation, privacy: .public) succeeded in \(elapsed, format: .fixed(precision: 2))s")
                reply(true, nil)
            } catch {
                let elapsed = Date().timeIntervalSince(start)
                RuntimeDiagnostics.shared.record(.helper, action, .failed, requestID: requestID,
                    code: Self.diagnosticCode(error), durationMS: elapsed * 1000)
                Self.log.error("\(operation, privacy: .public) failed after \(elapsed, format: .fixed(precision: 2))s: \(error.localizedDescription, privacy: .public)")
                reply(false, Self.failureReply(error, durationMS: Int(elapsed * 1000)))
            }
        }
    }

    /// Hardware failures carry a structured payload; the app falls back to the text for older helpers.
    private static func failureReply(_ error: Error, durationMS: Int? = nil) -> String {
        guard let hardware = error as? FanHardwareError else { return error.localizedDescription }
        return hardware.controlFailure(durationMS: durationMS).encodedReply()
    }

    private static func invalidRequest(_ message: String) -> String {
        HelperControlFailure(code: .invalidRequest, message: message).encodedReply()
    }

    /// Next to the hardware codes below; a write refused because the Mac is going to sleep.
    private static let systemSleepingCode = -10004

    private static func diagnosticCode(_ error: Error) -> Int {
        guard let hardware = error as? FanHardwareError else { return (error as NSError).code }
        switch hardware {
        case .unavailable(let code), .operation(_, let code): return Int(code)
        case .invalidValue: return -10001
        case .unlockTimeout: return -10002
        case .modeKeyMissing: return -10003
        }
    }

    private func connectedDriver() throws -> SMCFanDriver {
        if let driver { return driver }
        let newDriver = try makeDriver()
        driver = newDriver
        return newDriver
    }

    /// One write, retried once on a *fresh* SMC session when the failure is the
    /// kind reopening fixes. Without this, one bad exchange after sleep left the
    /// cached handle poisoned and every later write failed until the daemon was
    /// restarted, which the user experiences as "fan control stopped working".
    ///
    /// Runs on `hardwareQueue`; `driver` is confined to it.
    private func writeWithRetry(_ body: @escaping @Sendable (SMCFanDriver) throws -> Void) throws {
        do {
            try body(connectedDriver())
        } catch {
            guard Self.isRecoverable(error), driver != nil else { throw error }
            Self.log.notice("SMC write failed; reopening the session and retrying once")
            driver = nil
            RuntimeDiagnostics.shared.record(.helper, .recovery, .started)
            do {
                try body(connectedDriver())
                RuntimeDiagnostics.shared.record(.helper, .recovery, .succeeded)
            } catch {
                RuntimeDiagnostics.shared.record(.helper, .recovery, .failed, code: Self.diagnosticCode(error))
                throw error
            }
        }
    }

    /// A refused or unavailable SMC exchange is the class of failure where a new
    /// session is the known fix. A malformed value or a missing mode key would
    /// fail identically on a fresh session, so those are never retried.
    private static func isRecoverable(_ error: Error) -> Bool {
        guard let hardware = error as? FanHardwareError else { return false }
        switch hardware {
        case .unavailable, .operation, .unlockTimeout: return true
        case .invalidValue, .modeKeyMissing: return false
        }
    }

    /// Drops the cached session after a recoverable read failure so the next
    /// poll opens a fresh one instead of repeating the same error forever.
    private func forgetStaleDriver(after error: Error) {
        guard Self.isRecoverable(error), driver != nil else { return }
        driver = nil
        Self.log.notice("Dropped the cached SMC session after a recoverable read failure")
    }

    /// Limit this root service to the FanBar application. Deriving the team
    /// from our own signature keeps Development and Developer ID builds aligned
    /// without weakening the requirement.
    ///
    /// Ad-hoc ("codesign -s -") builds are the local case: the machine has no
    /// Developer ID identity, so nothing carries a team. The helper then falls
    /// back to an identifier-level requirement, which is the strongest check
    /// available without an anchor: only code whose bundle identifier is
    /// exactly the FanBar app may talk to root. Any other local process could
    /// still ad-hoc sign itself with that identifier, so this is a *degraded*
    /// trust model — it stops accidental clients, not a determined local
    /// attacker. A build with a team keeps the strict anchor + OU requirement.
    ///
    /// The check is bound to the connection's audit token, never its PID: a
    /// PID can be recycled or `exec`-replaced by a signed binary after an
    /// attacker has already opened the connection.
    private static func isAuthorizedClient(_ connection: NSXPCConnection) -> Bool {
        guard let text = clientRequirementText() else { return false }
        if #available(macOS 13.0, *) {
            // The system enforces the requirement against the audit token of
            // every incoming message, so a swapped process is rejected too.
            connection.setCodeSigningRequirement(text)
            return true
        }
        guard let token = auditToken(of: connection) else { return false }
        let tokenData = withUnsafeBytes(of: token) { Data($0) }
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else { return false }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private static func clientRequirementText() -> String? {
        clientRequirementText(
            teamID: ownTeamIdentifier(),
            certificateSHA1: OwnCodeSignature.leafCertificateSHA1()
        )
    }

    /// Only the FanBar app that carries the same signing identity as this helper
    /// may talk to root.
    ///
    /// A team-signed helper pins its team. A locally signed helper (this
    /// project's `Local QA Code Signing`, no Developer ID and therefore no team)
    /// pins its own leaf certificate instead, which the app shares: a process
    /// that merely copies the bundle identifier can no longer reach the daemon.
    /// FanBar Pro 0.9.0 refused team-less helpers entirely; 1.1.5 relaxed that
    /// to a bare identifier check, which any local process could spoof with
    /// `codesign -s -`. Pinning the certificate restores the guarantee without
    /// needing a Developer ID.
    ///
    /// Only a build with neither a team nor a certificate — unsigned — degrades
    /// to the identifier alone.
    static func clientRequirementText(teamID: String?, certificateSHA1: String? = nil) -> String? {
        if let teamID, !teamID.isEmpty {
            return "anchor apple generic and identifier \"\(FanBarService.appBundleID)\" " +
                "and certificate leaf[subject.OU] = \"\(teamID)\""
        }
        if let certificateSHA1, !certificateSHA1.isEmpty {
            return "identifier \"\(FanBarService.appBundleID)\" " +
                "and certificate leaf = H\"\(certificateSHA1)\""
        }
        return "identifier \"\(FanBarService.appBundleID)\""
    }

    /// `auditToken` is not public before macOS 13; KVC is the long-standing
    /// way helpers read it on older systems.
    private static func auditToken(of connection: NSXPCConnection) -> audit_token_t? {
        guard let value = connection.value(forKey: "auditToken") as? NSValue else { return nil }
        var token = audit_token_t()
        value.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return token
    }

    private static func ownTeamIdentifier() -> String? {
        OwnCodeSignature.teamIdentifier()
    }
}
