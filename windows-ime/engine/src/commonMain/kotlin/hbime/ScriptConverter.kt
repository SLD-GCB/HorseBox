package hbime

/**
 * 简 -> 繁 单字转换。从 Android 移植：只改加载入口（load(lines)）。
 */
object ScriptConverter {
    private var table: HashMap<Char, Char>? = null

    /** 每行：简化字\t繁体字（取第一个制表位前后各一字符） */
    fun load(lines: List<String>) {
        if (table != null) return
        val map = HashMap<Char, Char>(4096)
        for (line in lines) {
            if (line.length < 3) continue
            val tab = line.indexOf('\t')
            if (tab != 1) continue
            map[line[0]] = line[2]
        }
        table = map
    }

    fun toTraditional(text: String): String {
        val map = table ?: return text
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
}
