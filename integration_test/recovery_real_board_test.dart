import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 對一個真的看板驗證「卡住時自己救回來」。實機上沒辦法叫網路卡住，所以由測試
/// 自己製造故障：
///
/// 1. 讓訊息連線不再讀進任何東西，這時看板端按拍照。預期鄉民端換一條連線接回去，
///    看板端把那一張補送過來。
/// 2. 把視訊連線硬關掉。預期鄉民端發現畫面停住，請看板端重建，畫面恢復。
///
/// 需要有人（或 adb）在測試每次印出「請在看板端按拍照」之後 20 秒內按一次。
/// 用 `--dart-define=BOARD=192.168.1.115:47800` 指定位址；沒指定時跳過。
const _boardAddress = String.fromEnvironment('BOARD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('卡住時自己救回來', skip: _boardAddress.isEmpty, (tester) async {
    final link = WebRtcBoardLink();
    final shots = <int>[];
    var hasVideo = false;
    String? ended;
    final events = link.events.listen((event) {
      switch (event) {
        case VideoSizeChanged():
          hasVideo = true;
        case ShotReceived(:final id):
          shots.add(id);
          link.confirmReceived(id);
        case LinkEnded(:final message):
          ended = message;
        case ConnectAdvanced():
          break;
      }
    });
    final clock = Stopwatch()..start();
    void say(String what) {
      // ignore: avoid_print
      print(
        '第 ${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒：$what',
      );
    }

    /// 等到 [done] 成立，最多 [seconds] 秒。
    Future<void> waitUntil(
      bool Function() done,
      int seconds,
      String what,
    ) async {
      for (var i = 0; i < seconds * 4 && !done(); i++) {
        if (ended != null) fail('觀看被結束：$ended（在等「$what」）');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
      }
      if (!done()) fail('$seconds 秒內沒有等到：$what');
      say('等到了：$what');
    }

    await tester.runAsync(
      () => link.connect(
        BoardInfo.parseAddress(_boardAddress),
        viewerName: '整合測試',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: link.buildView())),
    );
    try {
      await waitUntil(() => hasVideo, 10, '第一次有畫面');
      await waitUntil(() => link.debugFramesDecoded > 0, 10, '解出畫面');
      link.startRecording();

      say('請在看板端按拍照（正常）');
      await waitUntil(() => shots.length == 1, 20, '第 1 張照片');

      link.debugStallSignal();
      say('訊息連線卡住了。請在看板端按拍照（卡住中）');
      await waitUntil(() => link.debugSignalReconnects >= 1, 15, '換了一條新的訊息連線');
      await waitUntil(() => shots.length >= 2, 25, '卡住時拍的那一張被補送過來');
      expect(shots.toSet(), hasLength(2), reason: '兩張的編號不同');

      final before = link.debugVideoConnections;
      await tester.runAsync(link.debugBreakVideo);
      say('視訊連線被關掉了');
      await waitUntil(() => link.debugVideoConnections > before, 20, '視訊連線重建了');
      await waitUntil(() => link.debugFramesDecoded > 0, 15, '重建後又解出畫面');

      say('請在看板端按拍照（救回來之後）');
      await waitUntil(() => shots.length >= 3, 20, '救回來之後照片仍然收得到');
      expect(ended, isNull);
    } finally {
      await events.cancel();
      await tester.runAsync(link.close);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  });
}
