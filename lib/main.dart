import 'package:flutter/material.dart';

import 'board_list_controller.dart';
import 'screens/board_list_screen.dart';
import 'services/board_browser.dart';
import 'services/board_probe.dart';

void main() {
  runApp(
    CamBoardApp(
      controller: BoardListController(
        browser: BonsoirBoardBrowser(),
        probe: probeBoard,
      ),
    ),
  );
}

/// 鄉民端。
class CamBoardApp extends StatelessWidget {
  const CamBoardApp({super.key, required this.controller});

  final BoardListController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '鄉民端',
      home: BoardListScreen(controller: controller),
    );
  }
}
