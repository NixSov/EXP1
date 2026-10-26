package com.nixsov.mctogether;

import android.util.Log;

import org.json.JSONObject;

import java.util.concurrent.TimeUnit;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;
import okio.ByteString;

/** WebSocket-соединение с сервером «MC Вместе» с автоматическим переподключением. */
public class RelayClient {
    private static final String TAG = "Relay";
    public static final int PROTOCOL_VERSION = 2;

    public interface Listener {
        void onConnected();
        void onDisconnected(String reason);
        void onJson(JSONObject msg);
        void onBinary(byte[] data);
    }

    private final OkHttpClient http = new OkHttpClient.Builder()
            .pingInterval(15, TimeUnit.SECONDS)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.SECONDS)
            .build();

    private final String url;
    private final Listener listener;
    private volatile WebSocket socket;
    private volatile boolean connected;
    private volatile boolean stopped;
    private int attempt;
    private Thread reconnectThread;

    public RelayClient(String address, Listener listener) {
        this.url = normalize(address);
        this.listener = listener;
    }

    /** «example.com» -> wss://example.com, «1.2.3.4:8080» -> ws://1.2.3.4:8080. */
    public static String normalize(String address) {
        String a = address.trim();
        if (a.startsWith("http://")) return "ws://" + a.substring(7);
        if (a.startsWith("https://")) return "wss://" + a.substring(8);
        if (a.startsWith("ws://") || a.startsWith("wss://")) return a;
        String host = a.split("/")[0];
        boolean ip = host.matches("^[0-9.]+(:\\d+)?$") || host.startsWith("localhost");
        boolean port = host.matches(".*:\\d+$");
        return (ip || port ? "ws://" : "wss://") + a;
    }

    public void start() {
        stopped = false;
        open();
    }

    private void open() {
        if (stopped) return;
        Request req;
        try {
            req = new Request.Builder().url(url).build();
        } catch (IllegalArgumentException e) {
            listener.onDisconnected("Неверный адрес сервера");
            stopped = true;
            return;
        }
        socket = http.newWebSocket(req, new WebSocketListener() {
            @Override
            public void onOpen(WebSocket ws, Response response) {
                if (ws != socket) return;
                connected = true;
                attempt = 0;
                listener.onConnected();
            }

            @Override
            public void onMessage(WebSocket ws, String text) {
                if (ws != socket) return;
                try {
                    listener.onJson(new JSONObject(text));
                } catch (Exception e) {
                    Log.w(TAG, "bad json", e);
                }
            }

            @Override
            public void onMessage(WebSocket ws, ByteString bytes) {
                if (ws != socket) return;
                listener.onBinary(bytes.toByteArray());
            }

            @Override
            public void onClosed(WebSocket ws, int code, String reason) {
                lost(ws, "Соединение закрыто");
            }

            @Override
            public void onFailure(WebSocket ws, Throwable t, Response response) {
                lost(ws, "Нет связи с сервером");
            }
        });
    }

    private synchronized void lost(WebSocket ws, String reason) {
        if (ws != socket) return;
        connected = false;
        listener.onDisconnected(reason);
        if (stopped) return;
        attempt = Math.min(attempt + 1, 6);
        long delay = 1000L << Math.min(attempt, 4); // 2..16 с
        reconnectThread = new Thread(() -> {
            try {
                Thread.sleep(delay);
            } catch (InterruptedException e) {
                return;
            }
            open();
        }, "relay-reconnect");
        reconnectThread.start();
    }

    public boolean isConnected() {
        return connected;
    }

    public void sendJson(JSONObject obj) {
        WebSocket s = socket;
        if (s != null && connected) s.send(obj.toString());
    }

    /** Отправить двоичный кадр. lossy=true — можно выбросить при перегрузке (голос). */
    public void sendBinary(byte[] data, int len, boolean lossy) {
        WebSocket s = socket;
        if (s == null || !connected) return;
        if (lossy && s.queueSize() > 64 * 1024) return;
        if (s.queueSize() > 4 * 1024 * 1024) return;
        s.send(ByteString.of(data, 0, len));
    }

    public void stop() {
        stopped = true;
        connected = false;
        if (reconnectThread != null) reconnectThread.interrupt();
        WebSocket s = socket;
        socket = null;
        if (s != null) s.close(1000, "bye");
    }
}
