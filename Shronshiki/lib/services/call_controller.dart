import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'rooms.dart';
import 'settings.dart';
import 'signaling.dart';

enum CallStatus { connecting, inRoom, full, failed, ended }

/// Участник комнаты (в том числе я сам).
class Participant {
  Participant({
    required this.peerId,
    required this.name,
    required this.joinedAt,
    this.isLocal = false,
  });

  final String peerId;
  final bool isLocal;
  String name;
  int joinedAt;
  bool muted = false;
  bool speaking = false;

  /// Состояние P2P-соединения с этим участником.
  RTCPeerConnectionState? connection;

  bool get connected =>
      isLocal || connection == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
}

/// Устройство ввода или вывода звука.
class AudioDevice {
  const AudioDevice({required this.id, required this.label, required this.icon});

  final String id;
  final String label;

  /// speaker, earpiece, headset, bluetooth, mic
  final String icon;
}

class _Peer {
  _Peer(this.pc, this.initiator);

  final RTCPeerConnection pc;
  final bool initiator;
  final List<RTCIceCandidate> pendingCandidates = [];
  bool remoteDescriptionSet = false;
  Timer? restartTimer;
}

/// Голосовой звонок в комнате: mesh из P2P-соединений. Сигналинг и список
/// участников — через короткие запросы к базе ([RoomSignaling]), потому что
/// WebSocket к Supabase у части российских провайдеров не работает.
class CallController extends ChangeNotifier {
  CallController({
    required this.room,
    required this.displayName,
    required this.config,
    required this.settings,
    SupabaseClient? client,
  })  : _db = client ?? Supabase.instance.client,
        peerId = _randomId();

  final Room room;
  final String displayName;
  final AppConfig config;
  final AudioSettings settings;
  final SupabaseClient _db;

  /// Уникальный идентификатор этого подключения (один аккаунт может зайти с двух устройств).
  final String peerId;

  CallStatus status = CallStatus.connecting;
  String? errorMessage;
  bool muted = false;

  List<AudioDevice> inputs = const [];
  List<AudioDevice> outputs = const [];
  String? inputId;
  String? outputId;
  bool _inputChosenByUser = false;

  /// Чат комнаты (последние сообщения) и сколько из них ещё не прочитано.
  final List<ChatMessage> chat = [];
  int unreadChat = 0;
  bool _chatOpen = false;

  bool get chatOpen => _chatOpen;

  /// Сервер поддерживает чат (выполнена миграция room_chat).
  bool get chatSupported => _signaling?.chatSupported ?? true;
  set chatOpen(bool value) {
    _chatOpen = value;
    if (value && unreadChat != 0) {
      unreadChat = 0;
      notifyListeners();
    }
  }

  static const _chatLimit = 200;
  Set<String> _presentIds = {};

  final Map<String, Participant> _participants = {};
  final Map<String, _Peer> _peers = {};
  RoomSignaling? _signaling;
  MediaStream? _localStream;
  Timer? _statsTimer;
  Timer? _pollTimer;
  DateTime? _connectStarted;
  DateTime? _lastServerContact;
  Object? _lastServerError;
  bool _pollInFlight = false;
  bool _pollAgain = false;

  /// Сколько пытаемся войти в комнату, прежде чем показать ошибку.
  static const _connectLimit = Duration(seconds: 30);

  /// Как часто опрашиваем сервер: чаще, пока соединения устанавливаются.
  static const _fastPoll = Duration(milliseconds: 1000);
  static const _slowPoll = Duration(milliseconds: 2000);

  /// Нет ответа от сервера дольше этого — показываем предупреждение.
  static const _serverLostAfter = Duration(seconds: 8);
  bool _disposed = false;
  bool _reconnecting = false;
  int? _joinedAtValue;
  int get _joinedAt => _joinedAtValue!;
  DateTime? _admittedAt;

  static const _speakingThreshold = 0.02;

  /// Участники по порядку входа, я — первым.
  List<Participant> get participants {
    final list = _participants.values.toList()
      ..sort((a, b) {
        if (a.isLocal != b.isLocal) return a.isLocal ? -1 : 1;
        final t = a.joinedAt.compareTo(b.joinedAt);
        return t != 0 ? t : a.peerId.compareTo(b.peerId);
      });
    return list;
  }

