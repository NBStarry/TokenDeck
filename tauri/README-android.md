# TokenDeck — Android (Tauri mobile)

Android 端基于 Tauri 2 移动端，复用 `tauri/` 下的 Svelte 前端 + Rust 后端。
桌面专属代码（托盘 / autostart / popover 窗口）已用 `#[cfg(desktop)]` 隔离，
移动端全屏显示主 App。本文档记录在一台新机器上从零把 Android 构建跑起来的步骤。

> 现状：已在 Windows 模拟器（AVD `Medium_Phone_API_36`，Android 16/API 36）实跑验证：
> APK 安装启动无崩溃，Svelte UI 全屏渲染正常；移动端适配生效（隐藏 quit、安全区、
> 隐藏桌面配置路径提示）；PhanRouter 卡片的 app 内凭证录入表单正常展开。
> 待真实凭证联调“录入→看到真实用量”，以及 Phase 3 原生小组件。

## 1. 工具链前置

- **Rust**（rustup）+ Android 编译目标：
  ```bash
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
  . "$HOME/.cargo/env"
  rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
  ```
- **JDK 17**（Android Gradle 需要）。
- **Android SDK + NDK**。命令行方式（macOS，Homebrew）：
  ```bash
  brew install --cask android-commandlinetools
  export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
  yes | sdkmanager --licenses
  sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.1" "ndk;27.2.12479018"
  ```
  （也可装 Android Studio，用其自带 SDK Manager 装同样的 platform-35 / build-tools / NDK r27c。）

- **环境变量**（写进 `~/.zprofile` 或 `~/.zshenv`，按实际 NDK 版本号调整）：
  ```bash
  export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"   # 或 Android Studio 的 sdk 路径
  export NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
  export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
  export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$HOME/.cargo/bin:$PATH"
  ```

## 2. 国内网络（GFW）修复 —— 否则 Gradle 必失败

Gradle（JVM）**不读** `http_proxy` 环境变量，会直连 `dl.google.com` /
`repo.maven.apache.org` 被 GFW 掐断 TLS（报 `Remote host terminated the handshake`）。
两处全局配置（都放 `~/.gradle/`，不随项目 re-init 丢失）：

`~/.gradle/gradle.properties`（代理端口按你的 Clash/代理实际端口）：
```properties
systemProp.http.proxyHost=127.0.0.1
systemProp.http.proxyPort=7897
systemProp.https.proxyHost=127.0.0.1
systemProp.https.proxyPort=7897
systemProp.http.nonProxyHosts=localhost|127.0.0.1
```

`~/.gradle/init.gradle`（阿里云镜像，国内直连稳定，避免国际仓握手）：
```groovy
def aliyun = [
    'https://maven.aliyun.com/repository/public',
    'https://maven.aliyun.com/repository/google',
    'https://maven.aliyun.com/repository/gradle-plugin',
    'https://maven.aliyun.com/repository/central',
]
allprojects {
    buildscript { repositories { aliyun.each { u -> maven { url u } } } }
    repositories { aliyun.each { u -> maven { url u } } }
}
settingsEvaluated { settings ->
    settings.pluginManagement { repositories { aliyun.each { u -> maven { url u } }; gradlePluginPortal() } }
    try { settings.dependencyResolutionManagement { repositories { aliyun.each { u -> maven { url u } } } } } catch (ignored) {}
}
```

（境外网络畅通的机器可跳过本节。）

## 3. 构建

```bash
cd tauri
npm install
chmod +x node_modules/.bin/*            # 跨平台 checkout 后 .bin 常丢执行权限

# gen/android 已随仓库提交;若缺失或换了 identifier 才需要重新生成:
# npx tauri android init

# 编译 + 打包调试 APK(单 ABI 最快)
npx tauri android build --debug --target aarch64
# 产物: src-tauri/gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk

# 接真机(开 USB 调试)后实机运行 + 热重载:
# npx tauri android dev
```

构建相关常量：identifier/applicationId = `app.usagedashboard`；
compile SDK 35；NDK r27c（27.2.12479018）。

> 验证：Windows 与 macOS 均已产出 aarch64 debug APK
> (`app/build/outputs/apk/universal/debug/app-universal-debug.apk`，debug 未裁剪 ~174MB)。

### Windows 注意：工程路径含中文（A:\文档\…）

