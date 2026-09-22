// 取数器与解析层。逐字移植 Sources/UsageBar/UsageFetcher.swift 的解析逻辑。
// 纯解析函数(parse_*/infer_vendor/日期辅助)不打网络,可单测;
// fetch_service 负责取凭证 + 调 http::get_json + 调对应 parse 函数。

#[cfg(not(mobile))]
use chrono::{DateTime, TimeZone, Utc};
#[cfg(not(mobile))]
use serde_json::Value;

#[cfg(not(mobile))]
use crate::credentials::{self, CodexCreds, NewApiCreds};
#[cfg(not(mobile))]
use crate::http;
#[cfg(not(mobile))]
use crate::models::{
    BalanceInfo, FetcherKind, ModelEntry, ServiceConfig, Usage, UsageWindow,
};

// ─── 解析辅助 ──────────────────────────────────────────────────

// 容忍 number/string 的数值提取(对齐 Swift numeric(_:))。
#[cfg(not(mobile))]
fn numeric(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.parse::<f64>().ok(),
        _ => None,
    }
}

// epoch(秒或毫秒) → DateTime。raw > 1e11 视为毫秒。
#[cfg(not(mobile))]
pub fn date_from_epoch(value: &Value) -> Option<DateTime<Utc>> {
    let raw = numeric(value)?;
    let secs = if raw > 1e11 { raw / 1000.0 } else { raw };
    let whole = secs.trunc() as i64;
    let nanos = ((secs - secs.trunc()) * 1_000_000_000.0).round() as u32;
    Utc.timestamp_opt(whole, nanos).single()
}

// ISO8601 字符串 → DateTime(支持带/不带小数秒)。
#[cfg(not(mobile))]
pub fn date_from_iso(value: &Value) -> Option<DateTime<Utc>> {
    let s = value.as_str()?;
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
}

// 首字母大写(对齐 Swift capitalizedPlan)。空串/非字符串返回 None。
#[cfg(not(mobile))]
pub fn capitalized_plan(value: &Value) -> Option<String> {
    let s = value.as_str()?;
    if s.is_empty() {
        return None;
    }
    let mut chars = s.chars();
    let first = chars.next()?;
    Some(first.to_uppercase().collect::<String>() + chars.as_str())
}

// pct 量化:(x*10).round()/10。
#[cfg(not(mobile))]
fn round_pct(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

// ─── Claude ───────────────────────────────────────────────────

#[cfg(not(mobile))]
pub fn parse_claude(v: &Value, status: u16) -> Result<Usage, String> {
    let data = match v.as_object() {
        Some(_) => v,
        None => return Err("接口返回结构异常".to_string()),
    };
    if status == 401 {
        return Err("Claude 登录已过期,请重新登录".to_string());
    }
    if !(200..300).contains(&status) {
        return Err(format!("接口请求失败 (HTTP {})", status));
    }

    let mut windows: Vec<UsageWindow> = Vec::new();
    for (key, label) in [("five_hour", "5 小时"), ("seven_day", "周")] {
        let w = match data.get(key).filter(|x| x.is_object()) {
            Some(w) => w,
            None => continue,
        };
        let util = match w.get("utilization") {
            Some(u) => u,
            None => continue,
        };
        let pct = match numeric(util) {
            Some(p) => p,
            None => continue,
        };
        windows.push(UsageWindow {
            label: label.to_string(),
            pct: round_pct(pct),
            reset_at: w.get("resets_at").and_then(date_from_iso),
        });
    }
    if windows.is_empty() {
        return Err("未解析到用量数据(接口结构可能已变)".to_string());
    }
    let plan = data.get("plan_type").and_then(capitalized_plan);
    Ok(Usage {
        api_info: None,
        reset_credits: None,
        plan,
        windows,
        balance: None,
    })
}

// ─── Codex / GPT ──────────────────────────────────────────────

// 从 dict 中按 keys 顺序取第一个对象型子项。
#[cfg(not(mobile))]
fn pick_dict<'a>(d: &'a Value, keys: &[&str]) -> Option<&'a Value> {
    for k in keys {
        if let Some(v) = d.get(*k).filter(|x| x.is_object()) {
            return Some(v);
        }
    }
    None
}

