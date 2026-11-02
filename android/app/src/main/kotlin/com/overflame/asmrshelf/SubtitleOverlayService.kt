package com.overflame.asmrshelf

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView
import kotlin.math.roundToInt

/**
 * 系统级常驻字幕窗。
 *
 * 字幕文字仍由 Dart 计算，通过 MainActivity 的 MethodChannel 传进来；这个
 * Service 只负责画一个位于其他应用上层的可拖动/可穿透的歌词条。
 */
class SubtitleOverlayService : Service() {

    companion object {
        private const val ACTION_SHOW = "show"
        private const val ACTION_UPDATE = "update"
        private const val ACTION_HIDE = "hide"
        private const val ACTION_LOCK = "lock"

        private const val EXTRA_CURRENT = "current"
        private const val EXTRA_NEXT = "next"
        private const val EXTRA_LOCKED = "locked"

        private const val PREFS = "subtitle_overlay"
        private const val KEY_X = "x"
        private const val KEY_Y = "y"

        @Volatile
        private var instance: SubtitleOverlayService? = null

        fun show(
            context: Context,
            current: String,
            next: String,
            locked: Boolean,
        ) {
            val intent = Intent(context, SubtitleOverlayService::class.java).apply {
                action = ACTION_SHOW
                putExtra(EXTRA_CURRENT, current)
                putExtra(EXTRA_NEXT, next)
                putExtra(EXTRA_LOCKED, locked)
            }
            context.startService(intent)
        }

        fun update(context: Context, current: String, next: String) {
            val running = instance
            if (running == null) {
                show(context, current, next, false)
                return
            }
            running.applyText(current, next)
        }

        fun hide(context: Context) {
            instance?.removeOverlay()
            context.stopService(Intent(context, SubtitleOverlayService::class.java))
        }

        fun setLocked(context: Context, locked: Boolean) {
            val running = instance
            if (running == null) {
                show(context, "", "", locked)
                return
            }
            running.applyLocked(locked)
        }
    }

    private lateinit var windowManager: WindowManager
    private var container: LinearLayout? = null
    private var currentView: TextView? = null
    private var nextView: TextView? = null
    private var params: WindowManager.LayoutParams? = null
    private var locked = false
    private var currentText = ""
    private var nextText = ""
    private var dragRawX = 0f
    private var dragRawY = 0f
    private var dragStartX = 0
    private var dragStartY = 0

    override fun onCreate() {
        super.onCreate()
        instance = this
        windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_HIDE -> {
                removeOverlay()
                stopSelf()
            }

            ACTION_LOCK -> {
                applyLocked(intent.getBooleanExtra(EXTRA_LOCKED, false))
            }

            ACTION_UPDATE -> {
                applyText(
                    intent.getStringExtra(EXTRA_CURRENT) ?: "",
                    intent.getStringExtra(EXTRA_NEXT) ?: "",
                )
            }

            else -> {
                val text = intent?.getStringExtra(EXTRA_CURRENT) ?: ""
                val next = intent?.getStringExtra(EXTRA_NEXT) ?: ""
                applyLocked(intent?.getBooleanExtra(EXTRA_LOCKED, false) ?: false)
                if (text.isBlank() && next.isBlank()) {
                    stopSelf()
                } else {
                    applyText(text, next)
                }
            }
        }
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        instance = null
        removeOverlay()
        super.onDestroy()
    }

    private fun applyText(current: String, next: String) {
        currentText = current
        nextText = next
        if (current.isBlank() && next.isBlank()) {
            removeOverlay()
            return
        }
        ensureOverlay()
        currentView?.text = current
        nextView?.apply {
            text = next
            visibility = if (next.isBlank()) View.GONE else View.VISIBLE
        }
    }

    private fun applyLocked(value: Boolean) {
        locked = value
        val p = params ?: return
        if (value) {
            p.flags = p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        } else {
            p.flags = p.flags and WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE.inv()
        }
        container?.let { windowManager.updateViewLayout(it, p) }
    }

    private fun ensureOverlay() {
        if (container != null) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            !Settings.canDrawOverlays(this)
        ) {
            stopSelf()
            return
        }

        val metrics = resources.displayMetrics
        val width = (metrics.widthPixels * 0.92f).roundToInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(16), dp(12), dp(16), dp(12))
            background = GradientDrawable().apply {
                setColor(Color.argb(0xB8, 18, 18, 22))
                cornerRadius = dp(18).toFloat()
            }
            setOnTouchListener { _, event -> onTouch(event) }
        }

        val title = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 19f
            gravity = Gravity.CENTER
            maxLines = 2
            setShadowLayer(4f, 0f, 1f, Color.argb(180, 0, 0, 0))
        }
        val subtitle = TextView(this).apply {
            setTextColor(Color.argb(0xCC, 255, 255, 255))
            textSize = 13f
            gravity = Gravity.CENTER
            maxLines = 2
            setPadding(0, dp(3), 0, 0)
        }

        root.addView(title)
        root.addView(subtitle)

        val p = WindowManager.LayoutParams(
            width,
            WindowManager.LayoutParams.WRAP_CONTENT,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
            x = prefs.getInt(KEY_X, ((metrics.widthPixels - width) / 2f).roundToInt())
            y = prefs.getInt(KEY_Y, metrics.heightPixels - dp(260))
        }
        params = p
        if (locked) {
            p.flags = p.flags or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        }

        container = root
        currentView = title
        nextView = subtitle
        title.text = currentText
        subtitle.text = nextText
        subtitle.visibility = if (nextText.isBlank()) View.GONE else View.VISIBLE

        try {
            windowManager.addView(root, p)
        } catch (_: Exception) {
            container = null
            currentView = null
            nextView = null
            params = null
            stopSelf()
        }
    }

    private fun onTouch(event: MotionEvent): Boolean {
        val p = params ?: return false
        if (locked) return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                dragRawX = event.rawX
                dragRawY = event.rawY
                dragStartX = p.x
                dragStartY = p.y
                return true
            }

            MotionEvent.ACTION_MOVE -> {
                p.x = dragStartX + (event.rawX - dragRawX).roundToInt()
                p.y = dragStartY + (event.rawY - dragRawY).roundToInt()
                val metrics = resources.displayMetrics
                p.x = p.x.coerceIn(-p.width / 3, metrics.widthPixels - p.width / 3)
                p.y = p.y.coerceIn(0, metrics.heightPixels - dp(48))
                container?.let { windowManager.updateViewLayout(it, p) }
                return true
            }

            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putInt(KEY_X, p.x)
                    .putInt(KEY_Y, p.y)
                    .apply()
                return true
            }
        }
        return false
    }

    private fun removeOverlay() {
        val view = container ?: return
        container = null
        currentView = null
        nextView = null
        params = null
        try {
            windowManager.removeView(view)
        } catch (_: Exception) {
            // 系统已经回收窗口时忽略。
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()
}