本仓库经 Syncthing 同步，Windows 端落在 `A:\文档\…`，路径里的中文会两处卡住 Android 构建，需各自绕开：

1. **NDK 链接器** `ld.lld`（经 `.cmd` wrapper 调用）按 GBK 编码中文路径，找不到 `target/`
   下的 `.o` / version script，报 `cannot find version script` / `unspecified system_category
   error`。绕法：构建前把 Rust target 目录指向纯 ASCII 路径——
   ```bash
   export CARGO_TARGET_DIR="C:/ud-target"
   ```
   Tauri CLI 会从同一目录定位 `.so` 并 symlink 进 jniLibs，无需额外配置。
2. **AGP 路径检查** 检测到非 ASCII 工程路径直接拒绝 apply 插件
   (`Your project path contains non-ASCII characters`)。绕法已写进
   `gen/android/gradle.properties`：`android.overridePathCheck=true`。

Windows 完整构建命令（代理端口按实际 Clash 端口）：
```bash
cd tauri
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
export NDK_HOME="$ANDROID_HOME/ndk/27.2.12479018"
export CARGO_TARGET_DIR="C:/ud-target"           # 中文路径必需,见上
export HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897
export CARGO_HTTP_CHECK_REVOKE=false
npx tauri android build --debug --target aarch64
```
（`ANDROID_HOME` / `NDK_HOME` 已持久化到 Windows User 环境变量，新终端无需再 export；
此处显式写出是为可复制。境外网络可去掉代理两行。）

### Release 签名包（体积小、可装真机/上架）

去掉 `--debug --target aarch64`（默认全架构 release + minify）：
```bash
npx tauri android build        # 其余环境变量同上
```
产物：
- `app/build/outputs/apk/universal/release/app-universal-release.apk`（~48MB，直接装机）
- `app/build/outputs/bundle/universalRelease/app-universal-release.aab`（~20MB，上架 Play）

**签名配置**（已接好，不入库的密钥需本机/各机各自准备）：
- `app/build.gradle.kts` 的 `signingConfigs.release` 从 `gen/android/keystore.properties` 读
  `storeFile`/`storePassword`/`keyAlias`/`keyPassword`，release buildType 引用它。
- keystore 与 `keystore.properties` 均 **gitignore**（`*.jks` / `*.keystore` / `keystore.properties`）——
  密钥绝不入库。换机器构建 release 前需先放好这两份文件（密码私下保管，丢了无法给同一
  applicationId 发更新）。
- 生成 keystore：
  ```bash
  keytool -genkeypair -v -keystore upload-keystore.jks -alias upload \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass <PW> -keypass <PW> -dname "CN=TokenDeck, O=TokenDeck, C=CN"
  ```
- **ProGuard**：release 开了 `isMinifyEnabled`。`app/proguard-rules.pro` 必须 keep 住
  `app.usagedashboard.**` 和 native 方法名——否则混淆会改掉 `MainActivity`/`nativeInit`，
  Rust 按 JNI 符号名 `Java_app_usagedashboard_MainActivity_nativeInit` 找不到 → ndk_context
  不初始化 → 首启 panic（同理 `WebLoginActivity` 靠 action intent 字符串启动，也需保留）。

## 4. 移动端适配（已做）

平台判定走 Rust `is_mobile` 命令（`cfg!(mobile)`，由 tauri-build 注入），前端
`store.ts` 的 `mobile` store 在 `init()` 时一次性读取，运行期不变。

- **隐藏 quit**：移动端无"退出"概念（返回/Home 键管理生命周期），`+page.svelte`
  footer 的退出按钮按 `$mobile` 隐藏。
- **安全区**：`app.html` viewport 加 `viewport-fit=cover`，`.root` padding 叠加
  `env(safe-area-inset-*)`（桌面端解析为 0，移动端避开状态栏/挖孔/底部手势条）。
- **凭证 app 内录入（Phase 2）**：手机沙盒里没法把 JSON 文件丢进 config 目录，
  设置页对每个 `newAPI` 服务提供"凭证录入"表单（baseUrl / accessToken / userId /
  quotaPerUnit / currency），保存走已有的 `save_new_api_credentials` 命令写入
  `config_dir()/<credentialFile>`，保存后自动 `refresh_now` 拉真实用量验证。
  桌面端同样可用。表单不预填（后端不暴露读凭证命令,accessToken 敏感）。
  Claude/Codex 同样有录入表单(仅移动端,带"如何获取"引导文字)。
