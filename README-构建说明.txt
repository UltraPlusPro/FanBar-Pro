================================================================================
  FanBar Pro 1.1.11 · 源码与 Xcode 工程 · 构建说明
================================================================================
  上游项目   helson-lin/FanBar（MIT）
  上游提交   c5525a74150f9d7fab0d19608e5b6f93b6a89adc（main）
  本版版本   1.1.11（CFBundleVersion 121）
  导出时间   2026-11-16
  签名身份   Local QA Code Signing（本地证书；1.1.6 起不再用 ad-hoc）
================================================================================

▲ 1.1.11 必读：构建顺序与两个 DMG 脚本的区别
--------------------------------------------------------------------------------
  本包可直接编译（swift build、Xcode ⌘B、一键编译.command 三种方式都可用），
  但「安装器」和「随附 DMG」是两步，不能一步到位：

    A. 只要主程序
       双击 一键编译.command            → build/FanBar Pro.app

    B. 要本次交付的那种 DMG（卡巴斯基风格安装器）
       1) 先产出主程序：一键编译.command
          （安装器会把已签名的主程序整包内嵌到 Contents/Resources/Payload/，
            所以没有主程序就打不出安装器，脚本只给一条警告）
       2) 再执行：
          cd Installer
          FANBAR_APP="$PWD/../build/FanBar Pro.app" bash make-fanbar-dmg.sh
       产物根目录只有两个条目：安装FanBarPro.app、卸载FanBarPro.app
       （外加本源码包 zip 与窗口背景，即交付镜像的样子）

    C. 要上游标准 DMG（App + Applications 链接，无安装器）
       双击 一键打包DMG.command        → build/FanBar-Pro-<版本>-arm64.dmg

  ▸ Installer/ 目录是安装器与卸载器的完整源码，含 root 安装引擎
    engine/install-core.sh。它的构建参数、引擎约束（禁止占位符模板替换等）
    见 Installer/README.txt。
  ▸ 所有构建脚本内均无硬编码绝对路径，解压到任何目录都能直接构建。

▲ 1.5.6 必读（相对 1.1.4/1.1.5 的构建差异）
--------------------------------------------------------------------------------
1. **不要用 ad-hoc 签名构建**。ad-hoc 的 app 没有 Team ID，SMAppService 会为
   helper 写下一条任何代码都满足不了的启动约束（`launchctl print` 里
   `LWCR … cdhash "$in" = [ ]`、`ccat = 0`），于是每次开机约 35 秒后 helper 被
   SIGKILL（Launch Constraint Violation）。这就是 1.1.5「开机不唤起」的根因。
   现在统一用 "Local QA Code Signing"：

       export FANBAR_SIGN_IDENTITY="Local QA Code Signing"
       export FANBAR_ARCHS=arm64
       export FANBAR_DISABLE_SWIFTPM_SANDBOX=1
       export FANBAR_APP_OUTPUT="build/FanBar Pro.app"
       zsh scripts/package-app.sh

   或直接双击 一键编译.command（它调用 脚本/构建-FanBar-Pro.command，参数同上）。

2. **不要把 `--deep` 当作校验手段**。Sparkle.framework 的 `Versions/B` +
   `Versions/Current` 软链布局会让 `codesign --verify --deep --strict` 报
   "bundle format is ambiguous" 并中止深度遍历。package-app.sh 已改为逐个嵌套
   组件 `--verify --strict`，再对 app 做一次非 deep 的 `--verify --strict`。

3. Hardened Runtime 只在 Developer ID 构建启用。本地证书没有 team，hardened
   runtime 的 library validation 会拒绝加载 Sparkle。

4. 细节见 变更说明-1.5.6.txt 与 docs/helper-lifecycle-1.5.6.md。

--------------------------------------------------------------------------------
以下为 1.1.4 时期的说明，构建路径与参数已按上面第 1、2 条更新，其余章节仍然适用。
--------------------------------------------------------------------------------


