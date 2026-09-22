package app.usagedashboard

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.ColorStateList
import android.graphics.Color
import android.os.Build
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.time.Instant
import java.util.Date
import java.util.Locale

// 单服务主屏小组件:每个实例绑定一个渠道(WidgetConfigActivity 选定,存 SharedPreferences),
// 读 Rust 写的 dataDir/widget.json,按该渠道渲染窗口进度条 / 余额。点击打开 App。
class UsageWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            ACTION_RENDER -> refreshAll(context)
            ACTION_REFRESH -> {
                val mgr = AppWidgetManager.getInstance(context)
                val id = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID
                )
                val pending = goAsync()
                Thread {
                    try {
                        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) refreshAllInBackground(context, mgr)
                        else refreshOneInBackground(context, mgr, id)
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
        }
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) renderOne(context, mgr, id)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val p = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE).edit()
        for (id in ids) {
            p.remove("svc_$id")
            p.remove("style_$id")
        }
        p.apply()
    }

    companion object {
        private const val ACTION_REFRESH = "app.usagedashboard.WIDGET_REFRESH"
        const val ACTION_RENDER = "app.usagedashboard.WIDGET_RENDER"

        // App 离开前台时刷新所有实例。
        fun refreshAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val cn = ComponentName(context, UsageWidgetProvider::class.java)
            for (id in mgr.getAppWidgetIds(cn)) renderOne(context, mgr, id)
        }

        fun barColor(pct: Int): Int = when {
            pct >= 90 -> Color.parseColor("#F85149")
            pct >= 75 -> Color.parseColor("#D29922")
            else -> Color.parseColor("#3FB950")
        }

        private val WIN_ROW = intArrayOf(R.id.w_win0, R.id.w_win1, R.id.w_win2)
        private val WIN_LABEL = intArrayOf(R.id.w_win0_label, R.id.w_win1_label, R.id.w_win2_label)
        private val WIN_RESET = intArrayOf(R.id.w_win0_reset, R.id.w_win1_reset, R.id.w_win2_reset)
        private val WIN_PCT = intArrayOf(R.id.w_win0_pct, R.id.w_win1_pct, R.id.w_win2_pct)
        private val WIN_BAR = intArrayOf(R.id.w_win0_bar, R.id.w_win1_bar, R.id.w_win2_bar)

        private data class WidgetStyle(
            val dot: Float,
            val title: Float,
            val updated: Float,
            val label: Float,
            val reset: Float,
            val pct: Float,
            val balance: Float,
            val balanceSub: Float,
            val status: Float,
            val rootHPad: Int,
            val rootTopPad: Int,
            val rootBottomPad: Int,
            val headerBottom: Int,
            val rowGap: Int,
            val refreshSize: Float,
            val refreshPad: Int,
            val barHeight: Float,
        )

        private fun widgetStyle(context: Context, id: Int): WidgetStyle {
            return when (
                context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE)
                    .getString("style_$id", "large")
            ) {
                "compact" -> WidgetStyle(9f, 12f, 8f, 10.5f, 8f, 10.5f, 18f, 10f, 11f, 9, 3, 7, 3, 3, 22f, 4, 4f)
                "standard" -> WidgetStyle(9.5f, 13f, 8.5f, 11f, 8.5f, 11f, 19f, 10.5f, 11.5f, 10, 3, 8, 4, 4, 23f, 4, 4.5f)
                else -> WidgetStyle(10f, 13.5f, 8.5f, 11.5f, 8.5f, 11.5f, 19.5f, 11f, 12f, 11, 3, 9, 4, 4, 24f, 4, 4.5f)
            }
        }

        fun dp(context: Context, v: Int): Int =
            TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), context.resources.displayMetrics).toInt()

        fun setSp(views: RemoteViews, viewId: Int, size: Float) {
            views.setTextViewTextSize(viewId, TypedValue.COMPLEX_UNIT_SP, size)
        }

        private fun applyWidgetStyle(context: Context, views: RemoteViews, style: WidgetStyle) {
            setSp(views, R.id.w_dot, style.dot)
            setSp(views, R.id.w_title, style.title)
            setSp(views, R.id.w_updated, style.updated)
            for (i in 0 until 3) {
                setSp(views, WIN_LABEL[i], style.label)
                setSp(views, WIN_RESET[i], style.reset)
                setSp(views, WIN_PCT[i], style.pct)
            }
            setSp(views, R.id.w_bal_value, style.balance)
            setSp(views, R.id.w_bal_sub, style.balanceSub)
            setSp(views, R.id.w_status, style.status)

            views.setViewPadding(
                R.id.w_root,
                dp(context, style.rootHPad),
                dp(context, style.rootTopPad),
                dp(context, style.rootHPad),
                dp(context, style.rootBottomPad)
            )
            views.setViewPadding(R.id.w_header, 0, 0, 0, dp(context, style.headerBottom))
            views.setViewPadding(R.id.w_win1, 0, dp(context, style.rowGap), 0, 0)
            views.setViewPadding(R.id.w_win2, 0, dp(context, style.rowGap), 0, 0)
            val refreshPad = dp(context, style.refreshPad)
            views.setViewPadding(R.id.w_refresh, refreshPad, refreshPad, refreshPad, refreshPad)
            if (Build.VERSION.SDK_INT >= 31) {
                views.setViewLayoutWidth(R.id.w_refresh, style.refreshSize, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutHeight(R.id.w_refresh, style.refreshSize, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutWidth(R.id.w_refresh_hit, style.refreshSize + 10f, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutHeight(R.id.w_refresh_hit, style.refreshSize + 2f, TypedValue.COMPLEX_UNIT_DIP)
                for (bar in WIN_BAR) {
                    views.setViewLayoutHeight(bar, style.barHeight, TypedValue.COMPLEX_UNIT_DIP)
                }
            }
        }

        fun displayTitle(serviceId: String?, title: String): String =
            if (serviceId == "codex") "Codex" else title

        // 重置倒计时:>=1 小时显示 "1h25m",否则 "25m";已过/无则空。
        fun countdown(resetMs: Long): String {
            if (resetMs <= 0) return ""
            val diff = resetMs - System.currentTimeMillis()
            if (diff <= 0) return ""
            val totalMin = (diff / 60000).toInt()
            val h = totalMin / 60
            val m = totalMin % 60
            return if (h >= 1) "${h}h${m}m" else "${m}m"
        }

        fun renderOne(context: Context, mgr: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.usage_widget)
            applyWidgetStyle(context, views, widgetStyle(context, id))
            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val refresh = Intent(context, UsageWidgetProvider::class.java)
                .setAction(ACTION_REFRESH)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            val refreshPending = PendingIntent.getBroadcast(context, 100_000 + id, refresh, flags)
            views.setOnClickPendingIntent(
                R.id.w_refresh,
                refreshPending
            )
            views.setOnClickPendingIntent(
                R.id.w_refresh_hit,
                PendingIntent.getBroadcast(context, 110_000 + id, refresh, flags)
            )

            val serviceId = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE)
                .getString("svc_$id", null)
            val svc = findService(context, serviceId)

            // 点击行为:未选渠道 → 打开配置页选渠道(部分桌面 pin 后不自动弹配置);已配置 → 打开 App。
            if (serviceId == null) {
                val cfg = Intent(context, WidgetConfigActivity::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    .setAction("cfg_$id")
                views.setOnClickPendingIntent(R.id.w_root, PendingIntent.getActivity(context, id, cfg, flags))
            } else {
                views.setOnClickPendingIntent(R.id.w_root, refreshPending)
            }

            if (svc == null) {
                showStatus(views, if (serviceId == null) "点击选择渠道" else "打开 App 加载数据", "#8E8E93")
                views.setTextViewText(R.id.w_title, "用量")
                views.setTextColor(R.id.w_dot, Color.GRAY)
                views.setTextViewText(R.id.w_updated, "")
                mgr.updateAppWidget(id, views)
                return
            }

            views.setTextViewText(R.id.w_title, (if (svc.optBoolean("isCurrentAccount")) "当前 · " else "") + displayTitle(svc.optString("id"), svc.optString("title", "用量")))
            views.setTextColor(R.id.w_dot, try { Color.parseColor(svc.optString("accent", "#8E8E93")) } catch (e: Exception) { Color.GRAY })
            views.setTextViewText(R.id.w_updated, updatedText(context))

            when (svc.optString("kind")) {
                "loading" -> showStatus(views, "加载中…", "#8E8E93")
                "error" -> showStatus(views, svc.optString("message", "出错了"), "#F85149")
                "ok" -> {
                    val balance = svc.optJSONObject("balance")
                    val summary = apiSummary(svc.optJSONObject("apiInfo"))
                    if (summary != null) {
                        views.setViewVisibility(R.id.w_windows, View.GONE)
                        views.setViewVisibility(R.id.w_status, View.GONE)
                        views.setViewVisibility(R.id.w_balance, View.VISIBLE)
                        views.setTextViewText(R.id.w_bal_value, summary.first)
                        views.setTextViewText(R.id.w_bal_sub, summary.second)
                    } else if (balance != null) renderBalance(views, balance)
                    else renderWindows(views, svc.optJSONArray("windows"))
                    val note = serviceNote(svc)
                    if (note.isNotEmpty()) {
                        views.setViewVisibility(R.id.w_status, View.VISIBLE)
                        views.setTextViewText(R.id.w_status, note)
                        views.setTextColor(R.id.w_status, Color.parseColor("#8E8E93"))
                    }
                }
                else -> showStatus(views, "无数据", "#8E8E93")
            }
            mgr.updateAppWidget(id, views)
        }

        fun apiSummary(info: JSONObject?): Pair<String, String>? {
            if (info == null) return null
            val balances = info.optJSONArray("balances")
            if (balances != null && balances.length() > 0) {
                val b = balances.getJSONObject(0)
                val title = "%s %.2f".format(b.optString("currency"), b.getDouble("total"))
                val sub = if (balances.length() > 1) "共 ${balances.length()} 种币种 · App 查看详情"
                    else "充值 %.2f · 赠金 %.2f".format(b.getDouble("toppedUp"), b.getDouble("granted"))
                return Pair(title, sub)
            }
            val models = info.optJSONArray("models") ?: return Pair("数据暂不可用", "打开 App 查看")
            return Pair("密钥查询正常", "${models.length()} 个授权模型 · 暂无额度查询")
        }

        fun serviceNote(svc: JSONObject): String {
            val parts = mutableListOf<String>()
            if (svc.optBoolean("stale")) parts.add("上次数据")
            val reset = svc.optJSONObject("resetCredits")
            if (reset != null) {
                parts.add("重置 ${reset.optInt("availableCount")} 次")
                val credits = reset.optJSONArray("credits")
                val dates = (0 until (credits?.length() ?: 0)).mapNotNull {
                    isoMs(optionalString(credits!!.getJSONObject(it), "expiresAt"))
                }
                dates.minOrNull()?.let {
                    parts.add(SimpleDateFormat("MM/dd HH:mm", Locale.getDefault()).format(Date(it)) + " 到期")
                }
            }
            return parts.joinToString(" · ")
        }

        fun findService(context: Context, serviceId: String?): JSONObject? {
            if (serviceId == null) return null
            return try {
                val f = File(context.dataDir, "widget.json")
                if (!f.exists()) return null
                val arr = JSONObject(f.readText()).optJSONArray("services") ?: return null
                (0 until arr.length()).asSequence()
                    .mapNotNull { arr.optJSONObject(it) }
                    .firstOrNull { it.optString("id") == serviceId }
            } catch (e: Exception) {
                null
            }
        }

        fun updatedText(context: Context): String {
            return try {
                val f = File(context.dataDir, "widget.json")
                val ms = JSONObject(f.readText()).optLong("updatedAtMs", 0L)
                if (ms > 0) "更新于 " + SimpleDateFormat("HH:mm", Locale.getDefault()).format(Date(ms)) else ""
            } catch (e: Exception) { "" }
        }

        private fun showStatus(views: RemoteViews, text: String, color: String) {
            views.setViewVisibility(R.id.w_windows, View.GONE)
            views.setViewVisibility(R.id.w_balance, View.GONE)
            views.setViewVisibility(R.id.w_status, View.VISIBLE)
            views.setTextViewText(R.id.w_status, text)
            views.setTextColor(R.id.w_status, try { Color.parseColor(color) } catch (e: Exception) { Color.GRAY })
        }

        private fun renderWindows(views: RemoteViews, wins: org.json.JSONArray?) {
            views.setViewVisibility(R.id.w_status, View.GONE)
            views.setViewVisibility(R.id.w_balance, View.GONE)
            views.setViewVisibility(R.id.w_windows, View.VISIBLE)
            val n = wins?.length() ?: 0
            if (n == 0) { showStatus(views, "无可展示窗口", "#8E8E93"); return }
            for (i in 0 until 3) {
                if (i < n) {
                    val w = wins!!.getJSONObject(i)
                    val pct = w.optDouble("pct", 0.0).toInt().coerceIn(0, 100)
                    views.setViewVisibility(WIN_ROW[i], View.VISIBLE)
                    views.setTextViewText(WIN_LABEL[i], w.optString("label"))
                    views.setTextViewText(WIN_RESET[i], countdown(w.optLong("resetAtMs", 0L)))
                    views.setTextViewText(WIN_PCT[i], "$pct%")
                    views.setTextColor(WIN_PCT[i], barColor(pct))
                    views.setProgressBar(WIN_BAR[i], 100, pct, false)
                    if (Build.VERSION.SDK_INT >= 31) {
                        views.setColorStateList(WIN_BAR[i], "setProgressTintList", ColorStateList.valueOf(barColor(pct)))
                    }
                } else {
                    views.setViewVisibility(WIN_ROW[i], View.GONE)
                }
            }
        }

        private fun renderBalance(views: RemoteViews, b: JSONObject) {
            views.setViewVisibility(R.id.w_status, View.GONE)
            views.setViewVisibility(R.id.w_windows, View.GONE)
            views.setViewVisibility(R.id.w_balance, View.VISIBLE)
            val cur = b.optString("currency", "$")
            val bal = b.optDouble("balance", 0.0)
            val used = b.optDouble("used", 0.0)
            views.setTextViewText(R.id.w_bal_value, "余额 $cur%.2f".format(bal))
            val req = if (b.isNull("requestCount")) null else b.optLong("requestCount")
            val sub = if (req != null) "消耗 $cur%.2f · %,d 次".format(used, req)
                      else "消耗 $cur%.2f".format(used)
            views.setTextViewText(R.id.w_bal_sub, sub)
        }

        private fun refreshAllInBackground(context: Context, mgr: AppWidgetManager) {
            val cn = ComponentName(context, UsageWidgetProvider::class.java)
            for (id in mgr.getAppWidgetIds(cn)) refreshOneInBackground(context, mgr, id)
        }

        private fun refreshOneInBackground(context: Context, mgr: AppWidgetManager, id: Int) {
            val serviceId = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE)
                .getString("svc_$id", null)
            if (serviceId == null) {
                renderOne(context, mgr, id)
                return
            }
            renderOne(context, mgr, id)
            val updated = try {
                fetchRelayService(context, serviceId)
                    ?: errorService(context, serviceId, "请先配置手机中转")
            } catch (e: Exception) {
                errorService(context, serviceId, e.message ?: "刷新失败")
            }
            updateWidgetService(context, updated)
            renderOne(context, mgr, id)
        }

        fun fetchRelayService(context: Context, serviceId: String): JSONObject? {
            val config = try { readJson(File(context.dataDir, "usage-bar/config.json")) } catch (e: Exception) { return null }
            val relay = config.optJSONObject("relay") ?: return null
            if (!relay.optBoolean("enabled", false)) return null
            val url = stringOr(relay, "url", "").trimEnd('/')
            val secret = stringOr(relay, "secret", "")
            if (url.isEmpty() || secret.isEmpty()) return null

            val (payload, status) = httpGet(
                "$url/usage",
                mapOf("Authorization" to "Bearer $secret", "Accept" to "application/json")
            )
            if (status == 401) throw IllegalStateException("中转密钥无效,请重新扫码")
            if (status !in 200..299) throw IllegalStateException("中转返回 HTTP $status")
            val services = payload.optJSONArray("services") ?: return null
            for (i in 0 until services.length()) {
                val item = services.optJSONObject(i) ?: continue
                val cfg = item.optJSONObject("config") ?: continue
                if (cfg.optString("id") != serviceId) continue
                val statusObj = item.optJSONObject("status") ?: return null
                return relaySnapshotService(context, serviceId, cfg, statusObj)
                    .put("isCurrentAccount", item.optBoolean("isCurrentAccount", false))
            }
            return null
        }

        private fun relaySnapshotService(
            context: Context,
            serviceId: String,
            cfg: JSONObject,
            status: JSONObject
        ): JSONObject {
            val baseTitle = stringOr(cfg, "title", serviceBase(context, serviceId).optString("title"))
            val base = serviceBase(context, serviceId)
                .put("title", displayTitle(serviceId, baseTitle))
                .put("accent", stringOr(cfg, "accent", serviceBase(context, serviceId).optString("accent")))
            return when (status.optString("kind")) {
                "ok", "stale" -> {
                    val usage = status.optJSONObject("usage")
                        ?: throw IllegalStateException("中转数据格式异常")
                    for (field in listOf("apiInfo", "resetCredits", "balance", "windows")) base.remove(field)
                    base.put("kind", "ok").put("stale", status.optString("kind") == "stale")
                    usage.optJSONObject("apiInfo")?.let { base.put("apiInfo", it) }
                    usage.optJSONObject("resetCredits")?.let { base.put("resetCredits", it) }
                    optionalString(usage, "plan")?.let { base.put("plan", it) }
                    val balance = usage.optJSONObject("balance")
                    if (balance != null) {
                        val outBalance = JSONObject()
                            .put("balance", balance.optDouble("balance", 0.0))
                            .put("used", balance.optDouble("used", 0.0))
                            .put("currency", stringOr(balance, "currency", "$"))
                        if (balance.has("requestCount") && !balance.isNull("requestCount")) {
                            outBalance.put("requestCount", balance.optLong("requestCount"))
                        }
                        base.put("balance", outBalance)
                    } else {
                        val windows = JSONArray()
                        val rawWindows = usage.optJSONArray("windows") ?: JSONArray()
                        for (i in 0 until rawWindows.length()) {
                            val win = rawWindows.optJSONObject(i) ?: continue
                            val out = JSONObject()
                                .put("label", win.optString("label"))
                                .put("pct", win.optDouble("pct", 0.0))
                            optionalString(win, "resetAt")?.let { isoMs(it)?.let { ms -> out.put("resetAtMs", ms) } }
                            windows.put(out)
                        }
                        base.put("windows", windows)
                    }
                    base
                }
                "error" -> base.put("kind", "error")
                    .put("message", status.optString("message", "出错了"))
                else -> base.put("kind", "loading")
            }
        }

        private fun widgetDoc(context: Context): JSONObject {
            return try {
                val f = File(context.dataDir, "widget.json")
                if (f.exists()) JSONObject(f.readText()) else JSONObject().put("services", JSONArray())
            } catch (e: Exception) {
                JSONObject().put("services", JSONArray())
            }
        }

        private fun serviceBase(context: Context, serviceId: String): JSONObject {
            val existing = findService(context, serviceId)
            val title = existing?.optString("title")?.takeIf { it.isNotEmpty() } ?: when (serviceId) {
                "claude" -> "Claude"
                "codex" -> "Codex"
                "phanrouter" -> "PhanRouter"
                else -> "用量"
            }
            val accent = existing?.optString("accent")?.takeIf { it.isNotEmpty() } ?: when (serviceId) {
                "claude" -> "#D97757"
                "codex" -> "#10A37F"
                "phanrouter" -> "#7C5CFC"
                else -> "#8E8E93"
            }
            return JSONObject()
                .put("id", serviceId)
                .put("title", title)
                .put("accent", accent)
        }

        fun errorService(context: Context, serviceId: String, message: String): JSONObject {
            return serviceBase(context, serviceId)
                .put("kind", "error")
                .put("message", message)
        }

        fun updateWidgetService(context: Context, service: JSONObject) {
            val doc = widgetDoc(context)
            val services = doc.optJSONArray("services") ?: JSONArray()
            val out = JSONArray()
            var replaced = false
            for (i in 0 until services.length()) {
                val current = services.optJSONObject(i)
                if (current != null && current.optString("id") == service.optString("id")) {
                    out.put(service)
                    replaced = true
                } else if (current != null) {
                    out.put(current)
                }
            }
            if (!replaced) out.put(service)
            doc.put("updatedAtMs", System.currentTimeMillis())
            doc.put("services", out)
            File(context.dataDir, "widget.json").writeText(doc.toString())
        }

        private fun readJson(path: File): JSONObject {
            if (!path.exists()) throw IllegalStateException("缺少凭证文件")
            return JSONObject(path.readText())
        }

        private fun httpGet(url: String, headers: Map<String, String>): Pair<JSONObject, Int> {
            val conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = 12_000
                readTimeout = 12_000
                useCaches = false
                instanceFollowRedirects = true
                setRequestProperty("User-Agent", "TokenDeck/1.0")
                setRequestProperty("Accept-Encoding", "identity")
                for ((k, v) in headers) setRequestProperty(k, v)
            }
            val status = conn.responseCode
            val body = try {
                (if (status in 200..299) conn.inputStream else conn.errorStream)
                    ?.bufferedReader()
                    ?.use { it.readText() }
            } finally {
                conn.disconnect()
            }
            if (body.isNullOrBlank()) throw IllegalStateException("接口返回为空")
            return JSONObject(body) to status
        }

        private fun stringOr(o: JSONObject, key: String, default: String): String =
            if (o.has(key) && !o.isNull(key)) o.optString(key).ifEmpty { default } else default

        private fun optionalString(o: JSONObject, key: String): String? =
            if (o.has(key) && !o.isNull(key)) o.optString(key).takeIf { it.isNotEmpty() } else null

        private fun isoMs(raw: String?): Long? {
            if (raw.isNullOrBlank()) return null
            return try { Instant.parse(raw).toEpochMilli() } catch (e: Exception) { null }
        }
    }
}

