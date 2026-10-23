package com.horseui.horsebox.ime

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File

/**
 * 词频记忆：记住「某段拼音你选过哪个词」，下次把它排到最前面。
 *
 * 每次选择都记权重：直接选第一项算确认（+2），翻到后面才算纠错（+6），
 * 所以"先错后改"的词会更快爬上来。同时记最后一次使用时间，
 * 计数相同时新的排前面，久不用的自然沉下去。
 *
 * 只存在应用私有目录的 ime_learned.txt，不上网；最多 2000 对。
 */
object ImeLearning {
    private const val FILE = "ime_learned.txt"
    private const val MAX_PAIRS = 2000

    private class Entry(var count: Int, var last: Long)

    private val table = HashMap<String, Entry>()
    private var dirty = false
    private var context: Context? = null

    private val handler = Handler(Looper.getMainLooper())
    private val flushTask = Runnable { flush() }

    var enabled: Boolean = true

    fun load(context: Context) {
        if (this.context != null) return
        this.context = context.applicationContext
        try {
            val file = File(context.filesDir, FILE)
            if (!file.exists()) return
            file.forEachLine { line ->
                val parts = line.split('\t')
                if (parts.size < 3) return@forEachLine
                val count = parts[2].toIntOrNull() ?: return@forEachLine
                if (count <= 0) return@forEachLine
                val last = if (parts.size >= 4) parts[3].toLongOrNull() ?: 0L else 0L
                table[key(parts[0], parts[1])] = Entry(count, last)
            }
        } catch (_: Throwable) {
        }
    }

    /**
     * 用户选中（或空格上屏）一个词时调用。
     *
     * [position] 是它在候选里的位置：0 表示直接确认，>0 表示是翻上去选的，
     * 后者说明词典排序不合你意，加权更重一点。
     */
    fun learn(code: String, word: String, position: Int = 0) {
        if (!enabled || code.isEmpty() || word.isEmpty()) return
        // 纯 ASCII 说明是把拼音本身当文字上屏了，没必要记。
        if (word.length > 8 || word.all { it.code < 128 }) return
        val boost = if (position <= 0) 2 else 6
        val now = System.currentTimeMillis()
        val item = table[key(code, word)]
        if (item == null) {
            table[key(code, word)] = Entry(boost, now)
        } else {
            item.count += boost
            item.last = now
        }
        if (table.size > MAX_PAIRS) trim()
        dirty = true
        handler.removeCallbacks(flushTask)
        handler.postDelayed(flushTask, 3000)
    }

    /** 同一组候选里，把用过的词提前；没记录过的保持原顺序（稳定排序）。 */
    fun rank(code: String, items: List<Candidate>): List<Candidate> {
        if (table.isEmpty()) return items
        var any = false
        for (item in items) {
            if (table.containsKey(key(code, item.word))) {
                any = true
                break
            }
        }
        if (!any) return items
        return items.sortedWith(
            compareByDescending<Candidate> { table[key(code, it.word)]?.count ?: 0 }
                .thenByDescending { table[key(code, it.word)]?.last ?: 0L },
        )
    }

    fun count(): Int = table.size

    fun clear() {
        table.clear()
        dirty = true
        flush()
    }

    fun flush() {
        val ctx = context ?: return
        if (!dirty) return
        dirty = false
        try {
            val builder = StringBuilder()
            for ((key, entry) in table) {
                builder.append(key)
                    .append('\t')
                    .append(entry.count)
                    .append('\t')
                    .append(entry.last)
                    .append('\n')
            }
            File(ctx.filesDir, FILE).writeText(builder.toString())
        } catch (_: Throwable) {
        }
    }

    private fun key(code: String, word: String): String = code + '\t' + word

    /** 超过上限时砍掉计数最低的四分之一（同分先砍最久没用的）。 */
    private fun trim() {
        val order = table.entries.sortedWith(
            compareBy<MutableMap.MutableEntry<String, Entry>> { it.value.count }
                .thenBy { it.value.last },
        )
        val remove = order.size / 4
        for (index in 0 until remove) table.remove(order[index].key)
    }
}
