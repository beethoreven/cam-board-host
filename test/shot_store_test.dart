import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/shot_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _red = 0xFFFF0000;
const _blue = 0xFF0000FF;

/// 做一張寬 2、高 1 的圖：左邊紅、右邊藍。
Future<Uint8List> redBluePng() async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder)
    ..drawRect(
      const ui.Rect.fromLTWH(0, 0, 1, 1),
      ui.Paint()..color = const ui.Color(_red),
    )
    ..drawRect(
      const ui.Rect.fromLTWH(1, 0, 1, 1),
      ui.Paint()..color = const ui.Color(_blue),
    );
  final image = await recorder.endRecording().toImage(2, 1);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// 把 PNG 解開，回傳寬、高，以及每個像素的顏色（一列一列、由左到右）。
Future<(int, int, List<int>)> pixelsOf(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final colors = <int>[
    for (var i = 0; i < data.lengthInBytes; i += 4)
      (data.getUint8(i + 3) << 24) |
          (data.getUint8(i) << 16) |
          (data.getUint8(i + 1) << 8) |
          data.getUint8(i + 2),
  ];
  return (image.width, image.height, colors);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('存檔前套用旋轉與左右反轉', () {
    testWidgets('不轉也不反轉：原封不動，連重新編碼都沒有', (tester) async {
      await tester.runAsync(() async {
        final png = await redBluePng();
        final out = await transformPng(
          png,
          rotation: ViewRotation.deg0,
          mirrored: false,
        );
        expect(identical(out, png), isTrue);
      });
    });

    testWidgets('順時針轉 90 度：變成直的，原本的左邊跑到上面', (tester) async {
      await tester.runAsync(() async {
        final out = await transformPng(
          await redBluePng(),
          rotation: ViewRotation.deg90,
          mirrored: false,
        );
        final (width, height, colors) = await pixelsOf(out);
        expect((width, height), (1, 2));
        expect(colors, [_red, _blue]);
      });
    });

    testWidgets('轉 180 度：左右對調', (tester) async {
      await tester.runAsync(() async {
        final out = await transformPng(
          await redBluePng(),
          rotation: ViewRotation.deg180,
          mirrored: false,
        );
        final (width, height, colors) = await pixelsOf(out);
        expect((width, height), (2, 1));
        expect(colors, [_blue, _red]);
      });
    });

    testWidgets('轉 270 度：變成直的，原本的左邊跑到下面', (tester) async {
      await tester.runAsync(() async {
        final out = await transformPng(
          await redBluePng(),
          rotation: ViewRotation.deg270,
          mirrored: false,
        );
        final (width, height, colors) = await pixelsOf(out);
        expect((width, height), (1, 2));
        expect(colors, [_blue, _red]);
      });
    });

    testWidgets('只左右反轉：左右對調', (tester) async {
      await tester.runAsync(() async {
        final out = await transformPng(
          await redBluePng(),
          rotation: ViewRotation.deg0,
          mirrored: true,
        );
        final (width, height, colors) = await pixelsOf(out);
        expect((width, height), (2, 1));
        expect(colors, [_blue, _red]);
      });
    });

    testWidgets('轉 90 度再左右反轉：直的圖左右反轉後上下順序不變', (tester) async {
      await tester.runAsync(() async {
        final out = await transformPng(
          await redBluePng(),
          rotation: ViewRotation.deg90,
          mirrored: true,
        );
        final (width, height, colors) = await pixelsOf(out);
        expect((width, height), (1, 2));
        expect(colors, [_red, _blue]);
      });
    });
  });

  group('寫進檔案系統', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('cam-board-shots'));
    tearDown(() => temp.deleteSync(recursive: true));

    testWidgets('建立資料夾並把照片存成指定的檔名', (tester) async {
      await tester.runAsync(() async {
        final store = FileShotStore();
        final png = await redBluePng();

        final folder = await store.createFolder(
          temp.path,
          '甲班抄錄紀錄_26-11-25-14-30-05',
        );
        await store.save(
          folder: folder,
          fileName: '001.png',
          png: png,
          rotation: ViewRotation.deg0,
          mirrored: false,
        );

        expect(folder, endsWith('甲班抄錄紀錄_26-11-25-14-30-05'));
        expect(File('$folder/001.png').readAsBytesSync(), png);
      });
    });
  });
}