// percent_left / remaining_percent 表示"剩余",换算成"已用";否则取 used_percent。
#[cfg(not(mobile))]
fn used_pct(w: &Value) -> Option<f64> {
    for k in ["percent_left", "remaining_percent"] {
        if let Some(v) = w.get(k).and_then(numeric) {
            return Some((100.0 - v).max(0.0));
        }
    }
    w.get("used_percent").and_then(numeric)
}

#[cfg(not(mobile))]
fn codex_reset_at(w: &Value) -> Option<DateTime<Utc>> {
    for k in ["reset_time_ms", "reset_at"] {
        if let Some(v) = w.get(k) {
            if k == "reset_time_ms" {
                if let Some(d) = date_from_epoch(v) {
                    return Some(d);
                }
            } else if let Some(d) = date_from_epoch(v).or_else(|| date_from_iso(v)) {
                return Some(d);
            }
        }
    }
    if let Some(nested) = w.get("primary_window").filter(|x| x.is_object()) {
        return codex_reset_at(nested);
    }
    None
}

#[cfg(not(mobile))]
pub fn parse_codex(v: &Value, status: u16) -> Result<Usage, String> {
    let data = match v.as_object() {
        Some(_) => v,
        None => return Err("接口返回结构异常".to_string()),
    };
    if status == 401 {
        return Err("Codex 登录已过期,运行 codex login 刷新".to_string());
    }
    if !(200..300).contains(&status) {
        return Err(format!("接口请求失败 (HTTP {})", status));
    }

    // 部分情况下接口以 200 返回错误信封。
    if let Some(err) = data.get("error").filter(|x| x.is_object()) {
        let code = err.get("code").and_then(|c| c.as_str()).unwrap_or("");
        let msg = err.get("message").and_then(|m| m.as_str()).unwrap_or("");
        if code.contains("expired")
            || msg.contains("expired")
            || data.get("status").and_then(|s| s.as_i64()) == Some(401)
        {
            return Err("Codex 登录已过期,运行 codex login 刷新".to_string());
        }
        let reason = if !msg.is_empty() {
            msg
        } else if !code.is_empty() {
            code
        } else {
            "未知错误"
        };
        return Err(format!("接口返回错误:{}", reason));
    }

    let rl = pick_dict(data, &["rate_limit", "rate_limits"]).unwrap_or(data);
    let five_hour = pick_dict(
        rl,
        &["five_hour", "five_hour_limit", "five_hour_rate_limit", "primary"],
    )
    .or_else(|| pick_dict(rl, &["primary_window"]));
    let weekly = pick_dict(
        rl,
        &["weekly", "weekly_limit", "weekly_rate_limit", "secondary"],
    )
    .or_else(|| pick_dict(rl, &["secondary_window"]));

    let mut windows: Vec<UsageWindow> = Vec::new();
    for (w, label) in [(five_hour, "5 小时"), (weekly, "周")] {
        let w = match w {
            Some(w) => w,
            None => continue,
        };
        let pct = match used_pct(w) {
            Some(p) => p,
            None => continue,
        };
        windows.push(UsageWindow {
            label: label.to_string(),
            pct: round_pct(pct),
            reset_at: codex_reset_at(w),
        });
    }
    if windows.is_empty() {
        return Err("未解析到用量数据(接口结构可能已变)".to_string());
    }
    let plan = data.get("plan_type").and_then(capitalized_plan);
    Ok(Usage {
        api_info: None,
        reset_credits: None,
        plan,
        windows,
        balance: None,
    })
}

// ─── New-API 兼容网关 ──────────────────────────────────────────

// 解析 /api/user/self,返回 (balance, used, request_count)。
#[cfg(not(mobile))]
pub fn parse_newapi_self(
    v: &Value,
    status: u16,
    quota_per_unit: f64,
    _currency: &str,
    title: &str,
) -> Result<(f64, f64, Option<i64>), String> {
    let obj = match v.as_object() {
        Some(_) => v,
        None => return Err("接口返回结构异常".to_string()),
    };
    if status == 401 {
        return Err(format!("{} 访问令牌已失效,请重新生成", title));
    }
    if obj.get("success").and_then(|s| s.as_bool()) == Some(false) {
        let msg = obj
            .get("message")
            .and_then(|m| m.as_str())
            .unwrap_or("未知错误");
        if msg.contains("access token") {
            return Err(format!("{} 访问令牌无效,请重新生成", title));
        }
        return Err(format!("接口返回错误:{}", msg));
    }
    let data = match obj.get("data").filter(|x| x.is_object()) {
        Some(d) => d,
        None => return Err("未解析到余额数据(接口结构可能已变)".to_string()),
    };
    let quota = match data.get("quota").and_then(numeric) {
        Some(q) => q,
        None => return Err("未解析到余额数据(接口结构可能已变)".to_string()),
    };
    let unit = if quota_per_unit > 0.0 {
        quota_per_unit
    } else {
        500000.0
    };
    let balance = quota / unit;
    let used = data.get("used_quota").and_then(numeric).unwrap_or(0.0) / unit;
    let request_count = data
        .get("request_count")
        .and_then(numeric)
        .map(|x| x as i64);
    Ok((balance, used, request_count))
}

