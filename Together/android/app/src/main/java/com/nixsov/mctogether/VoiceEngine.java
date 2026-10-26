package com.nixsov.mctogether;

import android.annotation.SuppressLint;
import android.media.AudioAttributes;
import android.media.AudioFormat;
import android.media.AudioRecord;
import android.media.AudioTrack;
import android.media.MediaRecorder;
import android.media.audiofx.AcousticEchoCanceler;
import android.media.audiofx.AutomaticGainControl;
import android.media.audiofx.NoiseSuppressor;
import android.util.Log;
import android.util.SparseArray;

import java.util.ArrayDeque;

/**
 * Голос: запись с микрофона, μ-law 16 кГц кадрами по 20 мс, и микширование
 * голосов всех участников в один поток воспроизведения.
 */
public class VoiceEngine {
    private static final String TAG = "Voice";
    public static final int RATE = 16000;
    public static final int FRAME = 320; // 20 мс
    private static final int START_FRAMES = 3; // буфер против рывков сети
    private static final int MAX_QUEUE = 15;

    public interface Sender {
        void sendVoice(byte[] frame, int len);
    }

    private final Sender sender;
    private volatile boolean running;
    private volatile boolean micOn;
    private volatile boolean speaking;
    private volatile float gateLevel = 350f;
    private Thread captureThread, playThread;

    private static class Peer {
        final ArrayDeque<short[]> queue = new ArrayDeque<>();
        boolean started;
        long lastFrame;
    }

    private final SparseArray<Peer> peers = new SparseArray<>();

    public VoiceEngine(Sender sender) {
        this.sender = sender;
    }

    public void setMicOn(boolean on) {
        micOn = on;
        if (!on) speaking = false;
    }

    public boolean isMicOn() {
        return micOn;
    }

    public boolean isSpeaking() {
        return speaking;
    }

    /** Кто сейчас говорит (кадр приходил последние 300 мс). */
    public boolean isPeerTalking(int id) {
        synchronized (peers) {
            Peer p = peers.get(id);
            return p != null && System.currentTimeMillis() - p.lastFrame < 300;
        }
    }

    public void start() {
        running = true;
        captureThread = new Thread(this::captureLoop, "voice-capture");
        playThread = new Thread(this::playLoop, "voice-play");
        captureThread.start();
        playThread.start();
    }

    public void stop() {
        running = false;
        if (captureThread != null) captureThread.interrupt();
        if (playThread != null) playThread.interrupt();
    }

    // ------------------------------------------------------------ приём

    public void onRemoteFrame(int id, byte[] data, int offset) {
        int n = Math.min(FRAME, data.length - offset);
        if (n <= 0) return;
        short[] pcm = new short[FRAME];
        for (int i = 0; i < n; i++) pcm[i] = ULaw.decode(data[offset + i]);
        synchronized (peers) {
            Peer p = peers.get(id);
            if (p == null) {
                p = new Peer();
                peers.put(id, p);
            }
            p.queue.addLast(pcm);
            while (p.queue.size() > MAX_QUEUE) p.queue.pollFirst();
            p.lastFrame = System.currentTimeMillis();
        }
    }

    public void removePeer(int id) {
        synchronized (peers) {
            peers.remove(id);
        }
    }

    private void playLoop() {
        int min = AudioTrack.getMinBufferSize(RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT);
        AudioTrack track;
        try {
            track = new AudioTrack.Builder()
                    .setAudioAttributes(new AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build())
                    .setAudioFormat(new AudioFormat.Builder()
                            .setSampleRate(RATE)
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                            .build())
                    .setBufferSizeInBytes(Math.max(min, FRAME * 2 * 4))
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build();
            track.play();
        } catch (Exception e) {
            Log.e(TAG, "AudioTrack", e);
            return;
        }
        int[] mix = new int[FRAME];
        short[] out = new short[FRAME];
        while (running) {
            java.util.Arrays.fill(mix, 0);
            synchronized (peers) {
                for (int i = 0; i < peers.size(); i++) {
                    Peer p = peers.valueAt(i);
                    if (!p.started && p.queue.size() >= START_FRAMES) p.started = true;
                    if (!p.started) continue;
                    short[] f = p.queue.pollFirst();
                    if (f == null) {
                        p.started = false;
                        continue;
                    }
                    for (int k = 0; k < FRAME; k++) mix[k] += f[k];
                }
            }
            for (int k = 0; k < FRAME; k++) {
                int v = mix[k];
                out[k] = (short) (v > 32767 ? 32767 : (v < -32768 ? -32768 : v));
            }
            track.write(out, 0, FRAME); // блокирующая запись задаёт темп 20 мс
        }
        try {
            track.stop();
        } catch (Exception ignored) {
        }
        track.release();
    }

    // ------------------------------------------------------------ запись

    @SuppressLint("MissingPermission")
    private void captureLoop() {
        int min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT);
        AudioRecord rec;
        try {
            rec = new AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, RATE,
                    AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, Math.max(min, FRAME * 2 * 8));
            if (rec.getState() != AudioRecord.STATE_INITIALIZED) throw new IllegalStateException("mic");
        } catch (Exception e) {
            Log.e(TAG, "AudioRecord", e);
            return;
        }
        int session = rec.getAudioSessionId();
        try {
            if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(session).setEnabled(true);
            if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(session).setEnabled(true);
            if (AutomaticGainControl.isAvailable()) AutomaticGainControl.create(session).setEnabled(true);
        } catch (Exception ignored) {
        }
        rec.startRecording();
        short[] pcm = new short[FRAME];
        byte[] packet = new byte[FRAME + 1];
        packet[0] = 0x01;
        int hangover = 0;
        while (running) {
            int got = 0;
            while (got < FRAME && running) {
                int r = rec.read(pcm, got, FRAME - got);
                if (r < 0) break;
                got += r;
            }
            if (!micOn) {
                hangover = 0;
                speaking = false;
                continue;
            }
            // простой шумовой порог: тишину не отправляем
            long sum = 0;
            for (short s : pcm) sum += (long) s * s;
            double rms = Math.sqrt(sum / (double) FRAME);
            if (rms > gateLevel) hangover = 15; // 300 мс после последнего звука
            else if (hangover > 0) hangover--;
            speaking = hangover > 0;
            if (!speaking) continue;
            for (int i = 0; i < FRAME; i++) packet[i + 1] = ULaw.encode(pcm[i]);
            sender.sendVoice(packet, packet.length);
        }
        try {
            rec.stop();
        } catch (Exception ignored) {
        }
        rec.release();
    }
}
