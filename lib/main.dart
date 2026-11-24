import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/material.dart';

import 'board_list_controller.dart';
import 'screens/board_list_screen.dart';
import 'screens/viewing_screen.dart';
import 'services/board_browser.dart';
import 'services/board_link.dart';
import 'services/board_probe.dart';
import 'services/window_control.dart';
import 'viewer_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final window = NativeWindowControl();
  runApp(
    CamBoardApp(
      listController: BoardListController(
        browser: BonsoirBoardBrowser(),
        probe: probeBoard,
      ),
      viewerController: ViewerController(
        createLink: WebRtcBoardLink.new,
        window: window,
      ),
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
              )
            : ViewingScreen(controller: viewerController, window: window),
      ),
    );
  }
}
