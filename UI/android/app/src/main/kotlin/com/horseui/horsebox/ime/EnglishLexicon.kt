package com.horseui.horsebox.ime

import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors
import java.util.zip.GZIPInputStream

/**
 * 英文词库：37 万词，按词频排序（google-10000 在前，其余补全）。
 *
 * 只做前缀补全，不做拼写纠正——键盘上打出来的东西应该就是你要的，
 * 自动改词反而容易误伤代号、命令和缩写。
 */
object EnglishLexicon {
    private const val ASSET = "flutter_assets/assets/ime/en_words.tsv.gz"

    private var words: Array<String> = emptyArray()
    private var scores: IntArray = IntArray(0)

    @Volatile
    var ready: Boolean = false
        private set

    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "horsebox-en-dict").apply { priority = Thread.MIN_PRIORITY }
    }

    fun preload(context: Context, onReady: () -> Unit) {
        if (ready) {
            onReady()
            return
        }
        val app = context.applicationContext
        worker.execute {
            try {
                load(app)
            } catch (_: Throwable) {
            }
            if (ready) Handler(Looper.getMainLooper()).post(onReady)
        }
    }

    @Synchronized
    private fun load(context: Context) {
        if (ready) return
        val wordList = ArrayList<String>(400_000)
        val scoreList = ArrayList<Int>(400_000)
        context.assets.open(ASSET).use { raw ->
            GZIPInputStream(raw).bufferedReader(Charsets.UTF_8).use { reader ->
                while (true) {
                    val line = reader.readLine() ?: break
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
            }
        }
        words = wordList.toTypedArray()
        scores = scoreList.toIntArray()
        ready = words.isNotEmpty()
    }

    /** 常用词集合（前 1 万），纠错只在它们里找，避免推荐生僻词。 */
    private val frequent = ArrayList<String>(10_000)
    private val frequentSet = HashSet<String>(16_384)

    /**
     * 拼写纠错：只处理"差一个字母"的情况（多、少、错、换位），
     * 而且候选必须落在常用词里、首字母相同——宁可漏纠，也不要瞎改。
     */
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

    /** 两个词的编辑距离是否 ≤ 1。 */
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
