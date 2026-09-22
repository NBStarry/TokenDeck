// 应用运行态:状态表、刷新编排、配置变更与告警冷却。
// 行为对齐 Sources/UsageBar/UsageStore.swift(refresh / apply / rebuildStates / updateAlerts)。
//
// 关键约束:
// - apply_outcome 只负责"更新状态 + 写缓存 + 评估告警(返回应触发的通知)",不依赖 AppHandle,
//   以便单测(无 Tauri 运行时)。通知/事件/托盘由 refresh 在持有 AppHandle 时处理。
// - refresh 中绝不跨 .await 持有 Mutex guard:先锁取配置克隆 → 放锁 → 并发取数 → 逐个回锁 apply。

use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};
#[cfg(not(mobile))]
use tauri_plugin_notification::NotificationExt;

use crate::alerts;
use crate::cache;
use crate::config_store;
use crate::fetchers;
use crate::models::{AppConfig, ServiceConfig, Usage};

// 单个服务的运行态。带内部 `kind` tag 供前端区分。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ServiceStatus {
    Loading,
    // 注意:enum 的 rename_all 只改变体名,不改结构变体内的字段。
    // 这些字段必须显式 rename 成 camelCase,否则前端读到的是 undefined
    // (历史 bug:fetched_at 序列化为 snake_case → hm(undefined) 抛错 → 渲染中断)。
    Ok {
        usage: Usage,
        #[serde(rename = "fetchedAt")]
        fetched_at: DateTime<Utc>,
    },
    Stale {
        usage: Usage,
        #[serde(rename = "cachedAt")]
        cached_at: Option<DateTime<Utc>>,
        error: String,
    },
    Error {
        message: String,
    },
}

// 前端列表项:配置 + 状态。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceSnapshot {
    pub config: ServiceConfig,
    pub status: ServiceStatus,
    #[serde(default)]
    pub is_current_account: bool,
}

// relay 模式下从 Mac 拉取的中转快照(契约 JSON 顶层结构)。
#[derive(Debug, Clone, Deserialize)]
pub struct RelayPayload {
    pub ts: Option<String>,
    pub services: Vec<ServiceSnapshot>,
}

pub struct AppState {
    pub config: Mutex<AppConfig>,
    pub statuses: Mutex<HashMap<String, ServiceStatus>>,
    pub last_alert_at: Mutex<HashMap<String, DateTime<Utc>>>,
    pub active_alert_keys: Mutex<HashMap<String, HashSet<String>>>,
    pub last_updated: Mutex<Option<DateTime<Utc>>>,
    pub relay_snapshots: Mutex<Option<Vec<ServiceSnapshot>>>,
}

impl AppState {
    pub fn new(config: AppConfig) -> Self {
        // 启动时用缓存预填,避免空白(对齐 Swift init)。
        let mut statuses = HashMap::new();
        for cfg in config.services.iter().filter(|c| c.enabled) {
            if let Some(cached) = cache::read(&cfg.id) {
                statuses.insert(
                    cfg.id.clone(),
                    ServiceStatus::Stale {
                        usage: cached.usage,
                        cached_at: cached.ts,
                        error: "加载中…".to_string(),
                    },
                );
            } else {
                statuses.insert(cfg.id.clone(), ServiceStatus::Loading);
            }
        }
        AppState {
            config: Mutex::new(config),
            statuses: Mutex::new(statuses),
            last_alert_at: Mutex::new(HashMap::new()),
            active_alert_keys: Mutex::new(HashMap::new()),
            last_updated: Mutex::new(None),
            relay_snapshots: Mutex::new(None),
        }
    }

    // relay 模式是否启用。
    fn relay_enabled(&self) -> bool {
        self.config
            .lock()
            .unwrap()
            .relay
            .as_ref()
            .map(|r| r.enabled)
            .unwrap_or(false)
    }

    // 将中转快照写入 relay_snapshots。
    pub fn apply_relay(&self, services: Vec<ServiceSnapshot>) {
        *self.relay_snapshots.lock().unwrap() = Some(services);
    }

    pub fn mark_relay_stale(&self) {
        if let Some(services) = self.relay_snapshots.lock().unwrap().as_mut() {
            for service in services {
                if let ServiceStatus::Ok { usage, fetched_at } = &service.status {
                    service.status = ServiceStatus::Stale {
                        usage: usage.clone(), cached_at: Some(*fetched_at),
                        error: "中转刷新失败，显示上次数据".into(),
                    };
                }
            }
        }
    }

