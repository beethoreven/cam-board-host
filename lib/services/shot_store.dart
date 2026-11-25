import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

/// 把抄錄到的照片存起來。
///
/// 用介面隔開，測試才不用真的寫檔案。
abstract interface class ShotStore {
  /// 在 [parent] 底下建立名稱是 [name] 的資料夾，回傳它的完整路徑。
  Future<String> createFolder(String parent, String name);

  /// 把看板端傳來的 [frame] 存成 [folder] 裡的 [fileName]（PNG）。先把畫面轉正，
  /// 再套用鄉民端自己的 [rotation] 和 [mirrored]，存下來的就是鄉民端看到的樣子。
  Future<void> save({
    required String folder,
    required String fileName,
    required RawFrame frame,
    required ViewRotation rotation,
    required bool mirrored,
  });
}

/// 存到這台電腦的檔案系統。
class FileShotStore implements ShotStore {
  @override
  Future<String> createFolder(String parent, String name) async {
    final folder = Directory('$parent${Platform.pathSeparator}$name');
    await folder.create(recursive: true);
    return folder.path;
  }

  @override
  Future<void> save({
    required String folder,
    required String fileName,
    required RawFrame frame,
    required ViewRotation rotation,
    required bool mirrored,
  }) async {
    final watch = Stopwatch()..start();
    final bytes = await encodeShot(
      frame,
      rotation: rotation,
      mirrored: mirrored,
    );
    final encoded = watch.elapsedMilliseconds;
    await File('$folder${Platform.pathSeparator}$fileName')
        .writeAsBytes(bytes, flush: true);
    // 按拍照到看板端跳出提示之間，鄉民端花的時間就是這兩段。
    debugPrint(
      '存照片 $fileName：轉成 PNG $encoded 毫秒，'
      '寫檔 ${watch.elapsedMilliseconds - encoded} 毫秒，${bytes.length} bytes',
    );
  }
}

/// 把看板端傳來的畫面變成一張 PNG：換成紅綠藍，轉正，再順時針轉 [rotation]，
/// 最後視 [mirrored] 左右反轉。
///
/// 順序跟觀看畫面一樣：先旋轉，再反轉看到的左右。
/// 這些事原本在手機上做，一張要一秒多，所以搬到這裡。
Future<Uint8List> encodeShot(
  RawFrame frame, {
  required ViewRotation rotation,
  required bool mirrored,
}) async {
  final decoded = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    frame.toRgba(),
    frame.width,
    frame.height,
    ui.PixelFormat.rgba8888,
    decoded.complete,
  );
  final source = await decoded.future;
  // 畫面本身要轉的角度，加上鄉民端自己轉的角度。
  final quarterTurns = (frame.rotation ~/ 90 + rotation.index) % 4;
  final sideways = quarterTurns.isOdd;
  final width = sideways ? source.height : source.width;
  final height = sideways ? source.width : source.height;

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  if (mirrored) {
    canvas
      ..translate(width.toDouble(), 0)
      ..scale(-1, 1);
  }
  canvas
    ..translate(width / 2, height / 2)
    ..rotate(quarterTurns * 3.141592653589793 / 2)
    ..translate(-source.width / 2, -source.height / 2)
    // 一個像素對一個像素搬過去，不做任何平滑處理。
    ..drawImage(
      source,
      ui.Offset.zero,
      ui.Paint()..filterQuality = ui.FilterQuality.none,
    );
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  source.dispose();
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}
