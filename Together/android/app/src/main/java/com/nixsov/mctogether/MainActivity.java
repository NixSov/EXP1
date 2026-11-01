package com.nixsov.mctogether;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Typeface;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.RadioButton;
import android.widget.RadioGroup;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
    private static final int REQ_PERMS = 1;

    private SharedPreferences prefs;
    private static final String MINECRAFT = "com.mojang.minecraftpe";

    private EditText server, room, name, game;
    private RadioButton hostRadio, guestRadio, directRadio;
    private TextView gameLabel;
    private Button startBtn, serverBtn, launchBtn, micBtn, overlayBtn;
    private TextView status, people;
    private LinearLayout form;
    private final Handler handler = new Handler(Looper.getMainLooper());

    private final Runnable refresher = new Runnable() {
        @Override
        public void run() {
            refresh();
            handler.postDelayed(this, 500);
        }
    };

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences("main", MODE_PRIVATE);
        setContentView(buildUi());
    }

    @Override
    protected void onResume() {
        super.onResume();
        handler.post(refresher);
    }

    @Override
    protected void onPause() {
        super.onPause();
        handler.removeCallbacks(refresher);
    }

    // ------------------------------------------------------------ интерфейс

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    private TextView label(LinearLayout parent, String text, int sizeSp, boolean bold) {
        TextView t = new TextView(this);
        t.setText(text);
        t.setTextSize(sizeSp);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setPadding(0, dp(10), 0, dp(4));
        parent.addView(t);
        return t;
    }

    private EditText field(LinearLayout parent, String hint, String key, String def) {
        EditText e = new EditText(this);
        e.setHint(hint);
        e.setSingleLine(true);
        e.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS);
        e.setText(prefs.getString(key, def));
        parent.addView(e);
        return e;
    }

    private View buildUi() {
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(20), dp(20), dp(20), dp(32));
        scroll.addView(root);

        TextView title = label(root, "MC Вместе", 26, true);
        title.setGravity(Gravity.CENTER_HORIZONTAL);
        TextView sub = label(root, "Голосовой чат и игра в одном мире Minecraft без Xbox и Realms", 14, false);
        sub.setGravity(Gravity.CENTER_HORIZONTAL);

        form = new LinearLayout(this);
        form.setOrientation(LinearLayout.VERTICAL);
        root.addView(form);

        label(form, "Адрес сервера «MC Вместе» (голос и туннель)", 14, true);
        server = field(form, "например: mc-together.onrender.com", "server", "");
        label(form, "Код комнаты (одинаковый у всех друзей)", 14, true);
        room = field(form, "например: nixsov", "room", "");
        label(form, "Твой ник", 14, true);
        name = field(form, "ник", "name", Build.MODEL);

        label(form, "Роль", 14, true);
        RadioGroup roles = new RadioGroup(this);
        hostRadio = new RadioButton(this);
        hostRadio.setText("Хост — мир открыт на моём телефоне");
        hostRadio.setId(View.generateViewId());
        guestRadio = new RadioButton(this);
        guestRadio.setText("Гость — подключаюсь к миру друга");
        guestRadio.setId(View.generateViewId());
        directRadio = new RadioButton(this);
        directRadio.setText("Сервер по адресу — хостинг или чужой сервер, без входа в Xbox");
        directRadio.setId(View.generateViewId());
        roles.addView(hostRadio);
        roles.addView(guestRadio);
        roles.addView(directRadio);
        String role = prefs.getString("role", prefs.getBoolean("host", false) ? TogetherService.ROLE_HOST : TogetherService.ROLE_GUEST);
        (TogetherService.ROLE_HOST.equals(role) ? hostRadio : TogetherService.ROLE_DIRECT.equals(role) ? directRadio : guestRadio).setChecked(true);
        form.addView(roles);
        roles.setOnCheckedChangeListener((g, id) -> refresh());

        gameLabel = label(form, "Адрес игрового сервера (IP:порт)", 14, true);
        game = field(form, "например: myserver.freemchost.com:19132", "game", "");

        serverBtn = new Button(this);
        serverBtn.setText("▶ Запустить сервер и открыть Minecraft");
        serverBtn.setOnClickListener(v -> {
            hostRadio.setChecked(true);
            pendingLaunch = true;
            onStartStop();
        });
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, -2);
        lp.topMargin = dp(16);
        root.addView(serverBtn, lp);

        startBtn = new Button(this);
        startBtn.setOnClickListener(v -> onStartStop());
        root.addView(startBtn, new LinearLayout.LayoutParams(-1, -2));

        launchBtn = new Button(this);
        launchBtn.setText("Открыть Minecraft");
        launchBtn.setOnClickListener(v -> openMinecraft());
        root.addView(launchBtn, new LinearLayout.LayoutParams(-1, -2));

        micBtn = new Button(this);
        micBtn.setOnClickListener(v -> {
            TogetherService s = TogetherService.instance;
            if (s != null) s.toggleMic();
            refresh();
        });
        root.addView(micBtn, new LinearLayout.LayoutParams(-1, -2));

        overlayBtn = new Button(this);
        overlayBtn.setText("Разрешить кнопку поверх игры");
        overlayBtn.setOnClickListener(v -> startActivity(new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:" + getPackageName()))));
        root.addView(overlayBtn, new LinearLayout.LayoutParams(-1, -2));

        status = label(root, "", 15, false);
        label(root, "В комнате", 14, true);
        people = label(root, "", 15, false);

        label(root, "Как играть", 14, true);
        label(root,
                "Хост (сервер на твоём телефоне):\n"
                        + "1. Нажми «Запустить сервер и открыть Minecraft».\n"
                        + "2. Открой свой мир. В настройках мира включи «Многопользовательская игра» и «Видимый для игроков LAN».\n"
                        + "   Сервер работает, пока мир открыт.\n\n"
                        + "Гость:\n"
                        + "1. Выбери «Гость», введи тот же сервер и код комнаты, нажми «Подключиться».\n"
                        + "2. Открой Minecraft → Играть → Друзья. Мир хоста появится в разделе «LAN-игры».\n"
                        + "   Нужен включённый Wi-Fi (подойдёт любой, даже без связи с хостом).\n\n"
                        + "Сервер по адресу (например, бесплатный хостинг):\n"
                        + "1. Введи адрес игрового сервера. Сервер и комнату «MC Вместе» можно оставить — тогда будет и голосовой чат.\n"
                        + "2. Нажми «Подключиться», открой Minecraft → Друзья → LAN-игры.\n\n"
                        + "Кнопка с микрофоном поверх игры: нажатие — вкл/выкл микрофон, перетаскивание — переместить, "
                        + "долгое нажатие — открыть это приложение.\n"
                        + "Совет: играй в наушниках, иначе друзья будут слышать звуки игры.",
                14, false);
        return scroll;
    }

    private void refresh() {
        TogetherService s = TogetherService.instance;
        boolean running = s != null;
        startBtn.setText(running ? "Отключиться" : "Подключиться");
        serverBtn.setVisibility(running ? View.GONE : View.VISIBLE);
        launchBtn.setVisibility(running ? View.VISIBLE : View.GONE);
        boolean direct = directRadio.isChecked();
        gameLabel.setVisibility(direct ? View.VISIBLE : View.GONE);
        game.setVisibility(direct ? View.VISIBLE : View.GONE);
        form.setAlpha(running ? 0.5f : 1f);
        setEnabledDeep(form, !running);
        micBtn.setVisibility(running ? View.VISIBLE : View.GONE);
        if (running) micBtn.setText(s.isMicOn() ? "🎤 Микрофон включён — выключить" : "🔇 Микрофон выключен — включить");
        overlayBtn.setVisibility(OverlayButton.canShow(this) ? View.GONE : View.VISIBLE);
        if (running) {
            status.setText(s.statusText());
            StringBuilder b = new StringBuilder();
            for (String line : s.memberLines()) b.append(line).append('\n');
            people.setText(b.toString().trim());
        } else {
            status.setText("Не подключено");
            people.setText("—");
        }
    }

    private void setEnabledDeep(View v, boolean enabled) {
        v.setEnabled(enabled);
        if (v instanceof LinearLayout || v instanceof RadioGroup) {
            android.view.ViewGroup g = (android.view.ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) setEnabledDeep(g.getChildAt(i), enabled);
        }
    }

    // ------------------------------------------------------------ запуск

    private void onStartStop() {
        if (TogetherService.instance != null) {
            TogetherService.stop(this);
            handler.postDelayed(this::refresh, 300);
            return;
        }
        String srv = server.getText().toString().trim();
        String rm = room.getText().toString().trim();
        String nm = name.getText().toString().trim();
        String gm = game.getText().toString().trim();
        if (directRadio.isChecked()) {
            if (gm.isEmpty() || nm.isEmpty()) {
                Toast.makeText(this, "Заполни адрес игрового сервера и ник", Toast.LENGTH_LONG).show();
                pendingLaunch = false;
                return;
            }
        } else if (srv.isEmpty() || rm.isEmpty() || nm.isEmpty()) {
            Toast.makeText(this, "Заполни сервер, код комнаты и ник", Toast.LENGTH_LONG).show();
            pendingLaunch = false;
            return;
        }
        prefs.edit().putString("server", srv).putString("room", rm).putString("name", nm)
                .putString("game", gm).putString("role", currentRole()).apply();

        List<String> need = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            need.add(Manifest.permission.RECORD_AUDIO);
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            need.add(Manifest.permission.POST_NOTIFICATIONS);
        if (!need.isEmpty()) {
            requestPermissions(need.toArray(new String[0]), REQ_PERMS);
            return;
        }
        launch();
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        super.onRequestPermissionsResult(code, perms, results);
        if (code != REQ_PERMS) return;
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Toast.makeText(this, "Без доступа к микрофону голосовой чат не работает", Toast.LENGTH_LONG).show();
            pendingLaunch = false;
            return;
        }
        launch();
    }

    private void launch() {
        if (!OverlayButton.canShow(this)) {
            Toast.makeText(this, "Разреши показ поверх других приложений, чтобы кнопка микрофона была видна в игре",
                    Toast.LENGTH_LONG).show();
        }
        TogetherService.start(this, server.getText().toString().trim(), room.getText().toString().trim(),
                name.getText().toString().trim(), currentRole(), game.getText().toString().trim());
        handler.postDelayed(this::refresh, 300);
        if (pendingLaunch) {
            pendingLaunch = false;
            handler.postDelayed(this::openMinecraft, 800);
        }
    }

    private boolean pendingLaunch;

    private String currentRole() {
        if (hostRadio.isChecked()) return TogetherService.ROLE_HOST;
        if (directRadio.isChecked()) return TogetherService.ROLE_DIRECT;
        return TogetherService.ROLE_GUEST;
    }

    private void openMinecraft() {
        Intent i = getPackageManager().getLaunchIntentForPackage(MINECRAFT);
        if (i == null) {
            Toast.makeText(this, "Minecraft не найден на этом телефоне", Toast.LENGTH_LONG).show();
            return;
        }
        startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
    }
}
