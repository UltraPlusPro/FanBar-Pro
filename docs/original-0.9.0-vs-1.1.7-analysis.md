FanBar 原版 0.9.0 对照分析
===========================

对照对象：FanBar 0.9.0 官方发布包（分析时使用本地临时解压副本）
本分支：FanBar Pro 1.1.7（117）
结论口径：只写**有代码证据**的项。无法从代码确认的写「未发现证据」。

================================================================
一、原版 0.9.0 既有缺陷
================================================================

【A1】温度口径不一致：托盘显示「最热核」，面板/告警显示「平均」
  证据（0.9.0）
    Sources/FanBar/SMCClient.swift:81
        var cpuDisplayCelsius: Double? { cpuHottestCelsius ?? cpuCelsius }
    Sources/FanBar/MenuBarDisplay.swift:92
        controller.temperatureHistory.last?.cpuDisplayCelsius   ← 托盘
    Sources/FanBar/FanController.swift:2301, 2320
        cpuCelsius: thermal.cpuDisplayCelsius                   ← 同时也喂给
        cpuCelsius: temperatureHistory.last?.cpuDisplayCelsius     曲线/告警/Widget
  缺陷
    `cpuDisplayCelsius` 把「最热核」写进名为 `cpuCelsius` 的字段，于是**同名字段
    在不同调用点代表不同传感器**。托盘读到的是最热核（偏高、逐样本跳），
    曲线和告警读到的也是它，但设置窗口的「当前」按平均值描述自己。
    用户看到的现象就是「托盘 63°，设置里 55°」。
  本分支状态
    已在 1.5.6 修：`cpuDisplayCelsius = cpuCelsius ?? cpuHottestCelsius`
    （SMCClient.swift:87），并把「菜单栏该显示哪一路」变成**显式设置**
    （1.1.7 的温控逻辑 Picker），默认回到平均，与曲线/告警同源。
    控制输入永远用平均，最热核只作为显示选项。
    测试：MenuBarTemperatureSourceTests 断言同一样本下
    menuBar(.socAverage)=61 / menuBar(.hottestCore)=78 / displayTemperatureCelsius=61。

【A2】Helper 掉线完全静默，用户无从得知
  证据（0.9.0）
    Sources/FanBar/HelperClient.swift:355-361
        invalidationHandler / interruptionHandler 只调 clearConnection，
        仅把 `connection` 置 nil，不做任何上报。
    Sources/FanBar/HelperClient.swift:400-408
        invalidateConnection() 只回调 onConnectionReset（用于重新应用模式），
        没有「服务消失」的通知路径。
    全仓库 grep `healthCheckIfStale` → 0 处；`prepareAtLaunch` → 0 处。
    Sources/FanBar/HelperJobInspector.swift → 文件不存在。
  缺陷
    特权 helper 被 launchd 杀死、崩溃或被系统移走后，app 侧唯一的迹象是
    「下一次写风扇会失败」。在此之前用户看到的一切都正常，风扇却已经回到
    macOS 控制 —— 这正是最难自行诊断的一类故障。
  本分支状态
    1.1.7 新增 HelperDropNotification：XPC invalidation/interruption 与
    探测超时都会上报 → 弹一次系统通知（10 分钟冷却，启动后 20 秒静默，
    用户主动交还/退出/迁移时不弹）。同时 1.5.6 已有的 healthCheckIfStale
    轻量探活 + prepareHelperAtLaunch 启动自愈继续生效。

【A3】构建脚本允许 ad-hoc 签名，而 ad-hoc 必然让 helper 无法鉴权
  证据（0.9.0）
    scripts/package-app.sh:19-27
        FANBAR_SIGN_IDENTITY=- 时，只要 FANBAR_ALLOW_ADHOC=1 就继续构建，
        仅打印一行警告。
    scripts/package-app.sh:217
        注释承认 ad-hoc 构建「cannot load Sparkle」。
  缺陷
    这是「能装、能开、但开机后 helper 被 SIGKILL」的直接成因链起点：
    ad-hoc 无 Team ID → SMAppService 生成不可满足的启动约束
    （`LWCR … cdhash "$in" = [ ]`）→ 下次开机 35 秒后
    `EXC_CRASH (SIGKILL, Launch Constraint Violation)`。
  本分支状态
    1.1.7 起 ad-hoc 是**硬失败**：identity 为空或 `-` 直接 exit 2，且签名前
    用 `security find-identity` 校验身份真实存在。已实测三种非法输入均 exit 2
    且不产出产物。

