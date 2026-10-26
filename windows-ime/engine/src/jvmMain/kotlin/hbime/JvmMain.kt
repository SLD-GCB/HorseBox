package hbime

import java.io.File
import java.util.zip.GZIPInputStream

private fun readGz(path: String): List<String> =
    GZIPInputStream(File(path).inputStream()).bufferedReader(Charsets.UTF_8).readLines()

private fun readPlain(path: String): List<String> =
    File(path).readLines(Charsets.UTF_8)

fun main(args: Array<String>) {
    val dictDir = args.getOrNull(0)
        ?: "D:/github_code/code/Android/project/HorseBox/UI/assets/ime"
    val outFile = args.getOrNull(1)
        ?: "D:/github_code/code/Android/project/HorseBox/windows-ime/engine/golden-jvm.txt"

    PinyinEngine.load(readGz("$dictDir/pinyin.tsv.gz"), readPlain("$dictDir/syllables.txt"))
    EnglishLexicon.load(readGz("$dictDir/en_words.tsv.gz"))
    ScriptConverter.load(readPlain("$dictDir/st_chars.tsv"))

    val inputs = listOf(
        "wo", "nihao", "beijing", "zhongguo", "women",
        "woaibeijing", "woaibeijingtiananmen",
        "jintiantianqihenhao", "zhonghuarenmingongheguo",
        "shanghai", "chifan", "xiexie",
    )

    val sb = StringBuilder()
    sb.append("entries=").append(PinyinEngine.entryCount)
        .append(" syllables=").append(PinyinEngine.ready)
        .append(" en=").append(EnglishLexicon.ready)
        .append(" sc=").append(true).append('\n')

    for (input in inputs) {
        val cs = PinyinEngine.candidates(input, 10, true, true)
        sb.append("== ").append(input).append(" ==\n")
        for (c in cs) sb.append("  ").append(c.word).append('\t').append(c.consumed).append('\n')
    }

    val text = sb.toString()
    print(text)
    File(outFile).writeText(text, Charsets.UTF_8)
    println("[golden] written to " + outFile)
}
