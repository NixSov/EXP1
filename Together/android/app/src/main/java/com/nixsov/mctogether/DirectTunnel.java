package com.nixsov.mctogether;

import android.util.Log;

import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.SocketAddress;
import java.util.Iterator;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Режим «Сервер по адресу»: показывает любой сервер Bedrock (например, на бесплатном
 * хостинге) как LAN-игру на этом телефоне. Пакеты идут напрямую по UDP, без ретранслятора,
 * поэтому входить в Xbox для вкладки «Серверы» не нужно.
 */
public class DirectTunnel {
    private static final String TAG = "DirectTunnel";
    private static final long IDLE_MS = 60_000;

    private final String host;
    private final int remotePort;
    private volatile InetSocketAddress remote;
    private DatagramSocket socket;
    private int port;
    private volatile boolean running;
    private volatile String worldInfo;
    private volatile long lastPong;
    private final Map<String, Upstream> upstreams = new ConcurrentHashMap<>();

    /** Отдельный сокет к серверу для каждого клиента Minecraft на телефоне. */
    private class Upstream {
        final SocketAddress client;
        final DatagramSocket up;
        volatile long lastActive = System.currentTimeMillis();

        Upstream(SocketAddress client) throws Exception {
            this.client = client;
            up = new DatagramSocket();
            up.connect(remote);
            Thread t = new Thread(this::readLoop, "direct-up");
            t.setDaemon(true);
            t.start();
        }

        void readLoop() {
            byte[] buf = new byte[2048];
            DatagramPacket p = new DatagramPacket(buf, buf.length);
            while (running && !up.isClosed()) {
                try {
                    p.setLength(buf.length);
                    up.receive(p);
                    lastActive = System.currentTimeMillis();
                    socket.send(new DatagramPacket(buf, p.getLength(), client));
                } catch (Exception e) {
                    break;
                }
            }
        }

        void send(byte[] d, int len) {
            lastActive = System.currentTimeMillis();
            try {
                up.send(new DatagramPacket(d, len));
            } catch (Exception e) {
                Log.w(TAG, "up send", e);
            }
        }
    }

    /** address: «example.net:19132» или «1.2.3.4» (порт по умолчанию 19132). */
    public DirectTunnel(String address) {
        String a = address.trim();
        int colon = a.lastIndexOf(':');
        int p = RakNet.DEFAULT_PORT;
        if (colon > 0 && a.indexOf(':') == colon) {
            try {
                p = Integer.parseInt(a.substring(colon + 1));
                a = a.substring(0, colon);
            } catch (NumberFormatException ignored) {
            }
        }
        host = a;
        remotePort = p;
    }

    public int getPort() {
        return port;
    }

    public String getWorldInfo() {
        return System.currentTimeMillis() - lastPong < 10_000 ? worldInfo : null;
    }

    public int getSessionCount() {
        return upstreams.size();
    }

    public String getTarget() {
        return host + ":" + remotePort;
    }

    public void start() throws Exception {
        socket = new DatagramSocket(null);
        socket.setReuseAddress(true);
        socket.setBroadcast(true);
        try {
            socket.bind(new InetSocketAddress(RakNet.DEFAULT_PORT));
        } catch (Exception e) {
            socket.close();
            socket = new DatagramSocket(null);
            socket.setReuseAddress(true);
            socket.setBroadcast(true);
            socket.bind(new InetSocketAddress(RakNet.DEFAULT_PORT + 2));
        }
        port = socket.getLocalPort();
        running = true;
        new Thread(this::localLoop, "direct-local").start();
        new Thread(this::pingLoop, "direct-ping").start();
    }

    public void stop() {
        running = false;
        if (socket != null) socket.close();
        for (Upstream u : upstreams.values()) u.up.close();
        upstreams.clear();
    }

    private InetSocketAddress resolve() {
        try {
            InetSocketAddress r = new InetSocketAddress(InetAddress.getByName(host), remotePort);
            remote = r;
            return r;
        } catch (Exception e) {
            return remote;
        }
    }

    private volatile byte[] lastServerPong;

    /** Раз в 3 секунды пингуем сервер: узнаём название и онлайн, держим ответ для LAN-пингов. */
    private void pingLoop() {
        long guid = new java.util.Random().nextLong();
        try (DatagramSocket s = new DatagramSocket()) {
            s.setSoTimeout(2000);
            byte[] buf = new byte[2048];
            while (running) {
                InetSocketAddress r = resolve();
                if (r != null) {
                    try {
                        byte[] ping = RakNet.buildPing(guid);
                        s.send(new DatagramPacket(ping, ping.length, r));
                        DatagramPacket p = new DatagramPacket(buf, buf.length);
                        s.receive(p);
                        if (RakNet.pongMotd(buf, p.getLength()) != null) {
                            byte[] copy = new byte[p.getLength()];
                            System.arraycopy(buf, 0, copy, 0, copy.length);
                            lastServerPong = copy;
                            worldInfo = RakNet.describe(copy, copy.length);
                            lastPong = System.currentTimeMillis();
                        }
                    } catch (Exception ignored) {
                    }
                }
                cleanup();
                try {
                    Thread.sleep(3000);
                } catch (InterruptedException e) {
                    break;
                }
            }
        } catch (Exception e) {
            Log.e(TAG, "ping", e);
        }
    }

    private void localLoop() {
        byte[] buf = new byte[2048];
        DatagramPacket p = new DatagramPacket(buf, buf.length);
        while (running) {
            try {
                p.setLength(buf.length);
                socket.receive(p);
            } catch (Exception e) {
                break;
            }
            int n = p.getLength();
            if (RakNet.isPing(buf, n)) {
                byte[] sp = lastServerPong;
                if (sp == null) continue;
                byte[] pong = RakNet.buildPongFor(buf, sp, sp.length, port, null);
                if (pong == null) continue;
                try {
                    socket.send(new DatagramPacket(pong, pong.length, p.getSocketAddress()));
                } catch (Exception ignored) {
                }
                continue;
            }
            if (remote == null) continue;
            SocketAddress from = p.getSocketAddress();
            String key = from.toString();
            Upstream u = upstreams.get(key);
            if (u == null) {
                try {
                    u = new Upstream(from);
                    upstreams.put(key, u);
                } catch (Exception e) {
                    Log.w(TAG, "upstream", e);
                    continue;
                }
            }
            u.send(buf, n);
        }
    }

    private void cleanup() {
        long now = System.currentTimeMillis();
        for (Iterator<Map.Entry<String, Upstream>> it = upstreams.entrySet().iterator(); it.hasNext(); ) {
            Upstream u = it.next().getValue();
            if (now - u.lastActive > IDLE_MS) {
                u.up.close();
                it.remove();
            }
        }
    }
}
