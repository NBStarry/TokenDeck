// 把当前用量快照写成 widget.json,供原生 App Widget(Kotlin)读取渲染。
// 仅移动端调用。写入 home_dir()/widget.json(= Kotlin 端 context.dataDir/widget.json)。
// 输出结构化数据(窗口型给 windows 的 label/pct,余额型给 balance),让小组件画进度条;
// 每个小组件实例绑定一个服务 id,单卡片展示。时间用 epoch 毫秒,由 Kotlin 本地化。

use chrono::{DateTime, Utc};
use serde_json::{json, Value};

use crate::paths::home_dir;
use crate::state::{ServiceSnapshot, ServiceStatus};

#[cfg(target_os = "android")]
fn notify_android_widgets() {
    use jni::objects::{JObject, JValue};

    let ctx = ndk_context::android_context();
    let vm = match unsafe { jni::JavaVM::from_raw(ctx.vm().cast()) } {
        Ok(vm) => vm,
        Err(_) => return,
    };
    let mut env = match vm.attach_current_thread() {
        Ok(env) => env,
        Err(_) => return,
    };
    let context = unsafe { JObject::from_raw(ctx.context().cast()) };

    for provider in [
        "app.usagedashboard.UsageWidgetProvider",
        "app.usagedashboard.UsageDoubleWidgetProvider",
    ] {
        let action = match env.new_string("app.usagedashboard.WIDGET_RENDER") {
            Ok(action) => action,
            Err(_) => continue,
        };
        let action_obj = JObject::from(action);
        let intent = match env.new_object(
            "android/content/Intent",
            "(Ljava/lang/String;)V",
            &[JValue::Object(&action_obj)],
        ) {
            Ok(intent) => intent,
            Err(_) => continue,
        };

        let class_name = match env.new_string(provider) {
            Ok(class_name) => class_name,
            Err(_) => continue,
        };
        let class_name_obj = JObject::from(class_name);
        if env
            .call_method(
                &intent,
                "setClassName",
                "(Landroid/content/Context;Ljava/lang/String;)Landroid/content/Intent;",
                &[JValue::Object(&context), JValue::Object(&class_name_obj)],
            )
            .is_err()
        {
            continue;
        }

        let _ = env.call_method(
            &context,
            "sendBroadcast",
            "(Landroid/content/Intent;)V",
            &[JValue::Object(&intent)],
        );
    }
}

fn service_json(s: &ServiceSnapshot) -> Value {
    let title = if s.config.id == "codex" {
        "Codex"
    } else {
        s.config.title.as_str()
    };
    let mut v = json!({
        "id": s.config.id,
        "title": title,
        "accent": s.config.accent,
        "isCurrentAccount": s.is_current_account,
    });
    match &s.status {
        ServiceStatus::Loading => {
            v["kind"] = json!("loading");
        }
        ServiceStatus::Error { message } => {
            v["kind"] = json!("error");
            v["message"] = json!(message);
        }
        ServiceStatus::Ok { usage, .. } | ServiceStatus::Stale { usage, .. } => {
            v["kind"] = json!("ok");
            v["stale"] = json!(matches!(&s.status, ServiceStatus::Stale { .. }));
            v["apiInfo"] = json!(usage.api_info);
            v["resetCredits"] = json!(usage.reset_credits);
            if let Some(p) = &usage.plan {
                v["plan"] = json!(p);
            }
            if let Some(b) = &usage.balance {
                v["balance"] = json!({
                    "balance": b.balance,
                    "used": b.used,
                    "currency": b.currency,
                    "requestCount": b.request_count,
                });
            } else {
                let wins: Vec<Value> = usage
                    .windows
                    .iter()
                    .map(|w| {
                        let mut wj = json!({ "label": w.label, "pct": w.pct });
                        if let Some(r) = w.reset_at {
                            wj["resetAtMs"] = json!(r.timestamp_millis());
                        }
                        wj
                    })
                    .collect();
                v["windows"] = json!(wins);
            }
        }
    }
    v
}

pub fn write_snapshot(snapshots: &[ServiceSnapshot], last_updated: Option<DateTime<Utc>>) {
    let updated_ms = last_updated.map(|t| t.timestamp_millis()).unwrap_or(0);
    let services: Vec<Value> = snapshots.iter().map(service_json).collect();
    let doc = json!({ "updatedAtMs": updated_ms, "services": services });
    if let Some(home) = home_dir() {
        if std::fs::write(home.join("widget.json"), doc.to_string()).is_ok() {
            #[cfg(target_os = "android")]
            notify_android_widgets();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_payload_preserves_providers_credits_and_current_identity() {
        let payload: crate::state::RelayPayload = serde_json::from_str(include_str!("../tests/fixtures/mac-relay.json")).unwrap();
        let services: Vec<Value> = payload.services.iter().map(service_json).collect();
        assert_eq!(services[0]["isCurrentAccount"], true);
        assert_eq!(services[0]["windows"][0]["label"], "周");
        assert_eq!(services[0]["resetCredits"]["availableCount"], 2);
        assert_eq!(services[1]["stale"], true);
        assert_eq!(services[2]["apiInfo"]["balances"][0]["total"], 0.0);
        assert_eq!(services[3]["apiInfo"]["models"].as_array().unwrap().len(), 2);
        let state = crate::state::AppState::new(crate::models::AppConfig::default());
        state.apply_relay(payload.services);
        state.mark_relay_stale();
        let retained = state.relay_snapshots.lock().unwrap();
        let stale = service_json(&retained.as_ref().unwrap()[2]);
        assert_eq!(stale["stale"], true);
        assert_eq!(stale["apiInfo"]["balances"][1]["currency"], "USD");
    }
}
