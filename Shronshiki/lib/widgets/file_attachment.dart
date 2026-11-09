import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

class FileSendButton extends StatefulWidget {
  const FileSendButton({
    super.key,
    required this.target,
    required this.room,
    required this.peer,
  });
  final String target;
  final bool room;
  final String peer;
  @override
  State<FileSendButton> createState() => _FileSendButtonState();
}

class _FileSendButtonState extends State<FileSendButton> {
  bool _busy = false;
  Future<void> _send() async {
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: false,
        withReadStream: true,
      );
      if (result == null) return;
      final file = result.files.single;
      if (file.size == 0 || file.size > 2 * 1024 * 1024) {
        throw Exception('Выберите файл размером от 1 байта до 2 МБ');
      }
      final chunks = BytesBuilder(copy: false);
      final input = file.readStream;
      if (input == null) throw Exception('Не удалось прочитать файл');
      await for (final chunk in input) {
        if (chunks.length + chunk.length > 2 * 1024 * 1024) {
          throw Exception('Файл больше 2 МБ');
        }
        chunks.add(chunk);
      }
      final data = chunks.takeBytes();
      final ext = file.extension?.toLowerCase();
      final mime = switch (ext) {
        'png' => 'image/png',
        'jpg' || 'jpeg' => 'image/jpeg',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        _ => 'application/octet-stream',
      };
      await AppState.instance.db.rpc(
        'send_file',
        params: {
          'p_target': widget.target,
          'p_room': widget.room,
          'p_peer': widget.peer,
          'p_filename': file.name,
          'p_mime': mime,
          'p_data': base64Encode(data),
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Файл не отправлен: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Картинка или файл (до 2 МБ)',
    onPressed: _busy ? null : _send,
    icon: _busy
        ? const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(),
          )
        : const Icon(Icons.attach_file),
  );
}

class FileAttachment extends StatefulWidget {
  const FileAttachment({
    super.key,
    required this.metadata,
    required this.message,
    required this.room,
  });
  final Map<String, dynamic> metadata;
  final int message;
  final bool room;
  @override
  State<FileAttachment> createState() => _FileAttachmentState();
}

class _FileAttachmentState extends State<FileAttachment> {
  bool _busy = false;
  Uint8List? _image;
  Future<void> _open({bool save = false}) async {
    setState(() => _busy = true);
    try {
      final raw = await AppState.instance.db.rpc(
        'message_file',
        params: {
          'p_message': widget.message,
          'p_room': widget.room,
          'p_content': true,
        },
      );
      if (raw == null) throw Exception('Файл удалён');
      final file = Map<String, dynamic>.from(raw as Map);
      final bytes = base64Decode(
        (file['data'] as String).replaceAll(RegExp(r'\s'), ''),
      );
      if (!mounted) return;
      if (!save &&
          const [
            'image/png',
            'image/jpeg',
            'image/gif',
            'image/webp',
          ].contains(file['mime'])) {
        setState(() => _image = bytes);
      } else {
        await FileSaver.instance.saveAs(
          name: file['name'] as String,
          fileExtension: '',
          includeExtension: false,
          bytes: bytes,
          mimeType: MimeType.other,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Не удалось открыть файл: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (_image != null)
        Image.memory(
          _image!,
          height: 180,
          fit: BoxFit.contain,
          errorBuilder: (_, error, stack) =>
              const Text('Изображение повреждено'),
        ),
      TextButton(
        onPressed: _busy ? null : () => _open(save: true),
        child: const Text('Сохранить файл'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _open,
        icon: const Icon(Icons.download),
        label: Text(
          _busy
              ? 'Загрузка…'
              : '${widget.metadata['name']} · ${((widget.metadata['size'] as num) / 1024).ceil()} КБ',
        ),
      ),
    ],
  );
}
