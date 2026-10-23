package com.horseui.horsebox.ime

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.InsetDrawable
import android.graphics.drawable.LayerDrawable
import android.graphics.drawable.RippleDrawable
import android.os.Build
import android.text.TextUtils
import android.util.TypedValue
import android.view.Gravity
import android.widget.PopupWindow
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.View.MeasureSpec
import android.view.WindowInsets
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * 系统输入法的键盘视图。
 *
 * 视觉参考 fcitx5-android：字号偏大、圆角 9dp、按键之间留 4dp 缝，
 * 候选条是纯文字 + 第一项高亮，不做彩色药丸，看起来更干净。
 *
 * 高度由 Service 固定给定（见 HorseImeService.keyboardHeight），
 * 不参与窗口 inset 计算，所以不会出现系统键盘把页面顶爆的问题。
 */
class ImeBoard(context: Context) : LinearLayout(context) {

    interface Host {
        fun commit(text: String)
        fun deleteBackward()
        fun deleteChars(count: Int)
        fun sendEnter()
        fun clearField()
        fun hideKeyboard()
        fun showSystemPicker()
    }

    var host: Host? = null

    private var chinese = ImePrefs.chinese
    private var nine = ImePrefs.layout == "nine"
    private var shift = false
    private var asciiOnly = false
    private var clipboardMode = false
    private var expandedMode = false
    private var allCandidates: List<Candidate> = emptyList()
    /** 符号分类下标，-1 表示显示分类入口。 */
    private var symbolPage = 0
    private var symbolPager: HorizontalScrollView? = null
    private var symbolTitle: TextView? = null
    private var symbolPageWidth = 0
    private var page = PAGE_LETTERS
    private var buffer = StringBuilder()
    private var candidates: List<Candidate> = emptyList()
    /** 拼音缓冲里的光标位置，0 表示在最前面。 */
    private var cursor = 0
    /** 英文模式已经打出去的字母，用于补全后回删。 */
    private var enBuffer = StringBuilder()
    private var enSuggest: List<String> = emptyList()
    private var pinyinView: TextView? = null
    private var scale = ImePrefs.scale
    // 每次用到都现读一次：设置一改就不会留下旧配色的快照。
    private val palette: ImePalette
        get() = ImeTheme.palette(context)

    private val topBar = LinearLayout(context)
    private val candidateBar = LinearLayout(context)
    private val keysArea = LinearLayout(context)

    init {
        orientation = VERTICAL
        setBackgroundColor(palette.bg)
        topBar.orientation = HORIZONTAL
        topBar.gravity = Gravity.CENTER_VERTICAL
        candidateBar.orientation = HORIZONTAL
        candidateBar.gravity = Gravity.CENTER_VERTICAL
        keysArea.orientation = VERTICAL
    }

    /** 把两种"底色"刷成当前配色：根容器（按键之间的地板）和两条工具栏。 */
    private fun applyColors() {
        setBackgroundColor(palette.bg)
        topBar.background = solid(palette.bar)
        candidateBar.background = solid(palette.bar)
    }

    fun build() {
        removeAllViews()
        applyColors()
        addView(topBar, LayoutParams(LayoutParams.MATCH_PARENT, dp(38)))
        addView(divider(), LayoutParams(LayoutParams.MATCH_PARENT, dp(1)))
        addView(candidateBar, LayoutParams(LayoutParams.MATCH_PARENT, dp(38)))
        addView(divider(), LayoutParams(LayoutParams.MATCH_PARENT, dp(1)))
        addView(keysArea, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        candidateBar.visibility =
            if (clipboardMode || expandedMode) GONE else VISIBLE
        rebuildTopBar()
        rebuildCandidateBar()
        rebuildKeys()
    }

    /** 每次开始输入时调用：密码框强制英文，其余跟随设置。 */
    fun resetForInput(asciiOnly: Boolean) {
        ImePrefs.load(context)
        this.asciiOnly = asciiOnly
        buffer = StringBuilder()
        cursor = 0
        candidates = emptyList()
        shift = false
        page = PAGE_LETTERS
        symbolPage = 0
        enBuffer = StringBuilder()
        enSuggest = emptyList()
        clipboardMode = false
        expandedMode = false
        allCandidates = emptyList()
        candidateBar.visibility = VISIBLE
        chinese = !asciiOnly && ImePrefs.chinese
        nine = ImePrefs.layout == "nine"
        scale = ImePrefs.scale
        applyColors()
        rebuildTopBar()
        rebuildCandidateBar()
        rebuildKeys()
        if (chinese) ensureEngine()
    }

    fun clearComposing() {
        if (buffer.isEmpty()) return
        buffer = StringBuilder()
        cursor = 0
        candidates = emptyList()
        rebuildCandidateBar()
    }

    /** 按键大小变了就整体重建一次；高度变化由 Service 改 layoutParams。 */
    fun applySizing() {
        val next = ImePrefs.scale
        if (next == scale) return
        scale = next
        build()
    }

    /** 系统深浅色 / 配色设置变了：只换颜色，不重建按键。 */
    fun applyTheme() {
        repaint()
    }

    /**
     * 就地换色：根容器、两条工具栏、每个键的底座和键帽、以及键上的文字。
     * 不新建任何 View，键盘正显示时也不会闪一下。
     */
    private fun repaint() {
        applyColors()
        repaintKeys(keysArea)
        rebuildTopBar()
        rebuildCandidateBar()
    }

    private fun repaintKeys(parent: ViewGroup) {
        for (index in 0 until parent.childCount) {
            val child = parent.getChildAt(index)
            if (child is FrameLayout && child.tag is Boolean) {
                val accent = child.tag as Boolean
                child.background = baseShape(accent)
                val content = child.getChildAt(0)
                if (content != null) {
                    content.background = keyBackground(accent)
                    paintLabels(content, accent)
                }
            } else if (child is ViewGroup) {
                repaintKeys(child)
            }
        }
    }

    private fun paintLabels(view: View, accent: Boolean) {
        if (view is TextView) {
            view.setTextColor(
                when (view.tag) {
                    TAG_HINT -> palette.hint
                    else -> if (accent) palette.onAccent else palette.label
                },
            )
            return
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                paintLabels(view.getChildAt(index), accent)
            }
        }
    }

    /** 词库后台加载完成后由 Service 调回来。 */
    fun onEngineReady() {
        if (buffer.isNotEmpty()) refreshCandidates()
        rebuildCandidateBar()
    }

