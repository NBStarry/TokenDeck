// 数据模型层:由后续任务(配置加载、取数、Tauri 命令、前端)逐步接入。

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

// 计费展示大类:订阅窗口型 vs API 余额/用量型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BillingCategory {
    Subscription,
    ApiUsage,
}

// 取数协议。新增渠道时优先复用 newAPI;特殊订阅号再新增具体 fetcher。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FetcherKind {
    ClaudeOauth,
    CodexWham,
    #[serde(rename = "newAPI")]
    NewApi,
    Deepseek,
    Yicloud,
    Unsupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UsageAlertRule {
    UsageExceedsElapsedWindowPercent,
    UsageExceedsThresholdOnly,
}

// ---- 配置默认值 ----

fn default_true() -> bool {
    true
}

fn default_minimum_usage_percent() -> f64 {
    60.0
}

fn default_alert_rule() -> UsageAlertRule {
    UsageAlertRule::UsageExceedsElapsedWindowPercent
}

fn default_pace_multiplier() -> f64 {
    1.0
}

fn default_cooldown_seconds() -> i64 {
    1800
}

fn default_refresh_seconds() -> i64 {
    300
}

fn default_accent() -> String {
    "#8E8E93".to_string()
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageAlertConfig {
    #[serde(default = "default_true")]
    pub enabled: bool,
    #[serde(default = "default_minimum_usage_percent")]
    pub minimum_usage_percent: f64,
    #[serde(default = "default_alert_rule")]
    pub rule: UsageAlertRule,
    #[serde(default = "default_pace_multiplier")]
    pub pace_multiplier: f64,
    #[serde(default = "default_cooldown_seconds")]
    pub cooldown_seconds: i64,
    #[serde(default)]
    pub service_ids: Option<Vec<String>>,
    #[serde(default)]
    pub windows: Option<Vec<String>>,
}

impl Default for UsageAlertConfig {
    fn default() -> Self {
        UsageAlertConfig {
            enabled: default_true(),
            minimum_usage_percent: default_minimum_usage_percent(),
            rule: default_alert_rule(),
            pace_multiplier: default_pace_multiplier(),
            cooldown_seconds: default_cooldown_seconds(),
            service_ids: None,
            windows: None,
        }
    }
}

// 卡片可单独控制的展示内容,缺省全开。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceDisplayOptions {
    #[serde(default = "default_true")]
    pub plan: bool,
    #[serde(default = "default_true")]
    pub five_hour: bool,
    #[serde(default = "default_true")]
    pub weekly: bool,
    #[serde(default = "default_true")]
    pub reset_countdown: bool,
    #[serde(default = "default_true")]
    pub updated_at: bool,
    #[serde(default = "default_true")]
    pub balance: bool,
    #[serde(default = "default_true")]
    pub used: bool,
    #[serde(default = "default_true")]
    pub request_count: bool,
    #[serde(default = "default_true")]
    pub models: bool,
}

impl Default for ServiceDisplayOptions {
    fn default() -> Self {
        ServiceDisplayOptions {
            plan: true,
            five_hour: true,
            weekly: true,
            reset_countdown: true,
            updated_at: true,
            balance: true,
            used: true,
            request_count: true,
            models: true,
        }
    }
}

fn default_category(id: &str) -> BillingCategory {
    match id {
        "claude" | "codex" => BillingCategory::Subscription,
        _ => BillingCategory::ApiUsage,
    }
}

fn default_fetcher(id: &str, category: BillingCategory) -> FetcherKind {
    match id {
        "claude" => FetcherKind::ClaudeOauth,
        "codex" => FetcherKind::CodexWham,
        _ => {
            if category == BillingCategory::ApiUsage {
                FetcherKind::NewApi
            } else {
                FetcherKind::Unsupported
            }
        }
    }
}