  static String _randomId() {
    final r = Random.secure();
    return List.generate(16, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static bool get _isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get _isAndroid => !kIsWeb && Platform.isAndroid;

  bool get canSwitchSpeaker => _isMobile;

  bool get speakerOn => outputId == 'speaker';

  /// Звонок идёт или подключается.
  bool get isActive => status == CallStatus.connecting || status == CallStatus.inRoom;

  /// Сервер давно не отвечает. Звук при этом идёт напрямую и может продолжаться.
  bool get serverLost =>
      status == CallStatus.inRoom &&
      _lastServerContact != null &&
      DateTime.now().difference(_lastServerContact!) > _serverLostAfter;

  // ---------------------------------------------------------------------------
  // Вход и выход
  // ---------------------------------------------------------------------------

  Future<void> start() async {
    if (_localStream == null) {
      try {
        _localStream = await navigator.mediaDevices.getUserMedia({
          'audio': settings.audioConstraints(),
          'video': false,
        });
      } catch (e) {
        _fail('Нет доступа к микрофону. Разрешите его приложению в настройках телефона.\n($e)');
        return;
      }
      if (_disposed) return;
      for (final track in _localStream!.getAudioTracks()) {
        track.enabled = !muted;
      }
    }

    if (_joinedAtValue == null) {
      _joinedAtValue = DateTime.now().millisecondsSinceEpoch;
      navigator.mediaDevices.ondevicechange = (_) => unawaited(refreshDevices());
      await refreshDevices(initial: true);
    }
    _participants[peerId] = Participant(
      peerId: peerId,
      name: displayName,
      joinedAt: _joinedAt,
      isLocal: true,
    )..muted = muted;

    // При «Обновить» оставляем тот же объект: он помнит, какие сообщения уже получены.
    _signaling ??= RoomSignaling(_db, roomId: room.id, peerId: peerId);
    _connectStarted = DateTime.now();
    _lastServerError = null;
    notifyListeners();
    _schedulePoll(Duration.zero);
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    if (_disposed || !isActive) return;
    _pollTimer = Timer(delay, _poll);
  }

  /// Один цикл опроса: отмечаемся в комнате, получаем участников и сообщения.
  Future<void> _poll() async {
    final signaling = _signaling;
    if (signaling == null || _disposed || !isActive) return;
    if (_pollInFlight) {
      _pollAgain = true;
      return;
    }
    _pollInFlight = true;
    final wasLost = serverLost;
    try {
      final result = await signaling.poll(name: displayName, muted: muted, joinedAt: _joinedAt);
      if (_disposed || signaling != _signaling || !isActive) return;
      _lastServerContact = DateTime.now();
      if (result.full) {
        if (status == CallStatus.connecting) {
          _setFull();
        } else {
          // Пока нас не было (сеть пропала), место заняли — выходим.
          _fail('Связь с комнатой пропала, а ваше место занял другой участник.');
        }
        return;
      }
      if (status == CallStatus.connecting) {
        status = CallStatus.inRoom;
        _admittedAt ??= DateTime.now();
        _startStats();
      }
      _applyPeers(result.peers);
      _applyChat(result.messages);
      // Строго по порядку: offer раньше своих ICE-кандидатов.
      for (final signal in result.signals) {
        await _onSignal(signal.from, signal.payload);
      }
      notifyListeners();
    } catch (e) {
      _lastServerError = e;
      debugPrint('poll failed: $e');
      if (status == CallStatus.connecting &&
          DateTime.now().difference(_connectStarted!) > _connectLimit) {
        _fail('Не удалось подключиться к комнате за ${_connectLimit.inSeconds} секунд. '
            'Проверьте интернет.\n(${_shortError(_lastServerError)})');
        return;
      }
      if (serverLost != wasLost) notifyListeners();
    } finally {
      _pollInFlight = false;
    }
    if (_pollAgain) {
      _pollAgain = false;
      _schedulePoll(Duration.zero);
    } else {
      final settling = _participants.values.any((p) => !p.connected);
      _schedulePoll(settling || status == CallStatus.connecting ? _fastPoll : _slowPoll);
    }
  }

  void _applyChat(List<ChatMessage> messages) {
    if (messages.isEmpty) return;
    chat.addAll(messages);
    if (chat.length > _chatLimit) chat.removeRange(0, chat.length - _chatLimit);
    if (!_chatOpen) unreadChat += messages.where((m) => m.peerId != peerId).length;
  }

  /// Имена для подсказки «@»: бывавшие в комнате, а если сервер этого не умеет —
  /// те, кто сейчас в комнате.
  Future<List<({String name, bool inRoom})>> mentionCandidates() async {
    List<({String name, bool inRoom})>? names;
    try {
      names = await _signaling?.memberNames();
    } catch (_) {}
    names ??= [
      for (final p in _participants.values)
        if (!p.isLocal) (name: p.name, inRoom: true),
    ];
    return names.where((n) => n.name != displayName).toList();
  }

  /// Отправка сообщения в чат. Сразу опрашиваем сервер, чтобы оно появилось в ленте.
  Future<void> sendChat(String text) async {
    final body = text.trim();
    final signaling = _signaling;
    if (body.isEmpty || signaling == null || status != CallStatus.inRoom) return;
    await signaling.sendChat(body);
    _schedulePoll(Duration.zero);
  }

  static String _shortError(Object? e) {
    final text = '$e';
    return text.length > 120 ? '${text.substring(0, 120)}…' : text;
  }

  /// Обновляет список участников по ответу сервера и заводит недостающие соединения.
  void _applyPeers(List<Map<String, dynamic>> peers) {
    final remotes = {
      for (final p in peers)
        if (p['peer_id'] != peerId) p['peer_id'] as String: p,
    };
    for (final entry in remotes.entries) {
      final p = entry.value;
      final participant = _participants.putIfAbsent(
        entry.key,
        () => Participant(
          peerId: entry.key,
          name: (p['name'] as String?) ?? 'Участник',
          joinedAt: (p['joined_at'] as num?)?.toInt() ?? 0,
        ),
      );
      participant
        ..name = (p['name'] as String?) ?? participant.name
        ..muted = p['muted'] == true;
    }
    _presentIds = remotes.keys.toSet();
    final gone = _participants.keys
        .where((id) => id != peerId && !remotes.containsKey(id))
        .toList();
    for (final id in gone) {
      // Сервер мог потерять участника из-за плохой связи с ним, а прямое
      // соединение при этом живо — тогда звонок не обрываем.
      if (_participants[id]!.connected && _peers.containsKey(id)) continue;
      _removeParticipant(id);
    }
    // Offer отправляет участник с меньшим peerId, второй ждёт.
    for (final id in remotes.keys) {
      if (!_peers.containsKey(id) && peerId.compareTo(id) < 0) {
        unawaited(_callPeer(id));
      }
    }
  }

  void _removeParticipant(String id) {
    _participants.remove(id);
    _closePeer(id);
  }

  /// Кнопка «Обновить»: заново подключаемся к комнате и ко всем участникам.
  /// Микрофон не перезапускается, место в очереди входа сохраняется.
  Future<void> reconnect() async {
    if (_reconnecting || _disposed || status == CallStatus.ended) return;
    _reconnecting = true;
    try {
      status = CallStatus.connecting;
      errorMessage = null;
      _statsTimer?.cancel();
      _pollTimer?.cancel();
      for (final id in _peers.keys.toList()) {
        _sendSignal(id, 'bye', const {});
        _closePeer(id);
      }
      _participants.removeWhere((id, _) => id != peerId);
      notifyListeners();
      await _signaling?.flush();
      if (_disposed) return;
      await start();
    } finally {
      _reconnecting = false;
    }
  }

  void _setFull() {
    status = CallStatus.full;
    notifyListeners();
    unawaited(_teardown());
  }

  void _fail(String message) {
    errorMessage = message;
    status = CallStatus.failed;
    notifyListeners();
    unawaited(_teardown());
  }

  Future<void> hangUp() async {
    if (status == CallStatus.ended) return;
    // Сообщаем остальным сразу, не дожидаясь, пока сервер заметит уход.
    for (final id in _peers.keys) {
      _sendSignal(id, 'bye', const {});
    }
    status = CallStatus.ended;
    notifyListeners();
    await _teardown();
  }

  Future<void> _teardown() async {
    _statsTimer?.cancel();
    _pollTimer?.cancel();
    navigator.mediaDevices.ondevicechange = null;
    for (final id in _peers.keys.toList()) {
      _closePeer(id);
    }
    final signaling = _signaling;
    _signaling = null;
    await signaling?.leave();
    final stream = _localStream;
    _localStream = null;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_teardown());
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // WebRTC
  // ---------------------------------------------------------------------------

  Future<_Peer> _createPeer(String remoteId, {required bool initiator}) async {
    final pc = await createPeerConnection({
      'iceServers': config.iceServers,
      'sdpSemantics': 'unified-plan',
    });
    final peer = _Peer(pc, initiator);
    _peers[remoteId] = peer;

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
    }

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate == null) return;
      _sendSignal(remoteId, 'ice', {
        'candidate': candidate.candidate,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onConnectionState = (state) {
      final participant = _participants[remoteId];
      if (participant != null) {
        participant.connection = state;
        notifyListeners();
      }
      final lost = state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed;
      if (lost && !_presentIds.contains(remoteId) && _peers[remoteId] == peer) {
        // Участника уже нет в комнате, и связь с ним пропала — убираем.
        _removeParticipant(remoteId);
        notifyListeners();
      } else if (lost && state != RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _scheduleIceRestart(remoteId);
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        peer.restartTimer?.cancel();
      }
    };

    // Входящий звук на Android и Windows воспроизводится автоматически.
    pc.onTrack = (event) {};
    return peer;
  }

  Future<void> _callPeer(String remoteId, {bool iceRestart = false}) async {
    try {
      final peer = _peers[remoteId] ?? await _createPeer(remoteId, initiator: true);
      final offer = await peer.pc.createOffer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
        if (iceRestart) 'iceRestart': true,
      });
      await peer.pc.setLocalDescription(offer);
      _sendSignal(remoteId, 'offer', {'sdp': offer.sdp, 'sdpType': offer.type});
    } catch (e) {
      debugPrint('offer to $remoteId failed: $e');
    }
  }

