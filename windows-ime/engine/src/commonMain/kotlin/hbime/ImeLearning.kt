package hbime

/**
 * 词频记忆：把「某段拼音你选过哪个词」记下来，下次排到前面。
 * 从 Android 移植：去掉 Handler/File/Context，改成 loadFromText/serialize，
 * 时间戳由平台传入。
 */
object ImeLearning {
    private const val MAX_PAIRS = 2000

    private class Entry(var count: Int, var last: Long)

    private val table = HashMap<String, Entry>()

    var enabled: Boolean = true

    fun loadFromText(text: String) {
        if (text.isEmpty()) return
        for (line in text.split('\n')) {
            val parts = line.split('\t')
            if (parts.size < 3) continue
            val count = parts[2].toIntOrNull() ?: continue
            if (count <= 0) continue
            val last = if (parts.size >= 4) parts[3].toLongOrNull() ?: 0L else 0L
            table[key(parts[0], parts[1])] = Entry(count, last)
        }
    }

    fun serialize(): String {
        val sb = StringBuilder()
        for ((k, e) in table) {
            sb.append(k).append('\t').append(e.count).append('\t').append(e.last).append('\n')
        }
        return sb.toString()
    }

    fun learn(code: String, word: String, position: Int, now: Long) {
        if (!enabled || code.isEmpty() || word.isEmpty()) return
        if (word.length > 8 || word.all { it.code < 128 }) return
        val boost = if (position <= 0) 2 else 6
        val k = key(code, word)
        val item = table[k]
        if (item == null) {
            table[k] = Entry(boost, now)
        } else {
            item.count += boost
            item.last = now
        }
        if (table.size > MAX_PAIRS) trim()
    }

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

    fun clear() = table.clear()

    private fun key(code: String, word: String): String = code + '\t' + word

    private fun trim() {
        val order = table.entries.sortedWith(
            compareBy<MutableMap.MutableEntry<String, Entry>> { it.value.count }
                .thenBy { it.value.last },
        )
        val remove = order.size / 4
        for (index in 0 until remove) table.remove(order[index].key)
    }
}
