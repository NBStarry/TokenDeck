# TokenDeck · AI 用量控制台

<p align="center">
  <a href="https://www.apple.com/macos/"><img alt="macOS 13+" src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white"></a>
  <a href="https://www.swift.org/"><img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white"></a>
  <a href="https://v2.tauri.app/"><img alt="Tauri 2" src="https://img.shields.io/badge/Tauri-2-24C8DB?logo=tauri&logoColor=white"></a>
  <a href="https://developer.android.com/about/versions/nougat"><img alt="Android 7+" src="https://img.shields.io/badge/Android-7%2B-3DDC84?logo=android&logoColor=white"></a>
</p>

<p align="center">
  <a href="#启动"><strong>▶ 快速开始</strong></a>
  &nbsp;·&nbsp;
  <a href="#界面"><strong>🖼️ 界面预览</strong></a>
  &nbsp;·&nbsp;
  <a href="tauri/README-android.md"><strong>📱 Android 构建</strong></a>
</p>

TokenDeck 把 **macOS 原生菜单栏看板**、**Windows 系统托盘客户端**和 **Android App / 主屏小组件**
放在同一套工程中，统一查看 Claude、Codex 与 New-API 兼容渠道的订阅窗口、余额和历史消耗。

macOS 端负责读取本机持续更新的登录凭证并聚合用量；Android 端可通过 Tailscale 连接 Mac
上的中转服务，避免在手机侧重复处理 OAuth、代理与凭证刷新。

## 启动

### macOS

```bash
./build-app.sh
open TokenDeck.app

# 建议安装到稳定路径后再开启“开机自启”
cp -R TokenDeck.app /Applications/
open /Applications/TokenDeck.app
```

`build-app.sh` 会执行 Release 编译、组装 `TokenDeck.app`、嵌入图标并完成
ad-hoc 签名。菜单栏图标右键可开启基于 `SMAppService` 的开机自启。

从旧名 `TokenUsageDashboard.app` 升级时，先在旧 App 中关闭开机自启并退出，再安装
`TokenDeck.app`，最后重新开启一次开机自启。两者沿用同一 Bundle ID，但不应同时保留为登录项。

### Windows

```powershell
cd tauri
npm install
npm run tauri dev

# 生产构建
npm run tauri build
```

构建产物为 NSIS 安装包。Windows 工具链、配置路径和凭证位置见
[tauri/README.md](tauri/README.md)。

### Android

```bash
cd tauri
npm install
npx tauri android build --debug --target aarch64
```

Android SDK、NDK、签名包、国内网络和真机运行说明见
[tauri/README-android.md](tauri/README-android.md)。

## 能力

- **订阅窗口**：Claude / Codex 展示用量、百分比和重置时间；macOS Codex 按接口实际窗口时长识别 5 小时或周额度。
- **macOS 重置机会**：各 Codex 账号显示剩余额度重置次数、当前套餐适用次数和每次机会的本地到期时间（按到期先后排列）。只读展示，不消耗次数；明细请求失败时保留用量与摘要次数，并提示到期明细暂不可用。
- **macOS 多账户**：保存任意数量的 Codex 订阅账号，当前登录账号自动置顶；凭证副本保存在钥匙串。
- **API 渠道**：New-API 兼容网关展示余额、历史消耗、请求次数和按来源分组的模型列表。
- **macOS API 扩展**：DeepSeek 按币种显示总余额、充值余额和赠金余额；易云 TokenFactory 显示密钥查询状态和授权模型，暂不提供额度查询。
- **macOS OpenRouter**：设置中安全保存 Key；普通 Key 展示自身用量与剩余额度，管理 Key 展示账户余额，金额为 USD。
- **macOS 单渠道刷新**：每张卡片右上角可独立刷新，显示进度并防止重复请求。
- **状态回退**：后台定时刷新；取数失败时显示上次成功缓存并标记异常。
- **分级告警**：5 小时与周窗口可独立设置阈值和规则，触发系统通知与菜单栏告警角标。
- **显示定制**：控制渠道开关、卡片顺序、颜色和卡片内展示字段。
- **开机自启**：macOS 使用 `SMAppService`，Windows 使用 `tauri-plugin-autostart`。
- **Mac 手机中转**：Mac 在 `8787` 端口提供带 Bearer 鉴权的用量快照，手机经 Tailscale 拉取。
- **Android 小组件**：每个小组件实例可绑定一个渠道，在主屏显示窗口进度或 API 余额。

