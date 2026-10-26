package com.nixsov.mctogether;

import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.SocketTimeoutException;
import java.util.Iterator;
import java.util.Map;
import java.util.Random;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Сторона хоста: пересылает пакеты гостей в мир Minecraft на этом телефоне
 * (127.0.0.1:19132) и ответы мира обратно гостям.
 */
public class HostTunnel {
    private static final String TAG = "HostTunnel";
    private static final long SESSION_IDLE_MS = 60_000;

    private final RelayClient relay;
    private final InetAddress local;
    private final int worldPort;
    private volatile boolean running;
    private volatile String worldInfo; // null — мир не найден
    private Thread pingThread;
    private final Map<Integer, Session> sessions = new ConcurrentHashMap<>();

    private class Session {
        final int guestId, sid;
        final DatagramSocket socket;
        volatile long lastActive = System.currentTimeMillis();

        Session(int guestId, int sid) throws Exception {
            this.guestId = guestId;
            this.sid = sid;
            socket = new DatagramSocket();
            socket.connect(local, worldPort);
            Thread t = new Thread(this::readLoop, "host-session-" + guestId + "-" + sid);
            t.setDaemon(true);
            t.start();
        }

        void readLoop() {
            byte[] buf = new byte[2048];
            byte[] out = new byte[buf.length + 5];
            DatagramPacket p = new DatagramPacket(buf, buf.length);
            while (running && !socket.isClosed()) {
                try {
                    socket.receive(p);
                } catch (Exception e) {
                    break;
                }
                lastActive = System.currentTimeMillis();
                int n = p.getLength();
                out[0] = 0x03;
                out[1] = (byte) (guestId >> 8);
                out[2] = (byte) guestId;
                out[3] = (byte) (sid >> 8);
                out[4] = (byte) sid;
                System.arraycopy(buf, 0, out, 5, n);
                relay.sendBinary(out, n + 5, false);
            }
        }

        void send(byte[] data, int off, int len) {
            lastActive = System.currentTimeMillis();
            try {
                socket.send(new DatagramPacket(data, off, len));
            } catch (Exception e) {
                Log.w(TAG, "send", e);
            }
        }

        void close() {
            socket.close();
        }
    }

    public HostTunnel(RelayClient relay) throws Exception {
        this.relay = relay;
        this.local = InetAddress.getByName("127.0.0.1");
        this.worldPort = RakNet.DEFAULT_PORT;
    }

    public String getWorldInfo() {
        return worldInfo;
    }

    public int getSessionCount() {
        return sessions.size();
    }

    public void start() {
        running = true;
        pingThread = new Thread(this::pingLoop, "host-ping");
        pingThread.start();
    }

    public void stop() {
        running = false;
        if (pingThread != null) pingThread.interrupt();
        for (Session s : sessions.values()) s.close();
        sessions.clear();
    }

    /** Пакет от гостя: [02][guest u16][sid u16][udp]. */
    public void onGuestPacket(byte[] d) {
        if (d.length < 6) return;
        int guestId = ((d[1] & 0xff) << 8) | (d[2] & 0xff);
        int sid = ((d[3] & 0xff) << 8) | (d[4] & 0xff);
        int key = (guestId << 16) | sid;
        Session s = sessions.get(key);
        if (s == null) {
            try {
                s = new Session(guestId, sid);
                sessions.put(key, s);
            } catch (Exception e) {
                Log.w(TAG, "session", e);
                return;
            }
        }
        s.send(d, 5, d.length - 5);
    }

    public void onGuestLeft(int guestId) {
        for (Iterator<Map.Entry<Integer, Session>> it = sessions.entrySet().iterator(); it.hasNext(); ) {
            Session s = it.next().getValue();
            if (s.guestId == guestId) {
                s.close();
                it.remove();
            }
        }
    }

    /** Раз в 2 секунды спрашиваем мир о себе и рассылаем «визитку» гостям. */
    private void pingLoop() {
        long guid = new Random().nextLong();
        String lastSent = null;
        long lastSentAt = 0;
        try (DatagramSocket s = new DatagramSocket()) {
            s.setSoTimeout(1000);
            byte[] buf = new byte[2048];
            while (running) {
                try {
                    byte[] ping = RakNet.buildPing(guid);
                    s.send(new DatagramPacket(ping, ping.length, local, worldPort));
                    DatagramPacket p = new DatagramPacket(buf, buf.length);
                    s.receive(p);
                    if (RakNet.pongMotd(buf, p.getLength()) != null) {
                        worldInfo = RakNet.describe(buf, p.getLength());
                        String b64 = Base64.encodeToString(buf, 0, p.getLength(), Base64.NO_WRAP);
                        long now = System.currentTimeMillis();
                        if (!b64.equals(lastSent) || now - lastSentAt > 10_000) {
                            relay.sendJson(new JSONObject().put("t", "pong").put("data", b64));
                            lastSent = b64;
                            lastSentAt = now;
                        }
                    }
                } catch (SocketTimeoutException e) {
                    worldInfo = null;
                } catch (Exception e) {
                    worldInfo = null;
                    Log.w(TAG, "ping", e);
                }
                cleanup();
                try {
                    Thread.sleep(2000);
                } catch (InterruptedException e) {
                    break;
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "ping socket", e);
        }
    }

    private void cleanup() {
        long now = System.currentTimeMillis();
        for (Iterator<Map.Entry<Integer, Session>> it = sessions.entrySet().iterator(); it.hasNext(); ) {
            Session s = it.next().getValue();
            if (now - s.lastActive > SESSION_IDLE_MS) {
                s.close();
                it.remove();
            }
        }
    }
}
