import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 對一個真的看板連續抄錄一段時間：每收到一張照片就印出是開始抄錄後第幾秒收到的。
///
/// 用來查「第一張收得到、後面的收不到」這類問題。測試本身不按拍照，
/// 要有人（或 adb）在這段時間內按看板端的「拍照」。
/// 用 `--dart-define=BOARD=192.168.1.115:47800` 指定位址；沒指定時跳過。
/// `--dart-define=SECONDS=90` 可以改要等多久（預設 90 秒）。
const _boardAddress = String.fromEnvironment('BOARD');
const _seconds = int.fromEnvironment('SECONDS', defaultValue: 90);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = _boardAddress.isEmpty;

  testWidgets('連續抄錄：印出每一張照片收到的時間', skip: skip, (tester) async {
    final board = BoardInfo.parseAddress(_boardAddress);
    final link = WebRtcBoardLink();
    final video = Completer<void>();
    final clock = Stopwatch();
    var received = 0;
    String? ended;
    final events = link.events.listen((event) {
      switch (event) {
        case VideoSizeChanged():
          if (!video.isCompleted) video.complete();
        case ShotReceived(:final id):
          received++;
          link.confirmReceived(id);
          // ignore: avoid_print
          print('第 ${clock.elapsed.inSeconds} 秒收到編號 $id 的照片');
        case LinkEnded(:final message):
          ended = message;
          // ignore: avoid_print
          print('第 ${clock.elapsed.inSeconds} 秒觀看被結束：$message');
          if (!video.isCompleted) video.completeError(message);
        case ConnectAdvanced():
          break;
      }
    });

    await tester.runAsync(() => link.connect(board, viewerName: '整合測試'));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: link.buildView())),
    );
    try {
      await tester.runAsync(
        () => video.future.timeout(const Duration(seconds: 10)),
      );
      link.startRecording();
      clock.start();
      // ignore: avoid_print
      print('開始抄錄，接下來 $_seconds 秒內按看板端的拍照');
      // 不 pump 畫面：這裡要看的是連線，視窗不在最前面時 pump 會卡住。
      await tester.runAsync(() async {
        while (clock.elapsed.inSeconds < _seconds && ended == null) {
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      });
      // ignore: avoid_print
      print('結束：一共收到 $received 張');
      expect(ended, isNull);
    } finally {
      await events.cancel();
      await tester.runAsync(link.close);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
