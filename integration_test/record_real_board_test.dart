import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:cam_board_host/services/shot_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 對一個真的看板（一支已經註冊的手機）抄錄：連上、開始抄錄、等看板端按「拍照」、
/// 把收到的照片存成檔案，並確認它是一張完整的 PNG。
///
/// 需要有人（或 adb）在測試印出「請在看板端按拍照」之後 60 秒內按一次看板端的「拍照」。
/// 用 `--dart-define=BOARD=192.168.1.115:47800` 指定位址；沒指定時整組測試跳過。
const _boardAddress = String.fromEnvironment('BOARD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = _boardAddress.isEmpty ? '沒有用 --dart-define=BOARD=… 指定看板' : null;

  testWidgets('抄錄：看板端按拍照，鄉民端存下一張 PNG', skip: skip != null, (tester) async {
    final board = BoardInfo.parseAddress(_boardAddress);
    final link = WebRtcBoardLink();
    final video = Completer<void>();
    final shot = Completer<ShotReceived>();
    final events = link.events.listen((event) {
      switch (event) {
        case VideoSizeChanged():
          if (!video.isCompleted) video.complete();
        case ShotReceived():
          if (!shot.isCompleted) shot.complete(event);
        case LinkEnded(:final message):
          if (!video.isCompleted) video.completeError('觀看被結束：$message');
          if (!shot.isCompleted) shot.completeError('觀看被結束：$message');
        case ConnectAdvanced():
          break;
      }
    });

    /// 一邊讓畫面繼續更新，一邊等 [done] 完成；超過 [seconds] 秒就失敗。
    Future<void> waitFor(
      Completer<Object?> done,
      int seconds,
      String what,
    ) async {
      for (var i = 0; i < seconds * 4 && !done.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
      if (!done.isCompleted) fail('$seconds 秒內沒有$what');
    }

    await tester.runAsync(() => link.connect(board, viewerName: '整合測試'));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: link.buildView())),
    );
    final folder = Directory.systemTemp.createTempSync('cam-board-record');
    try {
      await waitFor(video, 10, '收到畫面');
      link.startRecording();
      // ignore: avoid_print
      print('請在看板端按拍照');
      await waitFor(shot, 60, '收到照片');
      final received = await shot.future;

      final clock = Stopwatch()..start();
      await tester.runAsync(
        () => FileShotStore().save(
          folder: folder.path,
          fileName: shotFileName(1),
          png: received.png,
          rotation: ViewRotation.deg0,
          mirrored: false,
        ),
      );
      link.confirmSaved(received.id);

      final file = File('${folder.path}/${shotFileName(1)}');
      final size = await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(file.readAsBytesSync());
        final image = (await codec.getNextFrame()).image;
        return (image.width, image.height);
      });
      // ignore: avoid_print
      print(
        '存下 ${size!.$1}×${size.$2} 的 PNG，${file.lengthSync()} bytes，'
        '存檔花了 ${clock.elapsedMilliseconds} 毫秒：${file.path}',
      );
      // 1080p 的畫面，直拿或橫拿都算。
      expect({size.$1, size.$2}, {1920, 1080});
      // 讓「存好了」有時間送到看板端。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
    } finally {
      await events.cancel();
      await tester.runAsync(link.close);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
