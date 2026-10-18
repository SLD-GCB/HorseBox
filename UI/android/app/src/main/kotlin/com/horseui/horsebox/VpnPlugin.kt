package com.horseui.horsebox

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Dart 与 VpnService 之间的桥。 */
class VpnPlugin(private val activity: Activity) :
    MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private var pendingResult: MethodChannel.Result? = null
    private var pendingNotificationResult: MethodChannel.Result? = null

    fun attach(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHOD_CHANNEL)
            .setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, EVENT_CHANNEL)
            .setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "filesDir" -> result.success(activity.filesDir.absolutePath)
            "prepare" -> prepare(result)
            "ensureNotification" -> ensureNotification(result)
            "start" -> start(call, result)
            "stop" -> stop(result)
            "isRunning" -> result.success(BoxService.isRunning)
            "openNotificationSettings" -> openNotificationSettings(result)
            "openBatterySettings" -> openBatterySettings(result)
            "isIgnoringBattery" -> result.success(isIgnoringBattery())
            "listUserApps" -> result.success(listUserApps())
            else -> result.notImplemented()
        }
    }

    private fun prepare(result: MethodChannel.Result) {
        val intent = VpnService.prepare(activity)
        if (intent == null) {
            result.success(true)
            return
        }
        if (pendingResult != null) {
            pendingResult?.success(false)
        }
        pendingResult = result
        activity.startActivityForResult(intent, REQUEST_VPN)
    }

    private fun ensureNotification(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        pendingNotificationResult?.success(false)
        pendingNotificationResult = result
        activity.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_NOTIFICATION,
        )
    }

    private fun openNotificationSettings(result: MethodChannel.Result) {
        try {
            activity.startActivity(
                Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                    .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName),
            )
        } catch (_: Throwable) {
            activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:${activity.packageName}")
            })
        }
        result.success(null)
    }

    private fun isIgnoringBattery(): Boolean {
        val power = activity.getSystemService(PowerManager::class.java)
        return power.isIgnoringBatteryOptimizations(activity.packageName)
    }

    private fun openBatterySettings(result: MethodChannel.Result) {
        if (isIgnoringBattery()) {
            result.success(true)
            return
        }
        try {
            activity.startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:${activity.packageName}"),
                ),
            )
        } catch (_: Throwable) {
            runCatching {
                activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
        }
        result.success(false)
    }

    private fun listUserApps(): List<Map<String, String>> {
        val pm = activity.packageManager
        return pm.getInstalledApplications(0)
            .asSequence()
            .filter {
                (it.flags and ApplicationInfo.FLAG_SYSTEM) == 0 ||
                    it.packageName in PROXY_SYSTEM_APPS
            }
            .filter { it.packageName != activity.packageName }
            .map {
                mapOf(
                    "package" to it.packageName,
                    "label" to pm.getApplicationLabel(it).toString(),
                )
            }
            .sortedBy { it["label"]?.lowercase() }
            .toList()
    }

    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val config = call.argument<String>("config")
        if (config.isNullOrBlank()) {
            result.error("config", "缺少配置", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val allowed = call.argument<List<String>>("allowedPackages") ?: emptyList()
        val direct = call.argument<List<String>>("directPackages") ?: emptyList()
        val intent = Intent(activity, BoxService::class.java).apply {
            action = BoxService.ACTION_START
            putExtra(BoxService.EXTRA_CONFIG, config)
            putStringArrayListExtra(BoxService.EXTRA_ALLOWED_PACKAGES, ArrayList(allowed))
            putStringArrayListExtra(BoxService.EXTRA_DIRECT_PACKAGES, ArrayList(direct))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
        result.success(null)
    }

    private fun stop(result: MethodChannel.Result) {
        val intent = Intent(activity, BoxService::class.java).apply {
            action = BoxService.ACTION_STOP
        }
        activity.startService(intent)
        result.success(null)
    }

    /** @return true 表示这个结果由 VPN 授权流程消费。 */
    fun onActivityResult(requestCode: Int, resultCode: Int): Boolean {
        if (requestCode != REQUEST_VPN) return false
        pendingResult?.success(resultCode == Activity.RESULT_OK)
        pendingResult = null
        return true
    }

    /** @return true 表示通知权限请求由这里消费。 */
    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode != REQUEST_NOTIFICATION) return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
        return true
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        events?.success(BoxService.isRunning)
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    companion object {
        private const val METHOD_CHANNEL = "horsebox/vpn"
        private const val EVENT_CHANNEL = "horsebox/vpn/state"
        private const val REQUEST_VPN = 0x5601
        private const val REQUEST_NOTIFICATION = 0x5602

        /** YouTube / Play 等 Google 应用依赖的系统组件，允许被选进代理列表。 */
        private val PROXY_SYSTEM_APPS = setOf(
            "com.google.android.gms",
            "com.google.android.gsf",
            "com.android.vending",
            "com.android.providers.downloads",
            "com.android.providers.downloads.ui",
        )

        private val mainHandler = Handler(Looper.getMainLooper())

        @Volatile
        private var eventSink: EventChannel.EventSink? = null

        /** 服务在任意线程调用，切回主线程再推给 Dart。 */
        fun notifyState(running: Boolean) {
            mainHandler.post {
                eventSink?.success(running)
            }
        }
    }
}
