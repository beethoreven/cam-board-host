import 'package:cam_board_core/cam_board_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  const board = BoardInfo(name: '甲班', host: '192.168.1.10', port: 47800);
  const other = BoardInfo(name: '乙班', host: '192.168.1.11', port: 47800);
  late ViewerHarness h;

  /// 開始看 [board] 並收到一張橫的 1920×1080 畫面。
  Future<void> startWatching() async {
    await h.controller.watch(board);
    h.link.emitVideo(1920, 1080);
  }

  setUp(() => h = ViewerHarness());
  // 收掉還在等的逾時計時，免得它在後面的測試執行到一半時才觸發。
  tearDown(() => h.controller.dispose());

  group('開始與結束', () {
    test('點看板：開始連線，還沒收到畫面前視窗不變', () async {
      await h.controller.watch(board);

      expect(h.controller.state, ViewerState.connecting);
      expect(h.controller.board, board);
      expect(h.link.connectedTo, board);
      expect(h.window.videoMode, isFalse);
    });

    test('收到畫面：進入觀看，視窗變成無邊框', () async {
      await startWatching();

      expect(h.controller.state, ViewerState.watching);
      expect(h.window.videoMode, isTrue);
    });

    test('一次只看一個看板', () async {
      await startWatching();
      await h.controller.watch(other);

      expect(h.controller.board, board);
      expect(h.links, hasLength(1));
    });

    test('按「不看了」：通知看板端、視窗還原、回到清單，不顯示原因', () async {
      await startWatching();
      final link = h.link;
      await h.controller.stop();

      expect(h.controller.state, ViewerState.browsing);
      expect(link.closed, isTrue);
      expect(h.window.videoMode, isFalse);
      expect(h.controller.notice, isNull);
      expect(h.controller.link, isNull);
    });

    test('連線中也可以按「不看了」', () async {
      await h.controller.watch(board);
      final link = h.link;
      await h.controller.stop();

      expect(h.controller.state, ViewerState.browsing);
      expect(link.closed, isTrue);
    });

    test('看板端結束：回到清單並記下原因', () async {
      await startWatching();
      h.link.emitEnded('看板端不給看了');

      expect(h.controller.state, ViewerState.browsing);
      expect(h.controller.notice, '看板端不給看了');
      expect(h.window.videoMode, isFalse);
    });

    test('連不上：回到清單並記下原因', () async {
      await h.controller.watch(board);
      h.link.emitEnded('連不上看板端，它可能已經撤銷註冊');

      expect(h.controller.state, ViewerState.browsing);
      expect(h.controller.notice, contains('連不上'));
    });

    test('結束後可以再看，而且用新的連線、清掉上次的原因與設定', () async {
      await startWatching();
      h.controller
        ..rotate()
        ..toggleMirror();
      h.link.emitEnded('看板端不給看了');

      await h.controller.watch(other);

      expect(h.links, hasLength(2));
      expect(h.controller.notice, isNull);
      expect(h.controller.rotation, ViewRotation.deg0);
      expect(h.controller.mirrored, isFalse);
    });

    test('結束之後才送到的畫面事件不會讓視窗又變成觀看模式', () async {
      await startWatching();
      final link = h.link;
      await h.controller.stop();
      link.emitVideo(1920, 1080);

      expect(h.controller.state, ViewerState.browsing);
      expect(h.window.videoMode, isFalse);
    });
  });

  group('等太久畫面還是沒出來', () {
    const limit = Duration(seconds: 10);

    /// 開始連線，進行到 [stages] 之後就沒有下文，一路等到逾時。
    void stallAfter(FakeAsync async, List<ConnectStage> stages) {
      h.controller.watch(board);
      async.flushMicrotasks();
      for (final stage in stages) {
        h.link.emitAdvanced(stage);
      }
      async.elapse(limit);
    }

    test('時間到之前都還在連線中', () {
      fakeAsync((async) {
        h.controller.watch(board);
        async.elapse(limit - const Duration(milliseconds: 1));

        expect(h.controller.state, ViewerState.connecting);
      });
    });

    test('時間到：回到清單、收掉連線', () {
      fakeAsync((async) {
        stallAfter(async, []);

        expect(h.controller.state, ViewerState.browsing);
        expect(h.links.single.closed, isTrue);
        expect(h.controller.link, isNull);
        expect(h.window.videoMode, isFalse);
      });
    });

    test('加入要求還沒送出去：說連線逾時', () {
      fakeAsync((async) {
        stallAfter(async, []);

        expect(h.controller.notice, contains('連線逾時'));
      });
    });

    test('沒收到看板端的連線資訊：說看板端沒有回應', () {
      fakeAsync((async) {
        stallAfter(async, [ConnectStage.waitingForOffer]);

        expect(h.controller.notice, '看板端沒有回應');
      });
    });

    test('沒收到送完了：說交換連線資訊時中斷', () {
      fakeAsync((async) {
        stallAfter(async, [
          ConnectStage.waitingForOffer,
          ConnectStage.exchangingPaths,
        ]);

        expect(h.controller.notice, contains('交換連線資訊'));
      });
    });

    test('看板端的路徑都送完了：說兩台裝置之間的網路不通', () {
      fakeAsync((async) {
        stallAfter(async, [
          ConnectStage.waitingForOffer,
          ConnectStage.exchangingPaths,
          ConnectStage.pathsComplete,
        ]);

        expect(h.controller.notice, contains('網路不通'));
      });
    });

    test('送完了比連線資訊早到，還是算路徑都送完了', () {
      fakeAsync((async) {
        stallAfter(async, [
          ConnectStage.waitingForOffer,
          ConnectStage.pathsComplete,
          ConnectStage.exchangingPaths,
        ]);

        expect(h.controller.notice, contains('網路不通'));
      });
    });

    test('畫面已經出來就不會逾時', () {
      fakeAsync((async) {
        h.controller.watch(board);
        async.flushMicrotasks();
        h.link.emitVideo(1920, 1080);
        async.elapse(limit * 3);

        expect(h.controller.state, ViewerState.watching);
        expect(h.link.closed, isFalse);
      });
    });

    test('自己按了「不看了」之後，不會又跳出逾時的原因', () {
      fakeAsync((async) {
        h.controller.watch(board);
        async.flushMicrotasks();
        h.controller.stop();
        async.elapse(limit * 3);

        expect(h.controller.notice, isNull);
      });
    });

    test('上一次的逾時計時不會算到下一次觀看頭上', () {
      fakeAsync((async) {
        h.controller.watch(board);
        async.elapse(limit - const Duration(seconds: 1));
        h.link.emitEnded('看板端不給看了');
        h.controller.watch(other);
        async.elapse(const Duration(seconds: 2));

        expect(h.controller.state, ViewerState.connecting);
        expect(h.controller.board, other);
      });
    });
  });

  group('視窗大小跟著畫面', () {
    test('橫的畫面：視窗比例等於畫面比例，而且不超出螢幕', () async {
      await startWatching();
      final frame = h.window.frame;

      expect(frame.size.aspectRatio, closeTo(16 / 9, 0.001));
      expect(frame.left, greaterThanOrEqualTo(0));
      expect(frame.top, greaterThanOrEqualTo(25));
      expect(frame.left + frame.size.width, lessThanOrEqualTo(1920));
      expect(frame.top + frame.size.height, lessThanOrEqualTo(25 + 1080));
    });

    test('直的畫面：視窗是直的', () async {
      await h.controller.watch(board);
      h.link.emitVideo(1080, 1920);

      expect(h.window.frame.size.aspectRatio, closeTo(9 / 16, 0.001));
    });

    test('手機轉向：視窗跟著從橫的變成直的', () async {
      await startWatching();
      h.link.emitVideo(1080, 1920);

      expect(h.window.frame.size.aspectRatio, closeTo(9 / 16, 0.001));
      expect(h.controller.state, ViewerState.watching);
    });

    test('畫面大小改變時，視窗中心點不動', () async {
      await startWatching();
      final before = h.window.frame;
      h.link.emitVideo(1080, 1920);
      final after = h.window.frame;

      expect(
        after.left + after.size.width / 2,
        closeTo(before.left + before.size.width / 2, 0.001),
      );
    });
  });

  group('旋轉與反轉', () {
    test('轉 90 度：視窗的寬高比對調', () async {
      await startWatching();
      h.controller.rotate();

      expect(h.controller.rotation, ViewRotation.deg90);
      expect(h.window.frame.size.aspectRatio, closeTo(9 / 16, 0.001));
    });

    test('轉四次回到原本的角度和比例', () async {
      await startWatching();
      final ratios = <double>[];
      for (var i = 0; i < 4; i++) {
        h.controller.rotate();
        ratios.add(h.window.frame.size.aspectRatio);
      }

      expect(h.controller.rotation, ViewRotation.deg0);
      expect(ratios[0], closeTo(9 / 16, 0.001));
      expect(ratios[1], closeTo(16 / 9, 0.001));
      expect(ratios[2], closeTo(9 / 16, 0.001));
      expect(ratios[3], closeTo(16 / 9, 0.001));
    });

    test('左右反轉不改變視窗', () async {
      await startWatching();
      final before = h.window.frame;
      h.controller.toggleMirror();

      expect(h.controller.mirrored, isTrue);
      expect(h.window.frame.size, before.size);

      h.controller.toggleMirror();
      expect(h.controller.mirrored, isFalse);
    });

    test('沒有在看時，旋轉、反轉、放到最大都不會有作用', () {
      h.controller
        ..rotate()
        ..toggleMirror()
        ..toggleMaximize();

      expect(h.controller.rotation, ViewRotation.deg0);
      expect(h.controller.mirrored, isFalse);
      expect(h.controller.maximized, isFalse);
      expect(h.window.videoMode, isFalse);
    });
  });

  group('放到最大', () {
    test('橫的畫面在同比例的螢幕上：剛好填滿可用範圍，不蓋到選單列', () async {
      await startWatching();
      h.controller.toggleMaximize();
      final frame = h.window.frame;

      expect(frame.left, 0);
      expect(frame.top, 25);
      expect(frame.size, const Dimensions(1920, 1080));
    });

    test('直的畫面：頂到上下，左右空出來並置中', () async {
      await h.controller.watch(board);
      h.link.emitVideo(1080, 1920);
      h.controller.toggleMaximize();
      final frame = h.window.frame;

      expect(frame.top, 25);
      expect(frame.size.height, 1080);
      expect(frame.size.width, closeTo(607.5, 0.001));
      expect(frame.left, closeTo((1920 - 607.5) / 2, 0.001));
    });

    test('比較方的螢幕上，橫的畫面頂到左右，上下空出來', () async {
      h.window.area = (left: 0, top: 0, size: const Dimensions(1600, 1200));
      await startWatching();
      h.controller.toggleMaximize();
      final frame = h.window.frame;

      expect(frame.left, 0);
      expect(frame.size, const Dimensions(1600, 900));
      expect(frame.top, 150);
    });

    test('第二個螢幕：位置算在那個螢幕上', () async {
      h.window.area = (left: 1920, top: 0, size: const Dimensions(1280, 720));
      h.window.frame = const WindowFrame(
        left: 2200,
        top: 100,
        size: Dimensions(800, 600),
      );
      await startWatching();
      h.controller.toggleMaximize();

      expect(h.window.frame.left, 1920);
      expect(h.window.frame.size, const Dimensions(1280, 720));
    });

    test('放到最大時旋轉：仍然貼齊螢幕', () async {
      await startWatching();
      h.controller
        ..toggleMaximize()
        ..rotate();
      final frame = h.window.frame;

      expect(frame.size.height, 1080);
      expect(frame.size.aspectRatio, closeTo(9 / 16, 0.001));
    });

    test('再按一次還原成比較小的視窗', () async {
      await startWatching();
      h.controller.toggleMaximize();
      h.controller.toggleMaximize();

      expect(h.controller.maximized, isFalse);
      expect(h.window.frame.size.width, lessThan(1920));
      expect(h.window.frame.size.aspectRatio, closeTo(16 / 9, 0.001));
    });
  });
}