【A4】三个语言 catalog 无测试，错误格式符可悄悄上线
  证据（0.9.0）
    Tests/FanBarTests/ 下只有 FrenchCatalogTests / JapaneseCatalogTests /
    RussianCatalogTests 三个 catalog 测试。
    0.9.0 的 catalog 集合本身也只有这三个（+ 中文走转换器），因此 0.9.0 内部
    自洽 —— **这一项在 0.9.0 里不是现存缺陷**，而是「测试覆盖的缺口」。
  说明
    真正的错误格式符是在本项目 1.1.x 线新增 Portuguese/Ukrainian/Vietnamese
    三个 catalog 时引入的（`%,0f`、`.0f%%`），因为没有对应测试文件而一路通过
    构建。归属见第二节 B1，不记在 0.9.0 头上。

【A5】未发现证据的项
    · helper 生命周期、签名、温度、语言、设置这五块，除上述 A1–A3 外，
      未在 0.9.0 代码中发现其它可确证的缺陷。
    · 0.9.0 的 `SettingsSupportFooter` 有两个链接（Star on GitHub + 支持开发），
      这是产品选择，不是缺陷。

================================================================
二、本分支（1.1.7）新增缺陷 —— 开发过程中发现并已修复
================================================================

【B1】Portuguese / Ukrainian / Vietnamese catalog 里 11 条错误格式符
  证据（修复前）
    PortugueseCatalog.swift:278-282   "%.0f°C · %.0f%%" → "%,0f°C · %,0f%%"
                                      "%@ %.0f°C"      → "%@ %,0f°C"
    UkrainianCatalog.swift:278,284    同上
    VietnameseCatalog.swift:278,284   "%.0f°C · %.0f%%" → "%.0f°C · .0f%%"
  影响
    `%,0f` 不是合法格式符（`%` 后跟 `,` 会被当字面量，数值改用错位参数），
    `.0f%%` 少一个 `%` 会多消费一个参数。三者都不会在编译期报错。
  修复
    改为与英文逐位一致的格式符（只改格式符，不改译文语义）。
    新增 CatalogFormatCoverageTests 对全部 11 种语言做统一校验；
    新增 PortugueseCatalogTests；这是本版最重要的一条防回归。

【B2】catalog 生成器重复追加同键（开发过程中的自伤，未进入产物）
  证据
    反复运行增量脚本后，11 个 catalog 各出现 55–58 个**重复键**。
    Swift 对同字典字面量里的重复键不会编译报错，大型字面量会在运行期 trap。
  修复
    · 增量脚本改为幂等（先删同键旧条目再写）
    · CatalogFormatCoverageTests.testNoCatalogRepeatsAKey 直接扫描源码文本，
      保证这类回归不可能再悄悄通过
    · 修复后复核：11 个 catalog 全部 dupes=0 / miss=0 / stale=0 / spec=0

【B3】设置页脚加第三项后乌克兰语超出可用宽度
  证据
    SettingsSupportFooterTests 报
      Ukrainian: 520.0pt > 512.0pt（availableWidth）
  修复
    页脚保持「免费开源 · 支持开发」两项；浏览器打赏改为打赏窗口内的次要入口。
    所有 11 种语言现在都能单行。

【B4】打赏按钮英文标签被截断
  证据
    渲染截图显示 "Save payment cod…"（420pt 宽窗口放不下
    "Save payment code…" + "Copy payment code" + "Close"）
  修复
    标签缩短为 Save… / Copy / Close，渠道名移到 accessibilityLabel
    （「保存微信收款码」「复制微信收款码」），信息不丢失。

【B5】打赏二维码按原图纵横比固定宽度，窗口过高
  证据
    原图为竖版（1656×2256，1:1.36）。按 300pt 宽度算，高度约 408pt，
    窗口整体约 640pt 高。
  修复
    改为在一个 300×300 的方框内 scaledToFit，窗口高度降到约 560pt。

================================================================
三、结论
================================================================
· 原版 0.9.0 的既有缺陷集中在**温度口径（A1）**与**helper 掉线静默（A2）**，
  以及构建脚本允许 ad-hoc 这一**因果起点（A3）**。三项在本分支均已修复，
  且都有测试或可复现的验证手段。
· 本分支 1.1.7 开发期引入的缺陷（B1–B5）全部在提交前发现并修复，
  其中 B1（11 条错误格式符）与 B2（重复键）属于「不报错但会崩/会错」的类型，
  已各自补上防回归测试。
· 未在 0.9.0 中发现的候选项一律写「未发现证据」，不做推测。
