import FanBarShared
import SwiftUI

/// The third Menu Bar decision: which CPU metric the readout prints. Kept as
/// its own row so it is judged separately from *what* is shown — and so no one
/// mistakes it for a change to the fan control input, which it is not.
struct MenuBarTemperatureLogicPicker: View {
    @AppStorage(FanBarLanguage.preferenceKey)
    private var languageRawValue = FanBarLanguage.defaultValue
    @AppStorage(MenuBarTemperatureSource.preferenceKey)
    private var sourceRawValue = MenuBarTemperatureSource.defaultSource.rawValue

    private var source: MenuBarTemperatureSource {
        MenuBarTemperatureSource(rawValue: sourceRawValue) ?? .defaultSource
    }

    var body: some View {
        HStack(spacing: 12) {
            SettingsRowText(
                title: fanBarText("温控逻辑", "Temperature logic"),
                detail: source.detail
            )
            .help(fanBarText(
                "只影响菜单栏显示的温度；风扇控制始终使用 SoC 平均温度。",
                "Affects the menu bar readout only; fan control always steers by the SoC average."
            ))
            Picker(fanBarText("温控逻辑", "Temperature logic"), selection: $sourceRawValue) {
                ForEach(MenuBarTemperatureSource.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .id(languageRawValue)
            .frame(minWidth: SettingsChrome.trailingControlMinWidth)
            .fixedSize()
        }
        .settingsRow()
        .environment(\.locale, (FanBarLanguage(rawValue: languageRawValue) ?? .system).locale)
    }
}
