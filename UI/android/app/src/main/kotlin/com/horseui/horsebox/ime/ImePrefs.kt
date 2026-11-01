package com.horseui.horsebox.ime

import android.content.Context

/**
 * 系统输入法的偏好。
 *
 * Flutter 的设置页是唯一的入口：它把当前配置通过 MethodChannel 推下来，
 * 这里只负责落到 SharedPreferences，输入法启动时读一次。
 */
object ImePrefs {
    private const val FILE = "horsebox_ime"

    @Volatile
    var chinese: Boolean = false
        private set

    /** full = 全键盘，nine = 九宫格。 */
    @Volatile
    var layout: String = "full"
        private set

    @Volatile
    var fuzzy: Boolean = true
        private set

    @Volatile
    var sentence: Boolean = true
        private set

    @Volatile
    var candidates: Int = 5
        private set

    /** 键盘高度（dp），200–420；超矮屏在 Service 里再按屏高裁一次。 */
    @Volatile
    var heightDp: Int = 282
        private set

    /** 按键字号缩放，0.85–1.35，1.0 为默认。 */
    @Volatile
    var scale: Float = 1f
        private set

    /** 词频记忆：记住选过的词，下次优先。 */
    @Volatile
    var learn: Boolean = true
        private set

    /** 是否在键盘上显示剪贴板入口。 */
    @Volatile
    var clipboard: Boolean = true
        private set

    /** App 的主题色（ARGB），由设置页推下来。 */
    @Volatile
    var accent: Int = 0xFF4C8F6F.toInt()
        private set

    /** 键盘配色：app = 跟随 App，system = 跟随系统，custom = 自定义。 */
    @Volatile
    var accentMode: String = "app"
        private set

    /** 自定义配色（ARGB）。 */
    @Volatile
    var customAccent: Int = 0xFF4C8F6F.toInt()
        private set

    /** App 的明暗模式：system / dark / light，由设置页推下来。 */
    @Volatile
    var themeMode: String = "dark"
        private set

    /** 键盘明暗：app = 跟随 App，system = 跟随系统。 */
    @Volatile
    var darkMode: String = "app"
        private set

    /** 按键音、按键震动（自己实现，不跟系统的触摸提示开关）。 */
    @Volatile
    var sound: Boolean = false
        private set

    @Volatile
    var vibrate: Boolean = true
        private set

    /** 英文自动纠错（只纠差一个字母且落在常用词里的）。 */
    @Volatile
    var autocorrect: Boolean = true
        private set

    /** 自定义整套键盘配色（关掉时用明暗两套内置配色）。 */
    @Volatile
    var customPalette: Boolean = false
        private set

    @Volatile
    var paletteBg: Int = 0xFF1B1C1E.toInt()
        private set

    @Volatile
    var paletteKey: Int = 0xFF35373C.toInt()
        private set

    @Volatile
    var paletteText: Int = 0xFFEDEDEF.toInt()
        private set

    /** 输出字形：sc = 简体，tc = 繁体。 */
    @Volatile
    var script: String = "sc"
        private set

    /** 震动振幅 20–255，越大越强；不支持振幅控制的机型改成调时长。 */
    @Volatile
    var vibrateAmplitude: Int = 140
        private set

    fun load(context: Context) {
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        chinese = prefs.getBoolean("chinese", false)
        layout = if (prefs.getString("layout", "full") == "nine") "nine" else "full"
        fuzzy = prefs.getBoolean("fuzzy", true)
        sentence = prefs.getBoolean("sentence", true)
        candidates = prefs.getInt("candidates", 5).coerceIn(3, 9)
        heightDp = prefs.getInt("height", 282).coerceIn(200, 420)
        scale = prefs.getFloat("scale", 1f).coerceIn(0.85f, 1.35f)
        learn = prefs.getBoolean("learn", true)
        clipboard = prefs.getBoolean("clipboard", true)
        accent = prefs.getInt("accent", 0xFF4C8F6F.toInt())
        accentMode = prefs.getString("accent_mode", "app") ?: "app"
        customAccent = prefs.getInt("accent_custom", 0xFF4C8F6F.toInt())
        themeMode = prefs.getString("app_theme_mode", "dark") ?: "dark"
        darkMode = prefs.getString("dark_mode", "app") ?: "app"
        sound = prefs.getBoolean("sound", false)
        vibrate = prefs.getBoolean("vibrate", true)
        vibrateAmplitude = prefs.getInt("vibrate_amp", 140).coerceIn(20, 255)
        script = if (prefs.getString("script", "sc") == "tc") "tc" else "sc"
        autocorrect = prefs.getBoolean("autocorrect", true)
        customPalette = prefs.getBoolean("custom_palette", false)
        paletteBg = prefs.getInt("palette_bg", 0xFF1B1C1E.toInt())
        paletteKey = prefs.getInt("palette_key", 0xFF35373C.toInt())
        paletteText = prefs.getInt("palette_text", 0xFFEDEDEF.toInt())
    }