  void _scheduleIceRestart(String remoteId) {
    final peer = _peers[remoteId];
    if (peer == null || !peer.initiator) return;
    peer.restartTimer?.cancel();
    peer.restartTimer = Timer(const Duration(seconds: 3), () {
      final current = _peers[remoteId];
      if (current != peer || _disposed) return;
      final participant = _participants[remoteId];
      if (participant != null && !participant.connected) {
        unawaited(_callPeer(remoteId, iceRestart: true));
      }
    });
  }

  void _closePeer(String remoteId) {
    final peer = _peers.remove(remoteId);
    if (peer == null) return;
    peer.restartTimer?.cancel();
    unawaited(peer.pc.close().catchError((_) {}));
  }

  void _sendSignal(String to, String kind, Map<String, dynamic> data) {
    _signaling?.send(to, {'kind': kind, ...data});
  }

  Future<void> _onSignal(String from, Map<String, dynamic> data) async {
    if (_disposed || !isActive) return;
    try {
      switch (data['kind']) {
        case 'offer':
          var peer = _peers[from];
          if (peer == null || peer.initiator) {
            if (peer != null) _closePeer(from);
            peer = await _createPeer(from, initiator: false);
          }
          await peer.pc.setRemoteDescription(
              RTCSessionDescription(data['sdp'] as String?, data['sdpType'] as String?));
          peer.remoteDescriptionSet = true;
          await _flushCandidates(peer);
          final answer = await peer.pc.createAnswer({});
          await peer.pc.setLocalDescription(answer);
          _sendSignal(from, 'answer', {'sdp': answer.sdp, 'sdpType': answer.type});
        case 'answer':
          final peer = _peers[from];
          if (peer == null) return;
          await peer.pc.setRemoteDescription(
              RTCSessionDescription(data['sdp'] as String?, data['sdpType'] as String?));
          peer.remoteDescriptionSet = true;
          await _flushCandidates(peer);
        case 'bye':
          _presentIds.remove(from);
          _removeParticipant(from);
          notifyListeners();
        case 'ice':
          final candidate = RTCIceCandidate(
            data['candidate'] as String?,
            data['sdpMid'] as String?,
            (data['sdpMLineIndex'] as num?)?.toInt(),
          );
          final peer = _peers[from];
          if (peer == null) return;
          if (peer.remoteDescriptionSet) {
            await peer.pc.addCandidate(candidate);
          } else {
            peer.pendingCandidates.add(candidate);
          }
      }
    } catch (e) {
      debugPrint('signal ${data['kind']} from $from failed: $e');
    }
  }