// 单个服务的配置(由 config.json 控制显示/顺序/颜色/内容项)。
// 缺省时按 id 推断 category/fetcher,accent 缺省 #8E8E93。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawServiceConfig")]
pub struct ServiceConfig {
    pub id: String,
    pub title: String,
    pub accent: String,
    pub category: BillingCategory,
    pub fetcher: FetcherKind,
    pub credential_file: Option<String>,
    pub enabled: bool,
    pub display: ServiceDisplayOptions,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawServiceConfig {
    id: String,
    title: String,
    #[serde(default = "default_accent")]
    accent: String,
    #[serde(default)]
    category: Option<BillingCategory>,
    #[serde(default)]
    fetcher: Option<FetcherKind>,
    #[serde(default)]
    credential_file: Option<String>,
    #[serde(default = "default_true")]
    enabled: bool,
    #[serde(default)]
    display: ServiceDisplayOptions,
}

impl From<RawServiceConfig> for ServiceConfig {
    fn from(raw: RawServiceConfig) -> Self {
        let category = raw.category.unwrap_or_else(|| default_category(&raw.id));
        let fetcher = raw
            .fetcher
            .unwrap_or_else(|| default_fetcher(&raw.id, category));
        ServiceConfig {
            id: raw.id,
            title: raw.title,
            accent: raw.accent,
            category,
            fetcher,
            credential_file: raw.credential_file,
            enabled: raw.enabled,
            display: raw.display,
        }
    }
}

impl ServiceConfig {
    fn new(
        id: &str,
        title: &str,
        accent: &str,
        category: BillingCategory,
        fetcher: FetcherKind,
        credential_file: Option<&str>,
    ) -> Self {
        ServiceConfig {
            id: id.to_string(),
            title: title.to_string(),
            accent: accent.to_string(),
            category,
            fetcher,
            credential_file: credential_file.map(|s| s.to_string()),
            enabled: true,
            display: ServiceDisplayOptions::default(),
        }
    }
}

// relay 配置:手机端通过 relay 服务器中转取数请求。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayConfig {
    pub url: String,
    pub secret: String,
    #[serde(default)]
    pub enabled: bool,
}

// 整体配置。
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", from = "RawAppConfig")]
pub struct AppConfig {
    pub refresh_seconds: i64,
    pub alerts: UsageAlertConfig,
    pub services: Vec<ServiceConfig>,
    // 可选 HTTP 代理(如 http://127.0.0.1:7897 / 模拟器 http://10.0.2.2:7897)。
    // 设置后所有取数请求经此代理,由代理按规则分流(国内直连/国外走代理)。
    // 主要解决 GFW 下 Claude(api.anthropic.com)、Codex(chatgpt.com)无法直连。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub proxy_url: Option<String>,
    // 可选 relay 服务器(手机端无法直连时经 relay 中转)。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub relay: Option<RelayConfig>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawAppConfig {
    #[serde(default = "default_refresh_seconds")]
    refresh_seconds: i64,
    #[serde(default)]
    alerts: UsageAlertConfig,
    #[serde(default)]
    services: Option<Vec<ServiceConfig>>,
    #[serde(default)]
    proxy_url: Option<String>,
    #[serde(default)]
    relay: Option<RelayConfig>,
}

impl From<RawAppConfig> for AppConfig {
    fn from(raw: RawAppConfig) -> Self {
        AppConfig {
            refresh_seconds: raw.refresh_seconds,
            alerts: raw.alerts,
            services: raw
                .services
                .unwrap_or_else(|| AppConfig::default().services),
            proxy_url: raw.proxy_url,
            relay: raw.relay,
        }
    }
}