一、这份包里有什么
--------------------------------------------------------------------------------
  FanBar-Pro-1.1.11-源码与Xcode工程/
  ├─ README-构建说明.txt           ← 本文件
  ├─ 版本说明-FanBar-1.1.11.txt    ← 本版变更
  ├─ 一键编译.command              ← 双击即编译（推荐先试这个）
  ├─ 一键打包DMG.command           ← 双击产出上游标准 DMG
  ├─ FanBarPro.xcodeproj           ← Xcode 工程（双击可编译）
  ├─ Installer/                    ← 安装器 / 卸载器源码 + root 安装引擎 + 打 DMG 脚本
  │   ├─ README.txt                ←   构建参数与引擎约束
  │   ├─ build-installer.sh        ←   编译 安装FanBarPro.app / 卸载FanBarPro.app
  │   ├─ make-fanbar-dmg.sh        ←   产出交付用 DMG（安装器 + 卸载器）
  │   └─ engine/install-core.sh    ←   root 安装引擎（落位、服务注册、回滚）
  ├─ 脚本/
  │   └─ 构建-FanBar-Pro.command   ← 实际的编译 + 组装 + 签名脚本
  ├─ Package.swift / Package.resolved
  ├─ Sources/                      ← 全部 Swift 源码（8 个 target）
  ├─ Tests/                        ← 单元测试
  ├─ App/                          ← Info.plist、helper 的 LaunchDaemon plist
  ├─ Assets/                       ← 图标资源
  ├─ scripts/                      ← 上游构建脚本（含 package-app.sh）
  ├─ integrations/ WidgetExtension/ 等 ← 上游其余内容
  └─ README*.md / LICENSE / CONTRIBUTING.md 等 ← 上游文档

  为控制体积，已剔除以下与编译无关的内容（不影响任何构建路径）：
    .git/、.build/（编译缓存）、dist/、docs/screenshots/、docs/videos/、
    Assets/DMG/、.claude/


二、环境要求
--------------------------------------------------------------------------------
  · macOS 15.8 或更高（工程的最低部署目标是 15.8，见 Package.swift 与 App/Info.plist）
  · Xcode 16 或更高（本包在 Xcode 27.2 / Swift 6.4.2 上验证通过）
  · Apple Silicon（arm64）。脚本按 arm64 编译；要出通用二进制见第六节
  · 首次编译需要联网：要从 GitHub 拉 Sparkle 2.9.6（已锁定在 Package.resolved）

  命令行自检：
      xcode-select -p          # 应输出 /Applications/Xcode.app/Contents/Developer
      swift --version          # 应显示 Swift 6.x


三、三种编译方式（按推荐顺序）
--------------------------------------------------------------------------------
  A. 双击「一键编译.command」—— 最省事
     双击后会自动：检查工具链 → swift build → 组装 .app → ad-hoc 签名 → 输出到
     build/FanBar Pro.app。全程无需 Xcode 界面，约 1 分钟（视机器而定）。

  B. Xcode 直接打开 Package.swift —— 看代码、下断点用这个
     在 Xcode 里「File › Open…」选择本文件夹（或直接双击 Package.swift）。
     Xcode 会把 SwiftPM 包当作原生工程打开，左侧能看到 Sources 下全部源码，
     顶部 scheme 可选 FanBar / FanBarHelper / FanBarDiagnostics / FanBarCLI。
     按 ⌘B 编译、⌘R 运行（运行的是一个菜单栏程序，Dock 里不显示图标）。
     ▸ 注意：这种方式的产物是裸可执行文件，不带 .app 外壳，因此 helper 的
       LaunchDaemon 不会自动安装；要看完整功能请用 A 或 C。

  C. 双击「FanBarPro.xcodeproj」按 ⌘B —— 想要「有工程文件」的用法
     这个工程用的是 Xcode 的 External Build System 目标：Build 阶段会调用
     脚本/构建-FanBar-Pro.command，跟随 Xcode 当前选择的 Debug/Release 配置，
     产出同样是 build/FanBar Pro.app。
     已验证：xcodebuild -project FanBarPro.xcodeproj -scheme "FanBar Pro"
             -configuration Debug build  →  BUILD SUCCEEDED
     它的价值是在 Xcode 里保留「一个可 ⌘B 的工程」，同时绕开 Xcode 对包依赖
     的沙盒限制（见问题 1）。


四、命令行用法
--------------------------------------------------------------------------------
  ./脚本/构建-FanBar-Pro.command                # release + arm64 → build/FanBar Pro.app
  ./脚本/构建-FanBar-Pro.command --debug        # 编译更快，适合反复调试
  ./脚本/构建-FanBar-Pro.command --dmg          # 额外产出 DMG
  ./脚本/构建-FanBar-Pro.command --skip-build   # 跳过编译，只重新组装/签名
  ./脚本/构建-FanBar-Pro.command --open         # 完成后在访达中定位产物

  产物位置：
      build/FanBar Pro.app
      build/FanBar-Pro-1.1.11-arm64.dmg   （加 --dmg 时）


五、产物验证方法
--------------------------------------------------------------------------------
      /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
          "build/FanBar Pro.app/Contents/Info.plist"        # → 1.1.11
      codesign -v --deep --strict "build/FanBar Pro.app" && echo 签名OK
      lipo -info "build/FanBar Pro.app/Contents/MacOS/FanBar"   # → arm64

  本包导出时已实跑验证：
      swift build -c release                            → Build complete!（1.1.11 导出时实测 82s）
      swift build -c debug --disable-sandbox            → Build complete!
      xcodebuild -project FanBarPro.xcodeproj … build   → BUILD SUCCEEDED
      bash Installer/build-installer.sh                 → 两个 app 均编译并签名成功
      ▸ 上述验证均在「解压后的新路径」下进行，证明包内无硬编码绝对路径。


