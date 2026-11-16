import AppKit
import FanBarShared
import SwiftUI

/// Settings panes. The selection persists so the window reopens where the
/// user left off. The native labeled toolbar navigation is installed by the
/// window presenter so content can use the full height below the title bar.
/// Case order is the toolbar order (and ⌘1…⌘5).
enum SettingsTab: String, CaseIterable, Identifiable {
    /// Primary task: smart cooling curve (see `.impeccable.md`).
    case cooling
    /// Raw value kept from the former "Menu Bar" pane so a saved selection survives.
    case appearance = "menuBar"
    case panel
    case general
    case log

    static let preferenceKey = "fanbar.settingsSelectedTab"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cooling: fanBarText("散热", "Cooling")
        case .appearance: fanBarText("菜单栏", "Menu Bar")
        case .panel: fanBarText("面板", "Panel")
        case .general: fanBarText("通用", "General")
        // "Log" reads like a developer tool; the tab is about looking back.
        case .log: fanBarText("记录", "History")
        }
    }

    var symbol: String {
        switch self {
        case .cooling: FanBarSymbols.fan
        case .appearance: "macwindow"
        case .panel: "rectangle.on.rectangle"
        case .general: "gearshape"
        case .log: "doc.text"
        }
    }
}

struct FanBarSettingsView: View {
    @ObservedObject var controller: FanController
    @AppStorage(MenuBarDisplayMode.preferenceKey)
    private var displayModeRawValue = MenuBarDisplayMode.defaultMode.rawValue
    /// Observed so the "Display content" copy can describe the metric it shows.
    @AppStorage(MenuBarTemperatureSource.preferenceKey)
    private var temperatureSourceRawValue = MenuBarTemperatureSource.defaultSource.rawValue
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue
    @AppStorage(SwitchFeedbackPreferences.preferenceKey)
    private var switchFeedbackAnimationEnabled = true
    @AppStorage(PanelAnimationPreferences.preferenceKey)
    private var panelAnimationEnabled = true
    @AppStorage(SettingsTab.preferenceKey)
    private var selectedTabRawValue = SettingsTab.cooling.rawValue
    @AppStorage(AdaptiveModeCoordinator.batteryDisconnectActionKey)
    private var batteryDisconnectActionRaw = AdaptiveCoolingTrigger.noChange.rawValue
    @AppStorage(AdaptiveModeCoordinator.fullscreenGameActionKey)
    private var fullscreenGameActionRaw = AdaptiveCoolingTrigger.noChange.rawValue

    private var displayMode: MenuBarDisplayMode {
        MenuBarDisplayMode.resolve(rawValue: displayModeRawValue)
    }

    private var temperatureSource: MenuBarTemperatureSource {
        MenuBarTemperatureSource(rawValue: temperatureSourceRawValue) ?? .defaultSource
    }

