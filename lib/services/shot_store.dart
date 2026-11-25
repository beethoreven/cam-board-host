import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cam_board_core/cam_board_core.dart';

/// 把抄錄到的照片存起來。
///
/// 用介面隔開，測試才不用真的寫檔案。
abstract interface class ShotStore {
  /// 在 [parent] 底下建立名稱是 [name] 的資料夾，回傳它的完整路徑。
  Future<String> createFolder(String parent, String name);

  /// 把 [png] 存成 [folder] 裡的 [fileName]。存之前先套用鄉民端自己的
  /// [rotation] 和 [mirrored]，存下來的就是鄉民端看到的樣子。
  Future<void> save({
    required String folder,
    required String fileName,
    required Uint8List png,
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
    required Uint8List png,
    required ViewRotation rotation,
    required bool mirrored,
  }) async {
    final bytes = await transformPng(
      png,
      rotation: rotation,
      mirrored: mirrored,
    );
    await File('$folder${Platform.pathSeparator}$fileName')
        .writeAsBytes(bytes, flush: true);
  }
}

/// 把一張 PNG 順時針轉 [rotation]，再視 [mirrored] 左右反轉，回傳新的 PNG。
///
/// 順序跟觀看畫面一樣：先旋轉，再反轉看到的左右。
/// 不用轉也不用反轉時，原封不動回傳，不重新編碼。
Future<Uint8List> transformPng(
  Uint8List png, {
  required ViewRotation rotation,
  required bool mirrored,
}) async {
  if (rotation == ViewRotation.deg0 && !mirrored) return png;

  final codec = await ui.instantiateImageCodec(png);
  final source = (await codec.getNextFrame()).image;
  final sideways =
      rotation == ViewRotation.deg90 || rotation == ViewRotation.deg270;
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
    ..rotate(rotation.index * 3.141592653589793 / 2)
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
  codec.dispose();
  return data!.buffer.asUint8List();
}