    /** 返回是否真的有变化，输入法据此决定要不要刷新。 */
    fun update(context: Context, values: Map<*, *>): Boolean {
        val before = snapshot()
        val prefs = context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        (values["chinese"] as? Boolean)?.let {
            chinese = it
            editor.putBoolean("chinese", it)
        }
        (values["layout"] as? String)?.let {
            layout = if (it == "nine") "nine" else "full"
            editor.putString("layout", layout)
        }
        (values["fuzzy"] as? Boolean)?.let {
            fuzzy = it
            editor.putBoolean("fuzzy", it)
        }
        (values["sentence"] as? Boolean)?.let {
            sentence = it
            editor.putBoolean("sentence", it)
        }
        (values["candidates"] as? Number)?.let {
            candidates = it.toInt().coerceIn(3, 9)
            editor.putInt("candidates", candidates)
        }
        (values["height"] as? Number)?.let {
            heightDp = it.toInt().coerceIn(200, 420)
            editor.putInt("height", heightDp)
        }
        (values["scale"] as? Number)?.let {
            scale = it.toFloat().coerceIn(0.85f, 1.35f)
            editor.putFloat("scale", scale)
        }
        (values["learn"] as? Boolean)?.let {
            learn = it
            editor.putBoolean("learn", it)
        }
        (values["clipboard"] as? Boolean)?.let {
            clipboard = it
            editor.putBoolean("clipboard", it)
        }
        (values["accent"] as? Number)?.let {
            accent = it.toInt()
            editor.putInt("accent", accent)
        }
        (values["accentMode"] as? String)?.let {
            accentMode = if (it == "system" || it == "custom") it else "app"
            editor.putString("accent_mode", accentMode)
        }
        (values["accentColor"] as? Number)?.let {
            customAccent = it.toInt()
            editor.putInt("accent_custom", customAccent)
        }
        (values["themeMode"] as? String)?.let {
            themeMode = it
            editor.putString("app_theme_mode", it)
        }
        (values["darkMode"] as? String)?.let {
            darkMode = if (it == "system") "system" else "app"
            editor.putString("dark_mode", darkMode)
        }
        (values["sound"] as? Boolean)?.let {
            sound = it
            editor.putBoolean("sound", it)
        }
        (values["vibrate"] as? Boolean)?.let {
            vibrate = it
            editor.putBoolean("vibrate", it)
        }
        (values["autocorrect"] as? Boolean)?.let {
            autocorrect = it
            editor.putBoolean("autocorrect", it)
        }
        (values["customPalette"] as? Boolean)?.let {
            customPalette = it
            editor.putBoolean("custom_palette", it)
        }
        (values["paletteBg"] as? Number)?.let {
            paletteBg = it.toInt()
            editor.putInt("palette_bg", paletteBg)
        }
        (values["paletteKey"] as? Number)?.let {
            paletteKey = it.toInt()
            editor.putInt("palette_key", paletteKey)
        }
        (values["paletteText"] as? Number)?.let {
            paletteText = it.toInt()
            editor.putInt("palette_text", paletteText)
        }
        (values["vibrateAmplitude"] as? Number)?.let {
            vibrateAmplitude = it.toInt().coerceIn(20, 255)
            editor.putInt("vibrate_amp", vibrateAmplitude)
        }
        editor.apply()
        return before != snapshot()
    }

    /** 简繁切换要立即生效，所以单独提供写入口。 */
    fun setScript(context: Context, value: String) {
        script = if (value == "tc") "tc" else "sc"
        context.getSharedPreferences(FILE, Context.MODE_PRIVATE)
            .edit()
            .putString("script", script)
            .apply()
    }

    private fun snapshot(): List<Any> =
        listOf(
            chinese,
            layout,
            fuzzy,
            sentence,
            candidates,
            heightDp,
            scale,
            learn,
            clipboard,
            accent,
            accentMode,
            customAccent,
            themeMode,
            darkMode,
            sound,
            vibrate,
            vibrateAmplitude,
            autocorrect,
            customPalette,
            paletteBg,
            paletteKey,
            paletteText,
        )
}
