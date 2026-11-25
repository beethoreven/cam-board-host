import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/board_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const a = BoardInfo(name: '甲班', host: '192.168.1.10', port: 47800);
  late FakeBrowser browser;
  late FakeProbe probe;

  BoardListController build() =>
      BoardListController(browser: browser, probe: probe.call);

  setUp(() {
    browser = FakeBrowser();
    probe = FakeProbe({'192.168.1.20:47800': '乙班'});
  });

  test('啟動後開始搜尋，清單一開始是空的', () async {
    final controller = build();
    await controller.start();
    expect(browser.running, isTrue);
    expect(controller.boards, isEmpty);
    expect(controller.searchError, isNull);
  });

  test('看板出現就加進清單，消失就移除，並通知畫面更新', () async {
    final controller = build();
    var notified = 0;
    controller.addListener(() => notified++);
    await controller.start();

    browser.emitFound('甲班', a);
    expect(controller.boards, [a]);

    browser.emitLost('甲班');
    expect(controller.boards, isEmpty);
    expect(notified, 2);
  });

  test('搜尋無法啟動時顯示原因，仍然可以手動加入', () async {
    browser.failOnStart = true;
    final controller = build();
    await controller.start();
    expect(controller.searchError, isNotNull);

    expect(await controller.addManual('192.168.1.20'), isTrue);
    expect(controller.boards.single.name, '乙班');
  });

  group('手動輸入', () {
    test('連得上就加入，名稱用看板端回報的', () async {
      final controller = build();
      expect(await controller.addManual(' 192.168.1.20 '), isTrue);

      final board = controller.boards.single;
      expect(board.name, '乙班');
      expect(board.address, '192.168.1.20:47800');
      expect(controller.manualError, isNull);
    });

    test('格式不對時不會去連，直接顯示原因', () async {
      final controller = build();
      expect(await controller.addManual('1.2.3.4:abc'), isFalse);
      expect(controller.manualError, isNotNull);
      expect(probe.probed, isEmpty);
    });

    test('連不上時顯示原因，清單不變', () async {
      final controller = build();
      expect(await controller.addManual('192.168.1.99'), isFalse);
      expect(controller.manualError, '連不上');
      expect(controller.boards, isEmpty);
      expect(controller.probing, isFalse);
    });

    test('已經在清單上的看板不重複加入', () async {
      final controller = build();
      await controller.addManual('192.168.1.20');
      expect(await controller.addManual('192.168.1.20'), isFalse);
      expect(controller.manualError, isNotNull);
      expect(controller.boards, hasLength(1));
    });

    test('成功之後會清掉上一次的錯誤', () async {
      final controller = build();
      await controller.addManual('192.168.1.99');
      await controller.addManual('192.168.1.20');
      expect(controller.manualError, isNull);
    });
  });

  test('手動加入的看板可以移除，搜尋到的不行', () async {
    final controller = build();
    await controller.start();
    browser.emitFound('甲班', a);
    await controller.addManual('192.168.1.20');
    final manual = controller.boards.last;

    expect(controller.isManual(manual), isTrue);
    expect(controller.isManual(a), isFalse);

    controller.removeManual(manual);
    expect(controller.boards, [a]);
  });

  test('搜尋自己停掉時顯示原因', () async {
    final controller = build();
    await controller.start();
    browser.emitStopped();

    expect(controller.searchError, isNotNull);
  });
}
