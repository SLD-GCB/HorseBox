package hbime

/**
 * 英文词库：按词频排序，只做前缀补全，不做拼写纠正。
 * 从 Android 移植：只改加载入口（load(lines)），算法不变。
 */
object EnglishLexicon {
    private var words: Array<String> = emptyArray()
    private var scores: IntArray = IntArray(0)

    var ready: Boolean = false
        private set

    /** 每行：word\tscore */
    fun load(lines: List<String>) {
        if (ready) return
        val wordList = ArrayList<String>(400_000)
        val scoreList = ArrayList<Int>(400_000)
        for (line in lines) {
            if (line.isEmpty()) continue
            val tab = line.indexOf('\t')
            if (tab <= 1) continue
            val word = line.substring(0, tab)
            val score = line.substring(tab + 1).toIntOrNull() ?: 1
            wordList.add(word)
            scoreList.add(score)
            if (score >= 90000) {
                frequent.add(word)
                frequentSet.add(word)
            }
        }
        words = wordList.toTypedArray()
        scores = scoreList.toIntArray()
        ready = words.isNotEmpty()
    }

    private val frequent = ArrayList<String>(10_000)
    private val frequentSet = HashSet<String>(16_384)

    /** 拼写纠错：只处理差一个字母、且首字母相同、且落在常用词里的情况。 */
    fun correct(word: String): String? {
        if (!ready || word.length < 3) return null
        val lower = word.lowercase()
        if (frequentSet.contains(lower)) return null
        for (candidate in frequent) {
            if (candidate.length < lower.length - 1) continue
            if (candidate.length > lower.length + 1) continue
            if (candidate[0] != lower[0]) continue
            if (distanceAtMostOne(lower, candidate)) return candidate
        }
        return null
    }

    private fun distanceAtMostOne(a: String, b: String): Boolean {
        if (a == b) return true
        if (a.length - b.length > 1 || b.length - a.length > 1) return false
        var i = 0
        var j = 0
        var edits = 0
        while (i < a.length && j < b.length) {
            if (a[i] == b[j]) {
                i++
                j++
                continue
            }
            edits++
            if (edits > 1) return false
            when {
                a.length > b.length -> i++
                a.length < b.length -> j++
                else -> {
                    i++
                    j++
                }
            }
        }
        if (i < a.length || j < b.length) edits++
        return edits <= 1
    }

    /** 前缀补全：词表已按词频降序，命中即最好的那几个。 */
    fun suggest(prefix: String, limit: Int): List<String> {
        if (!ready || prefix.isEmpty() || limit <= 0) return emptyList()
        val lower = prefix.lowercase()
        val out = ArrayList<String>(limit)
        for (index in words.indices) {
            val word = words[index]
            if (word.length < prefix.length) continue
            if (!word.startsWith(lower)) continue
            out.add(word)
            if (out.size >= limit) break
        }
        return out
    }
}
