package com.horseui.horsebox

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import kotlin.concurrent.thread

private const val PREFS = "horsebox_monitor"
private const val CHANNEL = "horsebox_firewall"
private const val JOB_ID = 0x4842
private const val RESOURCE_THRESHOLD = 90.0

data class MonitorTarget(
    val name: String,
    val base: String,
    val pin: String,
    val token: String,
) {
    val key: String get() = base
}

object MonitorScheduler {
    fun schedule(context: Context) {
        val targets = MonitorStore.targets(context)
        val scheduler = context.getSystemService(JobScheduler::class.java) ?: return
        if (targets.isEmpty()) {
            scheduler.cancel(JOB_ID)
            return
        }
        val component = ComponentName(context, MonitorJobService::class.java)
        val info = JobInfo.Builder(JOB_ID, component)
            .setPeriodic(15 * 60 * 1000L)
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .setPersisted(true)
            .build()
        scheduler.schedule(info)
    }
}

class MonitorBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action == Intent.ACTION_BOOT_COMPLETED) {
            MonitorScheduler.schedule(context)
        }
    }
}

class MonitorJobService : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        thread(name = "horsebox-monitor") {
            try {
                FirewallMonitor.run(this)
            } finally {
                jobFinished(params, false)
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean = false
}

object MonitorStore {
    fun saveConfig(context: Context, raw: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString("config", raw).apply()
    }

    fun targetJson(context: Context): List<JSONObject> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString("config", "[]") ?: "[]"
        val out = mutableListOf<JSONObject>()
        try {
            val array = JSONArray(raw)
            for (i in 0 until array.length()) {
                array.optJSONObject(i)?.let { out.add(it) }
            }
        } catch (_: Exception) {
        }
        return out
    }

    fun targets(context: Context): List<MonitorTarget> = targetJson(context).mapNotNull { item ->
        val url = item.optString("url")
        val pin = item.optString("pin").replace(":", "").lowercase()
        if (url.isBlank() || pin.length != 64) return@mapNotNull null
        val uri = Uri.parse(url)
        if (uri.scheme != "https" || uri.host.isNullOrBlank()) return@mapNotNull null
        val port = if (uri.port > 0) ":${uri.port}" else ""
        MonitorTarget(
            name = item.optString("name", uri.host),
            base = "https://${uri.host}$port",
            pin = pin,
            token = item.optString("token"),
        )
    }

    private fun prefs(context: Context) =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun getJson(context: Context, key: String): JSONObject? {
        val raw = prefs(context).getString(key, null) ?: return null
        return try {
            JSONObject(raw)
        } catch (_: Exception) {
            null
        }
    }

    fun putJson(context: Context, key: String, value: JSONObject) {
        prefs(context).edit().putString(key, value.toString()).apply()
    }

    fun getLong(context: Context, key: String): Long =
        prefs(context).getLong(key, 0L)

    fun putLong(context: Context, key: String, value: Long) {
        prefs(context).edit().putLong(key, value).apply()
    }
}

object FirewallMonitor {
    fun run(context: Context, includeIpCare: Boolean = true) {
        val targets = MonitorStore.targets(context)
        for (target in targets) {
            try {
                checkGuard(context, target)
                checkMetrics(context, target)
                checkSources(context, target)
                if (includeIpCare) checkIpCare(context, target)
            } catch (_: Exception) {
            }
        }
    }

