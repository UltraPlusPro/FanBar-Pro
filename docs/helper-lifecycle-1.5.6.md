# 特权 Helper 生命周期（1.5.6）

本文记录 1.5.6 对「root Helper 开机不唤起」的根因判断、修复手段、以及每一种
注册方式的取舍。**结论先行**：无 Developer ID 的本地签名构建，`SMAppService`
写出的启动约束无法被任何代码满足，因此 1.5.6 让这种构建直接走 launchd 守护进程
（legacy）路径，并在安装脚本里做幂等清理，保证同一 label 只有一个注册。

---

## 1. 现象与证据

崩溃报告 `/Library/Logs/DiagnosticReports/local.fanbar.helper-2026-11-12-230400.ips`：

| 字段 | 值 |
| --- | --- |
| `exception` / `signal` | `EXC_CRASH` / `SIGKILL (Code Signature Invalid)` |
| `termination.namespace` | `CODESIGNING` |
| `termination.indicator` | `Launch Constraint Violation`（`code=4`） |
| `codeSigningTeamID` | `""`（空） |
| `uptime` | 35（开机约 35 秒） |
| `procPath` | `/Applications/FanBar Pro.app/Contents/Library/LaunchServices/local.fanbar.helper` |
| `parentProc` | `launchd` |

1.1.5 交付构建的签名状态：

```
$ codesign -dv "/Applications/FanBar Pro.app"                       → Signature=adhoc, TeamIdentifier=not set
$ codesign -dv ".../Contents/Library/LaunchServices/local.fanbar.helper" → Signature=adhoc, TeamIdentifier=not set
```

`launchctl print system/local.fanbar.helper` 里的启动约束（LWCR）：

```
LWCR = {
    "reqs" => { "cdhash" => { "$in" => [ 0 = ] } }   ← 空集合
    "vers" => 1
    "comp" => 1
    "ccat" => 0                                       ← 没有 team 分类
}
```

`cdhash.$in` 是空数组 ⇒ **没有任何代码能满足它**。`SMAppService` 在注册时依据父
app 的签名生成这条约束；app 没有 team（ad-hoc），于是它写出一条永远为假的约束。
注册当下 `kickstart`（IPC 触发）能起来，**下一次开机由 launchd 主动拉起时**约束
被求值 → `Launch Constraint Violation` → SIGKILL。这就是「装好能用，重启就掉」。

此外还存在**两个同 label 的注册**：

| 注册来源 | 程序路径 | 状态 |
| --- | --- | --- |
| `Contents/Library/LaunchDaemons/local.fanbar.helper.plist`（SMAppService，`submitted by smd`） | `Contents/Library/LaunchServices/local.fanbar.helper`（app 包内） | `state = running`，`parent bundle version = 115` |
| `/Library/LaunchDaemons/local.fanbar.helper.plist`（旧式遗留） | `/Library/PrivilegedHelperTools/local.fanbar.helper/...` | 同 label，开机时与上一条冲突 |

---

## 2. 1.5.6 的修复

### 2.1 统一签名（package-app.sh）

`scripts/package-app.sh` 现在接受 `FANBAR_SIGN_IDENTITY`，1.5.6 一律用
`Local QA Code Signing` 签 app、helper、CLI、诊断工具、widget appex 与 Sparkle
全部嵌套组件（由内到外）。app 与 helper 的 Authority 与 designated requirement
因此一致且跨重启稳定：

```
Authority=Local QA Code Signing
TeamIdentifier=not set          ← 本地证书没有 OU，仍无 team
```

> **Hardened Runtime 只在 Developer ID 构建启用。** 本地证书没有 team，
> hardened runtime 的 library validation 会拒绝加载 Sparkle（不同 team），
> 于是应用能启动却用不了更新框架。因此脚本改成
> `if identity == Developer ID Application:*` 才加 `--options runtime --timestamp`。

### 2.2 消除同 label 冲突（幂等清理）

`LegacyHelperDaemon.installCommand` 的第一步现在是清理，且**先删后写**：

```sh
launchctl bootout system/local.fanbar.helper 2>/dev/null   # 清掉任何在册注册（含 smd 提交的那条）
rm -f  /Library/LaunchDaemons/local.fanbar.helper.plist    # 旧式遗留 plist
rm -rf /Library/PrivilegedHelperTools/local.fanbar.helper  # 旧式遗留的根属副本目录
# 然后才 ditto → chown → codesign --verify --strict -R ... → printf plist → bootstrap
```