impl Default for AppConfig {
    fn default() -> Self {
        AppConfig {
            refresh_seconds: 300,
            alerts: UsageAlertConfig::default(),
            proxy_url: None,
            relay: None,
            services: vec![
                ServiceConfig::new(
                    "claude",
                    "Claude",
                    "#D97757",
                    BillingCategory::Subscription,
                    FetcherKind::ClaudeOauth,
                    None,
                ),
                ServiceConfig::new(
                    "codex",
                    "Codex",
                    "#10A37F",
                    BillingCategory::Subscription,
                    FetcherKind::CodexWham,
                    None,
                ),
                ServiceConfig::new(
                    "phanrouter",
                    "PhanRouter",
                    "#7C5CFC",
                    BillingCategory::ApiUsage,
                    FetcherKind::NewApi,
                    Some("phanrouter.json"),
                ),
            ],
        }
    }
}

// ---- 运行态(供前端消费) ----

// 归一化后的单个用量窗口(5 小时 / 周)。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageWindow {
    pub label: String,
    pub pct: f64,
    pub reset_at: Option<DateTime<Utc>>,
}

// 模型广场里的一个模型(用于按来源/厂商分类展示)。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelEntry {
    pub name: String,
    pub vendor: String,
}

// 余额型服务(PhanRouter 等 New-API 网关)的归一化数据。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BalanceInfo {
    pub balance: f64,
    pub used: f64,
    pub currency: String,
    pub request_count: Option<i64>,
    pub models: Vec<ModelEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiBalance {
    pub currency: String,
    pub total: f64,
    pub topped_up: f64,
    pub granted: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiInfo {
    pub balances: Option<Vec<ApiBalance>>,
    pub is_available: Option<bool>,
    pub models: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCredit {
    pub expires_at: Option<DateTime<Utc>>,
    pub applicable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResetCredits {
    pub available_count: u32,
    pub applicable_count: Option<u32>,
    pub credits: Option<Vec<ResetCredit>>,
}

// 一个服务的归一化用量。windows 用于用量窗口型(Claude/Codex),balance 用于余额型(PhanRouter)。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub plan: Option<String>,
    pub windows: Vec<UsageWindow>,
    pub balance: Option<BalanceInfo>,
    pub api_info: Option<ApiInfo>,
    pub reset_credits: Option<ResetCredits>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_has_three_services() {
        let c = AppConfig::default();
        assert_eq!(c.refresh_seconds, 300);
        let ids: Vec<_> = c.services.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["claude", "codex", "phanrouter"]);
        assert_eq!(c.services[2].fetcher, FetcherKind::NewApi);
        assert_eq!(c.services[2].credential_file.as_deref(), Some("phanrouter.json"));
        assert_eq!(c.alerts.minimum_usage_percent, 60.0);
    }

    #[test]
    fn service_config_infers_defaults_from_id() {
        let json = serde_json::json!({"id":"claude","title":"Claude"});
        let s: ServiceConfig = serde_json::from_value(json).unwrap();
        assert_eq!(s.accent, "#8E8E93");
        assert_eq!(s.category, BillingCategory::Subscription);
        assert_eq!(s.fetcher, FetcherKind::ClaudeOauth);
        assert!(s.enabled);
        assert!(s.display.five_hour);
    }

    #[test]
    fn alert_config_fills_missing_fields() {
        let a: UsageAlertConfig = serde_json::from_value(serde_json::json!({})).unwrap();
        assert!(a.enabled);
        assert_eq!(a.cooldown_seconds, 1800);
        assert_eq!(a.rule, UsageAlertRule::UsageExceedsElapsedWindowPercent);
    }

    #[test]
    fn relay_config_roundtrips() {
        let json = r#"{"refreshSeconds":300,"alerts":{},"services":[{"id":"claude","title":"Claude"}],"relay":{"url":"http://100.64.0.1:8787","secret":"abc","enabled":true}}"#;
        let cfg: AppConfig = serde_json::from_str(json).unwrap();
        let r = cfg.relay.clone().unwrap();
        assert_eq!(r.url, "http://100.64.0.1:8787");
        assert!(r.enabled);
        let back = serde_json::to_string(&cfg).unwrap();
        assert!(back.contains("\"relay\""));
    }

}
