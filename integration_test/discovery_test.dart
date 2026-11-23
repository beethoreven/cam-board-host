import 'dart:io';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/board_list_controller.dart';
import 'package:cam_board_host/main.dart';
import 'package:cam_board_host/services/board_browser.dart';
import 'package:cam_board_host/services/board_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 在真的鄉民端程式裡，用真的區域網路搜尋和真的連線來驗證。
///
/// 第一個測試需要這台 Mac 上先有人廣播一個叫「整合測試看板」的看板：
///
///     dns-sd -R "整合測試看板" _cam-board._tcp local 47999
///
/// 執行方式見 README。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpRealApp(WidgetTester tester) async {
    await tester.pumpWidget(
      CamBoardApp(
        controller: BoardListController(
          browser: BonsoirBoardBrowser(),
          probe: probeBoard,
        ),
      ),
    );
  }

  /// 每 0.25 秒看一次畫面，直到 [finder] 出現或超過 [seconds] 秒。
  Future<bool> waitFor(
    WidgetTester tester,
    Finder finder, {
    int seconds = 15,
  }) async {
    for (var i = 0; i < seconds * 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (finder.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('搜尋得到區域網路上廣播的看板', (tester) async {
    await pumpRealApp(tester);
    final found = await waitFor(tester, find.text('整合測試看板'));
    expect(
      found,
      isTrue,
      reason:
          '15 秒內沒有搜尋到。確認 dns-sd 有在執行，'
          '以及 macOS 的「區域網路」權限已經允許這個程式。',
    );
  });

  testWidgets('手動輸入位址可以連到真的看板伺服器', (tester) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.add(const HelloMessage(name: '手動加入的看板').encode());
    });

    await pumpRealApp(tester);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '127.0.0.1:${server.port}');
    await tester.tap(find.text('加入'));

    expect(await waitFor(tester, find.text('手動加入的看板')), isTrue);
  });
}
