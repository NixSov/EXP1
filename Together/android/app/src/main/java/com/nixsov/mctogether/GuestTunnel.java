package com.nixsov.mctogether;

import android.util.Base64;
import android.util.Log;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Сторона гостя: притворяется LAN-миром на этом телефоне. Minecraft видит мир
 * хоста во вкладке «Друзья → LAN-игры», а все пакеты уходят через сервер к хосту.
 */
public class GuestTunnel {
    private static final String TAG = "GuestTunnel";

    private final RelayClient relay;
    private volatile boolean running;
    private DatagramSocket socket;
    private int port;
    private Thread thread;
    private volatile byte[] hostPong;

    private final Map<String, Integer> sidByAddr = new ConcurrentHashMap<>();
    private final Map<Integer, SocketAddress> addrBySid = new ConcurrentHashMap<>();
    private int nextSid = 1;

    public GuestTunnel(RelayClient relay) {
        this.relay = relay;
    }

    /** Порт, на котором «висит» мир (0 — не удалось открыть). */
    public int getPort() {
        return port;
    }

    public boolean hasWorld() {
        return hostPong != null;
    }

    public String getWorldInfo() {
        byte[] p = hostPong;
        return p == null ? null : RakNet.describe(p, p.length);
    }

    public int getSessionCount() {
        return addrBySid.size();
    }

    public void setHostPong(String base64) {
        if (base64 == null) {
            hostPong = null;
            return;
        }
        try {
            hostPong = Base64.decode(base64, Base64.DEFAULT);
        } catch (Exception e) {
            hostPong = null;
        }
    }

    public void start() throws Exception {
        socket = new DatagramSocket(null);
        socket.setReuseAddress(true);
        socket.setBroadcast(true);
        try {
            socket.bind(new InetSocketAddress(RakNet.DEFAULT_PORT));
        } catch (Exception e) {
            // порт занят (например, открыт свой мир) — пробуем соседний
            socket.close();
            socket = new DatagramSocket(null);
            socket.setReuseAddress(true);
            socket.setBroadcast(true);
            socket.bind(new InetSocketAddress(RakNet.DEFAULT_PORT + 2));
        }
        port = socket.getLocalPort();
        running = true;
        thread = new Thread(this::loop, "guest-tunnel");
        thread.start();
    }

    public void stop() {
        running = false;
        if (socket != null) socket.close();
        sidByAddr.clear();
        addrBySid.clear();
    }

    private void loop() {
        byte[] buf = new byte[2048];
        byte[] out = new byte[buf.length + 3];
        DatagramPacket p = new DatagramPacket(buf, buf.length);
        while (running) {
            try {
                p.setLength(buf.length);
                socket.receive(p);
            } catch (Exception e) {
                if (running) Log.w(TAG, "receive", e);
                break;
            }
            int n = p.getLength();
            if (RakNet.isPing(buf, n)) {
                byte[] hp = hostPong;
                if (hp == null) continue; // мир хоста не открыт — молчим
                byte[] pong = RakNet.buildPongFor(buf, hp, hp.length, port, null);
                if (pong == null) continue;
                try {
                    socket.send(new DatagramPacket(pong, pong.length, p.getSocketAddress()));
                } catch (Exception e) {
                    Log.w(TAG, "pong", e);
                }
                continue;
            }
            SocketAddress from = p.getSocketAddress();
            String key = from.toString();
            Integer sid = sidByAddr.get(key);
            if (sid == null) {
                sid = nextSid;
                nextSid = nextSid % 65000 + 1;
                sidByAddr.put(key, sid);
                addrBySid.put(sid, from);
            }
            out[0] = 0x02;
            out[1] = (byte) (sid >> 8);
            out[2] = (byte) (int) sid;
            System.arraycopy(buf, 0, out, 3, n);
            relay.sendBinary(out, n + 3, false);
        }
    }

    /** Ответ мира хоста: [03][sid u16][udp]. */
    public void onHostPacket(byte[] d) {
        if (d.length < 4 || socket == null) return;
        int sid = ((d[1] & 0xff) << 8) | (d[2] & 0xff);
        SocketAddress to = addrBySid.get(sid);
        if (to == null) return;
        try {
            socket.send(new DatagramPacket(d, 3, d.length - 3, to));
        } catch (Exception e) {
            Log.w(TAG, "send", e);
        }
    }

    /** Хост ушёл — старые сессии больше не нужны. */
    public void resetSessions() {
        sidByAddr.clear();
        addrBySid.clear();
    }
}
