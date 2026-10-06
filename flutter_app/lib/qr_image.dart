import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Renders a shareable PNG: white card, large QR code, title and URL beneath.
/// Sized for projecting or sending in a chat (1080 px wide).
Future<Uint8List> renderQrPng(String url, String title) async {
  // ~4 modules of white quiet zone around the code, which scanners rely on.
  const width = 1080.0, qrSize = 840.0, pad = 120.0;
  const height = pad + qrSize + 260.0;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(const Rect.fromLTWH(0, 0, width, height), Paint()..color = Colors.white);

  final painter = QrPainter(
    data: url,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.M,
    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
    dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square, color: Colors.black),
  );
  canvas.save();
  canvas.translate((width - qrSize) / 2, pad);
  painter.paint(canvas, const Size(qrSize, qrSize));
  canvas.restore();

  void text(String s, double y, double size, FontWeight weight) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: TextStyle(
          color: Colors.black, fontSize: size, fontWeight: weight)),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
    )..layout(maxWidth: width - 2 * 40);
    tp.paint(canvas, Offset((width - tp.width) / 2, y));
  }

  text(title, pad + qrSize + 40, 56, FontWeight.bold);
  text(url, pad + qrSize + 130, 34, FontWeight.normal);

  final image = await recorder.endRecording().toImage(width.toInt(), height.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}
