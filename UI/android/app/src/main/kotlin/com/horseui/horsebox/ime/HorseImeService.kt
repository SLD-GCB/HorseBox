package com.horseui.horsebox.ime

import android.content.Context
import android.content.res.Configuration
import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager

/**
 * HorseBox 系统输入法。
 *
 * 它是 App 里的一个 Service（同一个 APK、同一个进程），不是独立应用：
 * 用户在系统设置里勾选后，可以在任何 App 里使用。
 *
 * 三件事是刻意的：
 * 1. 固定高度，不用系统 IME 的窗口 inset，避免把页面顶爆；
 * 2. 关掉全屏编辑模式（onEvaluateFullscreenMode），横屏也不接管整屏；
 * 3. 密码框强制英文，并且不产生候选、不学习词频。
 */
class HorseImeService : InputMethodService(), ImeBoard.Host {

    private var board: ImeBoard? = null

    override fun onCreate() {
        super.onCreate()
        ImePrefs.load(this)
        ImeFeedback.init(this)
        ImeClipboard.load(this)
        ImeLearning.load(this)
        ImeLearning.enabled = ImePrefs.learn
        PinyinEngine.preload(this) { board?.onEngineReady() }
        EnglishLexicon.preload(this) {}
    }

    override fun onCreateInputView(): View {
        ImePrefs.load(this)
        val view = ImeBoard(this)
        view.host = this
        view.build()
        view.layoutParams = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            keyboardHeight(),
        )
        board = view
        return view
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        val view = board ?: return
        view.resetForInput(info != null && isPasswordField(info))
        ImeLearning.enabled = ImePrefs.learn
        view.applySizing()
        val height = keyboardHeight()
        val params = view.layoutParams
        if (params != null && params.height != height) {
            params.height = height
            view.layoutParams = params
        }
    }

    override fun onFinishInput() {
        board?.clearComposing()
        ImeLearning.flush()
        super.onFinishInput()
    }

    override fun onDestroy() {
        ImeLearning.flush()
        super.onDestroy()
    }

    /** 系统切换深色/浅色时，键盘立刻换配色，不用等下一次弹出。 */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        ImePrefs.load(this)
        board?.applyTheme()
    }

    /** 横屏也不切全屏提取模式：键盘始终是固定高度的一条。 */
    override fun onEvaluateFullscreenMode(): Boolean = false

    override fun commit(text: String) {
        currentInputConnection?.commitText(text, 1)
    }

    override fun deleteBackward() {
        val connection = currentInputConnection ?: return
        val selected = connection.getSelectedText(0)
        if (!selected.isNullOrEmpty()) {
            connection.commitText("", 1)
            return
        }
        connection.deleteSurroundingText(1, 0)
    }

    override fun deleteChars(count: Int) {
        if (count <= 0) return
        currentInputConnection?.deleteSurroundingText(count, 0)
    }

    override fun sendEnter() {
        if (sendDefaultEditorAction(true)) return
        currentInputConnection?.commitText("\n", 1)
    }

    override fun clearField() {
        val connection = currentInputConnection ?: return
        connection.performContextMenuAction(android.R.id.selectAll)
        connection.commitText("", 1)
    }

    override fun hideKeyboard() {
        requestHideSelf(0)
    }

    override fun showSystemPicker() {
        val manager = getSystemService(Context.INPUT_METHOD_SERVICE) as? InputMethodManager
        manager?.showInputMethodPicker()
    }

    /**
     * 固定高度：不超过 282dp（和 App 内一致），也不低于 232dp；
     * 屏幕特别矮时按 46% 收缩，横屏也不会占掉大半屏。
     */
    private fun keyboardHeight(): Int {
        val metrics = resources.displayMetrics
        val screenDp = metrics.heightPixels / metrics.density
        // 用户设定的高度，但不能超过屏高的 55%，否则横屏会只剩一条缝。
        val limit = (screenDp * 0.55f).coerceAtLeast(220f).toInt()
        val heightDp = ImePrefs.heightDp.coerceAtMost(limit)
        return (heightDp * metrics.density).toInt()
    }

    private fun isPasswordField(info: EditorInfo): Boolean {
        val type = info.inputType
        val klass = type and InputType.TYPE_MASK_CLASS
        val variation = type and InputType.TYPE_MASK_VARIATION
        if (klass == InputType.TYPE_CLASS_NUMBER) {
            return variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
        }
        if (klass != InputType.TYPE_CLASS_TEXT) return false
        return variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
    }
}