六、常见问题
--------------------------------------------------------------------------------
  1) 报错：sandbox-exec: sandbox_apply: Operation not permitted
     原因：SwiftPM 默认给编译过程套一层自己的沙盒，某些环境（含部分虚拟机、
           受管控的 CI 容器）不允许再嵌套一层。
     解决：所有命令都加 --disable-sandbox（本包的脚本已经默认加上了）。
           在 Xcode 里打开 Package.swift 若撞到同一个错误，改用方式 A 或 C。

  2) 报错：Failed to clone Sparkle / 一直卡在 Resolving package graph
     原因：首次编译要联网拉依赖。
     解决：确认能访问 github.com；或先执行
             swift package resolve --disable-sandbox
           若需完全离线编译，可把 Sparkle 2.9.6 源码放到本地，把 Package.swift
           里的 .package(url:) 改成 .package(path:)，见文件内注释。

  3) 编译通过但 helper 装不上 / 风扇一直是"不可用"
     原因：本包是 ad-hoc 签名，没有 Team ID，macOS 13+ 的 SMAppService 会拒绝
           注册内嵌 daemon。源码已改为自动回退到 legacy launchd（root
           LaunchDaemon），首次启用会弹一次管理员授权。
     如果仍失败：看 ~/Library/Logs 下 FanBar 相关日志，或跑一次
           build/FanBar Pro.app/Contents/MacOS/FanBarDiagnostics
     注意：ad-hoc 构建的鉴权是"降级信任模型"（只认 bundle identifier），
           能挡误连，挡不住有意为之的本地攻击者。要恢复强鉴权请用 Developer ID
           重签并把 helper 鉴权改回 Team 模式（见 FanBarHelperService.swift）。

  4) 双击 app 提示"无法打开，因为无法验证开发者"
     解决：右键 › 打开，或到「系统设置 › 隐私与安全性」点"仍要打开"。

  5) 菜单栏里没有 widget
     原因：widget 需要 App Group 授权，ad-hoc 签名无法认领（上游 Team ID 的
           能力）。不带 widget 时程序会优雅降级，其余功能不受影响。

  6) 想编译 Intel 版本
     脚本固定 --arch arm64。需要通用二进制时，把脚本里两处
     `--arch arm64` 换成 `--arch arm64 --arch x86_64`，或用
     scripts/package-app.sh 并设 FANBAR_ARCHS="arm64 x86_64"。

     注意：必须先准备一个真实的代码签名身份（Developer ID，或本机自签的
     代码签名证书，例如 "Local QA Code Signing"），用它设置
     FANBAR_SIGN_IDENTITY 后再构建。**ad-hoc 签名（FANBAR_SIGN_IDENTITY=-）
     已不再支持**，脚本会直接失败退出 —— ad-hoc 包的特权 Helper 无法通过
     launchd/XPC 认证，装得上但永远控制不了风扇。


七、代码地图（想改哪里看哪里）
--------------------------------------------------------------------------------
  场景自适应（本版新增）
      Sources/FanBar/AdaptiveModeCoordinator.swift
      Sources/FanBar/FanBarSettingsView.swift       ← 两个下拉的设置界面

  风扇控制与模式
      Sources/FanBar/FanController.swift
      Sources/FanBar/FanMenu.swift

  helper 安装与鉴权
      Sources/FanBar/FanBarServiceManager.swift     ← SMAppService → launchd 回退
      Sources/FanBar/LegacyHelperDaemon.swift       ← LaunchDaemon 安装与要求
      Sources/FanBarHelper/FanBarHelperService.swift ← 客户端鉴权（audit token）

  多语言
      Sources/FanBarShared/FanBarLocalization.swift ← 12 种语言的枚举与匹配
      Sources/FanBarShared/*Catalog.swift           ← 每种语言 645 条文案

  打包与签名
      脚本/构建-FanBar-Pro.command                  ← 本包提供的脚本
      scripts/package-app.sh                        ← 上游脚本（需 Developer ID）


八、许可与来源
--------------------------------------------------------------------------------
  · 上游 FanBar 采用 MIT 许可，见 LICENSE；本修改版同样遵循 MIT。
  · 第三方组件授权见 THIRD_PARTY_NOTICES.md 与 ThirdParty/ 目录。
  · 变更补丁仅包含对上游的修改（40 个已跟踪文件），新增的 9 个文件已完整包含在
    Sources/ 与 Tests/ 中，详见 变更说明-1.1.4.txt。

================================================================================
