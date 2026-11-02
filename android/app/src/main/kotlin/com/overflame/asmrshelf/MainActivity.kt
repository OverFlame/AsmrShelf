package com.overflame.asmrshelf

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private val channelName = "asmrshelf/playback"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        PlaybackService.channel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "checkAllFilesAccess" ->
                    result.success(hasAllFilesAccess())

                "requestAllFilesAccess" -> {
                    if (Build.VERSION.SDK_INT >= 30) {
                        openAllFilesAccessSettings()
                    } else {
                        // Android 10 及以下走 READ_EXTERNAL_STORAGE 运行时权限
                        ActivityCompat.requestPermissions(
                            this, arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE), 201
                        )
                    }
                    result.success(null)
                }

                "checkNotificationPermission" ->
                    result.success(
                        Build.VERSION.SDK_INT < 33 ||
                            ContextCompat.checkSelfPermission(
                                this, Manifest.permission.POST_NOTIFICATIONS
                            ) == PackageManager.PERMISSION_GRANTED
                    )

                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= 33) {
                        ActivityCompat.requestPermissions(
                            this, arrayOf(Manifest.permission.POST_NOTIFICATIONS), 200
                        )
                    }
                    result.success(null)
                }

                "startPlaybackService" -> {
                    startPlaybackService()
                    result.success(null)
                }

                "updateNotification" -> {
                    @Suppress("UNCHECKED_CAST")
                    PlaybackService.refresh(call.arguments as? Map<String, Any?>)
                    result.success(null)
                }

                "stopPlaybackService" -> {
                    stopPlaybackService()
                    result.success(null)
                }

                "openVideo" -> {
                    val args = call.arguments as? Map<*, *>
                    val path = args?.get("path") as? String
                    val mime = args?.get("mimeType") as? String ?: "*/*"
                    if (path.isNullOrEmpty()) {
                        result.error("bad_args", "openVideo 缺少 path", null)
                    } else {
                        result.success(openWithSystemPlayer(path, mime))
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把文件交给系统播放器（BUILD_GUIDE 第 9.5 节）。
     *
     * 别的应用读不到 app 私有目录，共享存储也不能用 file:// 暴露，
     * 所以 URI 一律由 FileProvider 生成，并只授权这一次读取。
     */
    private fun openWithSystemPlayer(path: String, mimeType: String): Boolean {
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            // Android 11 起要看得见别的应用，得先在 manifest 的 queries 里声明
            if (packageManager.queryIntentActivities(intent, 0).isEmpty()) return false
            startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun hasAllFilesAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= 30) return Environment.isExternalStorageManager()
        return ContextCompat.checkSelfPermission(
            this, Manifest.permission.READ_EXTERNAL_STORAGE
        ) == PackageManager.PERMISSION_GRANTED
    }

    /** 跳转到系统「所有文件访问」授权页 */
    private fun openAllFilesAccessSettings() {
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
            intent.data = Uri.parse("package:$packageName")
            startActivity(intent)
        } catch (e: Exception) {
            // 兜底：跳转到通用授权列表
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            } catch (_: Exception) {
            }
        }
    }

    private fun startPlaybackService() {
        val intent = Intent(this, PlaybackService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun stopPlaybackService() {
        stopService(Intent(this, PlaybackService::class.java))
    }
}
