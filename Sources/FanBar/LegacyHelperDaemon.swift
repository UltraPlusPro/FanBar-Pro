import FanBarShared
import Foundation

/// How macOS 11 and 12, which have no `SMAppService`, install and check the
/// root helper through launchd. Kept free of side effects so the commands can
/// be tested; `FanBarServiceManager` runs them with administrator rights.
///
/// Legacy launchd checks neither the daemon's signature nor who can write it,
/// so everything root runs is a root-owned copy: the helper (with the Info.plist
/// it reads its build from and the Swift concurrency runtime macOS 11 lacks) is
/// copied out of the user-writable app, its signature is verified after the copy,
/// and the job plist is written by the root script itself.
enum LegacyHelperDaemon {
    /// The same label the `SMAppService` plist uses on macOS 13 and later.
    static let label = FanBarService.helperBundleID
    /// Early builds loaded the job under the plist's file name as its label.
    static let earlierLabel = FanBarService.helperPlistName
    /// launchd only bootstraps a system-domain plist owned by root and not
    /// writable by others, and only plists here survive a restart.
    static let installedPlistPath = "/Library/LaunchDaemons/\(FanBarService.helperPlistName)"
    /// Mirrors the app's layout so the helper's relative paths
    /// (`../../../Info.plist`, `../../Frameworks`) keep working.
    static let installedRootPath = "/Library/PrivilegedHelperTools/\(FanBarService.helperBundleID)"
    static let helperRelativePath = "Contents/Library/LaunchServices/\(FanBarService.helperBundleID)"
    static let concurrencyRuntimeRelativePath = "Contents/Frameworks/libswift_Concurrency.dylib"
    static var installedHelperPath: String { "\(installedRootPath)/\(helperRelativePath)" }

    /// Whether this macOS release registers the helper through launchd
    /// instead of `SMAppService`.
    static func isUsed(on os: OperatingSystemVersion) -> Bool {
        os.majorVersion < 13
    }

    /// After an upgrade from macOS 11 or 12 the legacy job still loads at boot
    /// under the label `SMAppService` registers, so it must go first.
    static func needsRemovalBeforeServiceManagement(on os: OperatingSystemVersion, legacyPlistExists: Bool) -> Bool {
        !isUsed(on: os) && legacyPlistExists
    }

    /// The team whose helper may be installed, or nil when the build carries no
    /// team. Ad-hoc builds (`codesign -s -`, the local case: no Developer ID on
    /// the machine) install too, with the degraded identifier-level requirement
    /// built by `helperRequirement(teamID:)`.
    static func installableTeam(_ teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        return teamID
    }

    /// Only the app's own helper may run as root.
    ///
    /// A team-signed build pins its team. A locally signed build carries no
    /// team, but `codesign -d -r-` still exposes its leaf certificate, so the
    /// requirement pins that certificate hash instead: it proves *who* signed
    /// the code without needing a Developer ID. Only a build with neither a
    /// team nor a certificate degrades to the bundle identifier, which proves
    /// *which* code is installed but not *who* signed it.
    static func helperRequirement(teamID: String?, certificateSHA1: String? = nil) -> String {
        if let teamID, !teamID.isEmpty {
            return "anchor apple generic and identifier \"\(FanBarService.helperBundleID)\" "
                + "and certificate leaf[subject.OU] = \"\(teamID)\""
        }
        if let certificateSHA1, !certificateSHA1.isEmpty {
            return "identifier \"\(FanBarService.helperBundleID)\" "
                + "and certificate leaf = H\"\(certificateSHA1)\""
        }
        return "identifier \"\(FanBarService.helperBundleID)\""
    }

    /// Nil when the embedded runtime must not be checked: an ad-hoc build keeps
    /// the toolchain's own signing identifier on this dylib
    /// (`com.apple.dt.runtime.swiftConcurrency`) after the packaging script
    /// re-signs it, so a team-anchored requirement cannot describe it. Verified
    /// on the real binary — `codesign --verify -R '=identifier
    /// "libswift_Concurrency.dylib"'` fails, while the Apple identifier passes.
    /// The helper itself, which is the code that runs as root, stays verified.
    static func runtimeRequirement(teamID: String?) -> String? {
        guard let teamID, !teamID.isEmpty else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    static func jobDefinition() -> [String: Any] {
        [
            "Label": label,
            // `Program` is the absolute path launchd execs. It names the same
            // binary as `ProgramArguments` (kept for tools that only read that
            // key) and removes any doubt about how the path is resolved.
            "Program": installedHelperPath,
            "ProgramArguments": [installedHelperPath],
            "MachServices": [FanBarService.helperBundleID: true],
            "ProcessType": "Interactive",
            // 1.5.6: a reboot used to leave the helper down until the next
            // manual enable, because the job only ever started on demand. It is
            // now started with the system, and relaunched if it ever dies.
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false]
        ]
    }

    /// The build of the helper copy launchd runs right now, or nil when nothing
    /// is installed. A mismatch with the app's own version means an upgrade has
    /// not refreshed the root-owned copy yet; `FanBarServiceManager` reports
    /// that instead of silently steering the fans with an older daemon.
    static func installedBundleVersion() -> String? {
        let infoPlist = URL(fileURLWithPath: installedRootPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any]
        else { return nil }
        return dictionary["CFBundleVersion"] as? String
    }

