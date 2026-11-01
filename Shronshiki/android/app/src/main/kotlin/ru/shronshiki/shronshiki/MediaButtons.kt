package ru.shronshiki.shronshiki

import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent

/**
 * Кнопка на наушниках (одно нажатие = play/pause).
 *
 * Android отдаёт такие нажатия приложению, которое последним проигрывало медиа.
 * Звук звонка медиа не считается, поэтому нажатия уходили музыкальному плееру.
 * Пока мы слушаем кнопку, играем беззвучную медиа-дорожку — тогда кнопка
 * достаётся нам.
 */
object MediaButtons {
    /** Название нажатой кнопки, например KEYCODE_HEADSETHOOK. Вызывается в главном потоке. */
    var onButton: ((String) -> Unit)? = null

    private val handler = Handler(Looper.getMainLooper())
    private var users = 0
    private var session: MediaSession? = null
    private var silence: AudioTrack? = null
    private var lastAt = 0L

    private val handledKeys = setOf(
        KeyEvent.KEYCODE_HEADSETHOOK,
        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
        KeyEvent.KEYCODE_MEDIA_PLAY,
        KeyEvent.KEYCODE_MEDIA_PAUSE,
    )

    fun start(context: Context) {
        users++
        if (session != null) return
        val s = MediaSession(context.applicationContext, "ShronshikiCall")
        s.setCallback(object : MediaSession.Callback() {
            override fun onMediaButtonEvent(mediaButtonIntent: Intent): Boolean {
                @Suppress("DEPRECATION")
                val event = mediaButtonIntent.getParcelableExtra<KeyEvent>(Intent.EXTRA_KEY_EVENT)
                    ?: return super.onMediaButtonEvent(mediaButtonIntent)
                return handleKey(event) || super.onMediaButtonEvent(mediaButtonIntent)
            }

            // Некоторые гарнитуры присылают сразу команды play/pause.
            override fun onPlay() = fire("PLAY")
            override fun onPause() = fire("PAUSE")
        })
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or PlaybackState.ACTION_PLAY_PAUSE)
                .setState(PlaybackState.STATE_PLAYING, 0, 1f)
                .build(),
        )
        s.isActive = true
        session = s
        startSilence()
    }

    fun stop() {
        users = maxOf(0, users - 1)
        if (users > 0) return
        session?.run {
            isActive = false
            release()
        }
        session = null
        silence?.run {
            try {
                stop()
            } catch (_: Exception) {
            }
            release()
        }
        silence = null
    }

    /** Нажатие, пришедшее прямо в окно приложения (когда оно на экране). */
    fun handleKey(event: KeyEvent): Boolean {
        if (session == null || event.keyCode !in handledKeys) return false
        if (event.action == KeyEvent.ACTION_UP) fire(KeyEvent.keyCodeToString(event.keyCode))
        return true
    }

    private fun fire(name: String) {
        // Одно нажатие может прийти и как key event, и как onPlay/onPause.
        val now = SystemClock.elapsedRealtime()
        if (now - lastAt < 400) return
        lastAt = now
        handler.post { onButton?.invoke(name) }
    }

    private fun startSilence() {
        try {
            val rate = 8000
            val samples = ShortArray(rate) // 1 секунда тишины, по кругу
            val track = AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
                samples.size * 2,
                AudioTrack.MODE_STATIC,
                AudioManager.AUDIO_SESSION_ID_GENERATE,
            )
            track.write(samples, 0, samples.size)
            track.setLoopPoints(0, samples.size, -1)
            track.play()
            silence = track
        } catch (e: Exception) {
            Log.w("MediaButtons", "silent track failed", e)
        }
    }
}
