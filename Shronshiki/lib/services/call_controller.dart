import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config.dart';
import 'rooms.dart';
import 'settings.dart';

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

class _Peer {
  _Peer(this.pc, this.initiator);

  final RTCPeerConnection pc;
  final bool initiator;
  final List<RTCIceCandidate> pendingCandidates = [];
  bool remoteDescriptionSet = false;
  Timer? restartTimer;
}

/// Голосовой звонок в комнате: mesh из P2P-соединений, сигналинг через
/// Supabase Realtime (broadcast — offer/answer/ICE, presence — список участников).
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
  bool speakerOn = true;

  final Map<String, Participant> _participants = {};
  final Map<String, _Peer> _peers = {};
  RealtimeChannel? _channel;
  MediaStream? _localStream;
  Timer? _statsTimer;
  Timer? _presenceTimeout;
  Timer? _connectTimeout;
  Object? _lastChannelError;

  /// Сколько ждём подключения к комнате. Realtime сам повторяет попытки,
  /// поэтому на медленном мобильном интернете не сдаёмся после первой.
  static const _connectLimit = Duration(seconds: 30);
  bool _tracked = false;
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

  bool get canSwitchSpeaker => _isMobile;

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
      speakerOn = settings.speakerByDefault;
      _joinedAtValue = DateTime.now().millisecondsSinceEpoch;
    }
    if (_isMobile) {
      unawaited(Helper.setSpeakerphoneOn(speakerOn).catchError((_) {}));
    }
    _participants[peerId] = Participant(
      peerId: peerId,
      name: displayName,
      joinedAt: _joinedAt,
      isLocal: true,
    )..muted = muted;

    final channel = _db.channel(
      'room:${room.id}',
      opts: RealtimeChannelConfig(key: peerId, private: true),
    );
    _channel = channel;
    _lastChannelError = null;

    _connectTimeout = Timer(_connectLimit, () {
      if (status == CallStatus.connecting && !_tracked) {
        _fail('Не удалось подключиться к комнате за ${_connectLimit.inSeconds} секунд. '
            'Проверьте интернет или включите VPN.'
            '${_lastChannelError != null ? '\n($_lastChannelError)' : ''}');
      }
    });

    channel
        .onBroadcast(event: 'signal', callback: _onSignal)
        .onPresenceSync((_) => _onPresenceSync())
        .subscribe((state, error) {
      if (_disposed) return;
      switch (state) {
        case RealtimeSubscribeStatus.subscribed:
          if (_tracked) {
            // Переподключились к Realtime — заново сообщаем о себе.
            unawaited(_track());
          } else {
            // Ждём текущий список участников, чтобы проверить, есть ли место.
            _presenceTimeout?.cancel();
            _presenceTimeout = Timer(const Duration(seconds: 3), _admitIfRoom);
          }
        case RealtimeSubscribeStatus.channelError:
        case RealtimeSubscribeStatus.timedOut:
          // Realtime повторит попытку сам; окончательно сдаёмся по _connectTimeout.
          _lastChannelError = error ?? state.name;
          debugPrint('realtime $state: $error');
        case RealtimeSubscribeStatus.closed:
          break;
      }
    });
    notifyListeners();
  }

  Map<String, dynamic> get _presencePayload => {
        'peer_id': peerId,
        'name': displayName,
        'muted': muted,
        'joined_at': _joinedAt,
      };

  Future<void> _track() async {
    try {
      await _channel?.track(_presencePayload);
    } catch (e) {
      debugPrint('presence track failed: $e');
    }
  }

  /// Перед входом проверяем, что в комнате меньше [Room.maxParticipants] человек.
  void _admitIfRoom() {
    _presenceTimeout?.cancel();
    if (_tracked || _disposed || status != CallStatus.connecting) return;
    final others = _remotePresences().length;
    if (others >= room.maxParticipants) {
      _setFull();
      return;
    }
    _tracked = true;
    _connectTimeout?.cancel();
    unawaited(_track());
  }

  /// Текущие участники из presence (кроме меня): peerId -> payload.
  Map<String, Map<String, dynamic>> _remotePresences() {
    final result = <String, Map<String, dynamic>>{};
    final channel = _channel;
    if (channel == null) return result;
    for (final state in channel.presenceState()) {
      if (state.key == peerId || state.presences.isEmpty) continue;
      result[state.key] = state.presences.last.payload;
    }
    return result;
  }

  void _onPresenceSync() {
    final channel = _channel;
    if (_disposed || channel == null) return;
    if (status != CallStatus.connecting && status != CallStatus.inRoom) return;
    if (!_tracked) {
      _admitIfRoom();
      return;
    }

    final remotes = _remotePresences();
    final selfPresent = channel.presenceState().any((s) => s.key == peerId);

    // Двое вошли одновременно в почти полную комнату — лишний (вошедший позже) выходит.
    if (selfPresent && status == CallStatus.connecting) {
      final ordered = [
        (peerId, _joinedAt),
        for (final e in remotes.entries) (e.key, (e.value['joined_at'] as num?)?.toInt() ?? 0),
      ]..sort((a, b) {
          final t = a.$2.compareTo(b.$2);
          return t != 0 ? t : a.$1.compareTo(b.$1);
        });
      final position = ordered.indexWhere((e) => e.$1 == peerId);
      if (position >= room.maxParticipants) {
        _setFull();
        return;
      }
      status = CallStatus.inRoom;
      _admittedAt = DateTime.now();
      _startStats();
    }

    // Обновляем список участников.
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
    final gone = _participants.keys
        .where((id) => id != peerId && !remotes.containsKey(id))
        .toList();
    for (final id in gone) {
      _participants.remove(id);
      _closePeer(id);
    }

    // Соединения: offer отправляет участник с меньшим peerId, второй ждёт.
    if (status == CallStatus.inRoom) {
      for (final id in remotes.keys) {
        if (!_peers.containsKey(id) && peerId.compareTo(id) < 0) {
          unawaited(_callPeer(id));
        }
      }
    }
    notifyListeners();
  }

  /// Кнопка «Обновить»: заново подключаемся к комнате и ко всем участникам.
  /// Микрофон не перезапускается, место в очереди входа сохраняется.
  Future<void> reconnect() async {
    if (_reconnecting || _disposed || status == CallStatus.ended) return;
    _reconnecting = true;
    try {
      status = CallStatus.connecting;
      errorMessage = null;
      _tracked = false;
      _statsTimer?.cancel();
      _presenceTimeout?.cancel();
      _connectTimeout?.cancel();
      for (final id in _peers.keys.toList()) {
        _closePeer(id);
      }
      _participants.removeWhere((id, _) => id != peerId);
      notifyListeners();
      await _leaveChannel();
      if (_disposed) return;
      await start();
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _leaveChannel() async {
    final channel = _channel;
    _channel = null;
    if (channel == null) return;
    try {
      await channel.untrack();
    } catch (_) {}
    try {
      await _db.removeChannel(channel);
    } catch (_) {}
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
    status = CallStatus.ended;
    notifyListeners();
    await _teardown();
  }

  Future<void> _teardown() async {
    _statsTimer?.cancel();
    _presenceTimeout?.cancel();
    _connectTimeout?.cancel();
    for (final id in _peers.keys.toList()) {
      _closePeer(id);
    }
    await _leaveChannel();
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
      _send(remoteId, 'ice', {
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
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
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
      _send(remoteId, 'offer', {'sdp': offer.sdp, 'sdpType': offer.type});
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

  // Поля type и event занимает сам Realtime (type = 'broadcast'), поэтому вид
  // сообщения передаём в kind, а тип SDP — в sdpType.
  void _send(String to, String kind, Map<String, dynamic> data) {
    final channel = _channel;
    if (channel == null) return;
    unawaited(channel.sendBroadcastMessage(
      event: 'signal',
      payload: {'from': peerId, 'to': to, 'kind': kind, ...data},
    ).catchError((e) {
      debugPrint('signal send failed: $e');
      return ChannelResponse.error;
    }));
  }

  Future<void> _onSignal(Map<String, dynamic> message) async {
    // Realtime кладёт полезную нагрузку в поле payload.
    final data = (message['payload'] is Map)
        ? Map<String, dynamic>.from(message['payload'] as Map)
        : message;
    if (data['to'] != peerId || _disposed) return;
    if (status != CallStatus.inRoom && status != CallStatus.connecting) return;
    final from = data['from'] as String?;
    if (from == null) return;

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
          _send(from, 'answer', {'sdp': answer.sdp, 'sdpType': answer.type});
        case 'answer':
          final peer = _peers[from];
          if (peer == null) return;
          await peer.pc.setRemoteDescription(
              RTCSessionDescription(data['sdp'] as String?, data['sdpType'] as String?));
          peer.remoteDescriptionSet = true;
          await _flushCandidates(peer);
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
    if (_tracked) await _track();
  }

  Future<void> toggleSpeaker() async {
    if (!canSwitchSpeaker) return;
    speakerOn = !speakerOn;
    notifyListeners();
    try {
      await Helper.setSpeakerphoneOn(speakerOn);
    } catch (e) {
      debugPrint('speaker switch failed: $e');
    }
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