幂等性：每一步都是「删除不存在的东西也返回 0 / `2>/dev/null`」，重复执行结果相同；
任何一步失败，`&&` 链立刻中止且不写 plist（有单测覆盖）。

可审计性：脚本在三个节点调用 `/usr/bin/logger -t fanbar-helper`：
`install: removing previous registration` / `helper signature verified` /
`job bootstrapped`，可直接在 Console.app 里按子系统过滤。

### 2.3 注册自愈

| 时机 | 动作 | 是否需要管理员 |
| --- | --- | --- |
| 安装/升级后首次启用 | `register()` → 清理 → 写 plist → `bootstrap` | 是（一次） |
| 每次开机 | plist 里 `RunAtLoad=true`，launchd 主动拉起 helper | 否 |
| 每次 App 启动 | `prepareHelperAtLaunch()` → `launchctl print` 确认进程在；不在则 `kickstart -k` | 否（权限不足则记录并留给已授权的安装路径） |
| helper 异常退出 | `KeepAlive = { SuccessfulExit = false }`，launchd 自动重启 | 否 |
| 登录 | 已有的登录项（`SMAppService.mainApp` 或 `~/Library/LaunchAgents/local.fanbar.app.plist`）拉起 App，再由上一行自愈 | 否 |

### 2.4 兜底方案与取舍（重要，不要谎报）

| 方案 | 能否满足 launchd | 安全性 | 版本漂移 | 1.5.6 结论 |
| --- | --- | --- | --- | --- |
| A. `SMAppService` + Developer ID 签名 | 能 | 最好（team 约束 + 系统管理 UI） | 无 | **保留**，仅在 `OwnCodeSignature.teamIdentifier() != nil` 时走 |
| B. `SMAppService` + 本地/adhoc 签名 | **不能**（LWCR 空 cdhash） | — | — | **禁用**，并主动 `unregister()` 清掉旧注册 |
| C. legacy LaunchDaemon（`/Library/LaunchDaemons` + 根属副本） | 能（launchd 不校验签名） | 中：签名在**安装时**校验 | 拷贝可能落后于 app | **采用**（本机路径） |
| D. legacy LaunchDaemon 直接执行 app 包内 helper | 能 | 较低：root 执行用户可写的路径 | 无漂移 | 备选，未采用（见下） |

采用 C 而不是 D 的原因：上游 0.9.0 起就把 helper 复制到 root 拥有的目录并在复制
**之后**用 `codesign --verify --strict -R <requirement>` 校验，避免 root 运行用户
可写路径上的代码。1.5.6 保留这一性质。

C 的代价与缓解：

* 拷贝落后于 app（`parent bundle version` 漂移）——`prepareAtLaunch()` 比较
  `/Library/PrivilegedHelperTools/local.fanbar.helper/Contents/Info.plist` 的
  `CFBundleVersion` 与 app 自身的版本，不一致时置 `installedBuildIsStale` 并在
  状态行提示「请重新启用控制服务」；`FanController.migrateHelperIfNeeded()` 本来
  就会在版本变化后重注册。
* launchd 启动时不重新校验签名——安装时校验 + 目录 `root:wheel`、`chmod -R go-w`，
  且校验的 requirement 在无 team 时**钉住 helper 的叶证书 SHA-1**
  （`identifier "local.fanbar.helper" and certificate leaf = H"…"`），比 1.1.5 的
  「只比 identifier」更强。

### 2.5 未验证 / 已知限制

* **没有做真实重启验证**（本轮禁止重启机器）。已用 `launchctl bootout` +
  `kickstart -k` 模拟「注册在、进程不在 → 重新拉起」，但这不等价于开机时 launchd
  求值 LWCR。**「每次重启都能唤起」需要用户自行重启实测确认。**
* 本机无法在没有管理员密码的情况下执行安装脚本，因此 `codesign --verify -R` 之后
  的 `bootstrap` 只做了脚本级（沙箱单测）验证。
* 若日后换成 Developer ID 证书构建，代码会自动回到方案 A；切换时
  `registerService()` 会先 `unregister()` 旧 SMAppService 注册再装 launchd（或反之），
  不会留下两个同 label 注册。