    override fun onApplyWindowInsets(insets: WindowInsets): WindowInsets {
        val bottom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            insets.getInsets(WindowInsets.Type.navigationBars()).bottom
        } else {
            @Suppress("DEPRECATION")
            insets.systemWindowInsetBottom
        }
        if (paddingBottom != bottom) setPadding(0, 0, 0, bottom)
        return insets
    }

    // -------------------------------------------------------------- 顶部工具栏

    private fun rebuildTopBar() {
        topBar.removeAllViews()
        topBar.addView(barButton(if (chinese) "中" else "英", chinese) { toggleLanguage() })
        topBar.addView(View(context), LayoutParams(0, 1, 1f))
        topBar.addView(
            barButton(
                if (ImePrefs.script == "tc") "繁" else "简",
                ImePrefs.script == "tc",
            ) { toggleScript() },
        )
        topBar.addView(iconButton(ImeIcon.Symbols, page == PAGE_SYMBOLS) { toggleSymbols() })
        if (ImePrefs.clipboard) {
            topBar.addView(iconButton(ImeIcon.Clipboard, clipboardMode) { openClipboard() })
        }
        topBar.addView(iconButton(ImeIcon.Keyboard, false) { host?.showSystemPicker() })
        topBar.addView(iconButton(ImeIcon.Clear, false) { host?.clearField() })
        topBar.addView(iconButton(ImeIcon.Collapse, false) { host?.hideKeyboard() })
    }

    private fun barButton(label: String, active: Boolean, onTap: () -> Unit): View {
        val view = TextView(context).apply {
            text = label
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
            setTextColor(if (active) emphasisColor() else palette.label)
            if (active) setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(9), 0, dp(9), 0)
            isClickable = true
            background = pressHighlight()
            setOnClickListener { onTap() }
        }
        view.layoutParams = LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            LayoutParams.MATCH_PARENT,
        )
        return view
    }

    /** 顶栏图标按钮：50dp 见方，图标 21dp，靠内边距拉开间距。 */
    private fun iconButton(kind: ImeIcon, active: Boolean, onTap: () -> Unit): View {
        val wrap = FrameLayout(context).apply {
            isClickable = true
            background = pressHighlight()
            setOnClickListener { onTap() }
        }
        val icon = ImeIconView(
            context,
            kind,
            if (active) accentColor() else palette.label,
        )
        wrap.addView(
            icon,
            FrameLayout.LayoutParams(dp(21), dp(21)).apply { gravity = Gravity.CENTER },
        )
        wrap.layoutParams = LayoutParams(dp(44), LayoutParams.MATCH_PARENT)
        return wrap
    }

    private fun divider(): View = View(context).apply { setBackgroundColor(palette.divider) }

    // -------------------------------------------------------------- 候选条

    private fun rebuildCandidateBar() {
        candidateBar.removeAllViews()
        if (page != PAGE_LETTERS) {
            candidateBar.addView(
                hintText(if (page == PAGE_DIGITS) "数字与常用标点" else "符号"),
            )
            return
        }
        if (!chinese) {
            if (enSuggest.isEmpty()) {
                candidateBar.addView(
                    hintText(
                        if (asciiOnly) {
                            "密码输入 · 仅英文"
                        } else {
                            "英文输入 · 长按字母打标点"
                        },
                    ),
                )
                return
            }
            candidateBar.addView(
                TextView(context).apply {
                    text = enBuffer.toString()
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
                    setTextColor(emphasisColor())
                    gravity = Gravity.CENTER_VERTICAL
                    setPadding(dp(14), 0, dp(10), 0)
                },
            )
            val row = LinearLayout(context).apply {
                orientation = HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
            }
            enSuggest.forEachIndexed { index, word ->
                row.addView(englishChip(word, index == 0))
            }
            val scroll = HorizontalScrollView(context).apply {
                isHorizontalScrollBarEnabled = false
                addView(row)
            }
            candidateBar.addView(scroll, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
            return
        }

        val pinyin = TextView(context).apply {
            text = pinyinLabel()
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
            setTextColor(if (buffer.isEmpty()) palette.hint else emphasisColor())
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), 0, dp(12), 0)
            isClickable = true
        }
        // 拼音区域可以点、可以拖：光标落哪儿，删除/插入就在哪儿生效。
        pinyin.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN, MotionEvent.ACTION_MOVE -> {
                    placeCursor(view as TextView, event.x)
                }
            }
            true
        }
        pinyinView = pinyin
        candidateBar.addView(pinyin)

        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        if (candidates.isEmpty()) {
            row.addView(
                hintText(
                    when {
                        !PinyinEngine.ready -> "词库加载中…"
                        buffer.isEmpty() -> "输入拼音选词"
                        else -> "没有候选，空格直接上屏"
                    },
                ),
            )
        } else {
            candidates.forEachIndexed { index, item ->
                row.addView(candidateChip(item, index == 0, index))
            }
        }
        val scroll = HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = false
            addView(row)
        }
        candidateBar.addView(scroll, LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))

        // 候选条右端的下拉箭头：点开看全部匹配，而不只是前几个。
        if (candidates.isNotEmpty()) {
            candidateBar.addView(
                TextView(context).apply {
                    text = "⌄"
                    gravity = Gravity.CENTER
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
                    setTextColor(palette.hint)
                    setPadding(dp(10), 0, dp(12), 0)
                    isClickable = true
                    background = pressHighlight()
                    setOnClickListener { openCandidates() }
                    layoutParams = LayoutParams(
                        ViewGroup.LayoutParams.WRAP_CONTENT,
                        LayoutParams.MATCH_PARENT,
                    )
                },
            )
        }
    }

    // -------------------------------------------------------------- 展开候选

    private fun openCandidates() {
        val code = buffer.toString()
        if (code.isEmpty()) return
        allCandidates = if (nine) {
            PinyinEngine.t9Candidates(code, 60)
        } else {
            ImeLearning.rank(
                code,
                PinyinEngine.candidates(
                    code,
                    60,
                    ImePrefs.fuzzy,
                    ImePrefs.sentence,
                ),
            )
        }
        if (allCandidates.isEmpty()) return
        expandedMode = true
        candidateBar.visibility = GONE
        renderCandidates()
    }

    private fun closeCandidates() {
        expandedMode = false
        allCandidates = emptyList()
        candidateBar.visibility = VISIBLE
        rebuildCandidateBar()
        rebuildKeys()
    }

    /** 展开面板：标题 + 拼音 + 每行五个候选。 */
    private fun renderCandidates() {
        keysArea.removeAllViews()

        val header = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), 0, dp(4), 0)
        }
        header.addView(
            TextView(context).apply {
                text = "全部候选"
                setTextColor(palette.label)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            },
        )
        header.addView(
            TextView(context).apply {
                text = "  " + buffer + " · " + allCandidates.size + " 个"
                setTextColor(palette.hint)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            },
        )
        header.addView(View(context), LayoutParams(0, 1, 1f))
        header.addView(barButton("返回", false) { closeCandidates() })
        keysArea.addView(header, LayoutParams(LayoutParams.MATCH_PARENT, dp(42)))

        val column = LinearLayout(context).apply {
            orientation = VERTICAL
            setPadding(dp(6), 0, dp(6), dp(6))
        }
        var index = 0
        while (index < allCandidates.size) {
            val row = LinearLayout(context).apply { orientation = HORIZONTAL }
            for (slot in 0 until 5) {
                val position = index + slot
                if (position >= allCandidates.size) {
                    row.addView(View(context), LayoutParams(0, LayoutParams.MATCH_PARENT, 1f))
                    continue
                }
                val item = allCandidates[position]
                val cell = TextView(context).apply {
                    text = displayText(item.word)
                    gravity = Gravity.CENTER
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 18f)
                    setTextColor(palette.label)
                    setPadding(dp(4), dp(9), dp(4), dp(9))
                    isClickable = true
                    background = pressHighlight()
                    setOnClickListener {
                        commitCandidate(item, position)
                        closeCandidates()
                    }
                }
                row.addView(
                    cell,
                    LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
                )
            }
            column.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
            index += 5
        }

        val scroll = ScrollView(context).apply { addView(column) }
        keysArea.addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
    }

    private fun englishChip(word: String, first: Boolean): View {
        val chip = TextView(context).apply {
            text = word
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, if (first) 18f else 17f)
            setTextColor(if (first) emphasisColor() else palette.label)
            if (first) setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(10), 0, dp(10), 0)
            isClickable = true
            background = pressHighlight()
            setOnClickListener { commitSuggestion(word) }
        }
        chip.layoutParams = LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            LayoutParams.MATCH_PARENT,
        )
        return chip
    }

    private fun hintText(text: String): TextView = TextView(context).apply {
        this.text = text
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
        setTextColor(palette.hint)
        gravity = Gravity.CENTER_VERTICAL
        setPadding(dp(14), 0, dp(14), 0)
    }

    /** 纯文字候选，第一项用主色加粗——和 fcitx5 的候选栏一致。 */
    private fun candidateChip(item: Candidate, first: Boolean, index: Int = 0): View {
        val chip = TextView(context).apply {
                text = displayText(item.word)
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, if (first) 18f else 17f)
            setTextColor(if (first) emphasisColor() else palette.label)
            if (first) setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(10), 0, dp(10), 0)
            isClickable = true
            background = pressHighlight()
            setOnClickListener { commitCandidate(item, index) }
        }
        val params = LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            LayoutParams.MATCH_PARENT,
        )
        chip.layoutParams = params
        return chip
    }

    // ---------------------------------------------------------------- 键盘

    private fun rebuildKeys() {
        keysArea.removeAllViews()
        // 符号页不需要候选条，把这一条的高度让给按键，让键和字母键一样大。
        if (!clipboardMode && !expandedMode) {
            candidateBar.visibility =
                if (page == PAGE_SYMBOLS) GONE else VISIBLE
        }
        if (clipboardMode) {
            renderClipboard()
            return
        }
        if (expandedMode) {
            renderCandidates()
            return
        }
        if (page == PAGE_SYMBOLS) {
            renderSymbolPager()
            return
        }
        val rows: List<LinearLayout> = when {
            page == PAGE_DIGITS -> digitRows()
            nine && chinese -> nineRows()
            else -> letterRows()
        }
        for (row in rows) {
            keysArea.addView(row, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
        }
    }

    private fun letterRows(): List<LinearLayout> = listOf(
        hRow(ROW_Q.map { char -> letterKey(char) }),
        hRow(ROW_A.map { char -> letterKey(char) }, horizontal = 8),
        hRow(
            buildList {
                add(
                    textKey("⇧", flex = 2f, accent = shift, size = 17f) {
                        shift = !shift
                        rebuildKeys()
                    },
                )
                ROW_Z.forEach { add(letterKey(it)) }
                add(textKey("⌫", flex = 2f, size = 18f) { backspace() })
            },
        ),
        hRow(
            listOf(
                textKey("123", flex = 3f, size = 13.5f) {
                    commitPending()
                    page = PAGE_DIGITS
                    rebuildCandidateBar()
                    rebuildKeys()
                },
                textKey(
                    "空格",
                    flex = 5f,
                    size = 14f,
                    onLongPress = { host?.showSystemPicker() },
                ) { space() },
                textKey("↵", flex = 2f, accent = true, size = 18f) { enter() },
            ),
        ),
    )

    /** 数字页：三个一行，最后一行是控制键。 */
    private fun digitRows(): List<LinearLayout> {
        fun digit(value: String): View = textKey(value, size = 22f) { typeText(value) }
        return listOf(
            hRow(listOf(digit("1"), digit("2"), digit("3"))),
            hRow(listOf(digit("4"), digit("5"), digit("6"))),
            hRow(listOf(digit("7"), digit("8"), digit("9"))),
            hRow(
                listOf(
                    digit("，"),
                    digit("0"),
                    textKey("⌫", size = 20f) { backspace() },
                ),
            ),
            hRow(
                listOf(
                    textKey("ABC", flex = 2f, size = 14f) {
                        page = PAGE_LETTERS
                        rebuildCandidateBar()
                        rebuildKeys()
                    },
                    textKey("空格", flex = 4f, size = 14f) { space() },
                    textKey("符号", flex = 2f, size = 14f) {
                        page = PAGE_SYMBOLS
                        rebuildCandidateBar()
                        rebuildKeys()
                    },
                    textKey("↵", flex = 2f, accent = true, size = 18f) { enter() },
                ),
            ),
        )
    }

    /** 符号页：九类横向翻页，左右滑或点底部箭头切换。 */
    private fun renderSymbolPager() {
        keysArea.removeAllViews()
        symbolPageWidth = resources.displayMetrics.widthPixels

        val pages = LinearLayout(context).apply { orientation = HORIZONTAL }
        for (pair in SYMBOL_CATEGORIES) {
            val page = LinearLayout(context).apply { orientation = VERTICAL }
            var index = 0
            while (index < pair.second.size) {
                val line = LinearLayout(context).apply { orientation = HORIZONTAL }
                for (slot in 0 until 11) {
                    val position = index + slot
                    if (position >= pair.second.size) {
                        line.addView(
                            View(context),
                            LayoutParams(0, LayoutParams.MATCH_PARENT, 1f),
                        )
                        continue
                    }
                    val symbol = pair.second[position]
                    line.addView(textKey(symbol, size = 18f) { typeSymbol(symbol) })
                }
                page.addView(line, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
                index += 11
            }
            // 不足四行的分类补空行，保证每页键高一致。
            while (page.childCount < 4) {
                page.addView(
                    LinearLayout(context),
                    LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f),
                )
            }
            pages.addView(page, LayoutParams(symbolPageWidth, LayoutParams.MATCH_PARENT))
        }

        val pager = HorizontalScrollView(context).apply {
            isHorizontalScrollBarEnabled = false
            overScrollMode = View.OVER_SCROLL_NEVER
            addView(
                pages,
                LayoutParams(
                    LayoutParams.WRAP_CONTENT,
                    LayoutParams.MATCH_PARENT,
                ),
            )
        }
        pager.setOnScrollChangeListener { _, scrollX, _, _, _ ->
            if (symbolPageWidth <= 0) return@setOnScrollChangeListener
            val current = ((scrollX + symbolPageWidth / 2) / symbolPageWidth)
                .coerceIn(0, SYMBOL_CATEGORIES.size - 1)
            if (current != symbolPage) {
                symbolPage = current
                updateSymbolTitle()
            }
        }
        pager.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> pager.postDelayed(
                    { snapSymbolPager() },
                    120,
                )
            }
            false
        }
        keysArea.addView(pager, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))

        // 底部控制行：ABC、空格、‹ 类名 ›、⌫、↵
        val control = LinearLayout(context).apply { orientation = HORIZONTAL }
        control.addView(
            textKey("ABC", flex = 2f, size = 13f) {
                page = PAGE_LETTERS
                rebuildCandidateBar()
                rebuildKeys()
            },
        )
        control.addView(textKey("空格", flex = 2f, size = 13f) { space() })
        control.addView(textKey("‹", flex = 1f, size = 16f) { goSymbolPage(symbolPage - 1) })
        symbolTitle = TextView(context).apply {
            text = ""
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            setTextColor(palette.hint)
            isSingleLine = true
        }
        control.addView(
            symbolTitle,
            LayoutParams(0, LayoutParams.MATCH_PARENT, 3f),
        )
        control.addView(textKey("›", flex = 1f, size = 16f) { goSymbolPage(symbolPage + 1) })
        control.addView(textKey("⌫", flex = 2f, size = 17f) { backspace() })
        control.addView(textKey("↵", flex = 2f, accent = true, size = 17f) { enter() })
        keysArea.addView(control, LayoutParams(LayoutParams.MATCH_PARENT, dp(46)))

        symbolPager = pager
        pager.post {
            pager.scrollTo(symbolPage * symbolPageWidth, 0)
            updateSymbolTitle()
        }
    }

    private fun goSymbolPage(index: Int) {
        val target = index.coerceIn(0, SYMBOL_CATEGORIES.size - 1)
        symbolPage = target
        symbolPager?.smoothScrollTo(target * symbolPageWidth, 0)
        updateSymbolTitle()
    }

    private fun snapSymbolPager() {
        val pager = symbolPager ?: return
        if (symbolPageWidth <= 0) return
        val page = ((pager.scrollX + symbolPageWidth / 2) / symbolPageWidth)
            .coerceIn(0, SYMBOL_CATEGORIES.size - 1)
        symbolPage = page
        pager.smoothScrollTo(page * symbolPageWidth, 0)
        updateSymbolTitle()
    }

    private fun updateSymbolTitle() {
        val pair = SYMBOL_CATEGORIES[symbolPage]
        symbolTitle?.text = pair.first + " " +
            (symbolPage + 1).toString() + "/" +
            SYMBOL_CATEGORIES.size.toString()
    }

    private fun nineRows(): List<LinearLayout> = listOf(
        hRow(NINE.take(3).map { twoLineKey(it.first, it.second) }),
        hRow(NINE.drop(3).take(3).map { twoLineKey(it.first, it.second) }),
        hRow(NINE.drop(6).take(3).map { twoLineKey(it.first, it.second) }),
        hRow(
            listOf(
                textKey("123", flex = 2f, size = 14f) {
                    commitPending()
                    page = PAGE_DIGITS
                    rebuildCandidateBar()
                    rebuildKeys()
                },
                textKey(
                    "空格",
                    flex = 4f,
                    size = 14f,
                    onLongPress = { host?.showSystemPicker() },
                ) { space() },
                textKey("⌫", flex = 2f, size = 18f) { backspace() },
                textKey("↵", flex = 2f, accent = true, size = 18f) { enter() },
            ),
        ),
    )

    private fun hRow(keys: List<View>, horizontal: Int = 0): LinearLayout {
        val row = LinearLayout(context).apply { orientation = HORIZONTAL }
        keys.forEach { row.addView(it) }
        if (horizontal > 0) row.setPadding(dp(horizontal), 0, dp(horizontal), 0)
        return row
    }

    private fun symbolKey(symbol: String): View = textKey(symbol, size = 16f) {
        typeSymbol(symbol)
    }

    private fun letterKey(char: String): View {
        val marks = PUNCT[char]
        val label = if (!chinese && shift) char.uppercase() else char
        val box = LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
        }
        box.addView(
            TextView(context).apply {
                text = label
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f * scale)
                setTextColor(palette.label)
                isSingleLine = true
                includeFontPadding = false
            },
        )
        // 字母下方的小字：提示长按能打哪些符号，打不全就省略。
        if (marks != null && marks.isNotEmpty()) {
            box.addView(
                TextView(context).apply {
                    text = marks.take(2).joinToString("")
                    gravity = Gravity.CENTER
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 8f * scale)
                    setTextColor(palette.hint)
                    isSingleLine = true
                    ellipsize = TextUtils.TruncateAt.END
                    includeFontPadding = false
                    setPadding(0, dp(1), 0, 0)
                },
            )
        }
        return cell(
            box,
            1f,
            false,
            onTap = {
                typeText(label)
                if (!chinese && shift) {
                    shift = false
                    rebuildKeys()
                }
            },
            marks = marks,
        )
    }

    private fun textKey(
        label: String,
        flex: Float = 1f,
        accent: Boolean = false,
        size: Float = 20f,
        marks: List<String>? = null,
        onLongPress: (() -> Unit)? = null,
        onTap: () -> Unit,
    ): View {
        val view = TextView(context).apply {
            text = label
            gravity = Gravity.CENTER
            setTextSize(TypedValue.COMPLEX_UNIT_SP, size * scale)
            setTextColor(if (accent) palette.onAccent else palette.label)
            isSingleLine = true
            tag = TAG_LABEL
        }
        return cell(
            view,
            flex,
            accent,
            onTap = onTap,
            marks = marks,
            onLongPress = onLongPress,
        )
    }

    private fun twoLineKey(main: String, sub: String): View {
        val box = LinearLayout(context).apply {
            orientation = VERTICAL
            gravity = Gravity.CENTER
        }
        box.addView(
            TextView(context).apply {
                text = main
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 21f * scale)
                setTextColor(palette.label)
            },
        )
        box.addView(
            TextView(context).apply {
                text = sub
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 9.5f * scale)
                setTextColor(palette.hint)
                tag = TAG_HINT
            },
        )
        return cell(box, 1f, false, onTap = { typeText(main) })
    }

    /**
     * 一个按键 = 底座 + 键帽。
     *
     * 触摸在这里统一处理（返回 true，不走 View 自己的点击）：
     * 按下就压下去并给反馈；按住 380ms 弹标点浮层，滑动选，抬手落字；
     * 普通点按在抬手且手指还在键内时触发。
     */
    private fun cell(
        content: View,
        flex: Float,
        accent: Boolean,
        onTap: () -> Unit,
        marks: List<String>? = null,
        onLongPress: (() -> Unit)? = null,
    ): View {
        val wrap = FrameLayout(context)
        val lift = dp((2 * scale).roundToInt())

        // tag 记住这个键是不是强调键，换色时就地刷新，不用重建。
        wrap.tag = accent
        wrap.background = baseShape(accent)
        content.background = keyBackground(accent)
        content.isClickable = true
        content.setOnTouchListener(object : View.OnTouchListener {
            private var pressed = false
            private var longFired = false
            private var downX = 0f
            private var downY = 0f
            private val longPress = Runnable {
                if (!pressed) return@Runnable
                longFired = true
                if (marks != null && marks.isNotEmpty()) {
                    showMarks(content, marks)
                } else {
                    onLongPress?.invoke()
                }
            }

            override fun onTouch(view: View, event: MotionEvent): Boolean {
                when (event.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        pressed = true
                        longFired = false
                        downX = event.rawX
                        downY = event.rawY
                        view.isPressed = true
                        view.animate()
                            .translationY(lift.toFloat())
                            .setDuration(45)
                            .start()
                        ImeFeedback.key(context, view)
                        if (marks != null || onLongPress != null) {
                            view.postDelayed(longPress, 380)
                        }
                    }

                    MotionEvent.ACTION_MOVE -> {
                        if (longFired) {
                            updateMarkSelection(event.rawX)
                        } else if (
                            abs(event.rawX - downX) > dp(22) ||
                            abs(event.rawY - downY) > dp(22)
                        ) {
                            view.removeCallbacks(longPress)
                        }
                    }

                    MotionEvent.ACTION_UP -> {
                        view.removeCallbacks(longPress)
                        view.isPressed = false
                        view.animate().translationY(0f).setDuration(90).start()
                        if (longFired) {
                            commitMark()
                        } else if (pressed && inside(view, event.rawX, event.rawY)) {
                            onTap()
                        }
                        pressed = false
                        longFired = false
                    }

                    MotionEvent.ACTION_CANCEL -> {
                        view.removeCallbacks(longPress)
                        view.isPressed = false
                        view.animate().translationY(0f).setDuration(90).start()
                        if (longFired) dismissMarks()
                        pressed = false
                        longFired = false
                    }
                }
                return true
            }
        })
        wrap.addView(
            content,
            FrameLayout.LayoutParams(
                LayoutParams.MATCH_PARENT,
                LayoutParams.MATCH_PARENT,
            ).apply { bottomMargin = lift },
        )
        val gap = dp((2 * scale).roundToInt())
        val params = LayoutParams(0, LayoutParams.MATCH_PARENT, flex)
        params.setMargins(gap, gap, gap, gap)
        wrap.layoutParams = params
        return wrap
    }

    private fun inside(view: View, rawX: Float, rawY: Float): Boolean {
        val loc = IntArray(2)
        view.getLocationOnScreen(loc)
        return rawX >= loc[0] &&
            rawX <= loc[0] + view.width &&
            rawY >= loc[1] &&
            rawY <= loc[1] + view.height
    }

    // -------------------------------------------------------------- 长按标点

    private var markPopup: PopupWindow? = null
    private var markItems: List<TextView> = emptyList()
    private var markValues: List<String> = emptyList()
    private var markIndex = 0

    private fun showMarks(anchor: View, marks: List<String>) {
        dismissMarks()
        val row = LinearLayout(context).apply {
            orientation = HORIZONTAL
            setPadding(dp(6), dp(4), dp(6), dp(4))
            background = GradientDrawable().apply {
                cornerRadius = dp(10).toFloat()
                setColor(palette.bar)
                setStroke(dp(1), palette.divider)
            }
        }
        markValues = marks
        markItems = marks.map { mark ->
            TextView(context).apply {
                text = mark
                gravity = Gravity.CENTER
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 19f)
                setTextColor(palette.label)
                setPadding(dp(11), dp(9), dp(11), dp(9))
            }
        }
        markItems.forEach { row.addView(it) }
        row.measure(
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
            MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED),
        )
        val width = row.measuredWidth
        val height = row.measuredHeight
        val loc = IntArray(2)
        anchor.getLocationOnScreen(loc)
        val x = loc[0] + anchor.width / 2 - width / 2
        val y = loc[1] - height - dp(4)
        val popup = PopupWindow(row, width, height, false)
        popup.isFocusable = false
        popup.isOutsideTouchable = false
        popup.isTouchable = false
        popup.elevation = dp(10).toFloat()
        try {
            popup.showAtLocation(
                anchor.rootView,
                Gravity.NO_GRAVITY,
                x.coerceAtLeast(0),
                y.coerceAtLeast(0),
            )
        } catch (_: Throwable) {
            return
        }
        markPopup = popup
        markIndex = 0
        highlightMark(0)
    }

    private fun updateMarkSelection(rawX: Float) {
        if (markItems.isEmpty()) return
        var best = 0
        var distance = Float.MAX_VALUE
        val loc = IntArray(2)
        markItems.forEachIndexed { index, item ->
            item.getLocationOnScreen(loc)
            val center = loc[0] + item.width / 2f
            val delta = abs(rawX - center)
            if (delta < distance) {
                distance = delta
                best = index
            }
        }
        if (best != markIndex) {
            markIndex = best
            highlightMark(best)
            ImeFeedback.key(context, null)
        }
    }

    private fun highlightMark(index: Int) {
        markItems.forEachIndexed { position, item ->
            val active = position == index
            item.setTextColor(if (active) emphasisColor() else palette.label)
            item.setTypeface(null, if (active) Typeface.BOLD else Typeface.NORMAL)
        }
    }

    private fun commitMark() {
        val value = markValues.getOrNull(markIndex)
        dismissMarks()
        if (!value.isNullOrEmpty()) host?.commit(value)
    }

    private fun dismissMarks() {
        try {
            markPopup?.dismiss()
        } catch (_: Throwable) {
        }
        markPopup = null
        markItems = emptyList()
        markValues = emptyList()
        markIndex = 0
    }

    // -------------------------------------------------------------- 剪贴板

    private fun openClipboard() {
        ImeClipboard.capture(context)
        clipboardMode = true
        candidateBar.visibility = GONE
        renderClipboard()
    }

    private fun closeClipboard() {
        clipboardMode = false
        candidateBar.visibility = VISIBLE
        rebuildCandidateBar()
        rebuildKeys()
    }

    /** 剪贴板面板占满键盘区域：上面一行标题，下面一列卡片。 */
    private fun renderClipboard() {
        keysArea.removeAllViews()
        val entries = ImeClipboard.list()

        val header = LinearLayout(context).apply {
            orientation = HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), 0, dp(4), 0)
        }
        header.addView(
            TextView(context).apply {
                text = "剪贴板"
                setTextColor(palette.label)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            },
        )
        if (entries.isNotEmpty()) {
            header.addView(
                TextView(context).apply {
                    text = "  " + entries.size + " 条"
                    setTextColor(palette.hint)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
                },
            )
        }
        header.addView(View(context), LayoutParams(0, 1, 1f))
        if (entries.isNotEmpty()) {
            header.addView(
                barButton("清空", false) {
                    ImeClipboard.clear(context)
                    renderClipboard()
                },
            )
        }
        header.addView(barButton("返回", false) { closeClipboard() })
        keysArea.addView(header, LayoutParams(LayoutParams.MATCH_PARENT, dp(42)))

        val column = LinearLayout(context).apply {
            orientation = VERTICAL
            setPadding(dp(10), 0, dp(10), dp(8))
        }
        if (entries.isEmpty()) {
            column.addView(
                TextView(context).apply {
                    text = "剪贴板是空的"
                    setTextColor(palette.hint)
                    setTextSize(TypedValue.COMPLEX_UNIT_SP, 12.5f)
                    setPadding(dp(6), dp(14), dp(6), 0)
                },
            )
        } else {
            for (item in entries) {
                column.addView(clipboardRow(item))
            }
        }
        val scroll = ScrollView(context).apply { addView(column) }
        keysArea.addView(scroll, LayoutParams(LayoutParams.MATCH_PARENT, 0, 1f))
    }

    private fun clipboardRow(item: ClipboardItem): View {
        val row = LinearLayout(context).apply {
            orientation = VERTICAL
            setPadding(dp(13), dp(9), dp(13), dp(9))
            background = keyBackground(false)
            isClickable = true
            setOnClickListener {
                host?.commit(item.text)
                closeClipboard()
            }
        }
        row.addView(
            TextView(context).apply {
                text = item.text
                maxLines = 2
                ellipsize = TextUtils.TruncateAt.END
                setTextColor(palette.label)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            },
        )
        row.addView(
            TextView(context).apply {
                text = item.text.length.toString() + " 个字符 · 点击粘贴"
                setTextColor(palette.hint)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 10f)
            },
        )
        val params = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT)
        params.setMargins(0, dp(5), 0, dp(1))
        row.layoutParams = params
        return row
    }

    // ---------------------------------------------------------------- 行为

    private fun ensureEngine() {
        PinyinEngine.preload(context) { onEngineReady() }
    }

    private fun typeText(text: String) {
        // 九宫格里数字就是编码，必须留在缓冲；其余情况只有字母进拼音缓冲。
        if (chinese && nine && text.length == 1 && text[0].isDigit()) {
            insertAtCursor(text)
            refreshCandidates()
            return
        }
        val letter = text.length == 1 && text[0] in 'a'..'z'
        if (!chinese) {
            // 密码框不做补全，避免候选暴露输入内容。
            if (page == PAGE_LETTERS && letter && !asciiOnly) {
                enBuffer.append(text)
                host?.commit(text)
                refreshEnglish()
            } else {
                host?.commit(text)
            }
            return
        }
        if (page != PAGE_LETTERS || !letter) {
            host?.commit(text)
            return
        }
        insertAtCursor(text)
        refreshCandidates()
    }

    /** 繁体模式下候选与上屏都换成繁体。 */
    private fun displayText(word: String): String =
        if (ImePrefs.script == "tc") {
            ScriptConverter.toTraditional(context, word)
        } else {
            word
        }

    private fun insertAtCursor(text: String) {
        val at = cursor.coerceIn(0, buffer.length)
        buffer.insert(at, text)
        cursor = (at + text.length).coerceAtMost(buffer.length)
    }

    /** 拼音区显示：在光标处插一个竖线。 */
    private fun pinyinLabel(): String {
        if (buffer.isEmpty()) return "拼音"
        val at = cursor.coerceIn(0, buffer.length)
        return buffer.substring(0, at) + "|" + buffer.substring(at)
    }

    /** 点在拼音文字的哪个位置，光标就落到哪个字符之间。 */
    private fun placeCursor(view: TextView, x: Float) {
        val layout = view.layout ?: return
        var offset = layout.getOffsetForHorizontal(0, x)
        val shown = cursor.coerceIn(0, buffer.length)
        // 显示串在 cursor 处多了一个竖线，换算回缓冲下标要减一。
        if (offset > shown) offset -= 1
        val next = offset.coerceIn(0, buffer.length)
        if (next == cursor) return
        cursor = next
        view.text = pinyinLabel()
    }

    private fun typeSymbol(symbol: String) {
        clearEnglish()
        host?.commit(symbol)
    }

    private fun clearEnglish() {
        if (enBuffer.isEmpty() && enSuggest.isEmpty()) return
        enBuffer = StringBuilder()
        enSuggest = emptyList()
        rebuildCandidateBar()
    }

    private fun refreshEnglish() {
        if (enBuffer.isEmpty()) {
            enSuggest = emptyList()
            rebuildCandidateBar()
            return
        }
        if (EnglishLexicon.ready) {
            enSuggest = EnglishLexicon.suggest(enBuffer.toString(), ImePrefs.candidates)
            rebuildCandidateBar()
            return
        }
        enSuggest = emptyList()
        rebuildCandidateBar()
        EnglishLexicon.preload(context) {
            if (!chinese) {
                enSuggest = EnglishLexicon.suggest(
                    enBuffer.toString(),
                    ImePrefs.candidates,
                )
                rebuildCandidateBar()
            }
        }
    }

    /** 点补全词：先删掉已经打出去的前缀，再整词上屏。 */
    private fun commitSuggestion(word: String) {
        val typed = enBuffer.length
        if (typed > 0) host?.deleteChars(typed)
        host?.commit(word)
        enBuffer = StringBuilder()
        enSuggest = emptyList()
        rebuildCandidateBar()
    }

    private fun refreshCandidates() {
        val code = buffer.toString()
        candidates = when {
            code.isEmpty() -> emptyList()
            nine -> PinyinEngine.t9Candidates(code, ImePrefs.candidates)
            else -> ImeLearning.rank(
                code,
                PinyinEngine.candidates(
                    code,
                    ImePrefs.candidates + 6,
                    ImePrefs.fuzzy,
                    ImePrefs.sentence,
                ),
            ).take(ImePrefs.candidates)
        }
        rebuildCandidateBar()
    }

    /**
     * 上屏一条候选。
     *
     * consumed 可能小于整个缓冲（选了首音节的一个单字），
     * 这时把剩下的拼音留在缓冲里，用户可以接着选下一个字——和 fcitx5 一样。
     */
    private fun commitCandidate(item: Candidate, position: Int = 0) {
        if (item.word.isEmpty()) return
        val code = buffer.toString()
        val used = item.consumed.coerceIn(0, code.length)
        if (chinese && used > 0) {
            ImeLearning.learn(code.substring(0, used), item.word, position)
        }
        host?.commit(displayText(item.word))
        if (used >= code.length) {
            buffer = StringBuilder()
            cursor = 0
            candidates = emptyList()
            rebuildCandidateBar()
            return
        }
        buffer = StringBuilder(code.substring(used))
        cursor = (cursor - used).coerceAtLeast(0)
        refreshCandidates()
    }

    private fun commitPending() {
        if (buffer.isEmpty()) return
        val first = candidates.firstOrNull()
        if (first != null) {
            commitCandidate(first)
            return
        }
        host?.commit(buffer.toString())
        buffer = StringBuilder()
        cursor = 0
        candidates = emptyList()
        rebuildCandidateBar()
    }

    private fun space() {
        if (chinese && buffer.isNotEmpty()) {
            commitPending()
            return
        }
        // 英文：打完一个词按空格时，若差一个字母且能落到常用词上就顺手改掉。
        if (!chinese && ImePrefs.autocorrect && enBuffer.length >= 3) {
            val typed = enBuffer.toString()
            val fixed = EnglishLexicon.correct(typed)
            if (fixed != null && fixed != typed) {
                host?.deleteChars(typed.length)
                host?.commit(fixed)
                enBuffer = StringBuilder()
                enSuggest = emptyList()
                host?.commit(" ")
                rebuildCandidateBar()
                return
            }
        }
        clearEnglish()
        host?.commit(" ")
    }

    private fun enter() {
        clearEnglish()
        commitPending()
        host?.sendEnter()
    }

    private fun backspace() {
        if (chinese && buffer.isNotEmpty()) {
            val at = cursor.coerceIn(0, buffer.length)
            if (at > 0) {
                buffer.deleteCharAt(at - 1)
                cursor = at - 1
            }
            if (buffer.isEmpty()) {
                candidates = emptyList()
                rebuildCandidateBar()
            } else {
                refreshCandidates()
            }
            return
        }
        if (!chinese && enBuffer.isNotEmpty()) {
            enBuffer.deleteCharAt(enBuffer.length - 1)
            refreshEnglish()
        }
        host?.deleteBackward()
    }

    private fun toggleScript() {
        ImePrefs.setScript(
            context,
            if (ImePrefs.script == "tc") "sc" else "tc",
        )
        rebuildTopBar()
        rebuildCandidateBar()
        rebuildKeys()
    }

    private fun toggleSymbols() {
        commitPending()
        page = if (page == PAGE_SYMBOLS) PAGE_LETTERS else PAGE_SYMBOLS
        symbolPage = 0
        rebuildTopBar()
        rebuildCandidateBar()
        rebuildKeys()
    }

    private fun toggleLanguage() {
        if (asciiOnly) return
        commitPending()
        chinese = !chinese
        shift = false
        page = PAGE_LETTERS
        rebuildTopBar()
        rebuildCandidateBar()
        rebuildKeys()
        if (chinese) ensureEngine()
    }

    // ---------------------------------------------------------------- 工具

    private fun solid(color: Int): GradientDrawable =
        GradientDrawable().apply { setColor(color) }

    /**
     * 键帽 + 底座：底层是深一档的圆角矩形，上层键帽整体上移 2dp 并带 1dp 描边。
     * 远看是一块块键帽浮在板子上，按下去有"落到实底"的感觉。
     */
    /** 底座（键帽下面那层）。 */
    private fun baseShape(accent: Boolean): GradientDrawable =
        GradientDrawable().apply {
            cornerRadius = keyRadius()
            setColor(baseColor(accent))
        }

    private fun keyRadius(): Float = dp((9 * scale).roundToInt()).toFloat()

    private fun keyBackground(accent: Boolean): Drawable {
        val radius = keyRadius()
        val cap = GradientDrawable().apply {
            cornerRadius = radius
            setColor(capColor(accent))
            setStroke(dp(1), borderColor(accent))
        }
        return RippleDrawable(
            ColorStateList.valueOf(palette.ripple),
            cap,
            GradientDrawable().apply {
                cornerRadius = radius
                setColor(Color.WHITE)
            },
        )
    }

    private fun capColor(accent: Boolean): Int =
        if (accent) accentColor() else palette.key

    private fun baseColor(accent: Boolean): Int =
        if (accent) shade(accentColor(), 0.74f) else palette.keyBase

    private fun borderColor(accent: Boolean): Int =
        if (accent) shade(accentColor(), 1.22f) else palette.keyBorder

    /** ratio 小于 1 变暗，大于 1 变亮，用来做底座和描边的同色深浅。 */
    private fun shade(color: Int, ratio: Float): Int {
        fun channel(value: Int): Int {
            val scaled = if (ratio <= 1f) {
                value * ratio
            } else {
                value + (255 - value) * (ratio - 1f)
            }
            return scaled.toInt().coerceIn(0, 255)
        }
        return Color.argb(
            Color.alpha(color),
            channel(Color.red(color)),
            channel(Color.green(color)),
            channel(Color.blue(color)),
        )
    }

    private fun pressHighlight(): RippleDrawable =
        RippleDrawable(ColorStateList.valueOf(palette.ripple), null, null)

    private fun accentColor(): Int = ImeTheme.accent(context)

    /**
     * 强调文字（首候选、激活的中/英、拼音提示）的颜色。
     *
     * 自定义整套配色时用用户选的文字色——否则会和文字色不一致，
     * 看起来像"某个字没跟上主题"。
     */
    private fun emphasisColor(): Int =
        if (ImePrefs.customPalette) palette.label else accentColor()

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()

    companion object {
        private const val PAGE_LETTERS = 0
        private const val PAGE_DIGITS = 1
        private const val PAGE_SYMBOLS = 2

        private const val TAG_LABEL = "label"
        private const val TAG_HINT = "hint"

        private val ROW_Q = listOf("q", "w", "e", "r", "t", "y", "u", "i", "o", "p")
        private val ROW_A = listOf("a", "s", "d", "f", "g", "h", "j", "k", "l")
        private val ROW_Z = listOf("z", "x", "c", "v", "b", "n", "m")
        /** 长按字母弹出的标点/符号，滑动选择。 */
        private val PUNCT = mapOf(
            "q" to listOf("\u300C", "\u300D", "\u300E", "\u300F"),
            "w" to listOf("\uFF0C", "\u3001", "\uFF1B"),
            "e" to listOf("\u3002", "\uFF0E", "\uFF1A"),
            "r" to listOf("\uFF01", "\uFF1F", "\u203D"),
            "t" to listOf("\u201C", "\u201D", "\u2018", "\u2019"),
            "y" to listOf("\u2192", "\u2190", "\u2191", "\u2193"),
            "u" to listOf("\uFF08", "\uFF09", "\uFF3B", "\uFF3D"),
            "i" to listOf("\u3010", "\u3011", "\uFF5B", "\uFF5D"),
            "o" to listOf("\u300A", "\u300B", "\u3008", "\u3009"),
            "p" to listOf("\u2014", "\u2026"),
            "a" to listOf("\u00B7", "\uFF5E", "\uFF3F"),
            "s" to listOf("\uFF0B", "\uFF0D", "\u00D7", "\u00F7"),
            "d" to listOf("\uFF1D", "\u2260", "\u2248"),
            "f" to listOf("\uFF05", "\u2030", "\u2103"),
            "g" to listOf("\uFFE5", "\uFF04", "\u20AC"),
            "h" to listOf("\uFF03", "\uFF06", "\uFF0A"),
            "j" to listOf("\uFF20", "\uFF3E", "\uFF5C"),
            "k" to listOf("\uFF1C", "\uFF1E", "\u2264", "\u2265"),
            "l" to listOf("\uFF0F", "\uFF3C"),
            "z" to listOf("\u2460", "\u2461", "\u2462"),
            "x" to listOf("\u2463", "\u2464", "\u2465"),
            "c" to listOf("\u2466", "\u2467", "\u2468"),
            "v" to listOf("\u2469", "\u2474", "\u2475"),
            "b" to listOf("\u3220", "\u3221", "\u3222"),
            "n" to listOf("\u2160", "\u2161", "\u2162"),
            "m" to listOf("\u25A0", "\u25A1", "\u25CF", "\u25CB"),
        )
        private val SYMBOL_CATEGORIES = listOf(
            "中文" to listOf(
                "、", "。", "，", "！", "？", "：", "；", "“", "”", "‘",
                "’", "（", "）", "【", "】", "《", "》", "〈", "〉", "〔",
                "〕", "「", "」", "『", "』", "…", "—", "～", "·", "丶",
                "丨", "﹏",
            ),
            "英文" to listOf(
                "!", "#", "$", "%", "&", "'", "(", ")", "*", "+",
                ",", "-", ".", "/", ":", ";", "<", "=", ">", "?",
                "@", "[", "\"", "]", "\\", "^", "_", "`", "{", "|",
                "}", "~", "“", "”", "‘", "’", "–", "—", "…",
            ),
            "数学" to listOf(
                "+", "−", "×", "÷", "=", "≠", "≈", "≤", "≥", "±",
                "∞", "∑", "∏", "√", "∫", "∂", "∆", "∇", "∈", "∉",
                "∋", "⊂", "⊃", "⊆", "⊇", "∪", "∩", "∧", "∨", "¬",
                "∀", "∃", "∅", "∴", "∵", "°", "′", "″", "≡", "≅",
                "∼", "⊥", "∠",
            ),
            "货币" to listOf(
                "$", "€", "£", "¥", "￥", "＄", "¢", "₩", "₹", "₽",
                "₺", "₴", "₫", "₪", "₦", "₱", "฿", "₡", "₲",
            ),
            "箭头" to listOf(
                "→", "←", "↑", "↓", "↔", "↕", "⇒", "⇐", "⇑", "⇓",
                "⇔", "⇕", "⟶", "⟵", "⤴", "⤵", "↪", "↩", "↺", "↻",
                "➔", "➜", "➤", "▶", "◀", "▲", "▼",
            ),
            "单位" to listOf(
                "℃", "℉", "°", "′", "″", "％", "‰", "‱", "㎜", "㎝",
                "㎞", "㎎", "㎏", "㎐", "㎑", "㎒", "㏑", "㏒", "㎡", "㎥",
                "㎤", "㎢", "㎠", "µ", "Ω", "Å",
            ),
            "序号" to listOf(
                "①", "②", "③", "④", "⑤", "⑥", "⑦", "⑧", "⑨", "⑩",
                "⑪", "⑫", "⑬", "⑭", "⑮", "⑯", "⑰", "⑱", "⑲", "⑳",
                "⑴", "⑵", "⑶", "⑷", "⑸", "⑹", "⑺", "⑻", "⑼", "⑽",
                "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ", "Ⅸ", "Ⅹ",
            ),
            "框线" to listOf(
                "─", "│", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴",
                "┼", "═", "║", "╔", "╗", "╚", "╝", "╠", "╣", "╦",
                "╩", "╬", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█",
                "░", "▒", "▓",
            ),
            "其他" to listOf(
                "©", "®", "™", "§", "¶", "†", "‡", "•", "※", "☆",
                "★", "○", "●", "◎", "◇", "◆", "□", "■", "△", "▽",
                "♠", "♣", "♥", "♦", "♪", "♫", "☀", "☁", "☂", "☎",
                "☑", "☒", "✓", "✔", "✘", "✕", "✖",
            ),
        )
        private val NINE = listOf(
            "1" to ".,?!",
            "2" to "abc",
            "3" to "def",
            "4" to "ghi",
            "5" to "jkl",
            "6" to "mno",
            "7" to "pqrs",
            "8" to "tuv",
            "9" to "wxyz",
        )
    }
}
