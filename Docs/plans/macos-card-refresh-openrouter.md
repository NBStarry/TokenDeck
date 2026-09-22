# Mac TODO：单渠道刷新与 OpenRouter

- 手机实机调试与手机适配暂停，保留工作区现有手机改动。本轮不安装手机应用，不提交或推送未经新授权的改动。
- 每张服务/账号卡片提供单独刷新按钮与进行中状态，仅更新目标卡片。保留已有结果，失败按原缓存规则回退；刷新互斥/去重，最多 4 个单卡并发，整体刷新在单卡结束后执行，身份或配置代际变化时拒绝旧结果。
- OpenRouter 使用官方 GET /api/v1/key 查询普通 Key 用量、限额、剩余额度及重置周期；is_management_key 为 true 时使用 GET /api/v1/credits，显示账户总余额=total_credits-total_usage 与累计消耗。明确账户/Key 口径，不把无上限解释为无限账户余额。
- Mac 设置提供 SecureField 保存 OpenRouter Key 至钥匙串，支持覆盖更新及明确保存提示；标准输入导入入口同时扩展。无原始 Key、label、响应输出，无模型调用。不强制申请管理 Key。
- 新字段可选并兼容现有缓存；手机工作暂停，OpenRouter 在 relay 标记为 unsupported，避免旧手机拒绝整份快照。手机展示另行适配。
- 验证单卡范围、并发/重复/失败及旧请求失效；验证 OpenRouter 两种口径、空限额、错误和配置去重；Swift 测试、Release 构建、合成卡片渲染。真实取数在凭证可用后验证。
- 更新 README 和 TODO 的完成状态，区分代码完成、加载与真实账号验收。

## 验证记录（2026-09-21）

- Swift 测试 39 项：38 通过，1 项可选钥匙串测试跳过；包含单卡去重、全局刷新排队、Key 更新丢弃旧响应、两种 OpenRouter 额度口径和缓存兼容。
- Release 构建与 `git diff --check` 通过；OpenRouter 合成卡片已渲染检查，刷新按钮与额度说明完整。
- 从用户指定的本机 `.env.typesafe.local` 读取 `OPEN_ROUTER_KEY`，经 stdin 保存到钥匙串。应用 `--fetch openrouter` 真实查询成功，为普通 Key，限额 50 USD，剩余约 49.99 USD；未调用模型。
- 本地测试 App 已重新签名启动，PID 87828；用户完成钥匙串授权后，运行中 relay 快照确认 7 个渠道/账号均为 ok，当前 Codex 账号唯一且置顶，OpenRouter Key 剩余额度约 49.99 USD。启动阻塞已解除；单卡按钮真实点击验收仍待用户确认，未把 relay 检查当作视觉验收。
- README 已同步单卡刷新、OpenRouter 设置和额度口径；TODO 区分实现与界面验收。本轮未修改手机实现、未提交或推送。

## 提交范围（2026-09-22）

- 用户授权提交推送 GitHub，并更新 README。提交本轮 Mac 单卡刷新、OpenRouter、对应测试、README、TODO 与本计划。
- 暂停中的手机改动及其 Mac relay 当前账号字段和测试留在工作区；README 提交版本不宣称尚未提交的手机能力。用户 AGENTS.md 改动不纳入。
- README 能力列表与使用说明已核对更新；旧界面截图继续明确标注为旧版，未将合成渲染当作真实用户验收。
- 将暂存版本导出至隔离目录执行 Swift 测试：39 项中 38 通过、1 项可选钥匙串测试跳过，无失败；确认本次提交不依赖未提交的手机配套字段。
