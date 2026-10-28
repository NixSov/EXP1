import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../app_state.dart';
import '../config.dart';
import 'diagnostics.dart';
import 'ice_servers.dart';

/// Проверка прямого соединения: какие STUN-серверы сообщают телефону его
/// внешний адрес и работает ли TURN. Без внешнего адреса телефоны за NAT
/// мобильного оператора не найдут друг друга.
class IceCheck {
  static Future<List<DiagResult>> run(void Function(List<DiagResult>) onProgress) async {
    final results = <DiagResult>[];
    void add(DiagResult r) {
      results.add(r);
      onProgress(List.of(results));
    }

    for (final entry in AppConfig.stunServers.entries) {
      final types = await _gather([
        {'urls': entry.value},
      ]);
      final ok = types.contains('srflx');
      add(DiagResult(
        'STUN ${entry.key}',
        ok: ok,
        detail: ok ? 'внешний адрес получен' : 'не ответил (${entry.value.replaceFirst('stun:', '')})',
      ));
    }

    final config = AppState.instance.config;
    await ServerIce.refresh(AppState.instance.db);
    final turns = [
      if (config.hasTurn)
        (
          name: 'TURN (из настроек)',
          ice: {'urls': config.turnUrls, 'username': config.turnUsername, 'credential': config.turnCredential},
        ),
      for (final s in ServerIce.servers) (name: 'TURN ${s.name} (с сервера)', ice: s.toIce()),
    ];
    for (final turn in turns) {
      final types = await _gather([turn.ice], relayOnly: true);
      final ok = types.contains('relay');
      add(DiagResult(turn.name, ok: ok, detail: ok ? 'работает' : 'не отвечает или неверный логин/пароль'));
    }
    if (turns.isEmpty) {
      add(DiagResult('TURN', ok: false, detail: 'не настроен: добавьте на сервере (ice_servers) или в настройках'));
    }
    return results;
  }

  /// Собирает ICE-кандидаты и возвращает их типы: host, srflx, relay.
  static Future<Set<String>> _gather(
    List<Map<String, dynamic>> servers, {
    bool relayOnly = false,
  }) async {
    final types = <String>{};
    RTCPeerConnection? pc;
    try {
      pc = await createPeerConnection({
        'iceServers': servers,
        'sdpSemantics': 'unified-plan',
        if (relayOnly) 'iceTransportPolicy': 'relay',
      });
      final done = Completer<void>();
      pc.onIceCandidate = (c) {
        final match = RegExp(r' typ (\w+)').firstMatch(c.candidate ?? '');
        if (match != null) types.add(match.group(1)!);
        if (types.contains(relayOnly ? 'relay' : 'srflx') && !done.isCompleted) done.complete();
      };
      pc.onIceGatheringState = (state) {
        if (state == RTCIceGatheringState.RTCIceGatheringStateComplete && !done.isCompleted) {
          done.complete();
        }
      };
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      final offer = await pc.createOffer({});
      await pc.setLocalDescription(offer);
      await done.future.timeout(const Duration(seconds: 6), onTimeout: () {});
    } catch (_) {
      // Ошибка создания соединения — считаем, что кандидатов нет.
    } finally {
      await pc?.close();
    }
    return types;
  }
}