// ─── 模型广场推断 ──────────────────────────────────────────────

#[cfg(not(mobile))]
pub fn parse_pricing(v: &Value) -> Vec<ModelEntry> {
    let list = match v.get("data").and_then(|d| d.as_array()) {
        Some(l) => l,
        None => return Vec::new(),
    };
    // vendor_id → 厂商名
    let mut vendor_name: std::collections::HashMap<i64, String> =
        std::collections::HashMap::new();
    if let Some(vendors) = v.get("vendors").and_then(|x| x.as_array()) {
        for ven in vendors {
            if let (Some(id), Some(name)) = (
                ven.get("id").and_then(|i| i.as_i64()),
                ven.get("name").and_then(|n| n.as_str()),
            ) {
                vendor_name.insert(id, name.to_string());
            }
        }
    }
    list.iter()
        .filter_map(|m| {
            let name = m.get("model_name").and_then(|n| n.as_str())?;
            let vid = m.get("vendor_id").and_then(|i| i.as_i64());
            // 优先用接口的 vendor_id 映射;缺失时按模型名前缀推断来源。
            let vendor = vid
                .and_then(|id| vendor_name.get(&id).cloned())
                .unwrap_or_else(|| infer_vendor(name));
            Some(ModelEntry {
                name: name.to_string(),
                vendor,
            })
        })
        .collect()
}

// 按模型名推断厂商(接口 vendor_id 缺失时的兜底)。
#[cfg(not(mobile))]
pub fn infer_vendor(model: &str) -> String {
    let n = model.to_lowercase();
    // PhanRouter 自有改名:前缀 PR-<字母>- 即厂商代码(注意 pr-ge 要在 pr-g 之前判断)。
    let prefixes: [(&str, &str); 6] = [
        ("pr-a-", "Anthropic"),
        ("pr-ge", "Google"),
        ("pr-g-", "Google"),
        ("pr-o-", "OpenAI"),
        ("pr-x-", "xAI"),
        ("pr-v-", "视频生成"),
    ];
    for (p, vendor) in prefixes {
        if n.starts_with(p) {
            return vendor.to_string();
        }
    }

    let rules: [(&[&str], &str); 23] = [
        (
            &[
                "gpt",
                "o1",
                "o3",
                "o4",
                "chatgpt",
                "davinci",
                "text-embedding",
                "dall-e",
                "whisper",
                "tts",
                "sora",
                "codex",
            ],
            "OpenAI",
        ),
        (&["claude"], "Anthropic"),
        (&["gemini", "gemma", "imagen", "veo"], "Google"),
        (&["deepseek"], "DeepSeek"),
        (&["qwen", "qwq", "tongyi", "wan", "wanx"], "阿里巴巴"),
        (&["doubao", "seed", "ui-tars"], "字节跳动"),
        (&["moonshot", "kimi"], "Moonshot"),
        (&["glm", "chatglm", "cogview", "cogvideo"], "智谱"),
        (&["grok"], "xAI"),
        (&["kling"], "快手"),
        (&["ernie", "wenxin"], "百度"),
        (&["llama"], "Meta"),
        (&["hunyuan"], "腾讯"),
        (&["minimax", "abab"], "MiniMax"),
        (&["step-"], "阶跃星辰"),
        (&["spark"], "讯飞"),
        (&["jina"], "Jina"),
        (&["flux"], "Black Forest"),
        (&["midjourney", "mj_", "mj-"], "Midjourney"),
        (&["suno"], "Suno"),
        (&["xiaomi", "mimo"], "小米"),
        (&["speech-"], "MiniMax"),
        (&["sd1", "sd2", "sd3", "sdxl", "stable"], "Stability"),
    ];
    for (keys, vendor) in rules {
        if keys.iter().any(|k| n.contains(k)) {
            return vendor.to_string();
        }
    }
    // 注意:Swift 表末尾还有 ("kat-","kwai")→快手,放在最后。
    if ["kat-", "kwai"].iter().any(|k| n.contains(k)) {
        return "快手".to_string();
    }
    "其他".to_string()
}

