package hbime

/**
 * 离线拼音词库：全拼 / 首字母 / 模糊音 / 九宫格 / 整句切分。
 *
 * 从 Android 的 PinyinEngine 移植：算法保持不变，只把 assets 读取改成
 * 由平台传入已解析的行（load）。不依赖任何 Android/JVM API。
 */
object PinyinEngine {
    private const val MAX_PER_KEY = 24
    private const val MAX_PER_T9 = 40

    private var codes: Array<String> = emptyArray()
    private var initials: Array<String> = emptyArray()
    private var words: Array<String> = emptyArray()
    private var weights: IntArray = IntArray(0)
    private val syllables = HashSet<String>(512)

    private var exactCache: HashMap<String, IntArray>? = null
    private var fuzzyCache: HashMap<String, IntArray>? = null
    private var t9Cache: HashMap<String, IntArray>? = null
    private var topCache: HashMap<String, Int>? = null

    var ready: Boolean = false
        private set

    var entryCount: Int = 0
        private set

    /** 从已解析的行加载。dictLines 每行：code\tinitials\tword\tweight */
    fun load(dictLines: List<String>, syllableLines: List<String>) {
        if (ready) return
        val codeList = ArrayList<String>(140_000)
        val initList = ArrayList<String>(140_000)
        val wordList = ArrayList<String>(140_000)
        val weightList = ArrayList<Int>(140_000)

        for (line in dictLines) {
            if (line.isEmpty()) continue
            val parts = line.split('\t')
            if (parts.size < 4) continue
            val weight = parts[3].toIntOrNull() ?: continue
            codeList.add(parts[0])
            initList.add(parts[1])
            wordList.add(parts[2])
            weightList.add(weight)
        }
        if (codeList.isEmpty()) return

        for (line in syllableLines) {
            val item = line.trim()
            if (item.isNotEmpty()) syllables.add(item)
        }

        codes = codeList.toTypedArray()
        initials = initList.toTypedArray()
        words = wordList.toTypedArray()
        weights = weightList.toIntArray()
        exactCache = buildIndex(MAX_PER_KEY) { codes[it] }
        topCache = buildTop()
        entryCount = codes.size
        ready = true
    }

    private fun buildIndex(limit: Int, keyOf: (Int) -> String): HashMap<String, IntArray> {
        val temp = HashMap<String, MutableList<Int>>(1 shl 18)
        for (index in codes.indices) {
            val key = keyOf(index)
            if (key.isEmpty()) continue
            val list = temp.getOrPut(key) { ArrayList(2) }
            if (list.size < limit) list.add(index)
        }
        val out = HashMap<String, IntArray>(temp.size)
        for ((key, value) in temp) out[key] = value.toIntArray()
        return out
    }

    private fun buildTop(): HashMap<String, Int> {
        val out = HashMap<String, Int>(1 shl 17)
        for (index in codes.indices) {
            if (!out.containsKey(codes[index])) out[codes[index]] = index
        }
        return out
    }

    private fun fuzzyIndex(): HashMap<String, IntArray> {
        fuzzyCache?.let { return it }
        val built = buildIndex(MAX_PER_KEY) { fuzzyOf(codes[it]) }
        fuzzyCache = built
        return built
    }

    private fun t9Index(): HashMap<String, IntArray> {
        t9Cache?.let { return it }
        val built = buildIndex(MAX_PER_T9) { digitsOf(codes[it]) }
        t9Cache = built
        return built
    }

    /** 候选：整句 → 精确 → 模糊音 → 前缀 → 首字母 → 首音节单字。 */
    fun candidates(
        buffer: String,
        limit: Int,
        fuzzy: Boolean,
        sentence: Boolean,
    ): List<Candidate> {
        if (!ready || buffer.isEmpty() || limit <= 0) return emptyList()
        val out = ArrayList<Candidate>(limit)
        // 去重用 HashSet：候选取到几百条时，线性查重会把单次按键拖到几百毫秒
        val seen = HashSet<String>(limit * 2)
        fun add(word: String, consumed: Int) {
            if (out.size >= limit || word.isEmpty()) return
            if (!seen.add(word)) return
            out.add(Candidate(word, consumed))
        }

        if (sentence && buffer.length >= 6) {
            val line = sentence(buffer)
            if (line != null && line != buffer) add(line, buffer.length)
        }

        exactCache?.get(buffer)?.let { list ->
            for (index in list) {
                if (out.size >= limit) return@let
                add(words[index], buffer.length)
            }
        }
        if (fuzzy) {
            fuzzyIndex()[fuzzyOf(buffer)]?.let { list ->
                for (index in list) {
                    if (out.size >= limit) return@let
                    add(words[index], buffer.length)
                }
            }
        }
        for (index in codes.indices) {
            if (out.size >= limit) break
            val code = codes[index]
            if (code.length <= buffer.length) continue
            if (!code.startsWith(buffer)) continue
            add(words[index], buffer.length)
        }
        if (out.size < limit && buffer.length >= 2) {
            for (index in codes.indices) {
                if (out.size >= limit) break
                if (initials[index] != buffer) continue
                add(words[index], buffer.length)
            }
        }

        val head = firstSyllable(buffer)
        if (head.isNotEmpty() && head.length < buffer.length && out.size < limit) {
            exactCache?.get(head)?.let { list ->
                for (index in list) {
                    if (out.size >= limit) break
                    if (words[index].length != 1) continue
                    add(words[index], head.length)
                }
            }
        }
        return out
    }