    private var currentTab: SettingsTab {
        SettingsTab(rawValue: selectedTabRawValue) ?? .cooling
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: currentTab == .general ? 24 : SettingsChrome.sectionSpacing) {
                switch currentTab {
                case .cooling: coolingTab
                case .appearance: menuBarTab
                case .panel: panelTab
                case .general: generalTab
                case .log: logTab
                }
            }
            .padding(.horizontal, SettingsChrome.horizontalPadding)
            .padding(.top, SettingsChrome.topPadding)
            .padding(.bottom, SettingsChrome.bottomPadding)
            .frame(width: SettingsChrome.contentWidth, alignment: .topLeading)
        }
        .frame(width: SettingsChrome.contentWidth)
        .background(Color(NSColor.windowBackgroundColor))
        // Invisible commands preserve fast keyboard navigation while the
        // visible controls live in AppKit's title-bar toolbar.
        .background(SettingsTabKeyboardShortcuts(selection: $selectedTabRawValue))
        .onChange(of: selectedTabRawValue) { _ in
            SettingsWindowPresenter.shared.resizeToFitContentSoon()
        }
        .environment(\.locale, (FanBarLanguage(rawValue: languageRawValue) ?? .system).locale)
    }

    // MARK: - Cooling

    @ViewBuilder
    private var coolingTab: some View {
        // Attention states only: when the service is healthy, the General
        // pane carries its status and the curve keeps the first position.
        if controller.helperState != .enabled {
            ControlServiceBanner(controller: controller)
            Button(fanBarText("查看本机兼容性…", "Check this Mac’s compatibility…")) {
                CompatibilityWindowPresenter.shared.show(controller: controller)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)
        } else if controller.compatibilitySnapshot?.fanCount == nil
            || controller.compatibilitySnapshot?.fanCount == 0 {
            compatibilitySection
        }
        CoolingPresetTiles(controller: controller)
        FanCurveEditorView(controller: controller)
        advancedCoolingSection
    }

    /// Conditional fan-mode automation: when the MacBook drops to battery or a
    /// full-screen game takes the foreground, FanBar temporarily switches the
    /// mode and restores the previous one afterward. Each row follows the same
    /// picker pattern as the other settings rows above.
    private var advancedCoolingSection: some View {
        SettingsSection(
            title: fanBarText("优化选项", "Advanced"),
            footer: fanBarText(
                "以上两项会在 MacBook 改用电池或前台出现全屏游戏时，临时切换风扇模式，并在条件结束后恢复此前的模式。",
                "The two options above temporarily switch the fan mode when your MacBook runs on battery or a full-screen game is frontmost, then restore the previous mode afterward."
            )
        ) {
            batteryDisconnectRow
            SettingsChrome.rowDivider
            fullscreenGameRow
        }
    }

    private var batteryDisconnectRow: some View {
        HStack {
            SettingsRowText(
                title: fanBarText("MacBook 拔电自动调整为…", "On battery, switch to…"),
                detail: fanBarText(
                    "断开交流电、改用电池时自动切换；重新接上后恢复。",
                    "Switches automatically when you unplug from AC power, and restores when you plug back in."
                )
            )
            Spacer(minLength: 12)
            Picker(
                fanBarText("MacBook 拔电自动调整为…", "On battery, switch to…"),
                selection: $batteryDisconnectActionRaw
            ) {
                ForEach(AdaptiveCoolingTrigger.allCases) { trigger in
                    Text(trigger.title).tag(trigger.rawValue)
                }
            }
            .labelsHidden()
            .id(languageRawValue)
            .frame(minWidth: SettingsChrome.trailingControlMinWidth)
            .fixedSize()
        }
        .settingsRow()
    }

    private var fullscreenGameRow: some View {
        HStack {
            SettingsRowText(
                title: fanBarText("检测到全屏游戏时，自动调整为…", "When a full-screen game is frontmost, switch to…"),
                detail: fanBarText(
                    "前台出现全屏游戏时自动切换；游戏退出后恢复。",
                    "Switches automatically when a full-screen game is frontmost, and restores when it quits."
                )
            )
            Spacer(minLength: 12)
            Picker(
                fanBarText("检测到全屏游戏时，自动调整为…", "When a full-screen game is frontmost, switch to…"),
                selection: $fullscreenGameActionRaw
            ) {
                ForEach(AdaptiveCoolingTrigger.allCases) { trigger in
                    Text(trigger.title).tag(trigger.rawValue)
                }
            }
            .labelsHidden()
            .id(languageRawValue)
            .frame(minWidth: SettingsChrome.trailingControlMinWidth)
            .fixedSize()
        }
        .settingsRow()
    }

    // MARK: - Menu bar

    @ViewBuilder
    private var menuBarTab: some View {
        // Icon and readout are one decision about the same status item, so
        // they share a card instead of two sections.
        SettingsSection(
            title: fanBarText("菜单栏", "Menu Bar"),
            footer: fanBarText(
                "选择 FanBar Pro 在菜单栏里的图标和显示内容。",
                "Choose FanBar Pro's icon and what it shows in the menu bar."
            )
        ) {
            // The strip shows the chosen icon and readout between system
            // items, so their combined width is judged in context.
            MenuBarPreviewStrip(controller: controller, displayMode: displayMode)

            MenuBarIconStylePicker(controller: controller)

            SettingsChrome.rowDivider

            HStack(spacing: 12) {
                SettingsRowText(
                    title: fanBarText("显示内容", "Display content"),
                    detail: displayMode.detail(temperatureSource: temperatureSource)
                )
                Picker(fanBarText("显示内容", "Display content"), selection: $displayModeRawValue) {
                    ForEach(MenuBarDisplayMode.allCases) { mode in
                        Text(mode.title(temperatureSource: temperatureSource)).tag(mode.rawValue)
                    }
                }
                .labelsHidden()
                // The pop-up caches its item titles, so it is rebuilt whenever
                // the language *or* the temperature logic changes.
                .id("\(languageRawValue)-\(temperatureSourceRawValue)")
                .fixedSize()
            }
            .settingsRow()

            SettingsChrome.rowDivider

            // Independent of "Display content": the same readout can follow
            // either CPU metric. Nothing here reaches the fan control input.
            MenuBarTemperatureLogicPicker()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(fanBarText("菜单栏", "Menu Bar"))

        MenuBarResourceSettings(controller: controller)

        SettingsSection(title: fanBarText("动画", "Animation")) {
            Toggle(isOn: $switchFeedbackAnimationEnabled) {
                SettingsRowText(
                    title: fanBarText("菜单栏图标动画", "Menu bar icon animation"),
                    detail: fanBarText(
                        "风扇运转时图标旋转并跟随实际转速，停转后缓缓静止。",
                        "The icon spins with the fans and coasts to a stop when they halt."
                    )
                )
            }
            .toggleStyle(.switch)
            .settingsRow()
        }
    }

    // MARK: - Panel

    @ViewBuilder
    private var panelTab: some View {
        PanelMonitorSettingsSection()
            .id(languageRawValue)

        SettingsSection(title: fanBarText("动画", "Animation")) {
            Toggle(isOn: $panelAnimationEnabled) {
                SettingsRowText(
                    title: fanBarText("主界面动画", "Panel animation"),
                    detail: fanBarText(
                        "主界面的风扇转动与模式切换过渡。关闭后仍实时显示转速。",
                        "Spinning fans and mode transitions in the menu bar panel. RPM readings still update live."
                    )
                )
            }
            .toggleStyle(.switch)
            .settingsRow()
        }
    }

    // MARK: - General

    /// CSV logging of temperatures and fan speeds; see docs/design/temperature-logging.md.
    private var logTab: some View {
        TemperatureLogSettingsView(controller: controller)
    }

    @ViewBuilder
    private var generalTab: some View {
        // Control → alerts → the app → power-user tools; see docs/design/settings-general.html.
        GeneralStatusHeader(controller: controller)
        fanControlSection
        NotificationSettingsSection(controller: controller)
        appSection
        ToolIntegrationsSection()
        freeSoftwareNotice
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
    }

    private var compatibilitySection: some View {
        SettingsSection(
            title: fanBarText("设备兼容性", "Device Compatibility"),
            footer: fanBarText("检测在本机完成，不会自动上传设备信息。", "Checks run locally. Device information is not automatically uploaded.")
        ) {
            Button {
                CompatibilityWindowPresenter.shared.show(controller: controller)
            } label: {
                HStack(spacing: 16) {
                    SettingsRowText(
                        title: fanBarText("本机能力与兼容性", "This Mac’s capabilities and compatibility"),
                        detail: controller.compatibilitySnapshot?.summary
                            ?? fanBarText("查看本机可用功能。", "See which features are available on this Mac.")
                    )
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
                }
                .settingsRow()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// How long manual modes last and whether to be warned first: both are
    /// about handing control back, so they share one section.
    private var fanControlSection: some View {
        SettingsSection(
            title: fanBarText("交还给 macOS", "Hand Back to macOS")
        ) {
            automaticRestoreRow
            SettingsChrome.rowDivider
            resumeCurveRow
            SettingsChrome.rowDivider
            HandBackReminderRow(controller: controller)
        }
    }

    /// App-level preferences that are set once and rarely revisited.
    private var appSection: some View {
        SettingsSection(title: "FanBar Pro") {
            launchAtLoginRow
            SettingsChrome.rowDivider
            languageRow
            SettingsChrome.rowDivider
            helperDropNotificationRow
            SettingsChrome.rowDivider
            AppIconPickerRow()
        }
    }

    /// The one alert about the control service itself: when it disappears the
    /// fans silently go back to macOS, so the user is told once.
    private var helperDropNotificationRow: some View {
        Toggle(
            isOn: Binding(
                get: { controller.notifyOnHelperDrop },
                set: { controller.setNotifyOnHelperDrop($0) }
            )
        ) {
            SettingsRowText(
                title: fanBarText("风扇控制服务掉线时通知我", "Notify me if the fan control service stops"),
                detail: fanBarText(
                    "服务意外退出时提醒一次；你主动交还控制时不会提醒。",
                    "One alert if the service exits unexpectedly; handing control back yourself never alerts."
                )
            )
        }
        .toggleStyle(.switch)
        .settingsRow()
        .help(fanBarText(
            "掉线后风扇会交回 macOS 自动控制，通知里可直接回到通用设置重新启用。",
            "After a drop the fans return to macOS control; the notice points you back to General to re-enable it."
        ))
    }

    private var launchAtLoginRow: some View {
        Toggle(
            isOn: Binding(
                get: { controller.launchAtLoginEnabled },
                set: { controller.setLaunchAtLogin($0) }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                SettingsRowText(title: fanBarText("登录时启动", "Launch at login"))
                if controller.launchAtLoginRequiresApproval {
                    Button(fanBarText("等待系统批准 · 打开设置", "Waiting for approval · Open Settings")) {
                        controller.openLoginItemSettings()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.orange)
                }
            }
        }
        .toggleStyle(.switch)
        .settingsRow()
    }

    private var automaticRestoreRow: some View {
        HStack {
            SettingsRowText(
                title: fanBarText("手动模式持续", "Manual modes last"),
                detail: fanBarText("到时由 macOS 接管", "Then macOS takes over")
            )
            .help(fanBarText("主界面中的修改只对当次生效。", "Changes made in the menu apply to that session only."))
            Spacer(minLength: 12)
            Picker(
                fanBarText("手动模式持续", "Manual modes last"),
                selection: Binding(
                    get: { controller.defaultAutomaticRestoreDuration },
                    set: { controller.setDefaultAutomaticRestoreDuration($0) }
                )
            ) {
                ForEach(FanController.AutomaticRestoreDuration.allCases) { duration in
                    Text(duration.title).tag(duration)
                }
            }
            .labelsHidden()
            .id(languageRawValue)
            .frame(minWidth: SettingsChrome.trailingControlMinWidth)
            .fixedSize()
        }
        .settingsRow()
    }

    /// Replays the manual mode a login or restart interrupted. Sits with the
    /// hand-back rows because both describe what happens to a manual session.
    private var resumeCurveRow: some View {
        Toggle(
            isOn: Binding(
                get: { controller.resumeLastCurveOnLaunch },
                set: { controller.setResumeLastCurveOnLaunch($0) }
            )
        ) {
            SettingsRowText(
                title: fanBarText(
                    "重启自动恢复自定义风扇曲线",
                    "Resume the custom fan curve after a restart"
                ),
                detail: fanBarText(
                    "登录或重启后自动沿用上次的风扇曲线（静谧、均衡、性能、极速或自定义预设），仍遵循上面的手动模式持续设定。",
                    "Reapply the last fan curve (Silent, Balanced, Performance, Extreme or a custom preset) after a login or restart. The manual-mode duration above still applies."
                )
            )
        }
        .toggleStyle(.switch)
        .settingsRow()
    }

    private var languageRow: some View {
        HStack {
            Text(fanBarText("界面语言", "Interface language"))
            Spacer(minLength: 12)
            Picker(
                fanBarText("界面语言", "Interface language"),
                selection: Binding(
                    get: { languageRawValue },
                    set: {
                        languageRawValue = $0
                        SettingsWindowPresenter.shared.updateTitle()
                    }
                )
            ) {
                ForEach(FanBarLanguage.allCases) { language in
                    Text(language.title).tag(language.rawValue)
                }
            }
            .labelsHidden()
            .id(languageRawValue)
            .frame(minWidth: SettingsChrome.trailingControlMinWidth)
            .fixedSize()
        }
        .settingsRow()
    }

    private var freeSoftwareNotice: some View {
        SettingsSupportFooter()
    }
}

/// One quiet line at the foot of the General tab: FanBar is free and open
/// source, then the tip button, which opens the bundled tip window.
struct SettingsSupportFooter: View {
    /// Read so the footer repaints when the interface language changes.
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue

    var body: some View {
        HStack(spacing: 0) {
            // Match the button's 8pt inset so the dots sit evenly between items.
            Text(fanBarText("FanBar Pro 免费开源", "FanBar Pro is free and open source"))
                .padding(.trailing, 8)
            separator
            // Opens the local tip window, not a browser: the payment codes ship
            // inside the bundle and the window works offline.
            SettingsFooterButton(
                title: fanBarText("支持开发", "Support"),
                help: fanBarText(
                    "随意付，用于签名证书与维护。打赏窗口会直接打开",
                    "Pay what you want toward signing and upkeep. Opens the tip window."
                )
            ) {
                Image(systemName: "heart")
            } action: {
                SupportTipWindowPresenter.shared.show()
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .lineLimit(1)
        .fixedSize()
        .frame(maxWidth: .infinity)
    }

    private var separator: some View {
        Text("·").accessibilityHidden(true)
    }
}

/// Pages FanBar can open in the browser. Both entries are kept deliberately
/// after 1.1.7 dropped their last in-app link: they are the canonical URLs the
/// support copy, the release notes and the update feed refer to, so they stay
/// here as documented constants rather than being re-typed at each call site.
enum FanBarLinks {
    /// The project home. The General footer no longer links to it — the "Star
    /// on GitHub" row was removed in 1.1.7 — but it stays as the canonical URL
    /// the support copy and the update feed refer to.
    static let repository = URL(string: "https://github.com/helson-lin/FanBar")!
    /// Dodo Payments checkout for donations. The footer's primary tip action
    /// opens the local window and the tip window itself now offers only the
    /// bundled payment codes, so nothing links here in 1.1.7. Kept on purpose
    /// as the address support replies and the release notes quote; re-adding a
    /// "pay by card" entry needs no new URL.
    static let donation = URL(string: "https://checkout.dodopayments.com/buy/pdt_0NqThcy5f4slzzZQspCty?quantity=1")!
}

/// A caption-sized footer action that runs in-app instead of navigating. It is
/// the only footer entry 1.1.7 has left (`SettingsFooterLink` went with the
/// browser checkout row), and a click opens a window rather than a browser tab.
struct SettingsFooterButton<Icon: View>: View {
    let title: String
    let help: String
    @ViewBuilder let icon: () -> Icon
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                    .accessibilityHidden(true)
                Text(title)
                Image(systemName: "arrow.up.forward.app")
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundColor(isHovered ? .accentColor : .secondary)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// Shown on the Cooling pane only when the control service needs attention,
/// with the state named by symbol and text rather than color alone.
struct ControlServiceBanner: View {
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue

    @ObservedObject var controller: FanController

    var body: some View {
        let state = controller.helperState
        HStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 18))
                .foregroundColor(state.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.noticeTitle)
                    .font(.system(size: 13, weight: .semibold))
                Text(fanBarFormat(
                    "曲线已保存，服务可用后才会生效。%@。",
                    "Your curves are saved and apply once the service is available. %@.",
                    state.noticeDetail
                ))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle = state.actionTitle {
                Button(actionTitle, action: controller.performHelperAction)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCornerRadius, style: .continuous)
                .fill(state.tint.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCornerRadius, style: .continuous)
                .stroke(state.tint.opacity(0.4), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .environment(\.locale, (FanBarLanguage(rawValue: languageRawValue) ?? .system).locale)
    }
}

/// Turns the one-minute warning and the hand-back notification on or off.
private struct HandBackReminderRow: View {
    /// Repaints the copy when the interface language changes.
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue
    @ObservedObject var controller: FanController

    var body: some View {
        Toggle(
            isOn: Binding(
                get: { controller.handBackRemindersEnabled },
                set: { controller.setHandBackRemindersEnabled($0) }
            )
        ) {
            SettingsRowText(
                title: fanBarText("交还前提醒", "Remind before hand-back"),
                detail: fanBarText("结束前 1 分钟提醒，可以直接延长", "One minute before, with a button to extend")
            )
        }
        .toggleStyle(.switch)
        .settingsRow()
        .help(fanBarText(
            "没有处理时，交回后再提示一次；面板开着时只在面板里显示。",
            "If nothing changes, once more after the hand-back. With the panel open, it shows there instead."
        ))
    }
}

/// High-temperature alerts and hand-back reminders.
private struct NotificationSettingsSection: View {
    /// Repaints the copy when the interface language changes.
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue
    @ObservedObject var controller: FanController

    var body: some View {
        SettingsSection(title: fanBarText("高温提醒", "High-temperature alerts")) {
            Toggle(
                isOn: Binding(
                    get: { controller.highTemperatureNotificationsEnabled },
                    set: { controller.setHighTemperatureNotificationsEnabled($0) }
                )
            ) {
                SettingsRowText(
                    title: fanBarText("温度过高时通知我", "Notify me when it gets too hot"),
                    detail: fanBarText("同一次高温只提醒一次", "Once per hot spell")
                )
            }
            .toggleStyle(.switch)
            .help(fanBarText(
                "降温后重置。面板会同时显示过热提示。",
                "Resets after cooling down. The panel shows the same warning."
            ))
            .disabled(controller.isRequestingHighTemperatureNotificationPermission)
            .settingsRow()

            SettingsChrome.rowDivider

            thresholdRow

            SettingsChrome.rowDivider

            ThermalAlertSoundRow(controller: controller)
        }
    }

    /// Inline stepper: reachable by keyboard and VoiceOver without a
    /// disclosure step, and matches the curve editor's Advanced rows.
    private var thresholdRow: some View {
        let range = ThermalAlertSettings.thresholdRange
        let value = controller.highTemperatureThresholdCelsius
        let valueText = String(format: "%.0f°C", value)
        return HStack {
            SettingsRowText(title: fanBarText("提醒温度", "Alert temperature"))
                .help(fanBarFormat(
                    "默认 %.0f°C；面板和曲线上的告警线使用同一数值。",
                    "Default %.0f°C. The panel and the curve's alert line use the same value.",
                    ThermalAlertSettings.defaultThresholdCelsius
                ))
            Spacer(minLength: 12)
            Stepper(
                value: Binding(
                    get: { Int(controller.highTemperatureThresholdCelsius.rounded()) },
                    set: { controller.setHighTemperatureThreshold(Double($0)) }
                ),
                in: Int(range.lowerBound)...Int(range.upperBound)
            ) {
                // Red, because this number *is* the alert: it reads as a limit
                // rather than as another adjustable value. `.systemRed` follows
                // Increase Contrast and both appearance modes; the panel's
                // warmer palette would not say "alert" at a glance.
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundColor(Color(nsColor: .systemRed))
                    .frame(width: 40, alignment: .trailing)
            }
            .fixedSize()
            .accessibilityLabel(fanBarText("提醒温度", "Alert temperature"))
            .accessibilityValue(valueText)
        }
        .settingsRow()
        .disabled(!controller.highTemperatureNotificationsEnabled)
    }
}
