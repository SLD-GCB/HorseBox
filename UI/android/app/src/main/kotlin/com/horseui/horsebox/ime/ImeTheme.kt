package com.horseui.horsebox.ime

import android.content.Context
import android.content.res.Configuration
import android.graphics.Color
import android.os.Build

/** 键盘的一套配色。 */
class ImePalette(
    val bg: Int,
    val bar: Int,
    val key: Int,
    /** 键帽底下那层"底座"的颜色，让按键看起来是浮在板子上的。 */
    val keyBase: Int,
    /** 键帽描边。 */
    val keyBorder: Int,
    val divider: Int,
    val label: Int,
    val hint: Int,
    val onAccent: Int,
    val ripple: Int,
)

/**
 * 键盘主题解析：
 * - 明暗：跟随 App（用 App 里选的 深色/浅色/跟随系统）或跟随系统；
 * - 主色：跟随 App、跟随系统动态取色、或用户自定义。
 */
object ImeTheme {

    fun accent(context: Context): Int = when (ImePrefs.accentMode) {
        "custom" -> ImePrefs.customAccent
        "system" -> systemAccent(context) ?: ImePrefs.accent
        else -> ImePrefs.accent
    }

    fun isDark(context: Context): Boolean {
        if (ImePrefs.darkMode == "system") return systemDark(context)
        return when (ImePrefs.themeMode) {
            "dark" -> true
            "light" -> false
            else -> systemDark(context)
        }
    }

    fun palette(context: Context): ImePalette {
        if (ImePrefs.customPalette) return customPalette()
        return if (isDark(context)) DARK else LIGHT
    }

    /** 用户自定义整套配色：背景、按键、文字，其余由它们推导。 */
    private fun customPalette(): ImePalette {
        val bg = ImePrefs.paletteBg
        val key = ImePrefs.paletteKey
        val text = ImePrefs.paletteText
        val darkKey = luminance(key) < 0.5f
        return ImePalette(
            bg = bg,
            bar = shade(bg, if (luminance(bg) < 0.5f) 1.16f else 0.95f),
            key = key,
            keyBase = shade(key, 0.78f),
            keyBorder = shade(key, 1.18f),
            divider = shade(bg, if (luminance(bg) < 0.5f) 1.28f else 0.88f),
            label = text,
            hint = (text and 0x00FFFFFF) or 0x8C000000.toInt(),
            onAccent = 0xFFFFFFFF.toInt(),
            ripple = if (darkKey) 0x30FFFFFF else 0x1F000000,
        )
    }

    private fun luminance(color: Int): Float {
        val r = Color.red(color) / 255f
        val g = Color.green(color) / 255f
        val b = Color.blue(color) / 255f
        return 0.299f * r + 0.587f * g + 0.114f * b
    }

    /** ratio < 1 变暗，> 1 变亮。 */
    private fun shade(color: Int, ratio: Float): Int {
        fun channel(value: Int): Int {
            val scaled = if (ratio <= 1f) {
                value * ratio
            } else {
                value + (255 - value) * (ratio - 1f)
            }
            return scaled.toInt().coerceIn(0, 255)
        }
        return Color.argb(
            Color.alpha(color),
            channel(Color.red(color)),
            channel(Color.green(color)),
            channel(Color.blue(color)),
        )
    }

    private fun systemDark(context: Context): Boolean {
        val mode = context.resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK
        return mode == Configuration.UI_MODE_NIGHT_YES
    }

    private fun systemAccent(context: Context): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        return try {
            context.getColor(android.R.color.system_accent1_400)
        } catch (_: Throwable) {
            null
        }
    }

    private val DARK = ImePalette(
        bg = 0xFF1B1C1E.toInt(),
        bar = 0xFF232529.toInt(),
        key = 0xFF35373C.toInt(),
        keyBase = 0xFF232529.toInt(),
        keyBorder = 0xFF44474E.toInt(),
        divider = 0xFF2C2E33.toInt(),
        label = 0xFFEDEDEF.toInt(),
        hint = 0x8CFFFFFF.toInt(),
        onAccent = 0xFFFFFFFF.toInt(),
        ripple = 0x30FFFFFF,
    )

    private val LIGHT = ImePalette(
        bg = 0xFFEDEEF0.toInt(),
        bar = 0xFFFFFFFF.toInt(),
        key = 0xFFFFFFFF.toInt(),
        keyBase = 0xFFD3D6DB.toInt(),
        keyBorder = 0xFFE1E4E8.toInt(),
        divider = 0xFFDCDEE2.toInt(),
        label = 0xFF1B1C1E.toInt(),
        hint = 0x66000000,
        onAccent = 0xFFFFFFFF.toInt(),
        ripple = 0x1F000000,
    )
}