  Future<void> _flushCandidates(_Peer peer) async {
    final pending = List<RTCIceCandidate>.from(peer.pendingCandidates);
    peer.pendingCandidates.clear();
    for (final c in pending) {
      await peer.pc.addCandidate(c);
    }
  }

  // ---------------------------------------------------------------------------
  // Управление звуком
  // ---------------------------------------------------------------------------

  Future<void> toggleMute() async {
    muted = !muted;
    for (final track in _localStream?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      track.enabled = !muted;
    }
    final me = _participants[peerId];
    if (me != null) {
      me.muted = muted;
      if (muted) me.speaking = false;
    }
    notifyListeners();
    // Сразу сообщаем серверу, чтобы остальные быстрее увидели значок.
    if (status == CallStatus.inRoom) _schedulePoll(Duration.zero);
  }

  /// Кнопка динамика: динамик ↔ наушники (или трубка, если наушников нет).
  Future<void> toggleSpeaker() async {
    if (!canSwitchSpeaker) return;
    final target = speakerOn ? _bestPrivateOutput() : 'speaker';
    if (target != null) await selectOutput(target);
  }

  String? _bestPrivateOutput() {
    for (final id in const ['bluetooth', 'wired-headset', 'earpiece']) {
      if (outputs.any((d) => d.id == id)) return id;
    }
    return null;
  }