    #[cfg(mobile)]
    fn set_enabled_errors(&self, message: &str) {
        let config = self.config.lock().unwrap();
        let mut statuses = self.statuses.lock().unwrap();
        statuses.clear();
        for cfg in config.services.iter().filter(|c| c.enabled) {
            statuses.insert(
                cfg.id.clone(),
                ServiceStatus::Error {
                    message: message.to_string(),
                },
            );
        }
    }

    // 按 config 顺序、仅 enabled 输出快照;状态缺失时用 cache→Stale("加载中…") 或 Loading。
    pub fn snapshots(&self) -> Vec<ServiceSnapshot> {
        // relay 模式:若已有中转快照直接返回,跳过本地取数结果。
        if self.relay_enabled() {
            if let Some(s) = self.relay_snapshots.lock().unwrap().clone() {
                return s;
            }
        }
        let config = self.config.lock().unwrap();
        let statuses = self.statuses.lock().unwrap();
        config
            .services
            .iter()
            .filter(|c| c.enabled)
            .map(|cfg| {
                let status = match statuses.get(&cfg.id) {
                    Some(s) => s.clone(),
                    None => match cache::read(&cfg.id) {
                        Some(cached) => ServiceStatus::Stale {
                            usage: cached.usage,
                            cached_at: cached.ts,
                            error: "加载中…".to_string(),
                        },
                        None => ServiceStatus::Loading,
                    },
                };
                ServiceSnapshot {
                    is_current_account: false,
                    config: cfg.clone(),
                    status,
                }
            })
            .collect()
    }

    // 托盘徽标据此计数切换告警图标(lib.rs 的 usage-updated 监听器消费)。
    #[cfg(desktop)]
    pub fn active_alert_count(&self) -> usize {
        self.active_alert_keys
            .lock()
            .unwrap()
            .values()
            .map(|s| s.len())
            .sum()
    }

    // 更新单个服务状态 + 写缓存 + 评估告警。
    // 返回应触发的通知(标题, 正文)列表;不依赖 AppHandle，便于单测。
    // 冷却在此处理:`now - last < max(60, cooldown)` 则跳过通知,但仍计入 active_keys(对齐 Swift)。
    #[cfg(not(mobile))]
    pub fn apply_outcome(
        &self,
        id: &str,
        outcome: Result<Usage, String>,
    ) -> Vec<(String, String)> {
        match outcome {
            Ok(usage) => {
                cache::write(&usage, id);
                let pending = self.evaluate_alerts(id, &usage, true);
                let mut statuses = self.statuses.lock().unwrap();
                statuses.insert(
                    id.to_string(),
                    ServiceStatus::Ok {
                        usage,
                        fetched_at: Utc::now(),
                    },
                );
                pending
            }
            Err(msg) => {
                let status = match cache::read(id) {
                    Some(cached) => ServiceStatus::Stale {
                        usage: cached.usage,
                        cached_at: cached.ts,
                        error: msg,
                    },
                    None => ServiceStatus::Error { message: msg },
                };
                self.statuses.lock().unwrap().insert(id.to_string(), status);
                Vec::new()
            }
        }
    }

    // 评估某服务告警:更新 active_alert_keys,处理冷却,返回应发送的通知。
    // send_notifications=false 时只刷新 active_keys(用于配置变更后的重算)。
    fn evaluate_alerts(
        &self,
        id: &str,
        usage: &Usage,
        send_notifications: bool,
    ) -> Vec<(String, String)> {
        let (service, alerts) = {
            let config = self.config.lock().unwrap();
            let service = config.services.iter().find(|c| c.id == id).cloned();
            (service, config.alerts.clone())
        };
        let Some(service) = service else {
            return Vec::new();
        };

        let now = Utc::now();
        let result = alerts::evaluate(&service, usage, &alerts, now);

        // active_keys 始终更新(无论冷却)。
        self.active_alert_keys
            .lock()
            .unwrap()
            .insert(id.to_string(), result.active_keys.iter().cloned().collect());

        if !send_notifications {
            return Vec::new();
        }

        let cooldown = alerts.cooldown_seconds.max(60);
        let mut last_alert_at = self.last_alert_at.lock().unwrap();
        let mut pending = Vec::new();
        for fire in result.fires {
            if let Some(last) = last_alert_at.get(&fire.key) {
                if (now - *last).num_seconds() < cooldown {
                    continue;
                }
            }
            last_alert_at.insert(fire.key.clone(), now);
            pending.push((fire.title, fire.body));
        }
        pending
    }

