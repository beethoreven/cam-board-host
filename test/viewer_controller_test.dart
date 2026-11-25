import 'package:cam_board_core/cam_board_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart' hide pumpEventQueue;

import 'fakes.dart';

/// 等所有排隊中的非同步工作做完。
Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);

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

  group('鄉民的名稱', () {
    test('沒取過名稱時，欄位和報給看板端的都是這台電腦的名稱', () async {
      await h.controller.loadViewerName();
      await h.controller.watch(board);

      expect(h.controller.viewerNameInput, '測試用的 Mac');
      expect(h.link.joinedAs, '測試用的 Mac');
    });

    test('取過名稱：下次開啟時帶回來，並報給看板端', () async {
      h.nameStore.saved = '阿明';
      await h.controller.loadViewerName();
      await h.controller.watch(board);

      expect(h.controller.viewerNameInput, '阿明');
      expect(h.link.joinedAs, '阿明');
    });

    test('改名稱會存起來', () async {
      await h.controller.setViewerName('小華');

      expect(h.nameStore.saved, '小華');
      expect(h.controller.viewerName, '小華');
    });

    test('把欄位清空時，報給看板端的改用這台電腦的名稱', () async {
      await h.controller.setViewerName('   ');
      await h.controller.watch(board);

      expect(h.link.joinedAs, '測試用的 Mac');
    });
  });

  group('抄錄', () {
    test('按「我要抄錄」：選位置、建立資料夾、通知看板端', () async {
      await startWatching();
      await h.controller.startRecording();

      expect(h.controller.recording, isTrue);
      expect(h.shots.folders, ['/Users/me/Documents/甲班抄錄紀錄_26-11-25-14-30-05']);
      expect(h.controller.recordingFolder, h.shots.folders.single);
      expect(h.link.recordingSignals, ['start']);
    });

    test('選位置時按取消：不開始抄錄，也不通知看板端', () async {
      await startWatching();
      h.pickedFolder = null;
      await h.controller.startRecording();

      expect(h.controller.recording, isFalse);
      expect(h.shots.folders, isEmpty);
      expect(h.link.recordingSignals, isEmpty);
    });

    test('還沒看到畫面不能抄錄', () async {
      await h.controller.watch(board);
      await h.controller.startRecording();

      expect(h.pickCount, 0);
      expect(h.controller.recording, isFalse);
    });

    test('已經在抄錄時再按一次不會重新選位置', () async {
      await startWatching();
      await h.controller.startRecording();
      await h.controller.startRecording();

      expect(h.pickCount, 1);
    });

    test('資料夾建不起來：顯示原因，不算開始抄錄', () async {
      await startWatching();
      h.shots.failOnCreate = true;
      await h.controller.startRecording();

      expect(h.controller.recording, isFalse);
      expect(h.controller.recordingError, contains('建立資料夾'));
      expect(h.link.recordingSignals, isEmpty);
    });

    test('看板端每拍一張就存一張，檔名照順序', () async {
      await startWatching();
      await h.controller.startRecording();

      final first = grayFrame(50);
      final second = grayFrame(200);
      h.link.emitShot(11, first);
      h.link.emitShot(12, second);
      await pumpEventQueue();

      expect(h.shots.saved.map((s) => s.fileName), ['001.png', '002.png']);
      expect(h.shots.saved.map((s) => s.frame), [first, second]);
      expect(h.shots.saved.first.folder, h.controller.recordingFolder);
      expect(h.link.recordingSignals, ['start', 'received 11', 'received 12']);
      expect(h.controller.savedCount, 2);
    });

    test('存檔時套用收到那一刻的旋轉和左右反轉', () async {
      await startWatching();
      await h.controller.startRecording();
      h.controller
        ..rotate()
        ..toggleMirror();

      h.link.emitShot(1);
      await pumpEventQueue();

      expect(h.shots.saved.single.rotation, ViewRotation.deg90);
      expect(h.shots.saved.single.mirrored, isTrue);
    });

    test('沒有在抄錄時收到照片，不存也不回報', () async {
      await startWatching();
      h.link.emitShot(1);
      await pumpEventQueue();

      expect(h.shots.saved, isEmpty);
      expect(h.link.recordingSignals, isEmpty);
    });

    test('按「抄錄完了」：通知看板端，之後收到的照片不存', () async {
      await startWatching();
      await h.controller.startRecording();
      h.controller.stopRecording();
      h.link.emitShot(1);
      await pumpEventQueue();

      expect(h.controller.recording, isFalse);
      expect(h.link.recordingSignals, ['start', 'stop']);
      expect(h.shots.saved, isEmpty);
    });

    test('照片一收到就回報，不等存檔', () async {
      await startWatching();
      await h.controller.startRecording();
      h.link.emitShot(11);

      // 還沒輪到存檔，看板端已經收到回報了。
      expect(h.shots.saved, isEmpty);
      expect(h.link.recordingSignals, ['start', 'received 11']);

      await pumpEventQueue();
      expect(h.shots.saved, hasLength(1));
    });

    test('存不進去：鄉民端自己顯示原因，下一張用同一個檔名再試', () async {
      await startWatching();
      await h.controller.startRecording();
      h.shots.failOnSave = true;
      h.link.emitShot(1);
      await pumpEventQueue();

      // 收到的回報在存檔之前就送出了，所以存不進去只有鄉民端自己知道。
      expect(h.controller.recordingError, contains('存不進去'));
      expect(h.link.recordingSignals, ['start', 'received 1']);

      h.shots.failOnSave = false;
      h.link.emitShot(2);
      await pumpEventQueue();

      expect(h.shots.saved.single.fileName, '001.png');
      expect(h.controller.recordingError, isNull);
    });

    test('按「不看了」時抄錄跟著結束', () async {
      await startWatching();
      await h.controller.startRecording();
      await h.controller.stop();

      expect(h.controller.recording, isFalse);
    });

    test('看板端不給看了，抄錄跟著結束；再看一次時不是抄錄中', () async {
      await startWatching();
      await h.controller.startRecording();
      h.link.emitEnded('看板端不給看了');
      await h.controller.watch(other);
      h.link.emitVideo(1920, 1080);

      expect(h.controller.recording, isFalse);
    });

    test('再抄錄一次：新的資料夾，檔名重新從 001 開始', () async {
      await startWatching();
      await h.controller.startRecording();
      h.link.emitShot(1);
      await pumpEventQueue();
      h.controller.stopRecording();

      h.now = DateTime(2026, 11, 25, 15, 0, 0);
      await h.controller.startRecording();
      h.link.emitShot(2);
      await pumpEventQueue();

      expect(h.shots.folders, hasLength(2));
      expect(h.shots.saved.last.folder, endsWith('26-11-25-15-00-00'));
      expect(h.shots.saved.last.fileName, '001.png');
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
