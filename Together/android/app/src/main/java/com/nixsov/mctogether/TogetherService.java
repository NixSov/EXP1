package com.nixsov.mctogether;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.PowerManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Фоновая служба: держит соединение с сервером, голос, туннель к миру
 * и плавающую кнопку микрофона.
 */
public class TogetherService extends Service implements RelayClient.Listener {
    public static final String ACTION_START = "start";
    public static final String ACTION_STOP = "stop";
    public static final String ACTION_TOGGLE_MIC = "toggle_mic";
    public static final String EXTRA_SERVER = "server";
    public static final String EXTRA_ROOM = "room";
    public static final String EXTRA_NAME = "name";
    public static final String EXTRA_HOST = "host";

    private static final String CHANNEL = "together";
    private static final int NOTIF_ID = 1;

    /** Текущий экземпляр — для экрана приложения. */
    public static volatile TogetherService instance;

    public static class Member {
        public final int id;
        public final String name;
        public boolean muted;
        public final boolean host;

        Member(int id, String name, boolean muted, boolean host) {
            this.id = id;
            this.name = name;
            this.muted = muted;
            this.host = host;
        }
    }

    private final Handler main = new Handler(Looper.getMainLooper());
    private RelayClient relay;
    private VoiceEngine voice;
    private HostTunnel hostTunnel;
    private GuestTunnel guestTunnel;
    private OverlayButton overlay;
    private WifiManager.MulticastLock multicastLock;
    private PowerManager.WakeLock wakeLock;

    private boolean isHost;
    private String room, name;
    private volatile String status = "Подключение…";
    private volatile String error;
    private volatile int myId;
    private volatile Integer hostId;
    private final Map<Integer, Member> members = new LinkedHashMap<>();

    // ------------------------------------------------------------ жизненный цикл

    public static void start(Context ctx, String server, String room, String name, boolean host) {
        Intent i = new Intent(ctx, TogetherService.class).setAction(ACTION_START)
                .putExtra(EXTRA_SERVER, server).putExtra(EXTRA_ROOM, room)
                .putExtra(EXTRA_NAME, name).putExtra(EXTRA_HOST, host);
        ctx.startForegroundService(i);
    }

    public static void stop(Context ctx) {
        ctx.startService(new Intent(ctx, TogetherService.class).setAction(ACTION_STOP));
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        String action = intent != null ? intent.getAction() : null;
        if (ACTION_STOP.equals(action)) {
            shutdown();
            return START_NOT_STICKY;
        }
        if (ACTION_TOGGLE_MIC.equals(action)) {
            toggleMic();
            return START_NOT_STICKY;
        }
        if (ACTION_START.equals(action) && relay == null) {
            begin(intent);
        }
        return START_NOT_STICKY;
    }

