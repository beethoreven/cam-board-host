import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/board_list_controller.dart';
import 'package:cam_board_host/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const a = BoardInfo(name: '甲班', host: '192.168.1.10', port: 47800);
  late FakeBrowser browser;

  Future<void> pumpApp(WidgetTester tester) async {
    final probe = FakeProbe({'192.168.1.20:47800': '乙班'});
    await tester.pumpWidget(
      CamBoardApp(
        controller: BoardListController(browser: browser, probe: probe.call),
      ),
    );
    await tester.pumpAndSettle();
  }

  setUp(() => browser = FakeBrowser());

  testWidgets('沒有看板時顯示「還沒有看板註冊」', (tester) async {
    await pumpApp(tester);
    expect(find.text('看板清單'), findsOneWidget);
    expect(find.text('還沒有看板註冊'), findsOneWidget);
    expect(browser.running, isTrue);
  });

  testWidgets('看板註冊後出現在清單，撤銷後消失', (tester) async {
    await pumpApp(tester);

    browser.emitFound('甲班', a);
    await tester.pump();
    expect(find.text('甲班'), findsOneWidget);
    expect(find.text('還沒有看板註冊'), findsNothing);

    browser.emitLost('甲班');
    await tester.pump();
    expect(find.text('甲班'), findsNothing);
    expect(find.text('還沒有看板註冊'), findsOneWidget);
  });

  testWidgets('手動輸入連得上的位址：加進清單並清空輸入框', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField), '192.168.1.20');
    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(find.text('乙班'), findsOneWidget);
    expect(find.text('192.168.1.20:47800'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('手動輸入連不上的位址：顯示原因，輸入的內容留著', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField), '192.168.1.99');
    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(find.text('連不上'), findsOneWidget);
    expect(find.text('192.168.1.99'), findsOneWidget);
    expect(find.text('還沒有看板註冊'), findsOneWidget);
  });

  testWidgets('手動輸入格式不對的位址：顯示原因', (tester) async {
    await pumpApp(tester);
    await tester.enterText(find.byType(TextField), '1.2.3.4:abc');
    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();

    expect(find.textContaining('埠必須是'), findsOneWidget);
  });

  testWidgets('自動搜尋無法啟動時顯示提示', (tester) async {
    browser.failOnStart = true;
    await pumpApp(tester);
    expect(find.textContaining('自動搜尋無法啟動'), findsOneWidget);
  });
}