    fun t9Candidates(digits: String, limit: Int): List<Candidate> {
        if (!ready || digits.isEmpty() || limit <= 0) return emptyList()
        val out = ArrayList<Candidate>(limit)
        t9Index()[digits]?.let { list ->
            for (index in list) {
                if (out.size >= limit) break
                val word = words[index]
                if (out.any { it.word == word }) continue
                out.add(Candidate(word, digits.length))
            }
        }
        if (out.size < limit) {
            for (index in codes.indices) {
                if (out.size >= limit) break
                val code = digitsOf(codes[index])
                if (code.length <= digits.length) continue
                if (!code.startsWith(digits)) continue
                if (out.any { it.word == words[index] }) continue
                out.add(Candidate(words[index], digits.length))
            }
        }
        return out
    }

    private fun firstSyllable(code: String): String {
        for (length in minOf(6, code.length) downTo 1) {
            val part = code.substring(0, length)
            if (syllables.contains(part)) return part
        }
        return ""
    }

    private fun sentence(buffer: String): String? {
        val n = buffer.length
        val unreachable = Int.MAX_VALUE / 2
        val counts = IntArray(n + 1) { unreachable }
        val scores = DoubleArray(n + 1) { -1e18 }
        val back = IntArray(n + 1) { -1 }
        val picked = arrayOfNulls<String>(n + 1)
        val top = topCache ?: return null
        counts[0] = 0
        scores[0] = 0.0
        for (end in 1..n) {
            for (start in 0 until end) {
                if (counts[start] == unreachable) continue
                val segment = buffer.substring(start, end)
                if (!readableAsSyllables(segment)) continue
                val index = top[segment] ?: continue
                val nextCount = counts[start] + 1
                val nextScore = scores[start] + kotlin.math.ln(weights[index] + 1.0)
                val better = nextCount < counts[end] ||
                    (nextCount == counts[end] && nextScore > scores[end])
                if (better) {
                    counts[end] = nextCount
                    scores[end] = nextScore
                    back[end] = start
                    picked[end] = words[index]
                }
            }
        }
        if (counts[n] == unreachable) return null
        val parts = ArrayList<String>(counts[n])
        var cursor = n
        while (cursor > 0) {
            parts.add(0, picked[cursor] ?: return null)
            cursor = back[cursor]
        }
        return parts.joinToString("")
    }

    private fun readableAsSyllables(code: String): Boolean {
        if (code.isEmpty()) return false
        var index = 0
        while (index < code.length) {
            var matched = 0
            for (length in minOf(6, code.length - index) downTo 1) {
                if (syllables.contains(code.substring(index, index + length))) {
                    matched = length
                    break
                }
            }
            if (matched == 0) return false
            index += matched
        }
        return true
    }

    private fun fuzzyOf(code: String): String =
        code.replace("zh", "z").replace("ch", "c").replace("sh", "s")

    private fun digitsOf(code: String): String {
        val builder = StringBuilder(code.length)
        for (index in code.indices) {
            val digit = T9[code[index]]
            if (digit != null) builder.append(digit)
        }
        return builder.toString()
    }

    private val T9: Map<Char, Char> = buildMap {
        for (char in "abc") put(char, '2')
        for (char in "def") put(char, '3')
        for (char in "ghi") put(char, '4')
        for (char in "jkl") put(char, '5')
        for (char in "mno") put(char, '6')
        for (char in "pqrs") put(char, '7')
        for (char in "tuv") put(char, '8')
        for (char in "wxyz") put(char, '9')
    }
}

/** 一条候选：word 是要上屏的文字，consumed 是它消耗掉多少位输入。 */
class Candidate(val word: String, val consumed: Int)