    // 全量刷新:对每个 enabled 服务并发取数,逐个 apply,触发通知,emit("usage-updated")。
    pub async fn refresh(&self, app: &AppHandle) {
        // 中转模式:从 Mac 拉快照,跳过本地取数。
        let relay = self.config.lock().unwrap().relay.clone();
        if let Some(r) = relay.filter(|r| r.enabled) {
            match fetchers::fetch_relay(&r).await {
                Ok(payload) => {
                    let lu = payload.ts.as_deref()
                        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                        .map(|dt| dt.with_timezone(&chrono::Utc))
                        .unwrap_or_else(Utc::now);
                    self.apply_relay(payload.services);
                    *self.last_updated.lock().unwrap() = Some(lu);
                    #[cfg(mobile)]
                    {
                        let snaps = self.snapshots();
                        let lu = *self.last_updated.lock().unwrap();
                        crate::widget::write_snapshot(&snaps, lu);
                    }
                    let _ = app.emit("usage-updated", ());
                }
                Err(_e) => {
                    self.mark_relay_stale();
                    #[cfg(mobile)]
                    {
                        if self.relay_snapshots.lock().unwrap().is_none() {
                            self.set_enabled_errors(&_e);
                        }
                        let snaps = self.snapshots();
                        let lu = *self.last_updated.lock().unwrap();
                        crate::widget::write_snapshot(&snaps, lu);
                    }
                    // 保留快照及其原始时间，但明确标记为旧数据。
                    let _ = app.emit("usage-updated", ());
                }
            }
            return;
        }

        #[cfg(mobile)]
        {
            self.set_enabled_errors("请先配置手机中转");
            *self.last_updated.lock().unwrap() = None;
            let snaps = self.snapshots();
            crate::widget::write_snapshot(&snaps, None);
            let _ = app.emit("usage-updated", ());
            return;
        }

        #[cfg(not(mobile))]
        {
            // 1) 锁取需要的 enabled 配置克隆,随即放锁。
            let services = {
                let config = self.config.lock().unwrap();
                config
                    .services
                    .iter()
                    .filter(|c| c.enabled)
                    .cloned()
                    .collect::<Vec<_>>()
            };

            // 2) 并发取数:各服务独立,一个失败不影响其他。
            let mut set = tokio::task::JoinSet::new();
            for cfg in services {
                set.spawn(async move {
                    let outcome = fetchers::fetch_service(&cfg).await;
                    (cfg.id, outcome)
                });
            }

            // 3) 逐个回锁 apply,收集待发通知。
            let mut pending: Vec<(String, String)> = Vec::new();
            while let Some(res) = set.join_next().await {
                if let Ok((id, outcome)) = res {
                    pending.extend(self.apply_outcome(&id, outcome));
                }
            }

            // 4) 发送通知(在持有 AppHandle 时)。
            for (title, body) in pending {
                let _ = app
                    .notification()
                    .builder()
                    .title(title)
                    .body(body)
                    .show();
            }

            *self.last_updated.lock().unwrap() = Some(Utc::now());

            let _ = app.emit("usage-updated", ());
        }
    }

    // 配置变更后:重建状态表(保留已有状态,缺失补 cache/Loading)+ 清理失效服务的告警键。
    // 对齐 Swift rebuildStates。
    pub fn rebuild_states(&self) {
        let config = self.config.lock().unwrap();
        let enabled_ids: HashSet<String> = config
            .services
            .iter()
            .filter(|c| c.enabled)
            .map(|c| c.id.clone())
            .collect();

        let mut statuses = self.statuses.lock().unwrap();
        let mut next: HashMap<String, ServiceStatus> = HashMap::new();
        for cfg in config.services.iter().filter(|c| c.enabled) {
            if let Some(existing) = statuses.get(&cfg.id) {
                next.insert(cfg.id.clone(), existing.clone());
            } else if let Some(cached) = cache::read(&cfg.id) {
                next.insert(
                    cfg.id.clone(),
                    ServiceStatus::Stale {
                        usage: cached.usage,
                        cached_at: cached.ts,
                        error: "加载中…".to_string(),
                    },
                );
            } else {
                next.insert(cfg.id.clone(), ServiceStatus::Loading);
            }
        }
        *statuses = next;
        drop(statuses);
        drop(config);

        // 清理已失效服务的活跃告警键。
        self.active_alert_keys
            .lock()
            .unwrap()
            .retain(|sid, _| enabled_ids.contains(sid));
    }

