# 手机中转适配与远端交付

- macOS 改动已先单独提交推送（1fc2519），本轮仅做手机适配及必要的 relay 标记扩展。适配 Android 中转数据接收、Svelte 卡片及单/双渠道桌面小组件。
- 兼容旧快照；新增 API 信息、Codex 重置次数/到期时间和当前账号标记。沿用服务 ID 绑定与 Mac 排序，不在手机保存新增 API Key 或切换 Mac CLI。
- DeepSeek 分币种余额与易云模型状态完整显示在 App；小组件展示摘要并保留过期缓存提示，详细信息在 App 查看。
- 执行 Swift、前端、Rust 检查和可用 Android 构建，检查脱敏 diff。2026-09-22 用户明确授权全部提交推送，纳入手机改动、配套 Mac 字段、文档和 AGENTS.md；手机调试仍暂停。
- 手机安装与现场视觉验收单独报告；不把构建成功当作真机通过。

- README 与 Android 文档已同步新增字段及展示边界；原 macOS 接入计划保留当时验收记录，无需改写历史。

## 验证进度
- Rust 32 项测试通过，包含旧快照兼容、新渠道/当前身份/重置机会保留、API 与重置字段缓存往返及中转失败旧数据标记。
- Svelte 检查 0 错误、0 警告；生产前端构建通过；新增 SSR 卡片断言覆盖当前标记、零余额、多币种、空模型、过期数据和明细缺失。
- Swift relay 当前标记专项测试通过，配套 Mac release 二进制构建通过；后续 OpenRouter 版本加载后，已从运行中 Mac 快照核验当前账号标记及 apiInfo/resetCredits。
- Android aarch64 Rust 构建与 Gradle 打包已通过，连接设备未安装或修改。手机改动未混入此前 macOS 提交，本次按用户新授权全部提交推送。
- Android Debug APK/AAB 已生成，APK 签名校验通过。产物为 `tauri/src-tauri/gen/android/app/build/outputs/apk/universal/debug/app-universal-debug.apk`。前端资源由 Tauri 内嵌到原生库，APK 中没有独立 JS 文件，不能以搜索独立 JS 文本作为验证；以前端构建、SSR 测试与打包结果为依据。未安装到连接手机，现场视觉/交互验收待做。