- **New-API 网页登录自动获取（已做）**：`newAPI` 表单上有"🔑 网页登录自动获取"按钮——
  填好 baseUrl 后点它,`login_new_api` 命令经 JNI 启动原生 `WebLoginActivity`(一个 WebView)
  打开网关页;用户正常登录后,`onPageFinished` 注入 JS 从 localStorage 读 userId、调
  `/api/user/token` 生成系统访问令牌,直接写入凭证文件。返回 app 时
  `visibilitychange→visible` 自动 `refresh_now`。**不用手动复制令牌**。
  > **JNI 取 Context 的坑**：Tauri 不用 ndk-glue,`ndk_context` 全局**不会自动初始化**,
  > 直接 `ndk_context::android_context()` 会 panic 并 abort 整个进程(`request_pin_widget`
  > 起初就因此崩)。修法:`MainActivity.onCreate` 调 Rust 导出的
  > `Java_app_usagedashboard_MainActivity_nativeInit(context)`,用 `env.get_java_vm()` +
  > 全局引用 `initialize_android_context`。之后 commands 里的 JNI 才能安全取 context。
- **可写路径（移动端必需）**：`dirs::config_dir()` 在 Android 上解析成 `/.config`
  这类只读路径，写配置/凭证报 `EROFS (os error 30)`——这正是手机端"保存失败"的根因。
  `paths.rs` 加了一个运行期可注入的 base（`OnceLock`），`lib.rs` setup 里**仅移动端**
  用 Tauri `app_config_dir()`（可写沙盒 `/data/user/0/<pkg>/usage-bar/`）注入，并重载
  config。桌面端不变（继续 `dirs::*` 并读 `~/.claude` 等）。已验证：模拟器上录入真实
  PhanRouter 凭证 → 保存成功 → 拉到真实余额，且配置/凭证重启后持久化。

## 5. 卡片首次渲染后不更新（已修，根因是序列化 bug）

现象一度被误判为"WebView 重绘问题"：后端 `refresh` 完成、store 也更新了，但卡片
DOM 卡在"加载中…"。真因是**渲染时抛异常导致 Svelte 调度器卡死**：

- `ServiceStatus` 是 enum，`#[serde(rename_all = "camelCase")]` **只改变体名,不改
  结构变体内的字段**，于是 `fetched_at` / `cached_at` 仍按 snake_case 序列化,前端读到
  的 `status.fetchedAt` 是 `undefined`。
- `ServiceCard` 渲染 ok 卡片时 `hm(status.fetchedAt)` → `undefined.getHours()` 抛错,
  这次 effect flush 出错后 Svelte 的调度器不再 flush 后续更新 → 整个页面冻结
  （首次渲染后任何 store/状态变化都不再反映,连设置页切换也卡住）。

修复：`state.rs` 给 `fetched_at`/`cached_at` 显式 `#[serde(rename = "...")]`;
`theme.ts` 的 `hm()` 加固为 null/非法日期返回 `--:--` 不抛错。已在模拟器验证:
PhanRouter 卡片正常显示真实余额/消耗/请求数/模型,设置页可反复切换,实时刷新生效。

## 6. 待办（接着做）

- ~~**Claude / Codex 手机端凭证录入**~~（已做）：设置页对 `claudeOauth`、`codexWham`
  服务也提供"凭证录入"表单（**仅移动端**——桌面端这两个文件由 CLI 维护,录入会覆盖,
  故 UI 隐藏且命令带 `cfg!(mobile)` 守卫）。Claude 填 accessToken,Codex 填
  access_token + account_id。后端 `save_claude_credentials` / `save_codex_credentials`
  写进 `home_dir()/.claude/.credentials.json`、`home_dir()/.codex/auth.json`（沙盒可写路径）,
  结构对齐 `credentials.rs` 的读取。已验证:保存成功、fetcher 读到并发起请求。

