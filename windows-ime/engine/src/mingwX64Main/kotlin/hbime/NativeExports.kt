package hbime

import kotlinx.cinterop.*
import kotlin.experimental.ExperimentalNativeApi
import kotlin.native.CName
import platform.posix.*

@OptIn(ExperimentalForeignApi::class)
private fun readText(path: String): String {
    val p = path.replace('/', '\\')
    val f = fopen(p, "rb") ?: return ""
    try {
        fseek(f, 0, SEEK_END)
        val size = ftell(f).toInt()
        fseek(f, 0, SEEK_SET)
        if (size <= 0) return ""
        val buf = ByteArray(size)
        buf.usePinned { pinned ->
            fread(pinned.addressOf(0), 1uL, size.toULong(), f)
        }
        return buf.decodeToString()
    } finally {
        fclose(f)
    }
}

@OptIn(ExperimentalForeignApi::class)
private fun writeText(path: String, text: String) {
    val p = path.replace('/', '\\')
    val f = fopen(p, "wb") ?: return
    try {
        val bytes = text.encodeToByteArray()
        if (bytes.isNotEmpty()) {
            bytes.usePinned { pinned ->
                fwrite(pinned.addressOf(0), 1uL, bytes.size.toULong(), f)
            }
        }
    } finally {
        fclose(f)
    }
}

private fun splitLines(text: String): List<String> =
    text.split('\n').map { it.trimEnd('\r') }

// 用户在设置页里能开关的几项，和安卓端 ImePrefs 一一对应
private var optFuzzy = true
private var optSentence = true
private var optLearn = true

@OptIn(ExperimentalForeignApi::class)
private fun nowMillis(): Long = time(null) * 1000L

@OptIn(ExperimentalForeignApi::class)
private fun toCString(s: String): CPointer<ByteVar>? {
    val bytes = s.encodeToByteArray()
    val mem = malloc((bytes.size + 1).toULong()) ?: return null
    val ptr = mem.reinterpret<ByteVar>()
    for (i in bytes.indices) ptr[i] = bytes[i]
    ptr[bytes.size] = 0
    return ptr
}

@CName("hb_load")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLoad(dirPtr: CPointer<ByteVar>?): Int {
    val dir = dirPtr?.toKString() ?: return -1
    val dict = splitLines(readText("$dir/pinyin.tsv"))
    val syl = splitLines(readText("$dir/syllables.txt"))
    if (dict.isEmpty()) return -2
    PinyinEngine.load(dict, syl)
    val en = splitLines(readText("$dir/en_words.tsv"))
    if (en.isNotEmpty()) EnglishLexicon.load(en)
    val st = splitLines(readText("$dir/st_chars.tsv"))
    if (st.isNotEmpty()) ScriptConverter.load(st)
    return PinyinEngine.entryCount
}

@CName("hb_candidates")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbCandidates(inputPtr: CPointer<ByteVar>?, limit: Int): CPointer<ByteVar>? {
    val input = inputPtr?.toKString() ?: return null
    val raw = PinyinEngine.candidates(input, limit, optFuzzy, optSentence)
    val cs = ImeLearning.rank(input, raw)
    val sb = StringBuilder()
    for (c in cs) {
        sb.append(c.word).append('\t').append(c.consumed).append('\n')
    }
    return toCString(sb.toString())
}

@CName("hb_english_suggest")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbEnglishSuggest(prefixPtr: CPointer<ByteVar>?, limit: Int): CPointer<ByteVar>? {
    val prefix = prefixPtr?.toKString() ?: return null
    return toCString(EnglishLexicon.suggest(prefix, limit).joinToString("\n"))
}

@CName("hb_to_traditional")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbToTraditional(textPtr: CPointer<ByteVar>?): CPointer<ByteVar>? {
    val text = textPtr?.toKString() ?: return null
    return toCString(ScriptConverter.toTraditional(text))
}

@CName("hb_options")
@OptIn(ExperimentalNativeApi::class)
fun hbOptions(fuzzy: Int, sentence: Int, learn: Int) {
    optFuzzy = fuzzy != 0
    optSentence = sentence != 0
    optLearn = learn != 0
    ImeLearning.enabled = optLearn
}

@CName("hb_learn")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLearn(codePtr: CPointer<ByteVar>?, wordPtr: CPointer<ByteVar>?, position: Int) {
    val code = codePtr?.toKString() ?: return
    val word = wordPtr?.toKString() ?: return
    ImeLearning.learn(code, word, position, nowMillis())
}

@CName("hb_learning_load")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLearningLoad(pathPtr: CPointer<ByteVar>?) {
    val path = pathPtr?.toKString() ?: return
    ImeLearning.loadFromText(readText(path))
}

@CName("hb_learning_flush")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLearningFlush(pathPtr: CPointer<ByteVar>?) {
    val path = pathPtr?.toKString() ?: return
    writeText(path, ImeLearning.serialize())
}

// 学习记录现在由外壳层加密后落盘，引擎只吃/吐文本
@CName("hb_learning_load_text")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLearningLoadText(textPtr: CPointer<ByteVar>?) {
    val text = textPtr?.toKString() ?: return
    ImeLearning.loadFromText(text)
}

@CName("hb_learning_dump")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLearningDump(): CPointer<ByteVar>? = toCString(ImeLearning.serialize())

@CName("hb_learning_count")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbLearningCount(): Int = ImeLearning.count()

@CName("hb_free")
@OptIn(ExperimentalForeignApi::class, ExperimentalNativeApi::class)
fun hbFree(p: CPointer<ByteVar>?) {
    if (p != null) free(p)
}