  Future<void> selectOutput(String id) async {
    outputId = id;
    if (!_inputChosenByUser) inputId = _inputFor(id) ?? inputId;
    notifyListeners();
    try {
      await Helper.selectAudioOutput(id);
    } catch (e) {
      debugPrint('select output failed: $e');
    }
  }

  Future<void> selectInput(String id) async {
    inputId = id;
    _inputChosenByUser = true;
    notifyListeners();
    try {
      await Helper.selectAudioInput(id);
    } catch (e) {
      debugPrint('select input failed: $e');
    }
  }

  /// Какой микрофон Android включит сам для выбранного выхода.
  String? _inputFor(String outputId) {
    if (!_isAndroid) return null;
    if (outputId == 'bluetooth' && inputs.any((d) => d.id == 'bluetooth')) return 'bluetooth';
    if (outputId == 'wired-headset' && inputs.any((d) => d.id == 'wired-headset')) {
      return 'wired-headset';
    }
    return inputs.where((d) => d.icon == 'mic').firstOrNull?.id;
  }

  /// Обновляет списки устройств. Подключили наушники — переключаемся на них,
  /// выбранное устройство пропало — выбираем лучшее из оставшихся.
  Future<void> refreshDevices({bool initial = false}) async {
    List<MediaDeviceInfo> all;
    try {
      all = await navigator.mediaDevices.enumerateDevices();
    } catch (e) {
      debugPrint('enumerateDevices failed: $e');
      return;
    }
    if (_disposed) return;
    final oldOutputIds = outputs.map((d) => d.id).toSet();

    final builtinMics = all.where((d) => d.kind == 'audioinput' && d.deviceId.startsWith('microphone')).length;
    inputs = [
      for (final d in all.where((d) => d.kind == 'audioinput')) _describeInput(d, builtinMics),
    ];
    outputs = [
      for (final d in all.where((d) => d.kind == 'audiooutput')) _describeOutput(d),
    ];
    final ids = outputs.map((d) => d.id).toSet();

    if (_isAndroid) {
      final newHeadset = ids.difference(oldOutputIds).where((id) => id == 'bluetooth' || id == 'wired-headset');
      String? target;
      if (initial) {
        target = ids.contains('bluetooth')
            ? 'bluetooth'
            : ids.contains('wired-headset')
                ? 'wired-headset'
                : (settings.speakerByDefault || !ids.contains('earpiece') ? 'speaker' : 'earpiece');
      } else if (newHeadset.isNotEmpty) {
        target = newHeadset.first;
      } else if (outputId != null && !ids.contains(outputId)) {
        target = _bestPrivateOutput() ?? 'speaker';
      }
      if (target != null && ids.contains(target)) {
        await selectOutput(target);
        return;
      }
      if (inputId != null && !inputs.any((d) => d.id == inputId)) {
        _inputChosenByUser = false;
        inputId = _inputFor(outputId ?? 'speaker');
      }
    }
    notifyListeners();
  }

