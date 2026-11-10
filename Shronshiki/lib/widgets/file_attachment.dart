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
    this.loadFile,
    this.foreground,
  });
  static bool isImage(Map<String, dynamic> metadata) =>
      const [
        'image/png',
        'image/jpeg',
        'image/gif',
        'image/webp',
      ].contains(metadata['mime']) ||
      RegExp(
        r'\.(png|jpe?g|gif|webp)$',
        caseSensitive: false,
      ).hasMatch('${metadata['name']}');
  final Map<String, dynamic> metadata;
  final Future<Map<String, dynamic>> Function()? loadFile;
  final Color? foreground;
  final int message;
  final bool room;
  @override
  State<FileAttachment> createState() => _FileAttachmentState();
}

class _FileAttachmentState extends State<FileAttachment> {
  bool _busy = false;
  Uint8List? _image;
  String? _error;
  @override
  void initState() {
    super.initState();
    if (FileAttachment.isImage(widget.metadata)) {
      Future.microtask(() {
        if (mounted) _open();
      });
    }
  }

  Future<void> _open({bool save = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final loading = widget.loadFile != null
          ? widget.loadFile!()
          : AppState.instance.db.rpc(
              'message_file',
              get: true,
              params: {
                'p_message': widget.message,
                'p_room': widget.room,
                'p_content': true,
              },
            );
      // Bound the entire download, not just receipt of HTTP headers.
      final raw = await loading.timeout(const Duration(seconds: 30));
      if (raw == null) throw Exception('Файл удалён');
      final file = Map<String, dynamic>.from(raw as Map);
      final bytes = base64Decode(
        (file['data'] as String).replaceAll(RegExp(r'\s'), ''),
      );
      if (!mounted) return;
      if (!save && FileAttachment.isImage(widget.metadata)) {
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
      if (mounted) setState(() => _error = 'Не удалось загрузить вложение');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (FileAttachment.isImage(widget.metadata)) {
      if (_image == null) {
        return SizedBox(
          width: 260,
          height: 180,
          child: Center(
            child: _error != null
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Не удалось загрузить фото',
                        style: TextStyle(color: widget.foreground),
                      ),
                      IconButton(
                        tooltip: 'Повторить загрузку изображения',
                        onPressed: _busy ? null : _open,
                        icon: const Icon(Icons.refresh),
                        color: widget.foreground,
                      ),
                    ],
                  )
                : CircularProgressIndicator(color: widget.foreground),
          ),
        );
      }
      return GestureDetector(
        onTap: () => showDialog<void>(
          context: context,
          builder: (context) => Dialog(
            child: Stack(
              children: [
                InteractiveViewer(child: Image.memory(_image!)),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton(
                    tooltip: 'Закрыть',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ),
              ],
            ),
          ),
        ),
        onLongPress: () => _open(save: true),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            _image!,
            height: 220,
            cacheWidth: 1600,
            fit: BoxFit.contain,
            errorBuilder: (_, error, stack) => Text(
              'Изображение повреждено',
              style: TextStyle(color: widget.foreground),
            ),
          ),
        ),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error != null) Text(_error!),
        TextButton.icon(
          onPressed: _busy ? null : () => _open(save: true),
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
}
