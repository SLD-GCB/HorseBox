package com.horseui.horsebox.ime

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.view.View

/** 顶栏用到的几个图标。 */
enum class ImeIcon { Symbols, Clipboard, Keyboard, Clear, Collapse }

/**
 * 用 Canvas 直接画的单色图标，避免引入整套矢量资源。
 * 画布按 24x24 的坐标系设计，再按实际尺寸缩放。
 */
class ImeIconView(
    context: Context,
    private val kind: ImeIcon,
    private var tint: Int,
) : View(context) {

    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 1.7f
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
    }

    override fun onDraw(canvas: Canvas) {
        val side = minOf(width, height).toFloat()
        val ratio = side / 24f
        canvas.save()
        canvas.translate((width - side) / 2f, (height - side) / 2f)
        canvas.scale(ratio, ratio)
        stroke.color = tint
        fill.color = tint
        when (kind) {
            ImeIcon.Symbols -> drawHash(canvas)
            ImeIcon.Clipboard -> drawClipboard(canvas)
            ImeIcon.Keyboard -> drawKeyboard(canvas)
            ImeIcon.Clear -> drawCross(canvas)
            ImeIcon.Collapse -> drawChevron(canvas)
        }
        canvas.restore()
    }

    private fun drawHash(canvas: Canvas) {
        canvas.drawLine(9.5f, 6.5f, 9.5f, 17.5f, stroke)
        canvas.drawLine(14.5f, 6.5f, 14.5f, 17.5f, stroke)
        canvas.drawLine(6.5f, 9.8f, 17.5f, 9.8f, stroke)
        canvas.drawLine(6.5f, 14.2f, 17.5f, 14.2f, stroke)
    }

    private fun drawClipboard(canvas: Canvas) {
        val body = RectF(5f, 4.5f, 19f, 20f)
        canvas.drawRoundRect(body, 2.6f, 2.6f, stroke)
        val clip = RectF(9f, 2.6f, 15f, 6.2f)
        canvas.drawRoundRect(clip, 1.4f, 1.4f, fill)
    }

    private fun drawKeyboard(canvas: Canvas) {
        val body = RectF(3.2f, 7.5f, 20.8f, 16.5f)
        canvas.drawRoundRect(body, 2.2f, 2.2f, stroke)
        canvas.drawCircle(7.4f, 11f, 1.05f, fill)
        canvas.drawCircle(12f, 11f, 1.05f, fill)
        canvas.drawCircle(16.6f, 11f, 1.05f, fill)
        canvas.drawLine(7.5f, 14f, 16.5f, 14f, stroke)
    }

    private fun drawCross(canvas: Canvas) {
        canvas.drawLine(7.5f, 7.5f, 16.5f, 16.5f, stroke)
        canvas.drawLine(16.5f, 7.5f, 7.5f, 16.5f, stroke)
    }

    private fun drawChevron(canvas: Canvas) {
        val path = Path().apply {
            moveTo(7f, 10f)
            lineTo(12f, 15f)
            lineTo(17f, 10f)
        }
        canvas.drawPath(path, stroke)
    }
}
