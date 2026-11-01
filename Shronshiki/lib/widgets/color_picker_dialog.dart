import 'package:flutter/material.dart';

/// Выбор цвета: готовые цвета, ползунки оттенка/насыщенности/яркости и HEX-код.
Future<Color?> showColorPickerDialog(
  BuildContext context, {
  required String title,
  required Color initial,
}) {
  return showDialog<Color>(
    context: context,
    builder: (context) => _ColorPickerDialog(title: title, initial: initial),
  );
}

class _ColorPickerDialog extends StatefulWidget {
  const _ColorPickerDialog({required this.title, required this.initial});

  final String title;
  final Color initial;

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  static const _presets = [
    Color(0xFF000000), Color(0xFF1E1F22), Color(0xFF2B2D31), Color(0xFF4E5058),
    Color(0xFF9E9E9E), Color(0xFFDBDEE1), Color(0xFFF2F3F5), Color(0xFFFFFFFF),
    Color(0xFF5865F2), Color(0xFF3F51B5), Color(0xFF2196F3), Color(0xFF00BCD4),
    Color(0xFF009688), Color(0xFF4CAF50), Color(0xFF8BC34A), Color(0xFFCDDC39),
    Color(0xFFFFEB3B), Color(0xFFFFC107), Color(0xFFFF9800), Color(0xFFFF5722),
    Color(0xFFF44336), Color(0xFFE91E63), Color(0xFF9C27B0), Color(0xFF795548),
    Color(0xFF3A3326), Color(0xFF6B5B3E), Color(0xFFC1652F), Color(0xFF556B2F),
  ];

  late HSVColor _hsv;
  late final TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initial);
    _hex = TextEditingController(text: _toHex(widget.initial));
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Color get _color => _hsv.toColor();

  static String _toHex(Color c) =>
      (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

  void _set(HSVColor hsv, {bool updateHex = true}) {
    setState(() => _hsv = hsv);
    if (updateHex) _hex.text = _toHex(hsv.toColor());
  }

  void _onHex(String value) {
    final clean = value.replaceAll('#', '').trim();
    if (clean.length != 6) return;
    final parsed = int.tryParse(clean, radix: 16);
    if (parsed == null) return;
    _set(HSVColor.fromColor(Color(0xFF000000 | parsed)), updateHex: false);
  }

  Widget _slider({
    required String label,
    required double value,
    required double max,
    required List<Color> gradient,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                gradient: LinearGradient(colors: gradient),
              ),
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 0,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(value: value, max: max, onChanged: onChanged),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hsv = _hsv;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in _presets)
                  InkWell(
                    onTap: () => _set(HSVColor.fromColor(c)),
                    customBorder: const CircleBorder(),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color.toARGB32() == c.toARGB32()
                              ? Theme.of(context).colorScheme.primary
                              : Colors.grey.withValues(alpha: 0.5),
                          width: _color.toARGB32() == c.toARGB32() ? 3 : 1,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            _slider(
              label: 'Оттенок',
              value: hsv.hue,
              max: 360,
              gradient: [
                for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
              ],
              onChanged: (v) => _set(hsv.withHue(v)),
            ),
            _slider(
              label: 'Насыщенность',
              value: hsv.saturation,
              max: 1,
              gradient: [hsv.withSaturation(0).toColor(), hsv.withSaturation(1).toColor()],
              onChanged: (v) => _set(hsv.withSaturation(v)),
            ),
            _slider(
              label: 'Яркость',
              value: hsv.value,
              max: 1,
              gradient: [Colors.black, hsv.withValue(1).toColor()],
              onChanged: (v) => _set(hsv.withValue(v)),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _color,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.withValues(alpha: 0.5)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _hex,
                    maxLength: 7,
                    decoration: const InputDecoration(
                      prefixText: '#',
                      labelText: 'Код цвета',
                      counterText: '',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onChanged: _onHex,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
        FilledButton(onPressed: () => Navigator.pop(context, _color), child: const Text('Готово')),
      ],
    );
  }
}