## 界面

以下为旧版单账号界面示意；新版增加多账户列表和固定顶部导航。

| 用量面板 | 显示设置 |
| --- | --- |
| ![TokenDeck 用量面板](Docs/Images/token-usage-dashboard-popover.png) | ![TokenDeck 显示设置](Docs/Images/token-usage-dashboard-settings.png) |

- **菜单栏 / 系统托盘**：常驻图标显示当前最高告警级别。
- **主面板**：每个服务一张卡片，macOS 的 Codex 按账号分别展示；订阅型展示进度窗口，API 型展示余额与模型。
- **设置页**：配置账号、告警、渠道顺序、展示字段及 Mac 手机中转二维码；macOS 顶部“完成”固定可见，正文可滚动。
- **移动端**：全屏显示同一套卡片，并提供手动刷新、凭证录入和中转配置。

## 操作

- macOS 左键菜单栏图标：展开或收起用量面板。
- macOS 右键菜单栏图标：立即刷新、切换开机自启或退出。
- 点击面板中的“设置”：调整告警规则、渠道开关、顺序和展示字段。
- 手机端扫描 Mac 设置页二维码：写入 Tailscale 中转地址与密钥并立即验证连接。
- Android 长按桌面添加小组件：选择要固定展示的渠道。

进度条颜色固定为：`<75%` 绿色、`75%–90%` 琥珀色、`≥90%` 红色。

### macOS 添加多个 Codex 账号

1. 打开 TokenDeck → 设置 → **添加账号**。
2. App 打开独立登录窗口并自动唤起浏览器，在官方页面选择账号完成登录。
3. 登录成功后自动保存账号并刷新用量，无需命令行、导入文件或填写备注。

账号名采用官方名称，缺失时使用邮箱或短身份摘要。同一账号再次登录只更新凭证，不重复添加。
过期账号点击 **重新登录**；必须登录原账号，否则提示不匹配。登录等待最多五分钟，可取消或重试；
保存失败可直接重试保存，无需重新登录。菜单栏弹窗关闭不会中断独立登录窗口，关闭登录窗口会取消本次任务。

需要本机已安装 Codex CLI；App 自动查找常用安装位置，找不到时可选择程序或打开官方安装说明。
添加／重新登录使用私有临时登录目录，不运行 logout、不改变默认 Codex 登录。临时文件在流程结束后清理，
完整登录凭证（含续期令牌）存入钥匙串。“其他添加方式”保留当前登录添加和目录/JSON 导入入口。

### 切换 Codex CLI 当前账号

点击账号旁的 **设为 CLI 当前账号**。旧账号缺少完整凭证时会自动引导重新登录，成功后继续切换。
切换保存原当前账号的最新凭证，并写入默认 `~/.codex/auth.json`；不会运行 logout 或结束现有进程。
完成后请新开或重新打开 CLI 会话；已有会话可能仍使用旧身份，共享默认登录的 IDE 也可能受影响。
TokenDeck 的当前账号、置顶及提醒跟随新身份。

仅支持默认目录文件认证；自定义 CODEX_HOME、API Key、钥匙串认证或受管理配置不由此按钮切换。
检测到外部登录/配置变化会中止并提示重试，不修改 CLI 配置与会话历史。
外部进程不共享锁，检查与原子替换之间仍有短暂竞争窗口；已有会话也可能在切换后再次写入登录。

当前账号依据 `~/.codex/auth.json` 自动识别，最多约 5 秒检测到切换，打开面板和刷新前也会检查。
当前账号始终置顶；未添加的当前账号也会显示，但切换后不会作为已保存账号保留。
Codex 的渠道开关与展示选项统一作用于全部账号。菜单栏角标和系统通知只计算当前 Codex，
Claude 等原有订阅渠道的告警保持不变；其他 Codex 账号仍展示各自用量。

应用仅在点击切换按钮时改变默认登录，不主动刷新 OAuth。保存的凭证过期后，需重新登录对应账号，
直接点击账号的“重新登录”。导入是一次性副本，不自动追踪源文件后续更新。
“移除”只删除 TokenDeck 保存的账号与钥匙串副本，不退出 Codex；
若移除的是当前账号，它仍以未保存状态显示。已有用量缓存保留。

官方账号名称和不可逆身份摘要位于 `config.json` 的 `codexAccounts`；访问令牌不写入配置或中转。
用量缓存和告警冷却按账号隔离，旧的单账号 `codex.json` 缓存因无法确认归属不再用于账号卡片。
旧版未按实际时长分类的 Codex 缓存也不再复用，首次刷新成功后重新生成，避免错误的 5 小时显示与告警。

