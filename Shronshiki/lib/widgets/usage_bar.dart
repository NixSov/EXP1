import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Сколько часов разговора осталось в этом месяце: линия заполнена настолько,
/// сколько осталось от самого тесного бесплатного лимита (TURN или посредник).
class UsageBar extends StatefulWidget {
  const UsageBar({super.key, this.load});

  /// Источник данных usage_summary (для тестов); по умолчанию — сервер.
  final Future<Object?> Function()? load;

  @override
  State<UsageBar> createState() => _UsageBarState();
}

class _Limit {
  _Limit(Map<String, dynamic> m)
      : key = m['key'] as String,
        title = m['title'] as String,
        used = (m['used'] as num).toDouble(),
        limit = (m['limit'] as num).toDouble(),
        hoursLeft = (m['hours_left'] as num).toDouble();

  final String key;
  final String title;
  final double used;
  final double limit;
  final double hoursLeft;

  double get left => limit <= 0 ? 0 : ((limit - used) / limit).clamp(0, 1);

  String get usedText => key == 'turn_bytes'
      ? '${_gb(used)} из ${_gb(limit)} ГБ'
      : '${_count(used)} из ${_count(limit)} запросов';

  static String _gb(double bytes) {
    final gb = bytes / 1e9;
    return gb < 10 ? gb.toStringAsFixed(gb < 1 ? 2 : 1).replaceAll('.', ',') : gb.round().toString();
  }

  static String _count(double n) => n >= 1e6
      ? '${(n / 1e6).toStringAsFixed(n % 1e6 == 0 ? 0 : 1).replaceAll('.', ',')} млн'
      : n >= 1e3
          ? '${(n / 1e3).toStringAsFixed(n < 1e4 ? 1 : 0).replaceAll('.', ',')} тыс.'
          : n.round().toString();
}

class _UsageBarState extends State<UsageBar> {
  List<_Limit>? _limits;
  DateTime? _resets;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final load = widget.load ?? () => Supabase.instance.client.rpc('usage_summary');
      final raw = await load().timeout(const Duration(seconds: 12));
      final data = Map<String, dynamic>.from(raw as Map);
      if (!mounted) return;
      setState(() {
        _limits = [for (final m in data['limits'] as List) _Limit(Map<String, dynamic>.from(m as Map))];
        _resets = DateTime.tryParse('${data['resets']}');
      });
    } catch (_) {
      // База без миграции usage или нет связи — линию не показываем.
      if (mounted) setState(() => _hidden = true);
    }
  }

  static const _months = [
    'января', 'февраля', 'марта', 'апреля', 'мая', 'июня',
    'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря',
  ];

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final limits = _limits;
    final theme = Theme.of(context);
    if (limits == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: LinearProgressIndicator(),
      );
    }
    // Самый тесный лимит определяет, сколько осталось.
    final tightest = limits.isEmpty
        ? null
        : limits.reduce((a, b) => a.hoursLeft <= b.hoursLeft ? a : b);
    // Лимиты считаются на одного участника; разговор вдвоём тратит вдвое быстрее.
    final hours = (tightest?.hoursLeft ?? 0) / 2;
    final left = tightest?.left ?? 1;
    final color = left > 0.3
        ? theme.colorScheme.primary
        : (left > 0.1 ? Colors.orange : theme.colorScheme.error);
    final resets = _resets;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  hours >= 1000 ? 'Осталось больше 1000 ч разговора' : 'Осталось ≈ ${hours.round()} ч разговора',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (resets != null)
                Text('до ${resets.day} ${_months[resets.month - 1]}', style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: left,
              minHeight: 10,
              color: color,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Вдвоём, если связь идёт через TURN и посредника. Напрямую лимиты не тратятся.\n'
            '${limits.map((l) => '${l.title}: ${l.usedText}').join('\n')}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
