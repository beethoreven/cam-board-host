import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_browser.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:cam_board_host/services/board_probe.dart';
import 'package:cam_board_host/services/window_control.dart';
import 'package:cam_board_host/viewer_controller.dart';
import 'package:flutter/widgets.dart';

class FakeBrowser implements BoardBrowser {
  final _events = StreamController<BoardBrowserEvent>.broadcast(sync: true);
  bool failOnStart = false;
  bool running = false;

  @override
  Stream<BoardBrowserEvent> get events => _events.stream;

  void emitFound(String id, BoardInfo board) =>
      _events.add(BoardFound(id, board));

  void emitLost(String id) => _events.add(BoardLost(id));

  @override
  Future<void> start() async {
    if (failOnStart) throw Exception('搜尋無法啟動');
    running = true;
  }

  @override
  Future<void> stop() async => running = false;
}

/// 假的試連：[names] 裡有的位址回傳對應的看板名稱，其他一律連不上。
class FakeProbe {
  FakeProbe([this.names = const {}]);

  final Map<String, String> names;
  final List<String> probed = [];

  Future<String> call(BoardInfo board) async {
    probed.add(board.address);
    final name = names[board.address];
    if (name == null) throw const BoardProbeException('連不上');
    return name;
  }
}

/// 假的看板連線：測試可以自己決定什麼時候收到畫面、什麼時候被結束。
class FakeBoardLink implements BoardLink {
  final _events = StreamController<BoardLinkEvent>.broadcast(sync: true);
  BoardInfo? connectedTo;
  bool closed = false;

  @override
  Stream<BoardLinkEvent> get events => _events.stream;

  /// 模擬收到畫面，或畫面大小改變。
  void emitVideo(double width, double height) =>
      _events.add(VideoSizeChanged(Dimensions(width, height)));

  /// 模擬連線又往前一步。
  void emitAdvanced(ConnectStage stage) => _events.add(ConnectAdvanced(stage));

  /// 模擬觀看被迫結束。
  void emitEnded(String message) => _events.add(LinkEnded(message));

  @override
  Future<void> connect(BoardInfo board) async => connectedTo = board;

  @override
  Widget buildView() => const ColoredBox(
    key: Key('video'),
    color: Color(0xFF224466),
    child: SizedBox.expand(),
  );

  @override
  Future<void> close() async => closed = true;
}

/// 假的視窗：螢幕可用範圍是 1920×1080，起點在 (0, 25)，模擬上方有選單列。
class FakeWindow implements WindowControl {
  ScreenArea area = (left: 0, top: 25, size: const Dimensions(1920, 1080));
  WindowFrame frame = const WindowFrame(
    left: 560,
    top: 265,
    size: Dimensions(800, 600),
  );
  final WindowFrame _listFrame = const WindowFrame(
    left: 560,
    top: 265,
    size: Dimensions(800, 600),
  );

  /// 目前是不是觀看用的無邊框視窗。
  bool videoMode = false;

  @override
  ScreenArea workArea() => area;

  @override
  WindowFrame currentFrame() => frame;

  @override
  void showVideo(WindowFrame frame) {
    videoMode = true;
    this.frame = frame;
  }

  @override
  void showList() {
    videoMode = false;
    frame = _listFrame;
  }

  @override
  Widget dragArea({required Widget child}) => child;
}

/// 建立 [ViewerController] 並記下它用過的每一條連線。
class ViewerHarness {
  ViewerHarness({this.connectTimeout = const Duration(seconds: 10)});

  final Duration connectTimeout;
  final window = FakeWindow();
  final List<FakeBoardLink> links = [];

  late final ViewerController controller = ViewerController(
    createLink: () {
      final link = FakeBoardLink();
      links.add(link);
      return link;
    },
    window: window,
    connectTimeout: connectTimeout,
  );

  FakeBoardLink get link => links.last;
}