## 取数与凭证

| 服务 | 数据来源 | macOS 凭证 |
| --- | --- | --- |
| Claude | `api.anthropic.com/api/oauth/usage` | 钥匙串 `Claude Code-credentials`，回退 `~/.claude/.credentials.json` |
| Codex | `chatgpt.com/backend-api/wham/usage`；macOS 重置明细：同路径前缀的 `rate-limit-reset-credits`（GET） | 当前账号：`~/.codex/auth.json`；已添加账号：macOS 钥匙串 |
| DeepSeek（macOS） | `api.deepseek.com/user/balance`（GET） | 本机钥匙串，以渠道 ID `deepseek` 引用 |
| 易云（macOS） | `token-api.yicloud.com/v1/models`（GET） | 本机钥匙串，以渠道 ID `yicloud` 引用 |
| OpenRouter（macOS） | `openrouter.ai/api/v1/key`；管理 Key 另查 `/api/v1/credits`（GET） | 设置中安全输入，保存至本机钥匙串 |
| New-API | `<baseUrl>/api/user/self` 与 `<baseUrl>/api/pricing` | `~/.config/usage-bar/<credentialFile>` |

DeepSeek 与易云从 Hermes 经 SSH 一次性导入已有 Key，后续由 Mac 直接查询，无需 aimax 在线。
管理入口 `TokenDeck --import-api-keys` 从标准输入接收 JSON 对象（键为 `deepseek`、`yicloud`、`openrouter`，值为对应 Key），仅保存到钥匙串并追加未存在的渠道；不要把 Key 放到命令参数或 shell 历史中。
重新导入会更新 Key，保留现有渠道顺序和显示选项。配置保存失败时，已写入钥匙串的 Key 保留，可重试导入；不回滚覆盖后续凭证更新。
Hermes 更换 Key 后需要重新导入，不自动远程同步。DeepSeek 不展示未提供的历史消耗，易云查询成功不代表模型推理一定可用。
这两个渠道不参与订阅额度告警；失败显示缓存时间或明确错误。relay 增加 `apiInfo` 字段，本轮未增加手机端展示。

Mac 卡片右上角可单独刷新，刷新期间保留已有结果并显示进度；同一渠道不重复请求，最多四个单卡并发。整体刷新在单卡请求结束后执行。

OpenRouter 在设置中输入 Key 后点击“保存并刷新”。普通 Key 显示自身累计用量、限额、剩余额度与重置周期；未设 Key 限额不代表账户余额无限。管理 Key 显示账户总额度减累计消耗后的余额。所有金额以 USD 显示，不进行模型调用。OpenRouter 手机展示尚未适配，relay 暂标记为 unsupported，兼容旧手机解析。

New-API 的 `accessToken` 是个人设置中生成的**系统访问令牌**，不是“令牌管理”中的
`sk-` 中转令牌。凭证只用于本机请求，不写入仓库，也不打印原始响应或 Bearer Token。

New-API 凭证文件示例：

```json
{
  "baseUrl": "https://example.com/new-api",
  "accessToken": "<系统访问令牌>",
  "userId": 0,
  "quotaPerUnit": 500000,
  "currency": "$"
}
```

## 配置

macOS 首次启动会生成 `~/.config/usage-bar/config.json`：

```json
{
  "refreshSeconds": 300,
  "alerts": {
    "enabled": true,
    "cooldownSeconds": 1800,
    "fiveHour": {
      "enabled": true,
      "threshold": 60,
      "rule": "usageExceedsElapsedWindowPercent",
      "paceMultiplier": 1
    },
    "weekly": {
      "enabled": true,
      "threshold": 80,
      "rule": "usageExceedsThresholdOnly",
      "paceMultiplier": 1
    }
  },
  "services": [
    {
      "id": "claude",
      "title": "Claude",
      "accent": "#D97757",
      "category": "subscription",
      "fetcher": "claudeOAuth",
      "enabled": true
    },
    {
      "id": "codex",
      "title": "Codex",
      "accent": "#10A37F",
      "category": "subscription",
      "fetcher": "codexWham",
      "enabled": true
    },
    {
      "id": "phanrouter",
      "title": "PhanRouter",
      "accent": "#7C5CFC",
      "category": "apiUsage",
      "fetcher": "newAPI",
      "credentialFile": "phanrouter.json",
      "enabled": true
    }
  ]
}
```

