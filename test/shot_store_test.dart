import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/shot_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

// 八個不同的亮度，用來認出每個像素被搬到哪裡。
const _a = 16, _b = 46, _c = 76, _d = 106;
const _e = 136, _f = 166, _g = 196, _h = 226;

/// 做一張寬 4、高 2、沒有顏色的畫面：
///
///     a b c d
///     e f g h
RawFrame lettersFrame({int rotation = 0}) => RawFrame(
  width: 4,
  height: 2,
  rotation: rotation,
  i420: Uint8List.fromList([
    _a,
    _b,
    _c,
    _d,
    _e,
    _f,
    _g,
    _h,
    128,
    128,
    128,
    128,
  ]),
);

/// 亮度 [luma] 換成紅綠藍之後的灰階值（跟 core 的換算一樣）。
int gray(int luma) => ((298 * (luma - 16) + 128) >> 8).clamp(0, 255);

/// 把 PNG 解開，回傳寬、高，以及每一列每個像素的灰階值。
Future<(int, int, List<List<int>>)> rowsOf(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  final image = (await codec.getNextFrame()).image;
  final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final rows = <List<int>>[
    for (var row = 0; row < image.height; row++)
      [
        for (var column = 0; column < image.width; column++)
          data.getUint8((row * image.width + column) * 4),
      ],
  ];
  return (image.width, image.height, rows);
}