    // 在当前已知用量上重算活跃告警(不发通知)。用于告警相关配置变更后(对齐 Swift refreshActiveAlertsFromCurrentStates)。
    pub fn refresh_active_alerts(&self) {
        let alerts_enabled = self.config.lock().unwrap().alerts.enabled;
        if !alerts_enabled {
            self.active_alert_keys.lock().unwrap().clear();
            return;
        }
        // 收集 (id, usage) 供重算,避免在评估时持有 statuses 锁。
        let snapshots: Vec<(String, Option<Usage>)> = {
            let statuses = self.statuses.lock().unwrap();
            statuses
                .iter()
                .map(|(id, status)| {
                    let usage = match status {
                        ServiceStatus::Ok { usage, .. }
                        | ServiceStatus::Stale { usage, .. } => Some(usage.clone()),
                        ServiceStatus::Loading | ServiceStatus::Error { .. } => None,
                    };
                    (id.clone(), usage)
                })
                .collect()
        };
        for (id, usage) in snapshots {
            match usage {
                Some(u) => {
                    self.evaluate_alerts(&id, &u, false);
                }
                None => {
                    self.active_alert_keys
                        .lock()
                        .unwrap()
                        .insert(id, HashSet::new());
                }
            }
        }
    }

    // 持久化当前配置。
    pub fn save_config(&self) -> Result<(), String> {
        let config = self.config.lock().unwrap();
        config_store::save(&config).map_err(|e| format!("配置保存失败:{}", e))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn deserialize_relay_payload() {
        let json = r##"{"ts":"2026-06-25T05:56:00Z","services":[
          {"config":{"id":"claude","title":"Claude","accent":"#D97757","category":"subscription","fetcher":"claudeOauth","credentialFile":null,"enabled":true,
            "display":{"plan":true,"fiveHour":true,"weekly":true,"resetCountdown":true,"updatedAt":true,"balance":true,"used":true,"requestCount":true,"models":true}},
           "status":{"kind":"ok","usage":{"plan":null,"windows":[{"label":"周","pct":35,"resetAt":null}],"balance":null},"fetchedAt":"2026-06-25T05:56:00Z"}}]}"##;
        let p: RelayPayload = serde_json::from_str(json).unwrap();
        assert_eq!(p.services.len(), 1);
        match &p.services[0].status {
            ServiceStatus::Ok { usage, .. } => assert_eq!(usage.windows[0].pct, 35.0),
            _ => panic!("expected ok"),
        }
    }

    #[test]
    #[serial]
    fn failure_falls_back_to_cache_as_stale() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_DASHBOARD_HOME", dir.path());
        let st = AppState::new(crate::models::AppConfig::default());
        // 预置缓存
        let u = crate::models::Usage {
            api_info: None,
            reset_credits: None,
            plan: Some("Pro".into()),
            windows: vec![crate::models::UsageWindow {
                label: "周".into(),
                pct: 10.0,
                reset_at: None,
            }],
            balance: None,
        };
        crate::cache::write(&u, "claude");
        st.apply_outcome("claude", Err("boom".into()));
        let s = st.statuses.lock().unwrap();
        match s.get("claude").unwrap() {
            ServiceStatus::Stale { error, .. } => assert_eq!(error, "boom"),
            _ => panic!("expected stale"),
        }
        std::env::remove_var("USAGE_DASHBOARD_HOME");
    }

    #[test]
    #[serial]
    fn failure_without_cache_is_error() {
        let dir = tempfile::tempdir().unwrap();
        std::env::set_var("USAGE_DASHBOARD_HOME", dir.path());
        let st = AppState::new(crate::models::AppConfig::default());
        st.apply_outcome("codex", Err("nope".into()));
        let s = st.statuses.lock().unwrap();
        assert!(matches!(s.get("codex").unwrap(), ServiceStatus::Error { .. }));
        std::env::remove_var("USAGE_DASHBOARD_HOME");
    }
}