告警仅作用于 `subscription` 服务：

- `usageExceedsElapsedWindowPercent`：超过阈值后，再判断用量是否跑赢当前窗口时间进度。
- `usageExceedsThresholdOnly`：超过阈值即告警。
- `cooldownSeconds`：限制同一窗口重复通知的频率。

旧版单一告警字段会在加载时自动迁移。缓存位于 `~/.cache/usage-dashboard/`，用于请求失败时
恢复最近一次成功数据。

## 手机中转

1. Mac App 启动时读取或生成 `~/.config/usage-bar/relay.json`。
2. `RelayServer` 监听默认端口 `8787`，通过 `GET /usage` 返回当前用量快照。
3. 手机扫描设置页二维码，获得 `http://<Mac Tailscale IP>:8787` 与随机密钥。
4. 手机请求携带 `Authorization: Bearer <secret>`；失败时保留上次成功快照。

多账户仍使用 `services[].config` / `services[].status` 契约，每个 Codex 账号对应独立的
`codex-<身份摘要>` 服务 ID，当前账号排在最前。不会中转访问令牌或真实账号 ID；旧手机小组件
若绑定单一 `codex` ID，需要重新选择对应账号。手机端实际显示与小组件重绑尚需设备验收。

中转依赖 Mac App 持续运行且两台设备位于同一 Tailscale 网络。开机启动时应确保
`/Applications/TokenDeck.app` 是包含中转功能的当前版本；仅更新仓库中的构建产物
不会自动替换已安装副本。

## 目录结构

```text
Sources/UsageBar/
  App.swift                    macOS App 入口、CLI 调试入口
  MenuBarController.swift      菜单栏、弹窗与中转服务生命周期
  UsageStore.swift             服务状态、定时刷新与告警协调
  UsageFetcher.swift           Claude / Codex / New-API 取数器
  CredentialStore.swift        本机凭证读取
  AppConfigStore.swift         macOS 配置加载、迁移与保存
  UsageCache.swift             最近成功用量缓存
  RelayServer.swift            8787 HTTP 中转服务
  RelaySnapshot.swift          中转快照序列化
  RelayConfigStore.swift       中转端口与密钥
  TailscaleAddress.swift       本机 Tailscale IPv4 检测
  Views/                       SwiftUI 卡片、进度条与设置页

tauri/
  src/                         Svelte 5 前端与共享卡片组件
  src-tauri/src/               Rust 状态、取数、缓存、告警与命令
  src-tauri/gen/android/       Android 工程、小组件与原生桥接
  README.md                    Windows 构建与配置
  README-android.md            Android 构建、签名与联调

Docs/Images/                   README 界面截图
build-app.sh                   macOS Release 打包脚本
make_icon.swift                App 图标生成脚本
```

## 调试

```bash
# macOS：隔离测试（独立构建目录也可避开项目改名后的旧模块缓存）
swift test --scratch-path .build/multi-account-validation

# 可选：真实钥匙串集成测试，仅创建随机身份的模拟凭证，结束后清理
TOKENDECK_KEYCHAIN_TEST=1 swift test --scratch-path .build/multi-account-validation --filter KeychainIntegrationTests

# 十账号隔离验收窗口，复用 480 点高的正式界面；可切换模拟当前账号
# 不读取真实凭证、不启动中转、不发送通知
.build/multi-account-validation/debug/TokenDeck --preview-accounts

# macOS：无头验证取数
.build/release/TokenDeck --fetch claude
.build/release/TokenDeck --fetch codex
.build/release/TokenDeck --fetch phanrouter

# macOS：中转与文档辅助
.build/release/TokenDeck --serve
.build/release/TokenDeck --relay-sample
.build/release/TokenDeck --render-readme
.build/release/TokenDeck --dump-alerts

# Tauri：前端检查与 Rust 测试
cd tauri
npm run check
cargo test --manifest-path src-tauri/Cargo.toml
```

## 当前边界

- macOS 是手机中转模式的宿主；Mac 关机、App 退出或 Tailscale 断开时，手机只能显示缓存。
- Claude / Codex 的订阅接口和凭证格式可能随上游变化，需要以实际 CLI 登录产物为准。
- 新增 New-API 渠道只需增加服务配置和独立凭证文件；新增其他订阅协议通常需要新的取数器。
- `.build/`、`*.app/`、Android 构建目录和本机凭证均属于本地产物，不应提交。
