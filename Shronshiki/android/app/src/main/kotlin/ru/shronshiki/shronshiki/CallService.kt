package ru.shronshiki.shronshiki

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.view.KeyEvent

/**
 * Foreground service на время звонка.
 *
 * - Держит процесс и доступ к микрофону, когда приложение свёрнуто или экран выключен
 *   (тип microphone; стартует, пока приложение на экране).
 * - Уведомление с кнопками «Микрофон» и «Отключиться».
 * - MediaSession: нажатие на кнопку наушников (play/pause) включает и выключает микрофон.
 *
 * Свой сервис вместо плагина: плагин запускал второй движок Flutter, и его копия
 * WebRTC перехватывала управление звуком — микрофон глох, звук уходил в динамик.
 */
class CallService : Service() {
    companion object {
        const val ACTION_START = "ru.shronshiki.CALL_START"
        const val ACTION_UPDATE = "ru.shronshiki.CALL_UPDATE"
        const val ACTION_HANGUP = "ru.shronshiki.CALL_HANGUP"
        const val ACTION_TOGGLE_MUTE = "ru.shronshiki.CALL_TOGGLE_MUTE"
        const val EXTRA_TITLE = "title"
        const val EXTRA_MUTED = "muted"

        private const val CHANNEL_ID = "shronshiki_call"
        private const val NOTIFICATION_ID = 4242

        /** Действия пользователя для Flutter: "hangup" или "toggleMute". */
        var listener: ((String) -> Unit)? = null

        fun send(context: Context, action: String, title: String? = null, muted: Boolean? = null) {
            val intent = Intent(context, CallService::class.java).setAction(action)
            title?.let { intent.putExtra(EXTRA_TITLE, it) }
            muted?.let { intent.putExtra(EXTRA_MUTED, it) }
            try {
                if (action == ACTION_START && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Система может запретить запуск сервиса из фона — звонок продолжится без уведомления.
                android.util.Log.w("CallService", "start failed", e)
            }
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaSession: MediaSession? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var title = "Shronshiki"
    private var muted = false
    private var lastButtonAt = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_UPDATE -> {
                intent.getStringExtra(EXTRA_TITLE)?.let { title = it }
                if (intent.hasExtra(EXTRA_MUTED)) muted = intent.getBooleanExtra(EXTRA_MUTED, false)
                showNotification()
                if (mediaSession == null) startMediaSession()
                acquireLocks()
            }
            ACTION_HANGUP -> notifyFlutter("hangup")
            ACTION_TOGGLE_MUTE -> notifyFlutter("toggleMute")
        }
        return START_NOT_STICKY
    }

    /**
     * При выключенном экране процессор и Wi-Fi могут засыпать — тогда приложение
     * перестаёт опрашивать сервер. На время звонка не даём им уснуть.
     */
    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "Shronshiki:call").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        }
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wm.createWifiLock(mode, "Shronshiki:call").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun notifyFlutter(action: String) {
        mainHandler.post { listener?.invoke(action) }
    }

    private fun showNotification() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Голосовой звонок", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "Уведомление, пока вы в голосовой комнате" },
            )
        }
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val openApp = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            flags,
        )
        fun serviceIntent(action: String, code: Int) = PendingIntent.getService(
            this, code, Intent(this, CallService::class.java).setAction(action), flags,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setSmallIcon(if (muted) android.R.drawable.stat_notify_call_mute else android.R.drawable.ic_btn_speak_now)
            .setContentTitle(title)
            .setContentText(if (muted) "Микрофон выключен" else "Вы в голосовой комнате")
            .setContentIntent(openApp)
            .setOngoing(true)
            .setShowWhen(false)
            .setCategory(Notification.CATEGORY_CALL)
            .addAction(
                Notification.Action.Builder(
                    null, if (muted) "Включить микрофон" else "Выключить микрофон",
                    serviceIntent(ACTION_TOGGLE_MUTE, 1),
                ).build(),
            )
            .addAction(Notification.Action.Builder(null, "Отключиться", serviceIntent(ACTION_HANGUP, 2)).build())
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** Кнопка на наушниках (одно нажатие = play/pause) переключает микрофон. */
    private fun startMediaSession() {
        val session = MediaSession(this, "ShronshikiCall")
        session.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                @Suppress("DEPRECATION")
                val event = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                    ?: return super.onMediaButtonEvent(mediaButtonIntent)
                when (event.keyCode) {
                    KeyEvent.KEYCODE_HEADSETHOOK,
                    KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                    KeyEvent.KEYCODE_MEDIA_PLAY,
                    KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                        if (event.action == KeyEvent.ACTION_UP) onHeadsetButton()
                        return true
                    }
                }
                return super.onMediaButtonEvent(mediaButtonIntent)
            }

            // Некоторые гарнитуры присылают сразу команды play/pause.
            override fun onPlay() = onHeadsetButton()
            override fun onPause() = onHeadsetButton()
        })
        session.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                .build(),
        )
        session.isActive = true
        mediaSession = session
    }

    private fun onHeadsetButton() {
        // Одно нажатие может прийти и как key event, и как onPlay/onPause.
        val now = SystemClock.elapsedRealtime()
        if (now - lastButtonAt < 400) return
        lastButtonAt = now
        notifyFlutter("toggleMute")
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Приложение смахнули из недавних — звонок завершается вместе с ним.
        stopSelf()
    }

    override fun onDestroy() {
        wakeLock?.takeIf { it.isHeld }?.release()
        wakeLock = null
        wifiLock?.takeIf { it.isHeld }?.release()
        wifiLock = null
        mediaSession?.run {
            isActive = false
            release()
        }
        mediaSession = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }
}
