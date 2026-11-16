import AppKit
import FanBarShared
import Foundation
import SwiftUI

/// General › Command Line & Automation: the load / unload switch for the 1.1.9
/// root LaunchDaemon that force-restarts the fan-control helper inside the
/// 30–90 s post-boot window.
///
/// The switch is driven by the plist's real existence on disk, never by a
/// UI-only flag. Loading runs the bundled `冷启动加强.command --install`
/// (administrator prompt → write plist + helper → `launchctl bootstrap system`);
/// unloading runs `--uninstall` (`launchctl bootout system/<label>` plus deleting
/// the plist and the helper script). Both are real root-owned filesystem actions.
@MainActor
final class ColdStartBooster: ObservableObject {
    static let shared = ColdStartBooster()

    nonisolated static let label = "local.fanbar.coldstart"
    nonisolated static let installedPlistPath = "/Library/LaunchDaemons/local.fanbar.coldstart.plist"
    nonisolated static let helperPath = "/Library/Application Support/FanBar/fanbar-coldstart.sh"
    nonisolated static let logPath = "/Library/Logs/FanBar-ColdStart.log"

    @Published private(set) var isInstalled = false
    @Published private(set) var isWorking = false
    @Published var failure: String?

    /// The bundled installer/uninstaller. Absent in `swift run` builds.
    nonisolated static var commandURL: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("冷启动加强.command")
    }

    nonisolated static var isAvailable: Bool {
        guard let url = commandURL else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Synchronise with the plist that launchd actually boots from.
    func refresh() {
        isInstalled = FileManager.default.fileExists(atPath: Self.installedPlistPath)
    }

    func setEnabled(_ enabled: Bool) {
        guard let url = Self.commandURL, Self.isAvailable else { return }
        failure = nil
        isWorking = true
        let mode = enabled ? "--install" : "--uninstall"
        // Same pattern as CommandLineToolInstaller: let the button redraw before
        // the administrator password sheet blocks this turn of the run loop.
        DispatchQueue.main.async { [self] in
            defer {
                isWorking = false
                refresh()
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [url.path, mode]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                failure = "无法执行冷启动加强脚本 / Could not run the booster: \(error.localizedDescription)"
                return
            }
            guard process.terminationStatus == 0 else {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                failure = "冷启动加强操作失败 / Booster failed: "
                    + (detail.isEmpty ? "exit \(process.terminationStatus)" : detail)
                return
            }
        }
    }
}

/// The row on Settings › General › Command Line & Automation.
///
/// Its copy is a plain bilingual literal on purpose: routing it through
/// `fanBarText` would require a matching key in all 11 language catalogs for a
/// control that is deliberately small. Chinese and English are always readable.
struct ColdStartBoosterRow: View {
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue
    @ObservedObject var booster: ColdStartBooster = .shared

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsRowText(
                    title: "冷启动加强 / Cold-Start Booster",
                    detail: detail
                )
                if let failure = booster.failure {
                    Text(failure)
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(booster.isInstalled ? "卸载… / Unload…" : "加载… / Load…") {
                booster.setEnabled(!booster.isInstalled)
            }
            .disabled(booster.isWorking)
        }
        .settingsRow()
        .onAppear(perform: booster.refresh)
        .environment(\.locale, (FanBarLanguage(rawValue: languageRawValue) ?? .system).locale)
    }

    private var detail: String {
        booster.isInstalled
            ? "已加载 Root LaunchDaemon / Loaded：开机后 30 / 60 / 90 秒各强制冷启动一次风扇控制服务；插电 MacBook 或台式机顺带设为均衡曲线，90 秒后本次开机不再拉起。"
            : "未加载 / Not loaded：以管理员权限安装 UID=0 的 LaunchDaemon，开机后短窗口内强力唤起风扇控制服务，免于手动关开一次按指纹冷启动。"
    }
}