    private fun checkGuard(context: Context, target: MonitorTarget) {
        val guard = getJson(target, "/api/ip-care/firewall/guard") ?: return
        val stale = guard.optBoolean("stale", true)
        val previousStale = MonitorStore.getLong(context, "stale_${target.key}")
        if (stale && previousStale == 0L) {
            notifyPort(
                context, target, "fwd", 0,
                "防火墙数据面异常",
                "${target.name}：horseui-fwd 未运行或快照过期",
            )
        } else if (!stale && previousStale == 1L) {
            notifyPort(
                context, target, "fwd", 0,
                "防火墙数据面已恢复",
                "${target.name}：fwd 快照恢复正常",
            )
        }
        MonitorStore.putLong(context, "stale_${target.key}", if (stale) 1L else 0L)

        val previous = MonitorStore.getJson(context, "ports_${target.key}") ?: JSONObject()
        val current = JSONObject()
        val ports = guard.optJSONArray("ports") ?: JSONArray()
        for (i in 0 until ports.length()) {
            val item = ports.optJSONObject(i) ?: continue
            val protocol = item.optString("protocol", "tcp")
            val port = item.optInt("port")
            if (port <= 0) continue
            val status = item.optString("status", "normal")
            val key = "$protocol:$port"
            current.put(key, status)
            val old = previous.optString(key, "")
            if (status == "closed" && old != "closed") {
                val currentValue = item.optInt("current")
                val limit = item.optDouble("limit", 0.0)
                notifyPort(
                    context, target, key, port,
                    "端口 $port 已关闭",
                    "${target.name} · ${protocol.uppercase()} · 当前 $currentValue / 上限 ${limit.toInt()}",
                )
            } else if (status != "closed" && old == "closed") {
                notifyPort(
                    context, target, key, port,
                    "端口 $port 已恢复",
                    "${target.name} · ${protocol.uppercase()} · 连接已回落",
                )
            }
        }
        MonitorStore.putJson(context, "ports_${target.key}", current)
    }

    private fun checkMetrics(context: Context, target: MonitorTarget) {
        val metrics = getJson(target, "/api/ip-care/system/metrics") ?: return
        val cpu = metrics.optDouble("cpu_percent", 0.0)
        val mem = metrics.optDouble("mem_percent", 0.0)
        val disk = metrics.optDouble("disk_percent", 0.0)
        val high = cpu >= RESOURCE_THRESHOLD || mem >= RESOURCE_THRESHOLD || disk >= RESOURCE_THRESHOLD
        val previous = MonitorStore.getLong(context, "metrics_${target.key}") == 1L
        if (high && !previous) {
            notifyPort(
                context, target, "metrics", 0,
                "服务器资源告警",
                "${target.name} · CPU ${cpu.toInt()}% · 内存 ${mem.toInt()}% · 硬盘 ${disk.toInt()}%",
            )
        } else if (!high && previous) {
            notifyPort(
                context, target, "metrics", 0,
                "服务器资源已恢复",
                "${target.name} · CPU ${cpu.toInt()}% · 内存 ${mem.toInt()}% · 硬盘 ${disk.toInt()}%",
            )
        }
        MonitorStore.putLong(context, "metrics_${target.key}", if (high) 1L else 0L)
    }

