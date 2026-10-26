package com.nixsov.mctogether;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/** Минимум RakNet, нужный для LAN-обнаружения мира Minecraft Bedrock. */
public final class RakNet {
    public static final int DEFAULT_PORT = 19132;
    public static final byte ID_UNCONNECTED_PING = 0x01;
    public static final byte ID_UNCONNECTED_PING_OPEN = 0x02;
    public static final byte ID_UNCONNECTED_PONG = 0x1c;
    public static final byte[] MAGIC = {
            0x00, (byte) 0xff, (byte) 0xff, 0x00, (byte) 0xfe, (byte) 0xfe, (byte) 0xfe, (byte) 0xfe,
            (byte) 0xfd, (byte) 0xfd, (byte) 0xfd, (byte) 0xfd, 0x12, 0x34, 0x56, 0x78};

    private RakNet() {
    }

    public static boolean isPing(byte[] d, int len) {
        return len >= 25 && (d[0] == ID_UNCONNECTED_PING || d[0] == ID_UNCONNECTED_PING_OPEN);
    }

    public static byte[] buildPing(long clientGuid) {
        ByteBuffer b = ByteBuffer.allocate(33);
        b.put(ID_UNCONNECTED_PING).putLong(System.currentTimeMillis()).put(MAGIC).putLong(clientGuid);
        return b.array();
    }

    /** Строка «MCPE;motd;...» из ответа на пинг, либо null. */
    public static String pongMotd(byte[] pong, int len) {
        if (len < 35 || pong[0] != ID_UNCONNECTED_PONG) return null;
        int strLen = ((pong[33] & 0xff) << 8) | (pong[34] & 0xff);
        if (35 + strLen > len) return null;
        return new String(pong, 35, strLen, StandardCharsets.UTF_8);
    }

    /**
     * Ответ на LAN-пинг гостя, собранный из «визитки» мира хоста: время берётся
     * из пинга гостя, порты в описании заменяются на локальные порты гостя.
     */
    public static byte[] buildPongFor(byte[] ping, byte[] hostPong, int hostPongLen, int localPort, String tag) {
        String motd = pongMotd(hostPong, hostPongLen);
        if (motd == null) return null;
        String[] f = motd.split(";", -1);
        if (f.length >= 12) {
            f[10] = Integer.toString(localPort);
            f[11] = Integer.toString(localPort + 1);
        }
        if (tag != null && f.length >= 8 && !f[7].isEmpty()) f[7] = tag;
        byte[] str = String.join(";", f).getBytes(StandardCharsets.UTF_8);
        ByteBuffer b = ByteBuffer.allocate(35 + str.length);
        b.put(ID_UNCONNECTED_PONG);
        b.put(ping, 1, 8); // время из пинга
        b.put(hostPong, 9, 8); // GUID сервера
        b.put(MAGIC);
        b.putShort((short) str.length);
        b.put(str);
        return b.array();
    }

    /** Название мира и число игроков для показа в приложении. */
    public static String describe(byte[] pong, int len) {
        String motd = pongMotd(pong, len);
        if (motd == null) return null;
        String[] f = motd.split(";", -1);
        if (f.length < 6) return motd;
        String world = f.length > 7 && !f[7].isEmpty() ? f[7] : f[1];
        return world + " (" + f[4] + "/" + f[5] + ")";
    }
}
