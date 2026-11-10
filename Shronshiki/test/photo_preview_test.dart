import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shronshiki/widgets/file_attachment.dart';

void main() {
  testWidgets(
    'photos load automatically without a filename or download buttons',
    (tester) async {
      final data = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawRect(
          const Rect.fromLTWH(0, 0, 2, 2),
          Paint()..color = Colors.blue,
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(2, 2);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!
            .buffer
            .asUint8List();
        image.dispose();
        picture.dispose();
        return base64Encode(bytes);
      });
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FileAttachment(
              metadata: const {
                'name': 'private-photo.png',
                'mime': 'image/png',
                'size': 100,
              },
              message: 1,
              room: true,
              loadFile: () async {
                loads++;
                return {
                  'name': 'private-photo.png',
                  'mime': 'image/png',
                  'data': data,
                };
              },
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(loads, 1);
      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('private-photo'), findsNothing);
      expect(find.byType(TextButton), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
