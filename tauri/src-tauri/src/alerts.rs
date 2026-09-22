use chrono::{DateTime, Utc};

use crate::models::{BillingCategory, ServiceConfig, Usage, UsageAlertConfig, UsageAlertRule};

// 结果结构体:本次判定出的活跃 key 集合 + 应触发的告警列表。
pub struct EvalResult {
    pub active_keys: Vec<String>,
    pub fires: Vec<AlertFire>,
}

pub struct AlertFire {
    pub key: String,
    pub title: String,
    pub body: String,
}

/// 窗口标签 → 持续秒数。含"5"→5h，含"周"→7d，其余 None。
pub fn window_duration_seconds(label: &str) -> Option<f64> {
    if label.contains('5') {
        Some(5.0 * 60.0 * 60.0)
    } else if label.contains('周') {
        Some(7.0 * 24.0 * 60.0 * 60.0)
    } else {
        None
    }
}

/// 窗口已流逝百分比（0–100，clamp）。
/// elapsed = duration - (reset_at - now)
pub fn elapsed_window_percent(
    label: &str,
    reset_at: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
) -> Option<f64> {
    let reset_at = reset_at?;
    let duration = window_duration_seconds(label)?;
    let remaining = (reset_at - now).num_milliseconds() as f64 / 1000.0;
    let elapsed = duration - remaining;
    Some((elapsed / duration * 100.0).clamp(0.0, 100.0))
}

/// 告警规则是否命中。
/// - ThresholdOnly：前提已过最小阈值，恒返回 true。
/// - ElapsedWindowPercent：usage_pct > clamp(elapsed_pct * max(0.1, pace), 0, 100)。
pub fn rule_matches(
    rule: UsageAlertRule,
    usage_pct: f64,
    elapsed_pct: Option<f64>,
    pace: f64,
) -> bool {
    match rule {
        UsageAlertRule::UsageExceedsThresholdOnly => true,
        UsageAlertRule::UsageExceedsElapsedWindowPercent => {
            let Some(elapsed_pct) = elapsed_pct else {
                return false;
            };
            let target = (elapsed_pct * pace.max(0.1)).clamp(0.0, 100.0);
            usage_pct > target
        }
    }
}

/// 告警去重键："{service_id}:{label}:{reset_epoch}:{rule_raw}"。
pub fn alert_key(
    service_id: &str,
    label: &str,
    reset_at: Option<DateTime<Utc>>,
    rule: UsageAlertRule,
) -> String {
    let reset_epoch = reset_at.map(|t| t.timestamp()).unwrap_or(0);
    let rule_raw = match rule {
        UsageAlertRule::UsageExceedsThresholdOnly => "usageExceedsThresholdOnly",
        UsageAlertRule::UsageExceedsElapsedWindowPercent => "usageExceedsElapsedWindowPercent",
    };
    format!("{service_id}:{label}:{reset_epoch}:{rule_raw}")
}

/// 告警正文，对齐 Swift alertBody。
fn alert_body(
    service_title: &str,
    label: &str,
    usage_pct: f64,
    elapsed_pct: Option<f64>,
    minimum_usage_percent: f64,
    rule: UsageAlertRule,
) -> String {
    let usage_text = format!("{}%", usage_pct.round() as i64);
    let threshold_text = format!("{}%", minimum_usage_percent.round() as i64);
    match rule {
        UsageAlertRule::UsageExceedsThresholdOnly => {
            format!(
                "{service_title} {label} 用量 {usage_text},已超过 {threshold_text} 阈值。"
            )
        }
        UsageAlertRule::UsageExceedsElapsedWindowPercent => {
            let elapsed_text = elapsed_pct
                .map(|p| format!("{}%", p.round() as i64))
                .unwrap_or_else(|| "未知".to_string());
            format!(
                "{service_title} {label} 用量 {usage_text},窗口时间进度 {elapsed_text},已超过 {threshold_text} 阈值。"
            )
        }
    }
}