    private void begin(Intent intent) {
        instance = this;
        isHost = intent.getBooleanExtra(EXTRA_HOST, false);
        room = intent.getStringExtra(EXTRA_ROOM);
        name = intent.getStringExtra(EXTRA_NAME);
        createChannel();
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE);
        } else {
            startForeground(NOTIF_ID, buildNotification());
        }

        PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "mctogether:service");
        wakeLock.acquire();
        WifiManager wifi = (WifiManager) getApplicationContext().getSystemService(WIFI_SERVICE);
        multicastLock = wifi.createMulticastLock("mctogether");
        multicastLock.setReferenceCounted(false);
        multicastLock.acquire();

        relay = new RelayClient(intent.getStringExtra(EXTRA_SERVER), this);
        voice = new VoiceEngine((frame, len) -> relay.sendBinary(frame, len, true));
        voice.start();
        try {
            if (isHost) {
                hostTunnel = new HostTunnel(relay);
                hostTunnel.start();
            } else {
                guestTunnel = new GuestTunnel(relay);
                guestTunnel.start();
            }
        } catch (Exception e) {
            error = "Не удалось открыть порт для мира: " + e.getMessage();
        }
        relay.start();

        overlay = new OverlayButton(this, new OverlayButton.Callbacks() {
            @Override
            public void onToggleMic() {
                toggleMic();
            }

            @Override
            public void onOpenApp() {
                Intent i = new Intent(TogetherService.this, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
                startActivity(i);
            }
        });
        overlay.show();
        main.post(ticker);
    }

    private final Runnable ticker = new Runnable() {
        private String lastNotif = "";

        @Override
        public void run() {
            if (relay == null) return;
            boolean othersTalking = false;
            synchronized (members) {
                for (Member m : members.values()) if (voice.isPeerTalking(m.id)) othersTalking = true;
            }
            int state = !relay.isConnected() ? OverlayButton.STATE_OFFLINE
                    : voice.isMicOn() ? OverlayButton.STATE_MIC_ON : OverlayButton.STATE_MIC_OFF;
            overlay.update(state, voice.isSpeaking(), othersTalking, relay.isConnected() ? memberCount() + 1 : 0);
            String n = notificationText();
            if (!n.equals(lastNotif)) {
                lastNotif = n;
                ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).notify(NOTIF_ID, buildNotification());
            }
            main.postDelayed(this, 150);
        }
    };

    private void shutdown() {
        main.removeCallbacks(ticker);
        if (overlay != null) overlay.hide();
        if (relay != null) relay.stop();
        if (voice != null) voice.stop();
        if (hostTunnel != null) hostTunnel.stop();
        if (guestTunnel != null) guestTunnel.stop();
        if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        relay = null;
        instance = null;
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    @Override
    public void onDestroy() {
        if (relay != null) shutdown();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    // ------------------------------------------------------------ микрофон

    public void toggleMic() {
        if (voice == null) return;
        boolean on = !voice.isMicOn();
        voice.setMicOn(on);
        try {
            relay.sendJson(new JSONObject().put("t", "mute").put("muted", !on));
        } catch (Exception ignored) {
        }
    }

    public boolean isMicOn() {
        return voice != null && voice.isMicOn();
    }

    // ------------------------------------------------------------ сервер

    @Override
    public void onConnected() {
        status = "Вход в комнату…";
        try {
            relay.sendJson(new JSONObject().put("t", "hello").put("v", RelayClient.PROTOCOL_VERSION)
                    .put("room", room).put("name", name).put("role", isHost ? "host" : "guest")
                    .put("muted", !voice.isMicOn()));
        } catch (Exception ignored) {
        }
    }

    @Override
    public void onDisconnected(String reason) {
        status = reason + ". Переподключение…";
        synchronized (members) {
            members.clear();
        }
        hostId = null;
        if (guestTunnel != null) guestTunnel.setHostPong(null);
    }

    @Override
    public void onJson(JSONObject m) {
        try {
            switch (m.getString("t")) {
                case "welcome": {
                    myId = m.getInt("id");
                    hostId = m.isNull("hostId") ? null : m.getInt("hostId");
                    JSONArray arr = m.getJSONArray("members");
                    synchronized (members) {
                        members.clear();
                        for (int i = 0; i < arr.length(); i++) addMember(arr.getJSONObject(i));
                    }
                    if (guestTunnel != null) guestTunnel.setHostPong(m.isNull("pong") ? null : m.getString("pong"));
                    status = "В комнате «" + room + "»";
                    error = null;
                    break;
                }
                case "join":
                    synchronized (members) {
                        addMember(m);
                    }
                    if (m.optBoolean("host")) hostId = m.getInt("id");
                    break;
                case "leave": {
                    int id = m.getInt("id");
                    synchronized (members) {
                        members.remove(id);
                    }
                    voice.removePeer(id);
                    if (hostTunnel != null) hostTunnel.onGuestLeft(id);
                    if (hostId != null && hostId == id) {
                        hostId = null;
                        if (guestTunnel != null) {
                            guestTunnel.setHostPong(null);
                            guestTunnel.resetSessions();
                        }
                    }
                    break;
                }
                case "mute":
                    synchronized (members) {
                        Member mem = members.get(m.getInt("id"));
                        if (mem != null) mem.muted = m.getBoolean("muted");
                    }
                    break;
                case "pong":
                    if (guestTunnel != null) guestTunnel.setHostPong(m.getString("data"));
                    break;
                case "error":
                    error = m.getString("message");
                    status = "Ошибка";
                    break;
            }
        } catch (Exception ignored) {
        }
    }

    private void addMember(JSONObject o) throws Exception {
        Member mem = new Member(o.getInt("id"), o.getString("name"), o.optBoolean("muted"), o.optBoolean("host"));
        members.put(mem.id, mem);
    }

    @Override
    public void onBinary(byte[] d) {
        if (d.length < 2) return;
        switch (d[0]) {
            case 0x01:
                if (d.length > 3) voice.onRemoteFrame(((d[1] & 0xff) << 8) | (d[2] & 0xff), d, 3);
                break;
            case 0x02:
                if (hostTunnel != null) hostTunnel.onGuestPacket(d);
                break;
            case 0x03:
                if (guestTunnel != null) guestTunnel.onHostPacket(d);
                break;
        }
    }

    // ------------------------------------------------------------ для экрана

    public int memberCount() {
        synchronized (members) {
            return members.size();
        }
    }

    public List<String> memberLines() {
        List<String> out = new ArrayList<>();
        out.add((isHost ? "👑 " : "• ") + name + " (ты)" + (voice.isMicOn() ? "" : " 🔇"));
        synchronized (members) {
            for (Member m : members.values()) {
                String talk = voice.isPeerTalking(m.id) ? " 🔊" : "";
                out.add((m.host ? "👑 " : "• ") + m.name + (m.muted ? " 🔇" : "") + talk);
            }
        }
        return out;
    }

    public String statusText() {
        StringBuilder b = new StringBuilder(status);
        if (error != null) b.append("\n⚠ ").append(error);
        if (relay != null && relay.isConnected()) {
            if (isHost) {
                String w = hostTunnel != null ? hostTunnel.getWorldInfo() : null;
                b.append("\nМир: ").append(w != null ? w : "не найден. Открой мир в Minecraft и включи «Видимый для игроков LAN».");
                if (hostTunnel != null && hostTunnel.getSessionCount() > 0)
                    b.append("\nПодключено к миру: ").append(hostTunnel.getSessionCount());
            } else if (guestTunnel != null) {
                String w = guestTunnel.getWorldInfo();
                if (hostId == null) b.append("\nХоста в комнате нет — доступен только голос.");
                else if (w == null) b.append("\nХост в комнате, но его мир не открыт.");
                else b.append("\nМир хоста: ").append(w).append("\nОткрой Minecraft → Играть → Друзья → LAN-игры.");
                if (guestTunnel.getPort() != RakNet.DEFAULT_PORT && guestTunnel.getPort() != 0)
                    b.append("\n⚠ Порт 19132 занят — закрой свой мир в Minecraft и перезапусти.");
            }
        }
        return b.toString();
    }

    // ------------------------------------------------------------ уведомление

    private void createChannel() {
        NotificationChannel ch = new NotificationChannel(CHANNEL, "MC Вместе", NotificationManager.IMPORTANCE_LOW);
        ch.setShowBadge(false);
        ((NotificationManager) getSystemService(NOTIFICATION_SERVICE)).createNotificationChannel(ch);
    }

    private String notificationText() {
        String mic = voice != null && voice.isMicOn() ? "микрофон включён" : "микрофон выключен";
        String conn = relay != null && relay.isConnected() ? "людей в комнате: " + (memberCount() + 1) : "нет связи";
        return mic + " · " + conn;
    }

    private Notification buildNotification() {
        int imm = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), imm);
        PendingIntent mic = PendingIntent.getService(this, 1,
                new Intent(this, TogetherService.class).setAction(ACTION_TOGGLE_MIC), imm);
        PendingIntent stop = PendingIntent.getService(this, 2,
                new Intent(this, TogetherService.class).setAction(ACTION_STOP), imm);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_stat_mic)
                .setContentTitle((isHost ? "Хост" : "Гость") + " · комната «" + room + "»")
                .setContentText(notificationText())
                .setContentIntent(open)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(null,
                        voice != null && voice.isMicOn() ? "Выключить микрофон" : "Включить микрофон", mic).build())
                .addAction(new Notification.Action.Builder(null, "Отключиться", stop).build())
                .build();
    }
}
