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
  /// 已經有同名的資料夾時不動它，回傳 null：裡面可能有上一次抄錄的照片，
  /// 共用的話新的 001.png 會蓋掉舊的。
  Future<String?> createFolder(String parent, String name);

  /// 抄錄沒有開始成：把剛建立的資料夾收掉。裡面有東西時不動它。
  Future<void> discardFolder(String folder);

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
  Future<String?> createFolder(String parent, String name) async {
    final folder = Directory('$parent${Platform.pathSeparator}$name');
    if (await folder.exists()) return null;
    await folder.create(recursive: true);
    return folder.path;
  }

  @override
  Future<void> discardFolder(String folder) async {
    try {
      // 不遞迴：資料夾不是空的就會失敗，剛好是我們要的。
      await Directory(folder).delete();
    } on FileSystemException {
      // 裡面有東西，或已經不在了：都不用處理。
    }
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
    // 先寫到暫時的檔名，寫完整了才改成正式的檔名。直接寫正式檔名的話，
    // 寫到一半失敗（磁碟滿了、隨身碟被拔掉）會留下一張打不開的 001.png。
    final target = File('$folder${Platform.pathSeparator}$fileName');
    final partial = File(
      '${target.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    try {
      await partial.writeAsBytes(bytes, flush: true);
      await partial.rename(target.path);
    } catch (_) {
      try {
        await partial.delete();
      } on FileSystemException {
        // 連暫時的檔案都沒寫成，沒有東西要刪。
      }
      rethrow;
    }
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
