package ru.shronshiki.shronshiki

import android.Manifest
import android.annotation.SuppressLint
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "shronshiki/call")
        this.channel = channel
        CallService.listener = { action -> channel.invokeMethod("onAction", action) }
        MediaButtons.onButton = { key -> channel.invokeMethod("onMediaKey", key) }

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    CallService.send(this, CallService.ACTION_START, call.argument("title"), call.argument("muted"))
                    result.success(null)
                }
                "update" -> {
                    CallService.send(this, CallService.ACTION_UPDATE, call.argument("title"), call.argument("muted"))
                    result.success(null)
                }
                "stop" -> {
                    stopService(Intent(this, CallService::class.java))
                    result.success(null)
                }
                "requestNotificationPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                    ) {
                        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                    }
                    result.success(null)
                }
                "startButtonTest" -> {
                    MediaButtons.start(this)
                    result.success(null)
                }
                "stopButtonTest" -> {
                    MediaButtons.stop()
                    result.success(null)
                }
                "showMention" -> {
                    showMention(
                        call.argument<String>("title") ?: "Shronshiki",
                        call.argument<String>("text") ?: "",
                        call.argument<String>("code") ?: "",
                    )
                    result.success(null)
                }
                "abi" -> result.success(AppUpdater.abi)
                "installApk" -> {
                    try {
                        AppUpdater.install(this, call.argument<String>("path") ?: "")
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("install", e.message, null)
                    }
                }
                "moveToBack" -> {
                    // «Назад» на главном экране во время звонка сворачивает приложение, а не закрывает.
                    moveTaskToBack(true)
                    result.success(null)
                }
                "isIgnoringBatteryOptimizations" -> {
                    val pm = getSystemService(POWER_SERVICE) as PowerManager
                    result.success(pm.isIgnoringBatteryOptimizations(packageName))
                }
                "requestIgnoreBatteryOptimizations" -> {
                    requestIgnoreBatteryOptimizations()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Упоминание в чате. Нажатие открывает shronshiki://join/КОД — вход в комнату. */
    private fun showMention(title: String, text: String, code: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(MENTIONS_CHANNEL, "Упоминания в чате", NotificationManager.IMPORTANCE_HIGH)
                    .apply { description = "Когда вас упоминают через @имя" },
            )
        }
        val open = Intent(Intent.ACTION_VIEW, Uri.parse(if (code.isEmpty()) "shronshiki://" else "shronshiki://join/$code"))
            .setPackage(packageName)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val pending = PendingIntent.getActivity(
            this, code.hashCode(), open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, MENTIONS_CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH)
        }
        val notification = builder
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_MESSAGE)
            .build()
        manager.notify(MENTIONS_BASE_ID + (System.currentTimeMillis() % 100000).toInt(), notification)
    }

    companion object {
        private const val MENTIONS_CHANNEL = "shronshiki_mentions"
        private const val MENTIONS_BASE_ID = 5000
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:$packageName")),
            )
        } catch (e: Exception) {
            startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    /** Когда приложение на экране, нажатие на наушниках приходит сюда раньше. */
    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        MediaButtons.handleKey(event) || super.dispatchKeyEvent(event)

    override fun onDestroy() {
        if (CallService.listener != null && isFinishing) {
            // Экран приложения закрыт окончательно — звонка больше нет.
            stopService(Intent(this, CallService::class.java))
        }
        CallService.listener = null
        MediaButtons.onButton = null
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
