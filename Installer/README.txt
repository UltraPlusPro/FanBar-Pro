FanBar Pro 1.1.11 · 卡巴斯基风格安装器 / 卸载器 源码
================================================================
本目录随源码包一起分发，用于重建 DMG 根目录里的两个 app：
  安装FanBarPro.app  —— 安装向导，主程序整包内嵌在 Contents/Resources/Payload/
  卸载FanBarPro.app  —— 独立卸载器（恒以「✓ 没有残留」收尾，永不显示失败）

文件分工
  安装器
    installer-main.swift      安装向导入口（AppKit，卡巴斯基式两段式流程）
    InstallerModel.swift      安装流程状态机 + 提权调用（osascript with administrator privileges）
    kask-ui.swift             共享视觉层（安装器与卸载器共用的卡片/进度/配色）
    engine/install-core.sh    ★ root 安装引擎（落位、服务注册、回滚逻辑都在这里）
  卸载器
    uninstaller-main.swift    卸载向导入口
    uninstall-shared.swift    卸载逻辑（宿主目录清理 + launchctl bootout）
  图标
    FanBarInstallerIcon.icns  安装器 app 图标：卡巴斯基外框 + 满覆盖的 FanBar Pro 本体
    ProductIcon.icns          FanBar Pro 本体图标（界面内产品图标）
    InstallerIcon.icns        卡巴斯基原版安装图标（备用）
    UninstallerIcon.icns      卸载器 app 图标 + 卸载器界面内产品图标
  构建
    build-installer.sh        编译并签名上面两个 app → out/
    make-fanbar-dmg.sh        调用上者后打 DMG（根目录只有安装器 + 卸载器两样）
    README.txt                本文件

构建（两步）
  # 1. 先产出主程序。任选其一：
  #    a) Xcode：打开仓库根的 FanBarPro.xcodeproj → Archive（Release / arm64）
  #    b) 命令行（等价于 Xcode 的 Release 构建）：
  cd ..                                        # 回到源码树根
  FANBAR_SIGN_IDENTITY="Local QA Code Signing" zsh scripts/package-app.sh
  #    产物：dist/FanBar Pro.app
  #
  # 2. 打安装器与 DMG（解压到任意目录都能跑，脚本内无硬编码路径）：
  cd Installer
  OUT="$PWD/out" bash build-installer.sh                            # 只出两个 app
  OUT="$PWD/FanBar-Pro-1.1.11-arm64.dmg" bash make-fanbar-dmg.sh    # 出完整 DMG

  主程序 payload 由 FANBAR_APP 决定，默认取 ../dist/FanBar Pro.app，也可显式指定：
      FANBAR_APP="/path/to/FanBar Pro.app" bash make-fanbar-dmg.sh

安装期登记的服务（由 engine/install-core.sh 以 root 执行）
  · local.fanbar.helper    特权 Helper（LegacyLaunchd 路径，不使用 SMAppService）
  · local.fanbar.coldstart 开机冷启动守护
  安装器把两项 plist 直接写入 /Library/LaunchDaemons 并 launchctl bootstrap，
  用户无需手工进「系统设置 → 登录项」。

安装引擎的硬性约束（构建期会校验，回潮即构建失败）
  · 只允许位置参数传路径，不允许出现 __FB_ 占位符模板替换 —— 旧方案会把引号
    带进变量值，导致「日志为空 + 退出码 1」。
  · 不使用 ${FB_LOG:-...} / ${FB_PAYLOAD:-...} 形式的默认值。
  · bash 3.2.57 在 UTF-8 locale 下会吞掉紧邻中文的字节，脚本变量一律写 ${VAR}。

离线 dry-run（不提权、不写系统目录，用于验证引擎逻辑）
  FB_ROOT=/tmp/sandbox-root FB_DRYRUN=1 bash engine/install-core.sh <日志路径> <payload 路径>

签名
  默认用 "Local QA Code Signing"；探测不到时退回 ad-hoc（--sign -）。
  生产分发请设置 FANBAR_SIGN_IDENTITY / FANBAR_DMG_SIGN_IDENTITY 为 Developer ID。

历史
  1.1.9 及更早使用 install-root.sh（占位符模板替换方案），已在 1.1.10 起被
  engine/install-core.sh（位置参数）取代。旧文件保留为 install-root.sh.1.1.9-已废弃
  仅供追溯，不参与构建。
