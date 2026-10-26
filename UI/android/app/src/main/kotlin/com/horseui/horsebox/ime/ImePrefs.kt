package com.horseui.horsebox.ime

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * 系统输入法的偏好。
 *
 * Flutter 的设置页是唯一的入口：它把当前配置通过 MethodChannel 推下来，
 * 这里只负责落到 filesDir/ime_prefs.json，输入法启动时读一次。
 */
object ImePrefs {
    /** 设置存成一个 json，和 ime_learned.txt 一起落在 filesDir 里，随备份走。 */
    private const val FILE_NAME = "ime_prefs.json"
    private const val LEGACY_PREFS = "horsebox_ime"

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
        val file = File(context.filesDir, FILE_NAME)
        if (file.exists()) {
            try {
                val raw = file.readText().trim()
                val plain = ImeCrypt.open(context, raw)
                if (plain.isEmpty()) return
                val obj = JSONObject(plain)
                val map = HashMap<String, Any?>()
                for (key in obj.keys()) map[key] = obj.get(key)
                fromMap(map)
                // 老版本是明文 json，读一次就改存密文
                if (!raw.startsWith("enc1:")) save(context)
                return
            } catch (_: Exception) {
                // 文件坏了就退回默认值，别让输入法起不来
            }
        }
        // 更老的版本存在 SharedPreferences 里，第一次读就迁到文件
        val legacy = context.getSharedPreferences(LEGACY_PREFS, Context.MODE_PRIVATE)
        if (legacy.all.isNotEmpty()) {
            fromMap(legacy.all)
            save(context)
        }
    }

    /** 保存当前全部设置项，和 ime_learned.txt 一起进备份。 */
    fun save(context: Context) {
        try {
            val obj = JSONObject()
            for ((key, value) in toMap()) obj.put(key, value)
            val sealed = ImeCrypt.sealOrNull(context, obj.toString()) ?: return
            File(context.filesDir, FILE_NAME).writeText(sealed)
        } catch (_: Exception) {
        }
    }

    private fun toMap(): Map<String, Any?> = mapOf(
        "chinese" to chinese,
        "layout" to layout,
        "fuzzy" to fuzzy,
        "sentence" to sentence,
        "candidates" to candidates,
        "height" to heightDp,
        "scale" to scale,
        "learn" to learn,
        "clipboard" to clipboard,
        "accent" to accent,
        "accent_mode" to accentMode,
        "accent_custom" to customAccent,
        "app_theme_mode" to themeMode,
        "dark_mode" to darkMode,
        "sound" to sound,
        "vibrate" to vibrate,
        "vibrate_amp" to vibrateAmplitude,
        "script" to script,
        "autocorrect" to autocorrect,
        "custom_palette" to customPalette,
        "palette_bg" to paletteBg,
        "palette_key" to paletteKey,
        "palette_text" to paletteText,
    )

    private fun fromMap(m: Map<String, Any?>) {
        chinese = m["chinese"] as? Boolean ?: false
        layout = if (m["layout"] as? String == "nine") "nine" else "full"
        fuzzy = m["fuzzy"] as? Boolean ?: true
        sentence = m["sentence"] as? Boolean ?: true
        candidates = ((m["candidates"] as? Number)?.toInt() ?: 5).coerceIn(3, 9)
        heightDp = ((m["height"] as? Number)?.toInt() ?: 282).coerceIn(200, 420)
        scale = ((m["scale"] as? Number)?.toFloat() ?: 1f).coerceIn(0.85f, 1.35f)
        learn = m["learn"] as? Boolean ?: true
        clipboard = m["clipboard"] as? Boolean ?: true
        accent = (m["accent"] as? Number)?.toInt() ?: 0xFF4C8F6F.toInt()
        accentMode = when (m["accent_mode"] as? String) {
            "system", "custom" -> m["accent_mode"] as String
            else -> "app"
        }
        customAccent = (m["accent_custom"] as? Number)?.toInt() ?: 0xFF4C8F6F.toInt()
        themeMode = m["app_theme_mode"] as? String ?: "dark"
        darkMode = if (m["dark_mode"] as? String == "system") "system" else "app"
        sound = m["sound"] as? Boolean ?: false
        vibrate = m["vibrate"] as? Boolean ?: true
        vibrateAmplitude = ((m["vibrate_amp"] as? Number)?.toInt() ?: 140).coerceIn(20, 255)
        script = if (m["script"] as? String == "tc") "tc" else "sc"
        autocorrect = m["autocorrect"] as? Boolean ?: true
        customPalette = m["custom_palette"] as? Boolean ?: false
        paletteBg = (m["palette_bg"] as? Number)?.toInt() ?: 0xFF1B1C1E.toInt()
        paletteKey = (m["palette_key"] as? Number)?.toInt() ?: 0xFF35373C.toInt()
        paletteText = (m["palette_text"] as? Number)?.toInt() ?: 0xFFEDEDEF.toInt()
    }

    /** 返回是否真的有变化，输入法据此决定要不要刷新。 */
    fun update(context: Context, values: Map<*, *>): Boolean {
        val before = snapshot()
        (values["chinese"] as? Boolean)?.let {
            chinese = it
        }
        (values["layout"] as? String)?.let {
            layout = if (it == "nine") "nine" else "full"
        }
        (values["fuzzy"] as? Boolean)?.let {
            fuzzy = it
        }
        (values["sentence"] as? Boolean)?.let {
            sentence = it
        }
        (values["candidates"] as? Number)?.let {
            candidates = it.toInt().coerceIn(3, 9)
        }
        (values["height"] as? Number)?.let {
            heightDp = it.toInt().coerceIn(200, 420)
        }
        (values["scale"] as? Number)?.let {
            scale = it.toFloat().coerceIn(0.85f, 1.35f)
        }
        (values["learn"] as? Boolean)?.let {
            learn = it
        }
        (values["clipboard"] as? Boolean)?.let {
            clipboard = it
        }
        (values["accent"] as? Number)?.let {
            accent = it.toInt()
        }
        (values["accentMode"] as? String)?.let {
            accentMode = if (it == "system" || it == "custom") it else "app"
        }
        (values["accentColor"] as? Number)?.let {
            customAccent = it.toInt()
        }
        (values["themeMode"] as? String)?.let {
            themeMode = it
        }
        (values["darkMode"] as? String)?.let {
            darkMode = if (it == "system") "system" else "app"
        }
        (values["sound"] as? Boolean)?.let {
            sound = it
        }
        (values["vibrate"] as? Boolean)?.let {
            vibrate = it
        }
        (values["autocorrect"] as? Boolean)?.let {
            autocorrect = it
        }
        (values["customPalette"] as? Boolean)?.let {
            customPalette = it
        }
        (values["paletteBg"] as? Number)?.let {
            paletteBg = it.toInt()
        }
        (values["paletteKey"] as? Number)?.let {
            paletteKey = it.toInt()
        }
        (values["paletteText"] as? Number)?.let {
            paletteText = it.toInt()
        }
        (values["vibrateAmplitude"] as? Number)?.let {
            vibrateAmplitude = it.toInt().coerceIn(20, 255)
        }
        save(context)
        return before != snapshot()
    }

    /** 简繁切换要立即生效，所以单独提供写入口。 */
    fun setScript(context: Context, value: String) {
        script = if (value == "tc") "tc" else "sc"
        save(context)
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