    /// The job plist on one line. Every value is a constant without line
    /// breaks, so dropping the indentation keeps the property list intact and
    /// lets the root script write it with a single `printf`.
    static func jobPlistText() throws -> String {
        let data = try PropertyListSerialization.data(fromPropertyList: jobDefinition(), format: .xml, options: 0)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
    }

    /// Unloads any loaded job, removes the previous install, copies the helper
    /// out of the app into a fresh root-owned directory, verifies the copy's
    /// signature, writes the job plist as root:wheel 0644 and loads it. Any
    /// failed step stops the script.
    ///
    /// The first steps are the idempotent cleanup 1.5.6 added: a leftover plist
    /// and directory from an older SMJobBless-style install share this job's
    /// label, so launchd could validate the app-bundle helper against a stale
    /// registration and SIGKILL it at boot ("Launch Constraint Violation").
    /// Deleting them before writing ours leaves exactly one registration.
    static func installCommand(
        appBundlePath: String,
        teamID: String?,
        certificateSHA1: String? = nil,
        jobPlist: String
    ) -> String {
        let source = appBundlePath.hasSuffix("/") ? String(appBundlePath.dropLast()) : appBundlePath
        let root = shellQuote(installedRootPath)
        let helper = shellQuote(installedHelperPath)
        let runtime = shellQuote("\(installedRootPath)/\(concurrencyRuntimeRelativePath)")
        let sourceRuntime = shellQuote("\(source)/\(concurrencyRuntimeRelativePath)")
        let plist = shellQuote(installedPlistPath)
        var steps = [
            // Idempotent cleanup: an old registration and its root-owned copy
            // must be gone before ours is written, or two jobs share a label.
            "{ /usr/bin/logger -t fanbar-helper 'install: removing previous registration'; }",
            "/bin/rm -f \(plist)",
            "/bin/rm -rf \(root)",
            "/bin/mkdir -p \(shellQuote("\(installedRootPath)/Contents/Library/LaunchServices"))"
                + " \(shellQuote("\(installedRootPath)/Contents/Frameworks"))",
            "/usr/bin/ditto \(shellQuote("\(source)/Contents/Info.plist")) \(shellQuote("\(installedRootPath)/Contents/Info.plist"))",
            "/usr/bin/ditto \(shellQuote("\(source)/\(helperRelativePath)")) \(helper)",
            "{ [ ! -e \(sourceRuntime) ] || /usr/bin/ditto \(sourceRuntime) \(runtime); }",
            "/usr/sbin/chown -R root:wheel \(root)",
            "/bin/chmod -R go-w \(root)",
            "/usr/bin/codesign --verify --strict -R"
                + " \(shellQuote("=" + helperRequirement(teamID: teamID, certificateSHA1: certificateSHA1))) \(helper)",
            "{ /usr/bin/logger -t fanbar-helper 'install: helper signature verified'; }"
        ]
        // A build with neither a team nor a leaf certificate cannot describe the
        // copied runtime, so that one check is skipped there; the helper check
        // above always runs.
        if let requirement = runtimeRequirement(teamID: teamID) {
            steps.append(
                "{ [ ! -e \(runtime) ] || /usr/bin/codesign --verify --strict"
                    + " -R \(shellQuote("=" + requirement)) \(runtime); }"
            )
        }
        steps.append(contentsOf: [
            "/usr/bin/printf '%s' \(shellQuote(jobPlist)) > \(plist)",
            "/usr/sbin/chown root:wheel \(plist)",
            "/bin/chmod 644 \(plist)",
            "/bin/launchctl enable system/\(label)",
            "{ /usr/bin/logger -t fanbar-helper 'install: bootstrapping job'; }",
            "/bin/launchctl bootstrap system \(plist)"
        ])
        return ["umask 022", unloadCommands, steps.joined(separator: " && ")].joined(separator: "; ")
    }

    /// Unloads the job (fine when it is not loaded) and deletes its plist and
    /// helper copy so nothing comes back after a restart.
    static func removeCommand() -> String {
        [
            unloadCommands,
            "/bin/rm -f \(shellQuote(installedPlistPath))",
            "/bin/rm -rf \(shellQuote(installedRootPath))"
        ].joined(separator: "; ")
    }

    static func status(jobIsLoaded: Bool) -> FanBarServiceStatus {
        jobIsLoaded ? .enabled : .notRegistered
    }

    /// Whether a launchd install is present at all, which macOS 13 and later
    /// must also accept: `SMAppService` cannot register an ad-hoc build, so the
    /// launchd daemon is the one that stays installed there. Either a loaded
    /// job or its root-owned plist is enough, because a job launchd has not
    /// bootstrapped yet still loads at the next login.
    static func isInstalled(plistExists: Bool, jobIsLoaded: Bool) -> Bool {
        plistExists || jobIsLoaded
    }

    private static var unloadCommands: String {
        [label, earlierLabel]
            .map { "/bin/launchctl bootout system/\($0) 2>/dev/null" }
            .joined(separator: "; ")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
