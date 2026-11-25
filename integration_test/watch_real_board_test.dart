import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_browser.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 連到一個真的看板（一支已經註冊的手機），確認真的收得到畫面。
///
/// 需要一支和這台 Mac 在同一個網路、已經在看板端按了「註冊」的手機。
/// 用 `--dart-define=BOARD=192.168.1.115:47800` 指定位址；沒指定時整組測試跳過。
/// 執行方式見 README。
const _boardAddress = String.fromEnvironment('BOARD');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final skip = _boardAddress.isEmpty ? '沒有用 --dart-define=BOARD=… 指定看板' : null;

  /// 連一次，回傳收到的第一張畫面的大小，以及從開始連線到收到它花了多久；
  /// 10 秒內沒收到或被結束就失敗。途中每往前一步都印出當時過了多久，
  /// 用來決定 core 的 `connectTimeout` 該設多少。
  Future<(Dimensions, Duration)> watchOnce(
    WidgetTester tester,
    BoardInfo board,
  ) async {
    final link = WebRtcBoardLink();
    final firstVideo = Completer<(Dimensions, Duration)>();
    final clock = Stopwatch()..start();
    final events = link.events.listen((event) {
      if (firstVideo.isCompleted) return;
      switch (event) {
        case VideoSizeChanged(:final size):
          firstVideo.complete((size, clock.elapsed));
        case ConnectAdvanced(:final stage):
          // ignore: avoid_print
          print('  ${clock.elapsedMilliseconds} 毫秒：${stage.name}');
        case LinkEnded(:final message):
          firstVideo.completeError('觀看被結束：$message');
      }
    });
    await tester.runAsync(() => link.connect(board));
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: link.buildView())),
    );
    try {
      for (var i = 0; i < 40 && !firstVideo.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
      }
      if (!firstVideo.isCompleted) fail('10 秒內沒有收到畫面');
      return await firstVideo.future;
    } finally {
      await events.cancel();
      await tester.runAsync(link.close);
      await tester.pumpWidget(const SizedBox.shrink());
    }
  }

  testWidgets('連續看五次，每次都收得到畫面', skip: skip != null, (tester) async {
    final board = BoardInfo.parseAddress(_boardAddress);
    for (var round = 1; round <= 5; round++) {
      final (size, took) = await watchOnce(tester, board);
      // ignore: avoid_print
      print(
        '第 $round 次：${took.inMilliseconds} 毫秒後收到 '
        '${size.width.toInt()}×${size.height.toInt()} 的畫面',
      );
      expect(size.width, greaterThan(0));
      // 讓看板端有時間關掉鏡頭、回到等候中，下一次才是完整的重新開始。
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
    }
  });

  testWidgets('自動搜尋找得到這個看板', skip: skip != null, (tester) async {
    final target = BoardInfo.parseAddress(_boardAddress);
    final browser = BonsoirBoardBrowser();
    final found = Completer<BoardInfo>();
    final events = browser.events.listen((event) {
      if (event is BoardFound &&
          event.board.address == target.address &&
          !found.isCompleted) {
        found.complete(event.board);
      }
    });
    await tester.runAsync(() async {
      await browser.start();
      await found.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => fail('10 秒內沒有搜尋到 ${target.address}'),
      );
      await events.cancel();
      await browser.stop();
    });
    // ignore: avoid_print
    print('搜尋到：${(await found.future).name}');
  });
}
