package ru.shronshiki.shronshiki

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
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

    override fun onDestroy() {
        if (CallService.listener != null && isFinishing) {
            // Экран приложения закрыт окончательно — звонка больше нет.
            stopService(Intent(this, CallService::class.java))
        }
        CallService.listener = null
        channel?.setMethodCallHandler(null)
        super.onDestroy()
    }
}
