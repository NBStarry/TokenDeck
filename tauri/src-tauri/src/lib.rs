mod alerts;
mod cache;
mod commands;
mod config_store;
#[cfg(not(mobile))]
mod credentials;
mod fetchers;
mod http;
mod models;
mod paths;
mod state;
#[cfg(desktop)]
mod tray;
// 原生 App Widget 的数据写出,仅移动端。
#[cfg(any(mobile, test))]
mod widget;

use tauri::Manager;
#[cfg(desktop)]
use tauri::{Listener, WindowEvent};

use state::AppState;

// 后台刷新定时器睡眠下限(秒),对齐 Swift 的 60s 地板。
const MIN_REFRESH_SECONDS: u64 = 60;

// Android: 由 MainActivity.onCreate 调用,把 Activity 传进来初始化 ndk_context
// (Tauri 不用 ndk-glue,不会自动初始化;不初始化则 commands 里的 JNI 取 context 会 panic)。
#[cfg(target_os = "android")]
#[no_mangle]
pub extern "system" fn Java_app_usagedashboard_MainActivity_nativeInit<'local>(
    env: jni::JNIEnv<'local>,
    _this: jni::objects::JObject<'local>,
    context: jni::objects::JObject<'local>,
) {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        let vm = match env.get_java_vm() {
            Ok(v) => v,
            Err(_) => return,
        };
        let global = match env.new_global_ref(&context) {
            Ok(g) => g,
            Err(_) => return,
        };
        let vm_ptr = vm.get_java_vm_pointer() as *mut core::ffi::c_void;
        let ctx_ptr = global.as_raw() as *mut core::ffi::c_void;
        // 泄漏全局引用,保持 context 进程级存活(ndk_context 只存裸指针)。
        std::mem::forget(global);
        unsafe { ndk_context::initialize_android_context(vm_ptr, ctx_ptr) };
    });
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    // WebView2 on Windows can fail to repaint regions after DOM changes while the
    // window is stable (GPU compositing not invalidating dirty rects). Disabling GPU
    // forces software rendering, which repaints reliably.
    #[cfg(windows)]
    std::env::set_var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", "--disable-gpu");

    let config = config_store::load();
    // 桌面端启动即应用代理(若 config 配了 proxyUrl),让首刷就能走代理。
    #[cfg(not(mobile))]
    http::set_proxy(config.proxy_url.clone());
    let app_state = AppState::new(config);

    #[allow(unused_mut)]
    let mut builder = tauri::Builder::default().plugin(tauri_plugin_notification::init());

    // 开机自启仅桌面端有意义(LaunchAgent / Windows 注册表),移动端无此概念。
    #[cfg(desktop)]
    {
        builder = builder.plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            Some(vec![]),
        ));
    }

    builder
        .manage(app_state)
        .invoke_handler(tauri::generate_handler![
            commands::get_snapshots,
            commands::get_config,
            commands::refresh_now,
            commands::set_service_enabled,
            commands::move_service,
            commands::set_display_content,
            commands::set_alerts_enabled,
            commands::set_alert_threshold,
            commands::set_alert_rule,
            commands::set_alert_cooldown_minutes,
            commands::set_relay_config,
            commands::request_pin_widget,
            commands::request_pin_double_widget,
            commands::is_mobile,
            commands::quit,
        ])
        .setup(|app| {
            let handle = app.handle().clone();

            // 移动端:把 config/cache/凭证 落到 app 可写沙盒(app_config_dir)。
            // 否则 dirs::config_dir() 指向只读路径,写凭证/存配置报 EROFS。
            // run() 早期那次 config 加载发生在注入之前(读只读路径拿默认值),
            // 这里注入后重新加载,确保读到上次持久化的配置并让后续写入落到可写处。
            #[cfg(mobile)]
            {
                if let Ok(dir) = app.path().app_config_dir() {
                    let _ = std::fs::create_dir_all(&dir);
                    paths::set_base_dir(dir);
                    let cfg = config_store::load();
                    let state = app.state::<AppState>();
                    *state.config.lock().unwrap() = cfg;
                    state.rebuild_states();
                }
            }

            // 桌面端:托盘 + popover 失焦收起 + usage-updated 驱动托盘告警图标。
            // 移动端无托盘/无浮动窗口/无失焦模型,整体跳过(主 App 全屏显示)。
            #[cfg(desktop)]
            {
                // 1) 托盘。
                tray::build_tray(&handle)?;

                // 2) popover 窗口失焦自动收起(对齐 Swift popover .transient 行为)。
                if let Some(window) = app.get_webview_window("main") {
                    let win = window.clone();
                    window.on_window_event(move |event| {
                        if let WindowEvent::Focused(false) = event {
                            let _ = win.hide();
                        }
                    });
                }

                // 3) usage-updated 事件 → 同步托盘告警图标。
                //    选这条单一通路:timer / refresh_now 命令 / 告警配置变更都会 emit usage-updated,
                //    在此统一驱动托盘,避免在 state.refresh 内反向依赖 tray。
                let alert_handle = handle.clone();
                app.listen("usage-updated", move |_event| {
                    let count = alert_handle.state::<AppState>().active_alert_count();
                    tray::set_alert(&alert_handle, count);
                });
            }

            // 4) 后台刷新定时器:每轮重读 config 的 refresh_seconds(取 60s 地板),
            //    sleep 后 refresh。不跨 .await 持有 Mutex guard(读完即放锁)。
            let timer_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                loop {
                    let secs = {
                        let state = timer_handle.state::<AppState>();
                        let cfg = state.config.lock().unwrap();
                        (cfg.refresh_seconds.max(0) as u64).max(MIN_REFRESH_SECONDS)
                    };
                    tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
                    let state = timer_handle.state::<AppState>();
                    state.refresh(&timer_handle).await;
                }
            });

            // 5) 启动首刷。
            let first_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                let state = first_handle.state::<AppState>();
                state.refresh(&first_handle).await;
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
