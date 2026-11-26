import 'dart:async';
import 'dart:io';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/board_list_controller.dart';
import 'package:cam_board_host/main.dart';
import 'package:cam_board_host/services/board_browser.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:cam_board_host/services/board_probe.dart';
import 'package:cam_board_host/services/shot_store.dart';
import 'package:cam_board_host/services/viewer_name_store.dart';
import 'package:cam_board_host/services/window_control.dart';
import 'package:cam_board_host/viewer_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 用整個鄉民端（真的畫面、真的視窗、真的連線、真的存檔）對一個真的看板抄錄
/// 一段時間，每秒看一次狀態，有變化就印出來。只有選資料夾換成固定的暫存資料夾。
///
/// 測試本身不按拍照，要有人（或 adb）在這段時間內按看板端的「拍照」。
/// 用 `--dart-define=BOARD=192.168.1.115:47800` 指定位址；沒指定時跳過。
/// `--dart-define=SECONDS=90` 可以改要抄錄多久（預設 90 秒）。
const _boardAddress = String.fromEnvironment('BOARD');
const _seconds = int.fromEnvironment('SECONDS', defaultValue: 90);

/// `--dart-define=MAXIMIZE=true`：抄錄前先「放到最大」。
const _maximize = bool.fromEnvironment('MAXIMIZE');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('整個鄉民端連續抄錄', skip: _boardAddress.isEmpty, (tester) async {
    final parent = Directory.systemTemp.createTempSync('cam-board-app-record');
    final window = NativeWindowControl();
    final viewer = ViewerController(
      createLink: WebRtcBoardLink.new,
      window: window,
      shots: FileShotStore(),
      pickFolder: () async => parent.path,
      nameStore: _NoNameStore(),
      defaultName: '整合測試',
    );
    await tester.pumpWidget(
      CamBoardApp(
        listController: BoardListController(
          browser: BonsoirBoardBrowser(),
          probe: probeBoard,
        ),
        viewerController: viewer,
        window: window,
      ),
    );

    final clock = Stopwatch()..start();
    void say(String what) {
      // ignore: avoid_print
      print(
        '第 ${(clock.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒：$what',
      );
    }

    /// 讓程式自己跑 [seconds] 秒，狀態有變化就印出來。
    Future<void> run(int seconds) async {
      var last = '';
      final until = clock.elapsed + Duration(seconds: seconds);
      while (clock.elapsed < until) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 250)),
        );
        await tester.pump();
        final now =
            '${viewer.state.name}，抄錄中=${viewer.recording}，'
            '存了 ${viewer.savedCount} 張，錯誤=${viewer.recordingError}，'
            '通知=${viewer.notice}';
        if (now != last) say(now);
        last = now;
      }
    }

    try {
      unawaited(viewer.watch(BoardInfo.parseAddress(_boardAddress)));
      await run(8);
      expect(viewer.state, ViewerState.watching);
      if (_maximize) {
        viewer.toggleMaximize();
        await run(2);
      }
      await tester.runAsync(viewer.startRecording);
      say('開始抄錄，接下來 $_seconds 秒內按看板端的拍照：${viewer.recordingFolder}');
      await run(_seconds);
      final folder = viewer.recordingFolder;
      say('資料夾裡有：${folder == null ? '（沒有在抄錄）' : _list(folder)}');
      expect(viewer.state, ViewerState.watching);
    } finally {
      await tester.runAsync(viewer.stop);
      await tester.pump();
    }
  });
}

String _list(String folder) =>
    Directory(folder)
        .listSync()
        .map((entry) => entry.uri.pathSegments.last)
        .join('、');

class _NoNameStore implements ViewerNameStore {
  @override
  Future<String?> load() async => null;

  @override
  Future<void> save(String name) async {}
}
