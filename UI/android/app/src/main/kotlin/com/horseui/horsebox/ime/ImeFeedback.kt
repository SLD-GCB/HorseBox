package com.horseui.horsebox.ime

import android.content.Context
import android.media.AudioAttributes
import android.media.SoundPool
import android.os.Build
import android.os.VibrationAttributes
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.View
import com.horseui.horsebox.R

/**
 * 按键反馈：自己播声音、自己触发震动。
 *
 * 震动参考 fcitx5-android 的做法：
 * 1. 优先直连 Vibrator（能用上用户设定的振幅）；
 * 2. Android 13 起，如果系统「触感反馈」被关掉，vibrator.vibrate() 会被静默吞掉，
 *    这时改走 View.performHapticFeedback(KEYBOARD_TAP, FLAG_IGNORE_GLOBAL_SETTING)，
 *    系统键盘用的就是这条通道，能绕过那个开关；
 * 3. 没有马达或直连失败时同样退回触感通道。
 */
object ImeFeedback {
    private var soundPool: SoundPool? = null
    private var clickId = 0
    private var deviceVibrator: Vibrator? = null
    private var initialized = false

    fun init(context: Context) {
        if (initialized) return
        initialized = true
        try {
            soundPool = SoundPool.Builder()
                .setMaxStreams(4)
                .setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ASSISTANCE_SONIFICATION)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                .build()
                .also { clickId = it.load(context, R.raw.key_click, 1) }
        } catch (_: Throwable) {
            soundPool = null
        }
        try {
            deviceVibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager =
                    context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                manager?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
        } catch (_: Throwable) {
            deviceVibrator = null
        }
    }

    fun key(context: Context, view: View? = null) {
        if (!initialized) init(context)
        if (ImePrefs.vibrate) vibrate(context, view)
        if (ImePrefs.sound) playClick()
    }

    fun diagnose(context: Context): Map<String, Boolean> {
        if (!initialized) init(context)
        val target = deviceVibrator
        val has = target?.hasVibrator() == true
        val amplitude = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            target?.hasAmplitudeControl() == true
        return mapOf(
            "hasVibrator" to has,
            "globalHaptic" to globalHapticEnabled(context),
            "amplitudeControl" to amplitude,
        )
    }

    private fun playClick() {
        try {
            soundPool?.play(clickId, 0.65f, 0.65f, 1, 0, 1f)
        } catch (_: Throwable) {
        }
    }

    private fun vibrate(context: Context, view: View?) {
        val target = deviceVibrator
        val strength = ImePrefs.vibrateAmplitude.coerceIn(20, 255)
        val globalOn = globalHapticEnabled(context)
        var sent = false
        if (target != null) {
            try {
                if (target.hasVibrator()) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        val amplitude = if (target.hasAmplitudeControl()) {
                            strength
                        } else {
                            VibrationEffect.DEFAULT_AMPLITUDE
                        }
                        // 参数分别是时长和振幅：转子马达 40ms 才"转得起来"，
                        // 振幅可控的机型直接用用户设定的强度。
                        val duration = if (target.hasAmplitudeControl()) {
                            40L
                        } else {
                            34L + strength / 6L
                        }
                        val effect = VibrationEffect.createOneShot(duration, amplitude)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            target.vibrate(
                                effect,
                                VibrationAttributes.createForUsage(
                                    VibrationAttributes.USAGE_TOUCH,
                                ),
                            )
                        } else {
                            target.vibrate(effect)
                        }
                    } else {
                        @Suppress("DEPRECATION")
                        target.vibrate(32L)
                    }
                    sent = true
                }
            } catch (_: Throwable) {
                sent = false
            }
        }
        if (!sent || !globalOn) haptic(view)
    }

    private fun haptic(view: View?) {
        val target = view ?: return
        try {
            var flags = HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING
            @Suppress("DEPRECATION")
            flags = flags or HapticFeedbackConstants.FLAG_IGNORE_GLOBAL_SETTING
            // 触感通道的强度不由我们决定，只能用常量近似：
            // 想要更重就换成 LONG_PRESS（一次更沉的"咚"）。
            val kind = if (ImePrefs.vibrateAmplitude >= 170) {
                HapticFeedbackConstants.LONG_PRESS
            } else {
                HapticFeedbackConstants.KEYBOARD_TAP
            }
            target.performHapticFeedback(kind, flags)
        } catch (_: Throwable) {
        }
    }

    private fun globalHapticEnabled(context: Context): Boolean = try {
        @Suppress("DEPRECATION")
        Settings.System.getInt(
            context.contentResolver,
            Settings.System.HAPTIC_FEEDBACK_ENABLED,
            1,
        ) == 1
    } catch (_: Throwable) {
        true
    }
}
