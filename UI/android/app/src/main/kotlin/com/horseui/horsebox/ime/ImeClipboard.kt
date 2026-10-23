package com.horseui.horsebox.ime

import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

class ClipboardItem(val text: String, val at: Long)

/**
 * 系统输入法的剪贴板历史：最多 30 条、单条 4000 字符，重复去重置顶。
 *
 * 只在这个输入法弹出来之后才读系统剪贴板（没有后台监听），
 * 落盘用 secret.key 加密，磁盘上看不到明文。
 */
object ImeClipboard {
    private const val FILE = "ime_clipboard.enc"
    private const val MAX_ITEMS = 30
    private const val MAX_CHARS = 4000
    private const val PREFS = "horsebox_ime"
    private const val KEY_SUPPRESS = "clip_suppress"

    private val items = ArrayList<ClipboardItem>()

    fun load(context: Context) {
        if (items.isNotEmpty()) return
        try {
            val file = File(context.filesDir, FILE)
            if (!file.exists()) return
            val plain = ImeCrypt.open(context, file.readText().trim())
            if (plain.isEmpty()) return
            val array = JSONArray(plain)
            for (index in 0 until array.length()) {
                val obj = array.optJSONObject(index) ?: continue
                val text = obj.optString("text")
                if (text.isEmpty()) continue
                items.add(ClipboardItem(text, obj.optLong("at")))
            }
        } catch (_: Throwable) {
        }
    }

    fun list(): List<ClipboardItem> = items.toList()

    fun count(): Int = items.size

    /**
     * 打开面板时把手上的剪贴板内容收进来。
     *
     * 但如果这条正是"清空"时系统剪贴板里躺着的那条，就不收回——
     * 否则清空之后一退出再进来，它又被抓回来了，看起来跟没删一样。
     */
    fun capture(context: Context) {
        val text = readClipboard(context)?.trim() ?: return
        if (text.isEmpty()) return
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val suppressed = prefs.getString(KEY_SUPPRESS, null)
        if (suppressed != null) {
            if (suppressed == digest(text)) return
            prefs.edit().remove(KEY_SUPPRESS).apply()
        }
        add(context, text)
    }

    fun clear(context: Context) {
        // 记住清空那一刻系统剪贴板里的内容（只存哈希），避免它被自动收回。
        val current = readClipboard(context)?.trim().orEmpty()
        val editor = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
        if (current.isEmpty()) {
            editor.remove(KEY_SUPPRESS)
        } else {
            editor.putString(KEY_SUPPRESS, digest(current))
        }
        editor.apply()
        items.clear()
        persist(context)
    }

    private fun digest(text: String): String {
        return try {
            val bytes = MessageDigest.getInstance("SHA-256")
                .digest(text.toByteArray(Charsets.UTF_8))
            bytes.joinToString("") { String.format("%02x", it) }
        } catch (_: Throwable) {
            text.hashCode().toString()
        }
    }

    private fun readClipboard(context: Context): String? {
        return try {
            val manager =
                context.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
            val clip = manager?.primaryClip ?: return null
            if (!clip.description.hasMimeType(ClipDescription.MIMETYPE_TEXT_PLAIN)) return null
            clip.getItemAt(0)?.coerceToText(context)?.toString()
        } catch (_: Throwable) {
            null
        }
    }

    private fun add(context: Context, raw: String) {
        val text = raw.trim()
        if (text.isEmpty() || text.length > MAX_CHARS) return
        items.removeAll { it.text == text }
        items.add(0, ClipboardItem(text, System.currentTimeMillis()))
        while (items.size > MAX_ITEMS) items.removeAt(items.size - 1)
        persist(context)
    }

    private fun persist(context: Context) {
        try {
            val array = JSONArray()
            for (item in items) {
                array.put(
                    JSONObject().apply {
                        put("text", item.text)
                        put("at", item.at)
                    },
                )
            }
            val data = ImeCrypt.seal(context, array.toString())
            File(context.filesDir, FILE).writeText(data)
        } catch (_: Throwable) {
        }
    }
}
