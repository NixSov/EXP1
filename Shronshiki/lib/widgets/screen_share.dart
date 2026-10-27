import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/call_controller.dart';

/// Окно выбора: какой экран или окно показывать и в каком качестве.
Future<({DesktopCapturerSource source, ScreenQuality quality})?> pickScreenSource(
  BuildContext context,
  CallController call,
) {
  return showDialog(
    context: context,
    builder: (context) => _SourcePicker(call: call),
  );
}

class _SourcePicker extends StatefulWidget {
  const _SourcePicker({required this.call});

  final CallController call;

  @override
  State<_SourcePicker> createState() => _SourcePickerState();
}

class _SourcePickerState extends State<_SourcePicker> {
  List<DesktopCapturerSource>? _sources;
  String? _error;
  DesktopCapturerSource? _selected;
  ScreenQuality _quality = ScreenQuality.economy;
  final List<StreamSubscription<Object>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final sources = await widget.call.screenSources();
      if (!mounted) return;
      // Миниатюры приходят не сразу — обновляем картинки по мере готовности.
      for (final s in sources) {
        _subscriptions.add(s.onThumbnailChanged.stream.listen((_) {
          if (mounted) setState(() {});
        }));
      }
      setState(() {
        _sources = [
          ...sources.where((s) => s.type == SourceType.Screen),
          ...sources.where((s) => s.type == SourceType.Window && s.name.trim().isNotEmpty),
        ];
        _selected = _sources!.firstOrNull;
      });
    } catch (e) {
      if (mounted) setState(() => _error = 'Не удалось получить список экранов: $e');
    }
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final turn = widget.call.turnPeers;
    final screens = sources?.where((s) => s.type == SourceType.Screen).length ?? 0;
    return AlertDialog(
      title: const Text('Показать экран'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: _error != null
                  ? Text(_error!)
                  : sources == null
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : GridView.count(
                          shrinkWrap: true,
                          crossAxisCount: 2,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 1.35,
                          children: [
                            for (final (i, s) in sources.indexed)
                              _SourceTile(
                                source: s,
                                title: s.type == SourceType.Screen
                                    ? (screens > 1 ? 'Весь экран ${i + 1}' : 'Весь экран')
                                    : s.name,
                                selected: s == _selected,
                                onTap: () => setState(() => _selected = s),
                              ),
                          ],
                        ),
            ),
            const SizedBox(height: 16),
            SegmentedButton<ScreenQuality>(
              segments: [
                for (final q in ScreenQuality.values)
                  ButtonSegment(value: q, label: Text(q.label)),
              ],
              selected: {_quality},
              onSelectionChanged: (v) => setState(() => _quality = v.first),
            ),
            const SizedBox(height: 6),
            Text(_quality.hint, style: Theme.of(context).textTheme.bodySmall),
            if (turn > 0) ...[
              const SizedBox(height: 10),
              Text(
                'С $turn ${turn == 1 ? 'участником' : 'участниками'} связь идёт через TURN. '
                'Демонстрация расходует его трафик (у бесплатного TURN — 500 МБ в месяц).',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 6),
            Text('Звук компьютера не передаётся — только картинка.',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () => Navigator.pop(context, (source: _selected!, quality: _quality)),
          child: const Text('Показать'),
        ),
      ],
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final DesktopCapturerSource source;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final thumbnail = source.thumbnail;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: Column(
          children: [
            Expanded(
              child: thumbnail != null && thumbnail.isNotEmpty
                  ? Image.memory(thumbnail, fit: BoxFit.contain, gaplessPlayback: true)
                  : Icon(
                      source.type == SourceType.Screen ? Icons.monitor : Icons.web_asset,
                      size: 40,
                    ),
            ),
            const SizedBox(height: 4),
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }
}

/// Демонстрация экрана другого участника. Нажатие — на весь экран.
class ScreenView extends StatefulWidget {
  const ScreenView({super.key, required this.call, required this.sharer});

  final CallController call;
  final Participant sharer;

  @override
  State<ScreenView> createState() => _ScreenViewState();
}

class _ScreenViewState extends State<ScreenView> {
  final _renderer = RTCVideoRenderer();
  bool _ready = false;
  MediaStream? _shown;

  @override
  void initState() {
    super.initState();
    _renderer.initialize().then((_) {
      if (!mounted) return;
      _ready = true;
      _attach();
    });
    _renderer.onFirstFrameRendered = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void didUpdateWidget(ScreenView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _attach();
  }

  void _attach() {
    if (!_ready) return;
    final screen = widget.call.screenOf(widget.sharer.peerId);
    if (screen == null || identical(screen.stream, _shown)) {
      if (mounted) setState(() {});
      return;
    }
    _shown = screen.stream;
    _renderer.setSrcObject(stream: screen.stream, trackId: screen.trackId).catchError((Object e) {
      debugPrint('screen renderer failed: $e');
    });
    setState(() {});
  }

  @override
  void dispose() {
    _renderer.srcObject = null;
    _renderer.dispose();
    super.dispose();
  }

  void _openFull() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _FullScreenView(
        renderer: _renderer,
        call: widget.call,
        sharer: widget.sharer,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasStream = widget.call.screenOf(widget.sharer.peerId) != null;
    final hasPicture = _renderer.value.width > 0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_ready && hasStream) RTCVideoView(_renderer),
            Positioned.fill(
              child: GestureDetector(behavior: HitTestBehavior.translucent, onDoubleTap: _openFull),
            ),
            if (!hasPicture)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    hasStream
                        ? 'Ждём картинку от ${widget.sharer.name}…'
                        : 'Картинка не пришла. Если долго нет — нажмите «Обновить».',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ),
            Positioned(
              left: 8,
              top: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Text(
                    'Экран: ${widget.sharer.name}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 4,
              bottom: 4,
              child: IconButton.filledTonal(
                tooltip: 'Во весь экран',
                onPressed: _openFull,
                icon: const Icon(Icons.fullscreen),
                style: IconButton.styleFrom(backgroundColor: scheme.surface.withValues(alpha: 0.7)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Полноэкранный просмотр с приближением (два пальца или колесо мыши).
class _FullScreenView extends StatefulWidget {
  const _FullScreenView({required this.renderer, required this.call, required this.sharer});

  final RTCVideoRenderer renderer;
  final CallController call;
  final Participant sharer;

  @override
  State<_FullScreenView> createState() => _FullScreenViewState();
}

class _FullScreenViewState extends State<_FullScreenView> {
  bool _landscape = false;

  /// Экран компьютера широкий — на телефоне удобнее смотреть боком.
  void _rotate() {
    setState(() => _landscape = !_landscape);
    SystemChrome.setPreferredOrientations(_landscape
        ? const [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : const []);
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    widget.call.addListener(_onCall);
  }

  /// Показ закончился или звонок завершён — закрываем.
  void _onCall() {
    if (!mounted) return;
    if (widget.call.screenSharer?.peerId != widget.sharer.peerId) {
      widget.call.removeListener(_onCall);
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    widget.call.removeListener(_onCall);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    if (_landscape) SystemChrome.setPreferredOrientations(const []);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // StackFit.expand: иначе размер задаёт полоса с кнопками и видео сжимается в неё.
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: InteractiveViewer(
              maxScale: 6,
              child: RTCVideoView(widget.renderer),
            ),
          ),
          Align(
            alignment: Alignment.topLeft,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton.filledTonal(
                      tooltip: 'Свернуть',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.fullscreen_exit),
                    ),
                    if (Platform.isAndroid || Platform.isIOS) ...[
                      const SizedBox(width: 8),
                      IconButton.filledTonal(
                        tooltip: _landscape ? 'Вертикально' : 'Повернуть боком',
                        onPressed: _rotate,
                        icon: const Icon(Icons.screen_rotation),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Text('Экран: ${widget.sharer.name}', style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
