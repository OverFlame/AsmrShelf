package com.overflame.asmrshelf

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.IBinder
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media.session.MediaButtonReceiver
import io.flutter.plugin.common.MethodChannel

/**
 * 后台播放前台服务：负责「保活 + MediaSession + MediaStyle 通知栏」。
 * 真正的音频解码/播放仍在 Dart 侧（flutter_soloud），本服务只是一个控制壳。
 *
 * Dart ↔ 原生通信（MethodChannel "asmrshelf/playback"）：
 *   Dart -> 原生：startPlaybackService / updateNotification / stopPlaybackService
 *   原生 -> Dart：onPlayPause / onNext / onPrevious / onSeekTo / onStop
 */
class PlaybackService : Service() {

    companion object {
        const val CHANNEL_ID = "asmrshelf_playback"
        const val NOTIFICATION_ID = 1001
        const val CHANNEL = "asmrshelf/playback"

        @Volatile
        var instance: PlaybackService? = null

        /** 由 MainActivity 在 configureFlutterEngine 中注入，用于向 Dart 回传事件 */
        @Volatile
        var channel: MethodChannel? = null

        fun emit(event: String, args: Any?) {
            channel?.invokeMethod(event, args)
        }

        fun refresh(data: Map<String, Any?>?) {
            instance?.applyUpdate(data)
        }
    }

    private lateinit var mediaSession: MediaSessionCompat
    private lateinit var notificationManager: NotificationManager

    private var title: String = ""
    private var artist: String = ""
    private var playing: Boolean = false
    private var positionMs: Long = 0
    private var durationMs: Long = 0
    private var coverPath: String? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        createChannel()

        mediaSession = MediaSessionCompat(this, "AsmrShelf").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = emit("onPlayPause", null)
                override fun onPause() = emit("onPlayPause", null)
                override fun onSkipToNext() = emit("onNext", null)
                override fun onSkipToPrevious() = emit("onPrevious", null)
                override fun onSeekTo(pos: Long) = emit("onSeekTo", pos)
                override fun onStop() = emit("onStop", null)
            })
            isActive = true
        }

        startForegroundCompat(buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        instance = null
        mediaSession.isActive = false
        mediaSession.release()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        super.onDestroy()
    }

    /** 更新通知与 MediaSession 状态 */
    fun applyUpdate(data: Map<String, Any?>?) {
        if (data == null) return
        title = data["title"] as? String ?: title
        artist = data["artist"] as? String ?: artist
        playing = data["playing"] as? Boolean ?: playing
        positionMs = (data["positionMs"] as? Number)?.toLong() ?: positionMs
        durationMs = (data["durationMs"] as? Number)?.toLong() ?: durationMs
        coverPath = data["coverPath"] as? String ?: coverPath

        updateSession()
        notificationManager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun updateSession() {
        val metadata = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title.ifEmpty { "AsmrShelf" })
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist)
            .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
            .apply { coverBitmap()?.let { putBitmap(MediaMetadataCompat.METADATA_KEY_ART, it) } }
            .build()
        mediaSession.setMetadata(metadata)

        val state =
            if (playing) PlaybackStateCompat.STATE_PLAYING else PlaybackStateCompat.STATE_PAUSED
        mediaSession.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY or
                        PlaybackStateCompat.ACTION_PAUSE or
                        PlaybackStateCompat.ACTION_PLAY_PAUSE or
                        PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
                        PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
                        PlaybackStateCompat.ACTION_SEEK_TO or
                        PlaybackStateCompat.ACTION_STOP
                )
                .setState(state, positionMs, if (playing) 1f else 0f)
                .build()
        )
    }

    private fun coverBitmap(): Bitmap? {
        val p = coverPath ?: return null
        return try {
            BitmapFactory.decodeFile(p)
        } catch (e: Exception) {
            null
        }
    }

    private fun buildNotification(): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val playPauseAction =
            if (playing) PlaybackStateCompat.ACTION_PAUSE else PlaybackStateCompat.ACTION_PLAY
        val playPauseLabel = if (playing) "暂停" else "播放"

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            // 通知栏小图标：此处用系统媒体图标，如需自定义请替换为自有 drawable
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title.ifEmpty { "AsmrShelf" })
            .setContentText(artist)
            .setContentIntent(contentIntent)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setOngoing(playing)
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_previous,
                    "上一首",
                    MediaButtonReceiver.buildMediaButtonPendingIntent(
                        this, PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
                    )
                )
            )
            .addAction(
                NotificationCompat.Action(
                    if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    playPauseLabel,
                    MediaButtonReceiver.buildMediaButtonPendingIntent(this, playPauseAction)
                )
            )
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_media_next,
                    "下一首",
                    MediaButtonReceiver.buildMediaButtonPendingIntent(
                        this, PlaybackStateCompat.ACTION_SKIP_TO_NEXT
                    )
                )
            )
            .addAction(
                NotificationCompat.Action(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "停止",
                    MediaButtonReceiver.buildMediaButtonPendingIntent(
                        this, PlaybackStateCompat.ACTION_STOP
                    )
                )
            )
            .setStyle(
                MediaStyle()
                    .setMediaSession(mediaSession.sessionToken)
                    .setShowActionsInCompactView(0, 1, 2)
            )

        coverBitmap()?.let { builder.setLargeIcon(it) }
        return builder.build()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun createChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "播放控制",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "AsmrShelf 后台播放通知"
            setShowBadge(false)
        }
        notificationManager.createNotificationChannel(channel)
    }
}
