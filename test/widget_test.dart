import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/board_list_controller.dart';
import 'package:cam_board_host/main.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const a = BoardInfo(name: '甲班', host: '192.168.1.10', port: 47800);
  late FakeBrowser browser;
  late ViewerHarness viewer;

  Future<void> pumpApp(WidgetTester tester) async {
    final probe = FakeProbe({'192.168.1.20:47800': '乙班'});
    await tester.pumpWidget(
      CamBoardApp(
        listController: BoardListController(
          browser: browser,
          probe: probe.call,
        ),
        viewerController: viewer.controller,
        window: viewer.window,
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 清單上出現甲班，點它，並收到一張橫的畫面。
  Future<void> startWatching(WidgetTester tester) async {
    browser.emitFound('甲班', a);
    await tester.pump();
    await tester.tap(find.text('甲班'));
    await tester.pump();
    viewer.link.emitVideo(1920, 1080);
    await tester.pump();
  }

  /// 把滑鼠移到視窗上，讓按鈕出現。
  Future<void> hover(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('video'))));
    await tester.pump();
  }

  setUp(() {
    browser = FakeBrowser();
    viewer = ViewerHarness();
  });

  group('看板清單', () {
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
  });

  group('觀看', () {
    testWidgets('點看板後先顯示連線中，可以按「不看了」取消', (tester) async {
      await pumpApp(tester);
      browser.emitFound('甲班', a);
      await tester.pump();
      await tester.tap(find.text('甲班'));
      await tester.pump();

      expect(find.textContaining('正在連到「甲班」'), findsOneWidget);
      expect(viewer.link.connectedTo, a);

      await tester.tap(find.text('不看了'));
      await tester.pumpAndSettle();
      expect(find.text('看板清單'), findsOneWidget);
    });

    testWidgets('收到畫面後顯示畫面，滑鼠沒移上去時看不到按鈕', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);

      expect(find.byKey(const Key('video')), findsOneWidget);
      expect(find.text('看板清單'), findsNothing);
      expect(find.text('不看了'), findsNothing);
    });

    testWidgets('滑鼠移上去出現四個按鈕', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      await hover(tester);

      for (final label in ['旋轉', '左右反轉', '放到最大', '不看了']) {
        expect(find.text(label), findsOneWidget);
      }
    });

    testWidgets('按「旋轉」每次轉 90 度', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      await hover(tester);

      int turns() => tester
          .widget<RotatedBox>(find.byKey(const Key('rotation')))
          .quarterTurns;
      expect(turns(), 0);
      await tester.tap(find.text('旋轉'));
      await tester.pump();
      expect(turns(), 1);
      await tester.tap(find.text('旋轉'));
      await tester.pump();
      expect(turns(), 2);
    });

    testWidgets('按「左右反轉」會翻轉畫面，再按一次翻回來', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      await hover(tester);

      bool flipped() => viewer.controller.mirrored;
      await tester.tap(find.text('左右反轉'));
      await tester.pump();
      expect(flipped(), isTrue);
      await tester.tap(find.text('左右反轉'));
      await tester.pump();
      expect(flipped(), isFalse);
    });

    testWidgets('按「放到最大」後按鈕變成「還原大小」', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      await hover(tester);
      await tester.tap(find.text('放到最大'));
      await tester.pump();

      expect(find.text('還原大小'), findsOneWidget);
      expect(viewer.window.frame.size, const Dimensions(1920, 1080));
    });

    testWidgets('按「不看了」回到看板清單，看板還在', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      final link = viewer.link;
      await hover(tester);
      await tester.tap(find.text('不看了'));
      await tester.pumpAndSettle();

      expect(find.text('看板清單'), findsOneWidget);
      expect(find.text('甲班'), findsOneWidget);
      expect(link.closed, isTrue);
      expect(browser.running, isTrue);
    });

    testWidgets('看板端不給看了：回到清單並顯示原因', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      viewer.link.emitEnded('看板端不給看了');
      await tester.pumpAndSettle();

      expect(find.text('看板清單'), findsOneWidget);
      expect(find.text('看板端不給看了'), findsOneWidget);
    });

    testWidgets('回到清單後，看板的出現與消失仍然會更新', (tester) async {
      await pumpApp(tester);
      await startWatching(tester);
      viewer.link.emitEnded('看板端撤銷註冊了');
      await tester.pumpAndSettle();

      browser.emitLost('甲班');
      await tester.pump();
      expect(find.text('甲班'), findsNothing);
    });
  });
}
