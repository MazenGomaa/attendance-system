import 'dart:io';

import 'package:attendance_host/qr_image.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders a labelled QR code as a 1080 px wide PNG', (tester) async {
    final png = await tester.runAsync(() =>
        renderQrPng('https://brave-lion-quick.trycloudflare.com', 'Tunnel 1'));
    expect(png, isNotNull);
    expect(png!.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);   // PNG signature
    final width = (png[16] << 24) | (png[17] << 16) | (png[18] << 8) | png[19];
    expect(width, 1080);
    final out = Platform.environment['QR_SAMPLE_OUT'];
    if (out != null) File(out).writeAsBytesSync(png);
  });
}