// ─── relay 中转取数 ────────────────────────────────────────────

// 从 Mac 中转服务器拉取契约 JSON 快照。
// 使用 get_json_direct 绕过 GFW 代理——relay 是 Tailscale 私网直连,不该走代理。
pub async fn fetch_relay(
    relay: &crate::models::RelayConfig,
) -> Result<crate::state::RelayPayload, String> {
    let url = format!("{}/usage", relay.url.trim_end_matches('/'));
    let bearer = format!("Bearer {}", relay.secret);
    let (value, status) = crate::http::get_json_direct(&url, &[("Authorization", &bearer)])
        .await
        .map_err(|e| format!("连接 Mac 中转失败:{e}"))?;
    if status == 401 {
        return Err("中转密钥无效,请重新扫码".to_string());
    }
    if !(200..300).contains(&status) {
        return Err(format!("中转返回 HTTP {}", status));
    }
    serde_json::from_value::<crate::state::RelayPayload>(value)
        .map_err(|e| format!("中转数据格式异常:{e}"))
}

// ─── 网络入口 ──────────────────────────────────────────────────

#[cfg(not(mobile))]
pub async fn fetch_service(cfg: &ServiceConfig) -> Result<Usage, String> {
    match cfg.fetcher {
        FetcherKind::ClaudeOauth => fetch_claude().await,
        FetcherKind::CodexWham => fetch_codex().await,
        FetcherKind::NewApi => fetch_newapi(cfg).await,
        FetcherKind::Deepseek | FetcherKind::Yicloud => Err("请通过 Mac 中转查看此渠道".into()),
        FetcherKind::Unsupported => Err(format!("{} 暂不支持自动取数", cfg.title)),
    }
}

#[cfg(not(mobile))]
async fn fetch_claude() -> Result<Usage, String> {
    let token = credentials::claude_token()
        .ok_or_else(|| "未找到 Claude 登录凭证,请运行 claude 登录".to_string())?;
    let auth = format!("Bearer {}", token);
    let headers = [
        ("Authorization", auth.as_str()),
        ("Accept", "application/json"),
        ("anthropic-beta", "oauth-2025-04-20"),
    ];
    let (json, status) =
        http::get_json("https://api.anthropic.com/api/oauth/usage", &headers).await?;
    parse_claude(&json, status)
}

#[cfg(not(mobile))]
async fn fetch_codex() -> Result<Usage, String> {
    let creds = match credentials::codex_creds() {
        CodexCreds::Ok {
            access_token,
            account_id,
        } => (access_token, account_id),
        CodexCreds::MissingFile => {
            return Err("未找到 Codex 认证文件,请先运行 codex login".to_string())
        }
        CodexCreds::ParseError => return Err("Codex 认证文件解析失败".to_string()),
        CodexCreds::Incomplete => {
            return Err("Codex 凭证不完整,请运行 codex login".to_string())
        }
    };
    let auth = format!("Bearer {}", creds.0);
    let headers = [
        ("Authorization", auth.as_str()),
        ("ChatGPT-Account-Id", creds.1.as_str()),
        ("Accept", "application/json"),
        ("Origin", "https://chatgpt.com"),
        ("Referer", "https://chatgpt.com/"),
    ];
    let (json, status) =
        http::get_json("https://chatgpt.com/backend-api/wham/usage", &headers).await?;
    parse_codex(&json, status)
}

