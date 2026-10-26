package com.nixsov.mctogether;

/** G.711 μ-law: 16-битный звук в 8 бит и обратно. */
public final class ULaw {
    private static final int BIAS = 0x84;
    private static final int CLIP = 32635;
    private static final short[] DECODE = new short[256];

    static {
        for (int i = 0; i < 256; i++) {
            int u = ~i & 0xff;
            int sign = u & 0x80;
            int exponent = (u >> 4) & 0x07;
            int mantissa = u & 0x0f;
            int sample = (((mantissa << 3) + BIAS) << exponent) - BIAS;
            DECODE[i] = (short) (sign != 0 ? -sample : sample);
        }
    }

    private ULaw() {
    }

    public static byte encode(short pcm) {
        int sample = pcm;
        int sign = (sample >> 8) & 0x80;
        if (sign != 0) sample = -sample;
        if (sample > CLIP) sample = CLIP;
        sample += BIAS;
        int exponent = 7;
        for (int mask = 0x4000; (sample & mask) == 0 && exponent > 0; mask >>= 1) exponent--;
        int mantissa = (sample >> (exponent + 3)) & 0x0f;
        return (byte) ~(sign | (exponent << 4) | mantissa);
    }

    public static short decode(byte b) {
        return DECODE[b & 0xff];
    }
}
