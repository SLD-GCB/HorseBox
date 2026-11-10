package com.horseui.horsebox

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import com.horseui.horsebox.ime.HorseImeService
import com.horseui.horsebox.ime.ImeClipboard
import com.horseui.horsebox.ime.ImeFeedback
import com.horseui.horsebox.ime.ImeLearning
import com.horseui.horsebox.ime.ImePrefs
import com.horseui.horsebox.ime.ImeTheme
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var vpnPlugin: VpnPlugin? = null
    private val notifyChannelId = "horsebox_status"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        vpnPlugin = VpnPlugin(this).also { it.attach(flutterEngine) }
        setupImeChannel(flutterEngine)
        setupNotifyChannel(flutterEngine)
    }

    /// IP 养护等状态通知。
    private fun setupNotifyChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "horsebox/notify",
        ).setMethodCallHandler { call, result ->
            if (call.method != "show") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val title = call.argument<String>("title") ?: "HorseBox"
            val body = call.argument<String>("body") ?: ""
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
                PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1201)
            }
            val manager = getSystemService(NotificationManager::class.java)
            if (Build.VERSION.SDK_INT >= 26) {
                manager.createNotificationChannel(
                    NotificationChannel(
                        notifyChannelId,
                        "HorseBox 状态",
                        NotificationManager.IMPORTANCE_DEFAULT,
                    ),
                )
            }
            val intent = Intent(this, MainActivity::class.java)
            val pending = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(this, notifyChannelId)
            } else {
                Notification.Builder(this)
            }
            val notification = builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(Notification.BigTextStyle().bigText(body))
                .setContentIntent(pending)
                .setAutoCancel(true)
                .build()
            manager.notify((System.currentTimeMillis() % 100000).toInt(), notification)
            result.success(true)
        }
    }

    /// 系统输入法的状态查询与跳转，设置页用它显示"未启用 / 已启用 / 正在使用"。
    private fun setupImeChannel(flutterEngine: FlutterEngine) {
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "horsebox/ime",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(imeStatus())
                "configure" -> {
                    val values = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                    ImePrefs.update(this, values)
                    // 输入法正在显示的话，立刻按新配置重建一次。
                    HorseImeService.instance?.onSettingsChanged()
                    result.success(null)
                }
                "openSettings" -> {
                    startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS))
                    result.success(null)
                }
                "stats" -> {
                    ImePrefs.load(this)
                    ImeClipboard.load(this)
                    ImeLearning.load(this)
                    val diagnostics = ImeFeedback.diagnose(this)
                    result.success(
                        mapOf(
                            "clipboard" to ImeClipboard.count(),
                            "learned" to ImeLearning.count(),
                            "hasVibrator" to (diagnostics["hasVibrator"] ?: false),
                            "globalHaptic" to (diagnostics["globalHaptic"] ?: true),
                            "amplitudeControl" to (diagnostics["amplitudeControl"] ?: false),
                            "customPalette" to ImePrefs.customPalette,
                            "keyboardDark" to ImeTheme.isDark(this),
                        ),
                    )
                }
                "clearClipboard" -> {
                    ImeClipboard.clear(this)
                    result.success(null)
                }
                "clearLearning" -> {
                    ImeLearning.load(this)
                    ImeLearning.clear()
                    result.success(null)
                }
                "preview" -> {
                    ImePrefs.load(this)
                    ImeFeedback.init(this)
                    ImeFeedback.key(this, window?.decorView)
                    result.success(ImeFeedback.diagnose(this))
                }
                "enableHaptic" -> result.success(enableSystemHaptic())
                // App 内置键盘（Flutter）也复用同一套反馈。
                "tap" -> {
                    ImeFeedback.init(this)
                    ImeFeedback.key(this, window?.decorView)
                    result.success(null)
                }
                "showPicker" -> {
                    val manager =
                        getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
                    manager?.showInputMethodPicker()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 打开系统的「触感反馈」开关。
     *
     * 写系统设置需要 WRITE_SETTINGS 授权：没授权时先把用户送到授权页，
     * 返回后再点一次才会真正写进去。
     */
    private fun enableSystemHaptic(): Boolean {
        if (!Settings.System.canWrite(this)) {
            try {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_WRITE_SETTINGS,
                        Uri.parse("package:" + packageName),
                    ),
                )
            } catch (_: Throwable) {
                try {
                    startActivity(Intent(Settings.ACTION_SETTINGS))
                } catch (_: Throwable) {
                }
            }
            return false
        }
        return try {
            Settings.System.putInt(
                contentResolver,
                Settings.System.HAPTIC_FEEDBACK_ENABLED,
                1,
            )
        } catch (_: Throwable) {
            false
        }
    }

    private fun imeStatus(): Map<String, Boolean> {
        val component = ComponentName(this, HorseImeService::class.java)
        val manager = getSystemService(INPUT_METHOD_SERVICE) as? InputMethodManager
        val enabled = manager?.enabledInputMethodList?.any {
            it.packageName == packageName && it.serviceName == HorseImeService::class.java.name
        } == true
        val current = Settings.Secure.getString(
            contentResolver,
            Settings.Secure.DEFAULT_INPUT_METHOD,
        )?.let { ComponentName.unflattenFromString(it) == component } == true
        return mapOf("enabled" to enabled, "current" to current)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (vpnPlugin?.onActivityResult(requestCode, resultCode) == true) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (vpnPlugin?.onRequestPermissionsResult(requestCode, grantResults) == true) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }
}
