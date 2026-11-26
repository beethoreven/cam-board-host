import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/material.dart';

import 'board_list_controller.dart';
import 'screens/board_list_screen.dart';
import 'screens/viewing_screen.dart';
import 'services/board_browser.dart';
import 'services/board_link.dart';
import 'services/board_probe.dart';
import 'services/debug_log.dart';
import 'services/folder_picker.dart';
import 'services/shot_store.dart';
import 'services/viewer_name_store.dart';
import 'services/window_control.dart';
import 'viewer_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 查問題用：紀錄另外寫一份到檔案，見 CLAUDE.md。
  startDebugLogFile('cam-board-host-debug.log');
  final window = NativeWindowControl();
  final viewerController = ViewerController(
    createLink: WebRtcBoardLink.new,
    window: window,
    shots: FileShotStore(),
    pickFolder: pickFolderWithSystemDialog,
    nameStore: PrefsViewerNameStore(),
    defaultName: computerName(),
  );
  // 名稱欄位一出現就要有上次的名稱，所以先讀好再顯示畫面。
  await viewerController.loadViewerName();
  runApp(
    CamBoardApp(
      listController: BoardListController(
        browser: BonsoirBoardBrowser(),
        probe: probeBoard,
      ),
      viewerController: viewerController,
      window: window,
    ),
  );
}

/// 鄉民端。沒有在看時顯示看板清單，點了看板就切到觀看畫面。
class CamBoardApp extends StatelessWidget {
  const CamBoardApp({
    super.key,
    required this.listController,
    required this.viewerController,
    required this.window,
  });

  final BoardListController listController;
  final ViewerController viewerController;
  final WindowControl window;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鄉民端',
      home: ListenableBuilder(
        listenable: viewerController,
        builder: (context, _) => viewerController.state == ViewerState.browsing
            ? BoardListScreen(
                controller: listController,
                onWatch: viewerController.watch,
                notice: viewerController.notice,
                viewerName: viewerController.viewerNameInput,
                onViewerNameChanged: viewerController.setViewerName,
              )
            : ViewingScreen(controller: viewerController, window: window),
      ),
    );
  }
}