- ~~**GFW 下 Claude/GPT 经代理取数**~~（已做）：Claude(`api.anthropic.com`)、
  Codex(`chatgpt.com`)在国内被墙,直连 403/连接失败。设置页新增 **HTTP 代理** 面板,
  填代理串(如 `http://127.0.0.1:7897`,模拟器视角宿主 `http://10.0.2.2:7897`)即可。
  - `config.proxyUrl` 持久化;`http.rs` 全局 `set_proxy` + 每次构建 reqwest client 时
    `reqwest::Proxy::all`(全量走代理,由代理按规则分流——国内直连、国外走代理,
    PhanRouter 等国内域名不受影响)。`set_proxy_url` 命令运行期改即生效并重新取数。
  - 已在模拟器(clean36)验证:设代理 `10.0.2.2:7897` 后**三张卡片全部出真实数据**——
    Claude 5小时41%/周29%、GPT 5小时5%/周62%、PhanRouter 余额 $1987.12。
  - 真机也可改用系统 VPN(Clash for Android,对 app 透明,无需填代理);二选一。

- ~~**Phase 3：Android 原生主屏小组件**~~（已做,**单渠道一卡片 + 进度条**）：
  原生 `AppWidgetProvider`(Kotlin)读 Rust 写的 `dataDir/widget.json`,**每个小组件实例
  绑定一个渠道**(添加时弹配置页选),渲染该渠道的窗口进度条(Claude/GPT)或余额(PhanRouter)。
  - 数据:`widget.rs` 每次 `refresh` 后(仅移动端)写结构化 `widget.json`——每服务带 id/title/
    accent/kind,窗口型给 `windows[{label,pct}]`,余额型给 `balance{balance,used,currency,
    requestCount}`(让小组件画进度条);时间用 epoch 毫秒,Kotlin 本地化。
  - 一渠道一卡片:`WidgetConfigActivity` 添加时列出渠道,选中后把 serviceId 按 appWidgetId
    存进 SharedPreferences;`UsageWidgetProvider` 按各实例绑定的渠道单独渲染。**未配置时点击
    小组件直接打开配置页选渠道**(部分桌面 pin 后不自动弹配置)。
  - 进度条:`res/layout/usage_widget.xml` 每窗口一条 `ProgressBar`,按百分比着色
    (绿<75/黄<90/红≥90,API 31+ 用 `setColorStateList` tint;老设备绿色默认)。
  - 刷新:`MainActivity.onStop()` 刷所有实例 + 30 分钟系统周期兜底。添加入口:设置页
    "添加主屏小组件"按钮(`request_pin_widget` 经 JNI 调 `requestPinAppWidget`),或长按桌面→微件。
  - 文件:`UsageWidgetProvider.kt`、`WidgetConfigActivity.kt`、`res/layout/usage_widget.xml`、
    `res/layout/activity_widget_config.xml`、`res/drawable/widget_progress.xml`、`widget_bg.xml`、
    `res/xml/usage_widget_info.xml`(带 `android:configure`)、`AndroidManifest.xml`、`widget.rs`。
  - 验证:模拟器上确认编译/安装/provider+config 注册/微件列表可见/`widget.json` 结构正确/
    **pin 预览里小组件实际渲染出来**(头部圆点+标题+状态)。最终"已配置渲染真实进度条"的落屏
    截图受模拟器启动器合成手势限制没拿到(picker 拖拽 / pin 确认都不吃 adb 合成手势),
    真机上拖入选渠道即可,非 app 问题。


## Mac 多账户与 API 中转适配

- 新版接收 `isCurrentAccount`、`resetCredits`、`apiInfo`，兼容没有这些字段的旧 Mac 快照。
- Codex 按 Mac 的稳定账号 ID 和排序显示，当前账号标为“当前使用”；周额度不再被手机解释为 5 小时。重置次数与每条到期时间在 App 展示，时间按手机本地时区显示。
- DeepSeek 显示分币种总余额、充值余额和赠金；易云显示查询状态与授权模型，明确暂无额度查询。不在手机保存这两家的 API Key，不新增直接取数或 Mac CLI 切换功能。
- 单/双渠道小组件支持这两类新卡片，Codex 展示重置次数与最近到期摘要。多币种/完整到期列表在 App 查看；缓存数据标为“上次数据”。原有 `codex` 小组件需重新选择具体账号，新绑定按账号 ID 保留。
- 校验：`npm run check`、`npm run test:relay`、`cargo test --manifest-path src-tauri/Cargo.toml`；Android 构建沿用上文流程。构建完成不代表手机安装或现场验收完成。
