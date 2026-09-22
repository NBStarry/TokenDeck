use chrono::{DateTime, Utc};
#[cfg(not(mobile))]
use chrono::SecondsFormat;
use serde_json::Value;
use std::fs;

use crate::models::{BalanceInfo, ModelEntry, Usage, UsageWindow};
use crate::paths::cache_dir;

pub struct Cached {
    pub usage: Usage,
    pub ts: Option<DateTime<Utc>>,
}

/// 辅助：从 JSON Value 中提取数值(对齐 Swift 的 num(_:) — 容忍 number/string)。
fn num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

/// 写 `cache_dir()/<service>.json`，格式与 Swift 兼容：
/// 窗口型 `{"ts","plan","windows":[{"label","pct","resetAt"}]}`
/// 余额型 `{"ts","balance":{"balance","used","currency","requestCount","models":[{"name","vendor"}]}}`
#[cfg(not(mobile))]
pub fn write(usage: &Usage, service: &str) {
    let dir = cache_dir();
    if fs::create_dir_all(&dir).is_err() {
        return;
    }

    let ts = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);

    let windows: Vec<Value> = usage
        .windows
        .iter()
        .map(|w| {
            let reset_at = w
                .reset_at
                .map(|t| Value::String(t.to_rfc3339_opts(SecondsFormat::Secs, true)))
                .unwrap_or(Value::Null);
            serde_json::json!({
                "label": w.label,
                "pct": w.pct,
                "resetAt": reset_at,
            })
        })
        .collect();

    let mut obj = serde_json::json!({
        "ts": ts,
        "plan": usage.plan.as_ref().map(|s| Value::String(s.clone())).unwrap_or(Value::Null),
        "windows": windows,
    });

    obj["apiInfo"] = serde_json::json!(usage.api_info);
    obj["resetCredits"] = serde_json::json!(usage.reset_credits);

    if let Some(b) = &usage.balance {
        let models: Vec<Value> = b
            .models
            .iter()
            .map(|m| serde_json::json!({"name": m.name, "vendor": m.vendor}))
            .collect();

        let request_count = b
            .request_count
            .map(|rc| Value::Number(rc.into()))
            .unwrap_or(Value::Null);

        obj["balance"] = serde_json::json!({
            "balance": b.balance,
            "used": b.used,
            "currency": b.currency,
            "requestCount": request_count,
            "models": models,
        });
    }

    let path = dir.join(format!("{}.json", service));
    if let Ok(data) = serde_json::to_vec(&obj) {
        let _ = fs::write(path, data);
    }
}