    private fun checkSources(context: Context, target: MonitorTarget) {
        val data = getJson(target, "/api/ip-care/firewall/attack-sources?limit=50") ?: return
        val items = data.optJSONArray("items") ?: return
        val previous = MonitorStore.getJson(context, "sources_${target.key}")
        val isFirstRun = previous == null
        val current = JSONObject()
        val now = System.currentTimeMillis() / 1000
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val ip = item.optString("ip")
            val port = item.optInt("port")
            val protocol = item.optString("protocol", "tcp")
            if (ip.isBlank() || port <= 0) continue
            val key = "$ip|$protocol|$port"
            current.put(key, now)
            if (!isFirstRun && previous?.has(key) != true) {
                val count = item.optInt("count")
                notifyPort(
                    context, target, "source:$key", port,
                    "异常 IP $ip",
                    "${target.name} · ${protocol.uppercase()}/$port · 连接 $count 次",
                )
            }
        }
        // 只保留最近 200 个来源，避免状态无限增长。
        if (current.length() > 200) {
            val keys = current.keys().asSequence().sortedByDescending { current.optLong(it) }.take(200)
            val trimmed = JSONObject()
            keys.forEach { trimmed.put(it, current.optLong(it)) }
            MonitorStore.putJson(context, "sources_${target.key}", trimmed)
        } else {
            MonitorStore.putJson(context, "sources_${target.key}", current)
        }
    }

    private fun checkIpCare(context: Context, target: MonitorTarget) {
        val now = System.currentTimeMillis() / 1000
        if (MonitorStore.getLong(context, "ipcare_due_${target.key}") > now) return
        val status = getJson(target, "/api/ip-care/status") ?: return
        val settings = status.optJSONObject("settings") ?: return
        val interval = settings.optLong("detect_interval_seconds", 86400L)
        val mode = settings.optString("detect_mode", "manual")
        if (mode == "manual") {
            MonitorStore.putLong(context, "ipcare_due_${target.key}", now + 3600)
            return
        }
        // 面板自己的检测周期是权威频率；App 只在到期附近查询是否有新结果。
        MonitorStore.putLong(
            context,
            "ipcare_due_${target.key}",
            now + maxOf(interval, 30L),
        )
        val last = status.optJSONObject("last") ?: return
        val id = last.optLong("id", 0L)
        val previousId = MonitorStore.getLong(context, "ipcare_${target.key}")
        if (id <= previousId) {
            MonitorStore.putLong(context, "ipcare_${target.key}", id)
            return
        }
        val isCN = last.optBoolean("is_cn", false)
        val error = last.optString("error", "")
        val wasCN = MonitorStore.getLong(context, "ipcare_cn_${target.key}") == 1L
        if (isCN && !wasCN) {
            notifyPort(
                context, target, "ipcare", 0,
                "IP 养护：检测到送中",
                "${target.name} · ${last.optString("ip")} · ${last.optString("google_region")}",
            )
        } else if (!isCN && wasCN) {
            notifyPort(
                context, target, "ipcare", 0,
                "IP 养护已恢复正常",
                "${target.name} · ${last.optString("ip")} · ${last.optString("google_region")}",
            )
        }
        MonitorStore.putLong(context, "ipcare_cn_${target.key}", if (isCN) 1L else 0L)
        val previousError = MonitorStore.getLong(context, "ipcare_err_${target.key}").toString()
        if (error.isNotBlank() && error != previousError) {
            notifyPort(
                context, target, "ipcare_error", 0,
                "IP 养护检测失败",
                "${target.name} · $error",
            )
        }
        MonitorStore.putLong(
            context,
            "ipcare_err_${target.key}",
            if (error.isBlank()) 0L else error.hashCode().toLong(),
        )
        MonitorStore.putLong(context, "ipcare_${target.key}", id)
    }

    private fun getJson(target: MonitorTarget, path: String): JSONObject? {
        val connection = open(target, path) ?: return null
        return try {
            if (connection.responseCode !in 200..299) return null
            val text = BufferedReader(InputStreamReader(connection.inputStream)).use { it.readText() }
            val root = JSONObject(text)
            if (root.optInt("code", 0) != 0) return null
            root.optJSONObject("data")
        } catch (_: Exception) {
            null
        } finally {
            connection.disconnect()
        }
    }

    private fun open(target: MonitorTarget, path: String): HttpsURLConnection? {
        return try {
            val url = URL(target.base + path)
            val connection = url.openConnection() as HttpsURLConnection
            connection.connectTimeout = 10_000
            connection.readTimeout = 10_000
            connection.requestMethod = "GET"
            connection.setRequestProperty("Authorization", "Bearer ${target.token}")
            connection.setRequestProperty("Accept", "application/json")
            connection.sslSocketFactory = pinnedFactory(target.pin)
            connection.hostnameVerifier = HostnameVerifier { _, _ -> true }
            connection
        } catch (_: Exception) {
            null
        }
    }

    private fun pinnedFactory(pin: String): javax.net.ssl.SSLSocketFactory {
        val trust = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val cert = chain?.firstOrNull() ?: throw CertificateException("missing cert")
                val digest = MessageDigest.getInstance("SHA-256")
                    .digest(cert.encoded)
                    .joinToString("") { "%02x".format(it) }
                if (!digest.equals(pin, ignoreCase = true)) {
                    throw CertificateException("certificate pin mismatch")
                }
            }

            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
        }
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf(trust), SecureRandom())
        return context.socketFactory
    }

    private fun notifyPort(
        context: Context,
        target: MonitorTarget,
        key: String,
        port: Int,
        title: String,
        body: String,
    ) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        val manager = context.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 26) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL, "玄武防火墙", NotificationManager.IMPORTANCE_HIGH),
            )
        }
        val intent = Intent(context, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) {
            Notification.Builder(context, CHANNEL)
        } else {
            Notification.Builder(context)
        }
        val notification = builder
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        val id = ("${target.key}|$key|$port").hashCode() and 0x7fffffff
        manager.notify(id, notification)
    }
}
