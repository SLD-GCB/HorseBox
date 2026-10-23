package com.horseui.horsebox.ime

import android.content.Context

/**
 * 简 -> 繁 单字转换（OpenCC 的 STCharacters，只取每字最常用的繁体形）。
 *
 * 只做逐字替换：词级异形（发→發/髮）靠词库里已有的繁体词条解决，
 * 所以候选里本来就有「頭髮」时不会被拆错。
 */
object ScriptConverter {
    private const val ASSET = "flutter_assets/assets/ime/st_chars.tsv"

    private var table: HashMap<Char, Char>? = null

    fun toTraditional(context: Context, text: String): String {
        val map = table ?: load(context) ?: return text
        var changed = false
        val builder = StringBuilder(text.length)
        for (ch in text) {
            val target = map[ch]
            if (target != null) {
                builder.append(target)
                changed = true
            } else {
                builder.append(ch)
            }
        }
        return if (changed) builder.toString() else text
    }

    private fun load(context: Context): HashMap<Char, Char>? {
        table?.let { return it }
        return try {
            val map = HashMap<Char, Char>(4096)
            context.assets.open(ASSET).bufferedReader(Charsets.UTF_8).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
                    if (line.length < 3) continue
                    val tab = line.indexOf('\t')
                    if (tab != 1) continue
                    map[line[0]] = line[2]
                }
            }
            table = map
            map
        } catch (_: Throwable) {
            null
        }
    }
}