/// 读 `cache_dir()/<service>.json`。
/// 优先解析 balance；否则解析 windows；windows 为空且无 balance 返回 None。
pub fn read(service: &str) -> Option<Cached> {
    let path = cache_dir().join(format!("{}.json", service));
    let data = fs::read(path).ok()?;
    let obj: Value = serde_json::from_slice(&data).ok()?;

    let ts = obj["ts"]
        .as_str()
        .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.with_timezone(&Utc));

    let plan = obj["plan"].as_str().map(|s| s.to_string());

    if let Some(value) = obj.get("apiInfo").filter(|v| v.is_object()) {
        let info = serde_json::from_value(value.clone()).ok()?;
        return Some(Cached { usage: Usage { plan, windows: vec![], balance: None,
            api_info: Some(info), reset_credits: None }, ts });
    }
    // 余额型
    if let Some(b) = obj.get("balance").filter(|v| v.is_object()) {
        if let Some(bal) = num(&b["balance"]) {
            let used = num(&b["used"]).unwrap_or(0.0);
            let currency = b["currency"]
                .as_str()
                .unwrap_or("$")
                .to_string();
            let request_count = b["requestCount"].as_i64();
            let models = b["models"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|m| {
                            let name = m["name"].as_str()?.to_string();
                            let vendor = m["vendor"]
                                .as_str()
                                .unwrap_or("其他")
                                .to_string();
                            Some(ModelEntry { name, vendor })
                        })
                        .collect()
                })
                .unwrap_or_default();

            return Some(Cached {
                usage: Usage {
                    api_info: None,
                    reset_credits: None,
                    plan: None,
                    windows: vec![],
                    balance: Some(BalanceInfo {
                        balance: bal,
                        used,
                        currency,
                        request_count,
                        models,
                    }),
                },
                ts,
            });
        }
    }

    // 用量窗口型
    let raw_windows = obj["windows"].as_array()?;
    let windows: Vec<UsageWindow> = raw_windows
        .iter()
        .filter_map(|w| {
            let label = w["label"].as_str()?.to_string();
            let pct = num(&w["pct"])?;
            let reset_at = w["resetAt"]
                .as_str()
                .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
                .map(|dt| dt.with_timezone(&Utc));
            Some(UsageWindow { label, pct, reset_at })
        })
        .collect();

    if windows.is_empty() {
        return None;
    }

    Some(Cached {
        usage: Usage {
            api_info: None,
            reset_credits: obj.get("resetCredits").and_then(|v| serde_json::from_value(v.clone()).ok()),
            plan,
            windows,
            balance: None,
        },
        ts,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn window_usage_roundtrips() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_DASHBOARD_HOME", dir.path());
        let u = Usage {
            api_info: None,
            reset_credits: None,
            plan: Some("Pro".into()),
            windows: vec![UsageWindow {
                label: "5 小时".into(),
                pct: 72.0,
                reset_at: None,
            }],
            balance: None,
        };
        write(&u, "claude");
        let got = read("claude").unwrap();
        assert_eq!(got.usage.plan.as_deref(), Some("Pro"));
        assert_eq!(got.usage.windows[0].pct, 72.0);
        std::env::remove_var("USAGE_DASHBOARD_HOME");
    }

    #[test]
    #[serial]
    fn balance_usage_roundtrips() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_DASHBOARD_HOME", dir.path());
        let u = Usage {
            api_info: None,
            reset_credits: None,
            plan: None,
            windows: vec![],
            balance: Some(BalanceInfo {
                balance: 18.42,
                used: 31.58,
                currency: "$".into(),
                request_count: Some(12),
                models: vec![ModelEntry {
                    name: "gpt-4.1".into(),
                    vendor: "OpenAI".into(),
                }],
            }),
        };
        write(&u, "phanrouter");
        let got = read("phanrouter").unwrap();
        let b = got.usage.balance.unwrap();
        assert_eq!(b.balance, 18.42);
        assert_eq!(b.models[0].vendor, "OpenAI");
        std::env::remove_var("USAGE_DASHBOARD_HOME");
    }

    #[test]
    #[serial]
    fn read_missing_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_DASHBOARD_HOME", dir.path());
        assert!(read("nope").is_none());
        std::env::remove_var("USAGE_DASHBOARD_HOME");
    }
    #[test]
    #[serial]
    fn relay_usage_extensions_roundtrip_without_credentials() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_DASHBOARD_HOME", dir.path());
        let payload: crate::state::RelayPayload = serde_json::from_str(include_str!("../tests/fixtures/mac-relay.json")).unwrap();
        for service in payload.services {
            let usage = match service.status {
                crate::state::ServiceStatus::Ok { usage, .. } |
                crate::state::ServiceStatus::Stale { usage, .. } => usage,
                _ => panic!("missing test usage"),
            };
            write(&usage, &service.config.id);
            let got = read(&service.config.id).unwrap();
            assert_eq!(serde_json::to_value(&usage.api_info).unwrap(), serde_json::to_value(&got.usage.api_info).unwrap());
            assert_eq!(serde_json::to_value(&usage.reset_credits).unwrap(), serde_json::to_value(&got.usage.reset_credits).unwrap());
        }
        std::env::remove_var("USAGE_DASHBOARD_HOME");
    }

}