#[cfg(not(mobile))]
async fn fetch_newapi(cfg: &ServiceConfig) -> Result<Usage, String> {
    let file_name = cfg
        .credential_file
        .clone()
        .unwrap_or_else(|| format!("{}.json", cfg.id));
    let creds = match credentials::new_api_creds(&file_name) {
        NewApiCreds::Ok(c) => c,
        NewApiCreds::MissingFile(path) => {
            return Err(format!("未找到 {} 凭证,请配置 {}", cfg.title, path))
        }
        NewApiCreds::InvalidPath => {
            return Err(format!("{} 凭证文件路径无效", cfg.title))
        }
        NewApiCreds::Incomplete => {
            return Err(format!(
                "{} 凭证不完整(需 baseUrl + accessToken)",
                cfg.title
            ))
        }
    };
    let base = creds
        .base_url
        .strip_suffix('/')
        .unwrap_or(&creds.base_url)
        .to_string();

    let user_id = creds.user_id.to_string();
    let auth = format!("Bearer {}", creds.access_token);
    let headers = [
        ("Authorization", auth.as_str()),
        ("New-Api-User", user_id.as_str()),
        ("Accept", "application/json"),
    ];

    // 1) 余额 + 历史消耗(需鉴权)
    let self_url = format!("{}/api/user/self", base);
    let (self_json, self_status) = http::get_json(&self_url, &headers).await?;
    let (balance, used, request_count) = parse_newapi_self(
        &self_json,
        self_status,
        creds.quota_per_unit,
        &creds.currency,
        &cfg.title,
    )?;

    // 2) 模型广场(公开接口,失败不致命)
    let pricing_url = format!("{}/api/pricing", base);
    let models = match http::get_json(&pricing_url, &headers).await {
        Ok((json, status)) if (200..300).contains(&status) => parse_pricing(&json),
        _ => Vec::new(),
    };

    Ok(Usage {
        api_info: None,
        reset_credits: None,
        plan: None,
        windows: Vec::new(),
        balance: Some(BalanceInfo {
            balance,
            used,
            currency: creds.currency,
            request_count,
            models,
        }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn claude_parses_two_windows_and_plan() {
        let v = json!({
            "plan_type": "pro",
            "five_hour": {"utilization": 72.4, "resets_at": "2026-06-23T18:00:00Z"},
            "seven_day": {"utilization": 48, "resets_at": "2026-06-25T18:00:00Z"}
        });
        let u = parse_claude(&v, 200).unwrap();
        assert_eq!(u.plan.as_deref(), Some("Pro"));
        assert_eq!(u.windows.len(), 2);
        assert_eq!(u.windows[0].label, "5 小时");
        assert_eq!(u.windows[0].pct, 72.4);
        assert!(u.windows[0].reset_at.is_some());
    }

    #[test]
    fn claude_401_is_expired_error() {
        let v = json!({});
        assert!(parse_claude(&v, 401).unwrap_err().contains("过期"));
    }

    #[test]
    fn codex_converts_percent_left_to_used() {
        let v = json!({
            "rate_limits": {
                "primary": {"percent_left": 30, "reset_time_ms": 1_900_000_000_000i64},
                "secondary": {"used_percent": 12}
            }
        });
        let u = parse_codex(&v, 200).unwrap();
        assert_eq!(u.windows[0].pct, 70.0);
        assert_eq!(u.windows[1].pct, 12.0);
    }

    #[test]
    fn codex_detects_expired_envelope() {
        let v = json!({"error": {"code":"token_expired","message":"expired"}});
        assert!(parse_codex(&v, 200).unwrap_err().contains("过期"));
    }

    #[test]
    fn newapi_self_computes_money() {
        let v = json!({"success": true, "data": {"quota": 9_210_000, "used_quota": 15_790_000, "request_count": 12864}});
        let (bal, used, rc) = parse_newapi_self(&v, 200, 500000.0, "$", "X").unwrap();
        assert!((bal - 18.42).abs() < 1e-9);
        assert!((used - 31.58).abs() < 1e-9);
        assert_eq!(rc, Some(12864));
    }

    #[test]
    fn pricing_maps_vendor_id_then_infers() {
        let v = json!({
            "data": [
                {"model_name":"gpt-4.1","vendor_id":1},
                {"model_name":"claude-3.7-sonnet"},
                {"model_name":"pr-ge-foo"}
            ],
            "vendors": [{"id":1,"name":"OpenAI"}]
        });
        let m = parse_pricing(&v);
        assert_eq!(m[0].vendor, "OpenAI");
        assert_eq!(m[1].vendor, "Anthropic");
        assert_eq!(m[2].vendor, "Google");
    }

    #[test]
    fn infer_vendor_prefix_order() {
        assert_eq!(infer_vendor("pr-ge-x"), "Google");
        assert_eq!(infer_vendor("pr-g-x"), "Google");
        assert_eq!(infer_vendor("deepseek-r1"), "DeepSeek");
        assert_eq!(infer_vendor("totally-unknown"), "其他");
    }
}