/// 主判定入口。移植 Swift updateAlerts（不含冷却，冷却在 state 层处理）。
/// 仅 subscription category 服务参与判定。
pub fn evaluate(
    service: &ServiceConfig,
    usage: &Usage,
    alerts: &UsageAlertConfig,
    now: DateTime<Utc>,
) -> EvalResult {
    // 非 subscription 或告警未启用 → 空
    if !alerts.enabled || service.category != BillingCategory::Subscription {
        return EvalResult { active_keys: vec![], fires: vec![] };
    }
    // serviceIDs 过滤
    if let Some(ref ids) = alerts.service_ids {
        if !ids.contains(&service.id) {
            return EvalResult { active_keys: vec![], fires: vec![] };
        }
    }

    let mut active_keys = Vec::new();
    let mut fires = Vec::new();

    for window in &usage.windows {
        // windows 过滤
        if let Some(ref allowed) = alerts.windows {
            if !allowed.contains(&window.label) {
                continue;
            }
        }

        let usage_pct = window.pct.clamp(0.0, 100.0);
        if usage_pct < alerts.minimum_usage_percent {
            continue;
        }

        let elapsed_pct = elapsed_window_percent(&window.label, window.reset_at, now);

        if !rule_matches(alerts.rule, usage_pct, elapsed_pct, alerts.pace_multiplier) {
            continue;
        }

        let key = alert_key(&service.id, &window.label, window.reset_at, alerts.rule);
        active_keys.push(key.clone());

        let title = format!("{} 用量提醒", service.title);
        let body = alert_body(
            &service.title,
            &window.label,
            usage_pct,
            elapsed_pct,
            alerts.minimum_usage_percent,
            alerts.rule,
        );
        fires.push(AlertFire { key, title, body });
    }

    EvalResult { active_keys, fires }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::*;
    use chrono::{Duration, Utc};

    fn sub_service() -> ServiceConfig {
        serde_json::from_value(serde_json::json!({"id":"claude","title":"Claude"})).unwrap()
    }

    #[test]
    fn threshold_only_fires_above_minimum() {
        let now = Utc::now();
        let svc = sub_service();
        let usage = Usage {
            api_info: None,
            reset_credits: None,
            plan: None,
            balance: None,
            windows: vec![UsageWindow {
                label: "5 小时".into(),
                pct: 80.0,
                reset_at: Some(now + Duration::hours(1)),
            }],
        };
        let mut a = UsageAlertConfig::default();
        a.rule = UsageAlertRule::UsageExceedsThresholdOnly;
        a.minimum_usage_percent = 60.0;
        let r = evaluate(&svc, &usage, &a, now);
        assert_eq!(r.fires.len(), 1);
        assert_eq!(r.active_keys.len(), 1);
    }

    #[test]
    fn below_threshold_no_fire() {
        let now = Utc::now();
        let svc = sub_service();
        let usage = Usage {
            api_info: None,
            reset_credits: None,
            plan: None,
            balance: None,
            windows: vec![UsageWindow {
                label: "5 小时".into(),
                pct: 50.0,
                reset_at: Some(now + Duration::hours(1)),
            }],
        };
        let mut a = UsageAlertConfig::default();
        a.minimum_usage_percent = 60.0;
        assert!(evaluate(&svc, &usage, &a, now).fires.is_empty());
    }

    #[test]
    fn elapsed_rule_requires_outpacing_time() {
        let now = Utc::now();
        // 5h 窗口，还剩 1h → 已流逝 80%
        let reset = now + Duration::hours(1);
        let svc = sub_service();
        let mut a = UsageAlertConfig::default();
        a.rule = UsageAlertRule::UsageExceedsElapsedWindowPercent;
        a.minimum_usage_percent = 60.0;
        a.pace_multiplier = 1.0;
        let over = Usage {
            api_info: None,
            reset_credits: None,
            plan: None,
            balance: None,
            windows: vec![UsageWindow {
                label: "5 小时".into(),
                pct: 90.0,
                reset_at: Some(reset),
            }],
        };
        assert_eq!(evaluate(&svc, &over, &a, now).fires.len(), 1);
        let under = Usage {
            api_info: None,
            reset_credits: None,
            plan: None,
            balance: None,
            windows: vec![UsageWindow {
                label: "5 小时".into(),
                pct: 70.0,
                reset_at: Some(reset),
            }],
        };
        assert!(evaluate(&svc, &under, &a, now).fires.is_empty());
    }

    #[test]
    fn api_usage_service_never_alerts() {
        let now = Utc::now();
        let svc: ServiceConfig = serde_json::from_value(
            serde_json::json!({"id":"phanrouter","title":"P","category":"apiUsage"}),
        )
        .unwrap();
        let usage = Usage {
            api_info: None,
            reset_credits: None,
            plan: None,
            balance: None,
            windows: vec![UsageWindow {
                label: "5 小时".into(),
                pct: 99.0,
                reset_at: Some(now + Duration::hours(1)),
            }],
        };
        let a = UsageAlertConfig::default();
        assert!(evaluate(&svc, &usage, &a, now).fires.is_empty());
    }
}