List<List<int>> grays(List<List<int>> lumas) => [
  for (final row in lumas) [for (final luma in row) gray(luma)],
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<(int, int, List<List<int>>)> encode(
    WidgetTester tester,
    RawFrame frame, {
    ViewRotation rotation = ViewRotation.deg0,
    bool mirrored = false,
  }) async {
    final result = await tester.runAsync(() async {
      final png = await encodeShot(
        frame,
        rotation: rotation,
        mirrored: mirrored,
      );
      return rowsOf(png);
    });
    return result!;
  }

  group('把畫面變成 PNG', () {
    testWidgets('不用轉的畫面：一個像素對一個像素，亮度換成灰階', (tester) async {
      final (width, height, rows) = await encode(tester, lettersFrame());
      expect((width, height), (4, 2));
      expect(
        rows,
        grays([
          [_a, _b, _c, _d],
          [_e, _f, _g, _h],
        ]),
      );
    });

    testWidgets('畫面本身要轉 90 度才是正的：存下來是直的，原本的左邊在上面', (tester) async {
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(rotation: 90),
      );
      expect((width, height), (2, 4));
      expect(
        rows,
        grays([
          [_e, _a],
          [_f, _b],
          [_g, _c],
          [_h, _d],
        ]),
      );
    });

    testWidgets('有顏色的畫面：紅的存下來還是紅的', (tester) async {
      final red = RawFrame(
        width: 2,
        height: 2,
        rotation: 0,
        i420: Uint8List.fromList([81, 81, 81, 81, 90, 240]),
      );
      final pixel = await tester.runAsync(() async {
        final png = await encodeShot(
          red,
          rotation: ViewRotation.deg0,
          mirrored: false,
        );
        final codec = await ui.instantiateImageCodec(png);
        final image = (await codec.getNextFrame()).image;
        final data = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        return [for (var i = 0; i < 4; i++) data.getUint8(i)];
      });
      expect(pixel, [255, 0, 0, 255]);
    });
  });

  group('存檔前套用鄉民端的旋轉與左右反轉', () {
    testWidgets('順時針轉 90 度：變成直的，原本的左邊跑到上面', (tester) async {
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(),
        rotation: ViewRotation.deg90,
      );
      expect((width, height), (2, 4));
      expect(
        rows,
        grays([
          [_e, _a],
          [_f, _b],
          [_g, _c],
          [_h, _d],
        ]),
      );
    });

    testWidgets('轉 180 度：上下左右都對調', (tester) async {
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(),
        rotation: ViewRotation.deg180,
      );
      expect((width, height), (4, 2));
      expect(
        rows,
        grays([
          [_h, _g, _f, _e],
          [_d, _c, _b, _a],
        ]),
      );
    });

    testWidgets('轉 270 度：變成直的，原本的左邊跑到下面', (tester) async {
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(),
        rotation: ViewRotation.deg270,
      );
      expect((width, height), (2, 4));
      expect(
        rows,
        grays([
          [_d, _h],
          [_c, _g],
          [_b, _f],
          [_a, _e],
        ]),
      );
    });

    testWidgets('只左右反轉：左右對調，上下不變', (tester) async {
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(),
        mirrored: true,
      );
      expect((width, height), (4, 2));
      expect(
        rows,
        grays([
          [_d, _c, _b, _a],
          [_h, _g, _f, _e],
        ]),
      );
    });

    testWidgets('轉 90 度再左右反轉：直的圖左右反轉後上下順序不變', (tester) async {
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(),
        rotation: ViewRotation.deg90,
        mirrored: true,
      );
      expect((width, height), (2, 4));
      expect(
        rows,
        grays([
          [_a, _e],
          [_b, _f],
          [_c, _g],
          [_d, _h],
        ]),
      );
    });

    testWidgets('畫面本身的角度和鄉民端的旋轉會加在一起', (tester) async {
      // 畫面要轉 90 度才是正的，鄉民端又轉了 90 度：總共 180 度。
      final (width, height, rows) = await encode(
        tester,
        lettersFrame(rotation: 90),
        rotation: ViewRotation.deg90,
      );
      expect((width, height), (4, 2));
      expect(
        rows,
        grays([
          [_h, _g, _f, _e],
          [_d, _c, _b, _a],
        ]),
      );
    });
  });

  group('寫進檔案系統', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('cam-board-shots'));
    tearDown(() => temp.deleteSync(recursive: true));

    testWidgets('建立資料夾並把照片存成指定檔名的 PNG', (tester) async {
      await tester.runAsync(() async {
        final store = FileShotStore();

        final folder = (await store.createFolder(
          temp.path,
          '甲班抄錄紀錄_26-11-25-14-30-05',
        ))!;
        await store.save(
          folder: folder,
          fileName: '001.png',
          frame: lettersFrame(rotation: 90),
          rotation: ViewRotation.deg0,
          mirrored: false,
        );

        expect(folder, endsWith('甲班抄錄紀錄_26-11-25-14-30-05'));
        final (width, height, _) = await rowsOf(
          File('$folder/001.png').readAsBytesSync(),
        );
        expect((width, height), (2, 4));
      });
    });

    testWidgets('一張 1920×1080 的畫面存得下來（順便印出花的時間）', (tester) async {
      await tester.runAsync(() async {
        // 做一張有細節的畫面：全白或全黑的圖壓起來太快，量不準。
        final bytes = Uint8List(RawFrame.byteLength(1920, 1080));
        var seed = 7;
        for (var i = 0; i < bytes.length; i++) {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          bytes[i] = 100 + ((i ~/ 37) % 60) + (seed >> 24) % 12;
        }
        final frame = RawFrame(
          width: 1920,
          height: 1080,
          rotation: 90,
          i420: bytes,
        );
        await FileShotStore().save(
          folder: temp.path,
          fileName: '001.png',
          frame: frame,
          rotation: ViewRotation.deg0,
          mirrored: false,
        );
        final (width, height, _) = await rowsOf(
          File('${temp.path}/001.png').readAsBytesSync(),
        );
        expect((width, height), (1080, 1920));
      });
    });
  });

  group('資料夾與寫檔的保護', () {
    late Directory temp;

    setUp(() => temp = Directory.systemTemp.createTempSync('cam-board-shots'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('同名的資料夾已經在了：不共用，回傳 null', () async {
      final store = FileShotStore();
      expect(await store.createFolder(temp.path, '甲班'), isNotNull);
      expect(await store.createFolder(temp.path, '甲班'), isNull);
    });

    test('收掉空的資料夾；裡面有東西時不動它', () async {
      final store = FileShotStore();
      final empty = (await store.createFolder(temp.path, '空的'))!;
      final used = (await store.createFolder(temp.path, '有照片'))!;
      File('$used/001.png').writeAsBytesSync([1, 2, 3]);

      await store.discardFolder(empty);
      await store.discardFolder(used);

      expect(Directory(empty).existsSync(), isFalse);
      expect(File('$used/001.png').existsSync(), isTrue);
    });

    testWidgets('存不進去時不會留下寫到一半的檔案', (tester) async {
      await tester.runAsync(() async {
        final store = FileShotStore();
        final folder = (await store.createFolder(temp.path, '甲班'))!;
        // 正式檔名的位置已經被一個資料夾佔住，改名會失敗。
        Directory('$folder/001.png').createSync();
        File('$folder/001.png/x').writeAsBytesSync([1]);

        await expectLater(
          store.save(
            folder: folder,
            fileName: '001.png',
            frame: grayFrame(),
            rotation: ViewRotation.deg0,
            mirrored: false,
          ),
          throwsA(anything),
        );

        final leftovers = Directory(folder)
            .listSync()
            .where((entry) => entry.path.endsWith('.part'));
        expect(leftovers, isEmpty);
      });
    });
  });
}