  static AudioDevice _describeInput(MediaDeviceInfo d, int builtinMics) {
    final id = d.deviceId;
    if (!_isAndroid) return AudioDevice(id: id, label: d.label.isEmpty ? 'Микрофон' : d.label, icon: 'mic');
    if (id == 'wired-headset') {
      return AudioDevice(id: id, label: 'Микрофон проводной гарнитуры', icon: 'headset');
    }
    if (id == 'bluetooth') return AudioDevice(id: id, label: 'Bluetooth-гарнитура', icon: 'bluetooth');
    var label = 'Микрофон телефона';
    if (builtinMics > 1) {
      final address = id.replaceFirst('microphone-', '').toLowerCase();
      const names = {'bottom': 'нижний', 'back': 'задний', 'top': 'верхний', 'front': 'передний'};
      final name = names.entries.where((e) => address.contains(e.key)).firstOrNull?.value;
      label = name != null ? '$label ($name)' : '$label ($address)';
    }
    return AudioDevice(id: id, label: label, icon: 'mic');
  }

  static AudioDevice _describeOutput(MediaDeviceInfo d) {
    final id = d.deviceId;
    if (!_isAndroid) return AudioDevice(id: id, label: d.label.isEmpty ? 'Динамики' : d.label, icon: 'speaker');
    return switch (id) {
      'speaker' => AudioDevice(id: id, label: 'Динамик', icon: 'speaker'),
      'earpiece' => AudioDevice(id: id, label: 'Телефон (у уха)', icon: 'earpiece'),
      'wired-headset' => AudioDevice(id: id, label: 'Проводные наушники', icon: 'headset'),
      'bluetooth' => AudioDevice(
          id: id,
          label: d.label.isEmpty || d.label.toLowerCase().contains('bluetooth')
              ? 'Bluetooth-наушники'
              : 'Bluetooth: ${d.label}',
          icon: 'bluetooth',
        ),
      _ => AudioDevice(id: id, label: d.label, icon: 'speaker'),
    };
  }

  /// Как долго я в комнате (для экрана).
  Duration get inRoomFor =>
      _admittedAt == null ? Duration.zero : DateTime.now().difference(_admittedAt!);

  // ---------------------------------------------------------------------------
  // Индикатор голоса: уровни звука из статистики WebRTC
  // ---------------------------------------------------------------------------

  void _startStats() {
    _statsTimer?.cancel();
    _statsTimer = Timer.periodic(const Duration(milliseconds: 350), (_) => _pollStats());
  }

  bool _polling = false;

  Future<void> _pollStats() async {
    if (_polling || _disposed) return;
    _polling = true;
    var changed = false;
    var localLevel = 0.0;
    try {
      for (final entry in _peers.entries.toList()) {
        List<StatsReport> reports;
        try {
          reports = await entry.value.pc.getStats();
        } catch (_) {
          continue;
        }
        var remoteLevel = 0.0;
        for (final report in reports) {
          final level = report.values['audioLevel'];
          if (level is! num) continue;
          if (report.type == 'inbound-rtp') {
            remoteLevel = max(remoteLevel, level.toDouble());
          } else if (report.type == 'media-source') {
            localLevel = max(localLevel, level.toDouble());
          }
        }
        final participant = _participants[entry.key];
        if (participant != null) {
          final speaking = !participant.muted && remoteLevel > _speakingThreshold;
          if (participant.speaking != speaking) {
            participant.speaking = speaking;
            changed = true;
          }
        }
      }
      final me = _participants[peerId];
      if (me != null) {
        final speaking = !muted && localLevel > _speakingThreshold;
        if (me.speaking != speaking) {
          me.speaking = speaking;
          changed = true;
        }
      }
    } finally {
      _polling = false;
    }
    if (changed && !_disposed) notifyListeners();
  }
}