// 双服务 2x2 主屏小组件:上半区和下半区各绑定一个渠道,共用一个刷新按钮。
class UsageDoubleWidgetProvider : AppWidgetProvider() {
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        when (intent.action) {
            UsageWidgetProvider.ACTION_RENDER -> refreshAll(context)
            ACTION_REFRESH -> {
                val mgr = AppWidgetManager.getInstance(context)
                val id = intent.getIntExtra(
                    AppWidgetManager.EXTRA_APPWIDGET_ID,
                    AppWidgetManager.INVALID_APPWIDGET_ID
                )
                val pending = goAsync()
                Thread {
                    try {
                        if (id == AppWidgetManager.INVALID_APPWIDGET_ID) {
                            refreshAllInBackground(context, mgr)
                        } else {
                            refreshOneInBackground(context, mgr, id)
                        }
                    } finally {
                        pending.finish()
                    }
                }.start()
            }
        }
    }

    override fun onUpdate(context: Context, mgr: AppWidgetManager, ids: IntArray) {
        for (id in ids) renderOne(context, mgr, id)
    }

    override fun onDeleted(context: Context, ids: IntArray) {
        val p = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE).edit()
        for (id in ids) {
            p.remove("double_top_$id")
            p.remove("double_bottom_$id")
            p.remove("double_style_$id")
        }
        p.apply()
    }

    companion object {
        private const val ACTION_REFRESH = "app.usagedashboard.WIDGET_DOUBLE_REFRESH"

        private data class BlockIds(
            val root: Int,
            val header: Int,
            val dot: Int,
            val title: Int,
            val updated: Int,
            val windows: Int,
            val balance: Int,
            val status: Int,
            val balanceValue: Int,
            val balanceSub: Int,
            val rows: IntArray,
            val labels: IntArray,
            val resets: IntArray,
            val pcts: IntArray,
            val bars: IntArray,
        )

        private data class DoubleWidgetStyle(
            val dot: Float,
            val title: Float,
            val updated: Float,
            val label: Float,
            val reset: Float,
            val pct: Float,
            val balance: Float,
            val balanceSub: Float,
            val status: Float,
            val rootHPad: Int,
            val rootVPad: Int,
            val headerBottom: Int,
            val rowGap: Int,
            val refreshSize: Float,
            val refreshPad: Int,
            val barHeight: Float,
        )

        private val TOP = BlockIds(
            R.id.dw_top_block,
            R.id.dw_top_header,
            R.id.dw_top_dot,
            R.id.dw_top_title,
            R.id.dw_top_updated,
            R.id.dw_top_windows,
            R.id.dw_top_balance,
            R.id.dw_top_status,
            R.id.dw_top_bal_value,
            R.id.dw_top_bal_sub,
            intArrayOf(R.id.dw_top_win0, R.id.dw_top_win1),
            intArrayOf(R.id.dw_top_win0_label, R.id.dw_top_win1_label),
            intArrayOf(R.id.dw_top_win0_reset, R.id.dw_top_win1_reset),
            intArrayOf(R.id.dw_top_win0_pct, R.id.dw_top_win1_pct),
            intArrayOf(R.id.dw_top_win0_bar, R.id.dw_top_win1_bar),
        )

        private val BOTTOM = BlockIds(
            R.id.dw_bottom_block,
            R.id.dw_bottom_header,
            R.id.dw_bottom_dot,
            R.id.dw_bottom_title,
            R.id.dw_bottom_updated,
            R.id.dw_bottom_windows,
            R.id.dw_bottom_balance,
            R.id.dw_bottom_status,
            R.id.dw_bottom_bal_value,
            R.id.dw_bottom_bal_sub,
            intArrayOf(R.id.dw_bottom_win0, R.id.dw_bottom_win1),
            intArrayOf(R.id.dw_bottom_win0_label, R.id.dw_bottom_win1_label),
            intArrayOf(R.id.dw_bottom_win0_reset, R.id.dw_bottom_win1_reset),
            intArrayOf(R.id.dw_bottom_win0_pct, R.id.dw_bottom_win1_pct),
            intArrayOf(R.id.dw_bottom_win0_bar, R.id.dw_bottom_win1_bar),
        )

        fun refreshAll(context: Context) {
            val mgr = AppWidgetManager.getInstance(context)
            val cn = ComponentName(context, UsageDoubleWidgetProvider::class.java)
            for (id in mgr.getAppWidgetIds(cn)) renderOne(context, mgr, id)
        }

        private fun widgetStyle(context: Context, id: Int): DoubleWidgetStyle {
            return when (
                context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE)
                    .getString("double_style_$id", "large")
            ) {
                "compact" -> DoubleWidgetStyle(8.5f, 12f, 7.5f, 10.5f, 7.5f, 10.5f, 17f, 9.5f, 10.5f, 9, 6, 2, 3, 22f, 4, 4f)
                "standard" -> DoubleWidgetStyle(9f, 12.5f, 8f, 11f, 8f, 11f, 18f, 10f, 11f, 10, 7, 3, 3, 23f, 4, 4.5f)
                else -> DoubleWidgetStyle(9.5f, 13f, 8.5f, 11.5f, 8.5f, 11.5f, 19f, 10.5f, 11.5f, 11, 7, 3, 4, 24f, 4, 4.5f)
            }
        }

        private fun applyWidgetStyle(context: Context, views: RemoteViews, style: DoubleWidgetStyle) {
            views.setViewPadding(
                R.id.dw_root,
                UsageWidgetProvider.dp(context, style.rootHPad),
                UsageWidgetProvider.dp(context, style.rootVPad),
                UsageWidgetProvider.dp(context, style.rootHPad),
                UsageWidgetProvider.dp(context, style.rootVPad)
            )
            for (ids in listOf(TOP, BOTTOM)) {
                UsageWidgetProvider.setSp(views, ids.dot, style.dot)
                UsageWidgetProvider.setSp(views, ids.title, style.title)
                UsageWidgetProvider.setSp(views, ids.updated, style.updated)
                UsageWidgetProvider.setSp(views, ids.balanceValue, style.balance)
                UsageWidgetProvider.setSp(views, ids.balanceSub, style.balanceSub)
                UsageWidgetProvider.setSp(views, ids.status, style.status)
                views.setViewPadding(ids.header, 0, 0, 0, UsageWidgetProvider.dp(context, style.headerBottom))
                for (i in 0 until 2) {
                    UsageWidgetProvider.setSp(views, ids.labels[i], style.label)
                    UsageWidgetProvider.setSp(views, ids.resets[i], style.reset)
                    UsageWidgetProvider.setSp(views, ids.pcts[i], style.pct)
                    if (i > 0) {
                        views.setViewPadding(ids.rows[i], 0, UsageWidgetProvider.dp(context, style.rowGap), 0, 0)
                    }
                    if (Build.VERSION.SDK_INT >= 31) {
                        views.setViewLayoutHeight(ids.bars[i], style.barHeight, TypedValue.COMPLEX_UNIT_DIP)
                    }
                }
            }
            val refreshPad = UsageWidgetProvider.dp(context, style.refreshPad)
            views.setViewPadding(R.id.dw_refresh, refreshPad, refreshPad, refreshPad, refreshPad)
            if (Build.VERSION.SDK_INT >= 31) {
                views.setViewLayoutWidth(R.id.dw_refresh, style.refreshSize, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutHeight(R.id.dw_refresh, style.refreshSize, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutWidth(R.id.dw_refresh_hit, style.refreshSize + 10f, TypedValue.COMPLEX_UNIT_DIP)
                views.setViewLayoutHeight(R.id.dw_refresh_hit, style.refreshSize + 2f, TypedValue.COMPLEX_UNIT_DIP)
            }
        }

        fun renderOne(context: Context, mgr: AppWidgetManager, id: Int) {
            val views = RemoteViews(context.packageName, R.layout.usage_double_widget)
            applyWidgetStyle(context, views, widgetStyle(context, id))

            val flags = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            val refresh = Intent(context, UsageDoubleWidgetProvider::class.java)
                .setAction(ACTION_REFRESH)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
            val refreshPending = PendingIntent.getBroadcast(context, 220_000 + id, refresh, flags)
            views.setOnClickPendingIntent(R.id.dw_refresh, refreshPending)
            views.setOnClickPendingIntent(
                R.id.dw_refresh_hit,
                PendingIntent.getBroadcast(context, 230_000 + id, refresh, flags)
            )

            val prefs = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE)
            val topId = prefs.getString("double_top_$id", null)
            val bottomId = prefs.getString("double_bottom_$id", null)

            if (topId == null || bottomId == null) {
                val cfg = Intent(context, DoubleWidgetConfigActivity::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    .setAction("double_cfg_$id")
                views.setOnClickPendingIntent(
                    R.id.dw_root,
                    PendingIntent.getActivity(context, 240_000 + id, cfg, flags)
                )
                showBlockStatus(views, TOP, "用量", "#8E8E93", "点击选择上方渠道")
                showBlockStatus(views, BOTTOM, "2x2", "#8E8E93", "点击选择下方渠道")
                mgr.updateAppWidget(id, views)
                return
            }

            views.setOnClickPendingIntent(R.id.dw_root, refreshPending)
            renderBlock(context, views, TOP, topId)
            renderBlock(context, views, BOTTOM, bottomId)
            mgr.updateAppWidget(id, views)
        }

        private fun renderBlock(context: Context, views: RemoteViews, ids: BlockIds, serviceId: String) {
            val svc = UsageWidgetProvider.findService(context, serviceId)
            if (svc == null) {
                showBlockStatus(views, ids, UsageWidgetProvider.displayTitle(serviceId, "用量"), "#8E8E93", "打开 App 加载数据")
                return
            }
            val title = (if (svc.optBoolean("isCurrentAccount")) "当前 · " else "") + UsageWidgetProvider.displayTitle(svc.optString("id"), svc.optString("title", "用量"))
            val accent = svc.optString("accent", "#8E8E93")
            views.setTextViewText(ids.title, title)
            views.setTextColor(ids.dot, try { Color.parseColor(accent) } catch (e: Exception) { Color.GRAY })
            views.setTextViewText(ids.updated, UsageWidgetProvider.updatedText(context))

            when (svc.optString("kind")) {
                "loading" -> showBlockStatus(views, ids, title, accent, "加载中…")
                "error" -> showBlockStatus(views, ids, title, accent, svc.optString("message", "出错了"))
                "ok" -> {
                    val balance = svc.optJSONObject("balance")
                    val summary = UsageWidgetProvider.apiSummary(svc.optJSONObject("apiInfo"))
                    if (summary != null) {
                        views.setViewVisibility(ids.windows, View.GONE)
                        views.setViewVisibility(ids.status, View.GONE)
                        views.setViewVisibility(ids.balance, View.VISIBLE)
                        views.setTextViewText(ids.balanceValue, summary.first)
                        views.setTextViewText(ids.balanceSub, summary.second)
                    } else if (balance != null) renderBlockBalance(views, ids, balance)
                    else renderBlockWindows(views, ids, svc.optJSONArray("windows"))
                    val note = UsageWidgetProvider.serviceNote(svc)
                    if (note.isNotEmpty()) {
                        views.setViewVisibility(ids.status, View.VISIBLE)
                        views.setTextViewText(ids.status, note)
                        views.setTextColor(ids.status, Color.parseColor("#8E8E93"))
                    }
                }
                else -> showBlockStatus(views, ids, title, accent, "无数据")
            }
        }

        private fun showBlockStatus(
            views: RemoteViews,
            ids: BlockIds,
            title: String,
            accent: String,
            text: String,
        ) {
            views.setTextViewText(ids.title, title)
            views.setTextColor(ids.dot, try { Color.parseColor(accent) } catch (e: Exception) { Color.GRAY })
            views.setTextViewText(ids.updated, "")
            views.setViewVisibility(ids.windows, View.GONE)
            views.setViewVisibility(ids.balance, View.GONE)
            views.setViewVisibility(ids.status, View.VISIBLE)
            views.setTextViewText(ids.status, text)
            views.setTextColor(ids.status, Color.parseColor("#8E8E93"))
        }

        private fun renderBlockWindows(views: RemoteViews, ids: BlockIds, wins: JSONArray?) {
            views.setViewVisibility(ids.status, View.GONE)
            views.setViewVisibility(ids.balance, View.GONE)
            views.setViewVisibility(ids.windows, View.VISIBLE)
            val n = wins?.length() ?: 0
            if (n == 0) {
                views.setViewVisibility(ids.windows, View.GONE)
                views.setViewVisibility(ids.status, View.VISIBLE)
                views.setTextViewText(ids.status, "无可展示窗口")
                views.setTextColor(ids.status, Color.parseColor("#8E8E93"))
                return
            }
            for (i in 0 until 2) {
                if (i < n) {
                    val w = wins!!.getJSONObject(i)
                    val pct = w.optDouble("pct", 0.0).toInt().coerceIn(0, 100)
                    views.setViewVisibility(ids.rows[i], View.VISIBLE)
                    views.setTextViewText(ids.labels[i], w.optString("label"))
                    views.setTextViewText(ids.resets[i], UsageWidgetProvider.countdown(w.optLong("resetAtMs", 0L)))
                    views.setTextViewText(ids.pcts[i], "$pct%")
                    views.setTextColor(ids.pcts[i], UsageWidgetProvider.barColor(pct))
                    views.setProgressBar(ids.bars[i], 100, pct, false)
                    if (Build.VERSION.SDK_INT >= 31) {
                        views.setColorStateList(ids.bars[i], "setProgressTintList", ColorStateList.valueOf(UsageWidgetProvider.barColor(pct)))
                    }
                } else {
                    views.setViewVisibility(ids.rows[i], View.GONE)
                }
            }
        }

        private fun renderBlockBalance(views: RemoteViews, ids: BlockIds, b: JSONObject) {
            views.setViewVisibility(ids.status, View.GONE)
            views.setViewVisibility(ids.windows, View.GONE)
            views.setViewVisibility(ids.balance, View.VISIBLE)
            val cur = b.optString("currency", "$")
            val bal = b.optDouble("balance", 0.0)
            val used = b.optDouble("used", 0.0)
            views.setTextViewText(ids.balanceValue, "余额 $cur%.2f".format(bal))
            val req = if (b.isNull("requestCount")) null else b.optLong("requestCount")
            val sub = if (req != null) "消耗 $cur%.2f · %,d 次".format(used, req)
                      else "消耗 $cur%.2f".format(used)
            views.setTextViewText(ids.balanceSub, sub)
        }

        private fun refreshAllInBackground(context: Context, mgr: AppWidgetManager) {
            val cn = ComponentName(context, UsageDoubleWidgetProvider::class.java)
            for (id in mgr.getAppWidgetIds(cn)) refreshOneInBackground(context, mgr, id)
        }

        private fun refreshOneInBackground(context: Context, mgr: AppWidgetManager, id: Int) {
            val prefs = context.getSharedPreferences("usage_widget", Context.MODE_PRIVATE)
            val serviceIds = listOfNotNull(
                prefs.getString("double_top_$id", null),
                prefs.getString("double_bottom_$id", null),
            ).distinct()
            if (serviceIds.isEmpty()) {
                renderOne(context, mgr, id)
                return
            }
            renderOne(context, mgr, id)
            for (serviceId in serviceIds) {
                val updated = try {
                    UsageWidgetProvider.fetchRelayService(context, serviceId)
                        ?: UsageWidgetProvider.errorService(context, serviceId, "请先配置手机中转")
                } catch (e: Exception) {
                    UsageWidgetProvider.errorService(context, serviceId, e.message ?: "刷新失败")
                }
                UsageWidgetProvider.updateWidgetService(context, updated)
            }
            renderOne(context, mgr, id)
        }
    }
}
