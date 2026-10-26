package com.nixsov.mctogether;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.PixelFormat;
import android.graphics.RectF;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.WindowManager;

/**
 * Круглая кнопка микрофона поверх всех приложений (в том числе поверх Minecraft).
 * Нажатие — включить/выключить микрофон, перетаскивание — переместить,
 * долгое нажатие — открыть приложение.
 */
public class OverlayButton extends View {
    public interface Callbacks {
        void onToggleMic();
        void onOpenApp();
    }

    public static final int STATE_OFFLINE = 0;
    public static final int STATE_MIC_OFF = 1;
    public static final int STATE_MIC_ON = 2;

    private final WindowManager wm;
    private final WindowManager.LayoutParams lp;
    private final Callbacks callbacks;
    private final SharedPreferences prefs;
    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private final RectF rect = new RectF();
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final int size;
    private final int touchSlop;

    private int state = STATE_OFFLINE;
    private boolean speaking;
    private boolean othersTalking;
    private int people;
    private boolean attached;

    private float downX, downY;
    private int startX, startY;
    private boolean dragging, longPressed;
    private final Runnable longPress;

    public OverlayButton(Context ctx, Callbacks callbacks) {
        super(ctx);
        this.callbacks = callbacks;
        this.longPress = () -> {
            longPressed = true;
            performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS);
            callbacks.onOpenApp();
        };
        this.wm = (WindowManager) ctx.getSystemService(Context.WINDOW_SERVICE);
        this.prefs = ctx.getSharedPreferences("overlay", Context.MODE_PRIVATE);
        float d = ctx.getResources().getDisplayMetrics().density;
        size = Math.round(52 * d);
        touchSlop = ViewConfiguration.get(ctx).getScaledTouchSlop();
        lp = new WindowManager.LayoutParams(size, size,
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE | WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                PixelFormat.TRANSLUCENT);
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.x = prefs.getInt("x", Math.round(16 * d));
        lp.y = prefs.getInt("y", Math.round(140 * d));
    }

    public static boolean canShow(Context ctx) {
        return Settings.canDrawOverlays(ctx);
    }

    public void show() {
        if (attached || !canShow(getContext())) return;
        try {
            wm.addView(this, lp);
            attached = true;
        } catch (Exception ignored) {
        }
    }

    public void hide() {
        if (!attached) return;
        try {
            wm.removeView(this);
        } catch (Exception ignored) {
        }
        attached = false;
    }

    public void update(int state, boolean speaking, boolean othersTalking, int people) {
        if (this.state == state && this.speaking == speaking && this.othersTalking == othersTalking && this.people == people) return;
        this.state = state;
        this.speaking = speaking;
        this.othersTalking = othersTalking;
        this.people = people;
        invalidate();
    }

    @Override
    protected void onDraw(Canvas c) {
        float w = getWidth(), h = getHeight();
        float cx = w / 2f, cy = h / 2f, r = Math.min(w, h) / 2f;

        // кольцо: кто-то говорит
        if (speaking || othersTalking) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(speaking ? 0x8800FF66 : 0x8833AAFF);
            c.drawCircle(cx, cy, r, paint);
        }
        int bg;
        switch (state) {
            case STATE_MIC_ON: bg = 0xEE1E9E4A; break;
            case STATE_MIC_OFF: bg = 0xEEC62828; break;
            default: bg = 0xCC555555;
        }
        paint.setStyle(Paint.Style.FILL);
        paint.setColor(bg);
        c.drawCircle(cx, cy, r * 0.82f, paint);

        // значок микрофона
        paint.setColor(Color.WHITE);
        float mw = r * 0.26f, mh = r * 0.5f;
        rect.set(cx - mw / 2, cy - mh * 0.75f, cx + mw / 2, cy + mh * 0.25f);
        c.drawRoundRect(rect, mw / 2, mw / 2, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(r * 0.07f);
        rect.set(cx - mw * 0.95f, cy - mh * 0.35f, cx + mw * 0.95f, cy + mh * 0.45f);
        c.drawArc(rect, 0, 180, false, paint);
        c.drawLine(cx, cy + mh * 0.45f, cx, cy + mh * 0.62f, paint);

        if (state != STATE_MIC_ON) {
            // перечёркнут
            paint.setStrokeWidth(r * 0.09f);
            c.drawLine(cx - r * 0.38f, cy - r * 0.38f, cx + r * 0.38f, cy + r * 0.38f, paint);
        }

        // число людей в комнате
        if (people > 0) {
            paint.setStyle(Paint.Style.FILL);
            paint.setColor(0xFF222222);
            float br = r * 0.3f;
            c.drawCircle(w - br, h - br, br, paint);
            paint.setColor(Color.WHITE);
            paint.setTextSize(br * 1.3f);
            paint.setTextAlign(Paint.Align.CENTER);
            c.drawText(String.valueOf(people), w - br, h - br + br * 0.45f, paint);
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    @Override
    public boolean onTouchEvent(MotionEvent e) {
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = e.getRawX();
                downY = e.getRawY();
                startX = lp.x;
                startY = lp.y;
                dragging = false;
                longPressed = false;
                handler.postDelayed(longPress, 700);
                return true;
            case MotionEvent.ACTION_MOVE: {
                float dx = e.getRawX() - downX, dy = e.getRawY() - downY;
                if (!dragging && Math.hypot(dx, dy) > touchSlop) {
                    dragging = true;
                    handler.removeCallbacks(longPress);
                }
                if (dragging) {
                    lp.x = startX + Math.round(dx);
                    lp.y = startY + Math.round(dy);
                    if (attached) wm.updateViewLayout(this, lp);
                }
                return true;
            }
            case MotionEvent.ACTION_UP:
                handler.removeCallbacks(longPress);
                if (dragging) {
                    prefs.edit().putInt("x", lp.x).putInt("y", lp.y).apply();
                } else if (!longPressed) {
                    performHapticFeedback(android.view.HapticFeedbackConstants.VIRTUAL_KEY);
                    callbacks.onToggleMic();
                }
                return true;
            case MotionEvent.ACTION_CANCEL:
                handler.removeCallbacks(longPress);
                return true;
        }
        return false;
    }
}
