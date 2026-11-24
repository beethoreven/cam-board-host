import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

import 'services/board_link.dart';
import 'services/window_control.dart';

/// 鄉民端觀看一個看板的流程：把 core 的規則（[ViewerSession]、視窗大小計算）
/// 接上連線和視窗。
class ViewerController extends ChangeNotifier {
  ViewerController({required this._createLink, required this._window});

  /// 沒有放到最大時，視窗最多佔螢幕可用範圍的比例。
  static const _normalScale = 0.6;

  final BoardLinkFactory _createLink;
  final WindowControl _window;
  final ViewerSession _session = ViewerSession();
  BoardLink? _link;
  StreamSubscription<BoardLinkEvent>? _events;
  Dimensions? _video;

  ViewerState get state => _session.state;

  /// 正在看（或正在連）的看板。
  BoardInfo? get board => _board;
  BoardInfo? _board;

  /// 目前的連線，用來顯示畫面。沒有在看時是 null。
  BoardLink? get link => _link;

  ViewRotation get rotation => _rotation;
  ViewRotation _rotation = ViewRotation.deg0;

  bool get mirrored => _mirrored;
  bool _mirrored = false;

  bool get maximized => _maximized;
  bool _maximized = false;

  /// 上一次觀看被迫結束的原因，顯示在看板清單上。自己按「不看了」時是 null。
  String? get notice => _notice;
  String? _notice;

  /// 點了清單上的一個看板。已經在看別的看板時不會有作用。
  Future<void> watch(BoardInfo board) async {
    if (state != ViewerState.browsing) return;
    _session.startConnecting();
    _board = board;
    _notice = null;
    _rotation = ViewRotation.deg0;
    _mirrored = false;
    _maximized = false;
    _video = null;
    final link = _createLink();
    _link = link;
    _events = link.events.listen(_onEvent);
    notifyListeners();
    await link.connect(board);
  }

  void _onEvent(BoardLinkEvent event) {
    switch (event) {
      case VideoSizeChanged(:final size):
        if (state == ViewerState.browsing) return;
        _video = size;
        if (state == ViewerState.connecting) _session.videoArrived();
        _applyWindow();
        notifyListeners();
      case LinkEnded(:final message):
        _finish(ByeReason.boardStopped, notice: message);
    }
  }

  /// 順時針轉 90 度。
  void rotate() {
    if (state != ViewerState.watching) return;
    _rotation = _rotation.next;
    _applyWindow();
    notifyListeners();
  }

  /// 左右反轉。不影響視窗大小。
  void toggleMirror() {
    if (state != ViewerState.watching) return;
    _mirrored = !_mirrored;
    notifyListeners();
  }

  /// 放到最大，或還原。
  void toggleMaximize() {
    if (state != ViewerState.watching) return;
    _maximized = !_maximized;
    _applyWindow();
    notifyListeners();
  }

  /// 「不看了」。連線中也可以按。
  Future<void> stop() async {
    if (state == ViewerState.browsing) return;
    final link = _link;
    _finish(ByeReason.viewerLeft);
    await link?.close();
  }

  void _finish(ByeReason reason, {String? notice}) {
    if (state == ViewerState.browsing) return;
    _events?.cancel();
    _events = null;
    _link = null;
    _board = null;
    _video = null;
    _notice = notice;
    _session.end(reason);
    _window.showList();
    notifyListeners();
  }

  /// 讓視窗剛好等於畫面：沒有黑邊，空出來的地方看得到後面的桌面。
  void _applyWindow() {
    final video = _video;
    if (video == null) return;
    final area = _window.workArea();

    if (_maximized) {
      final fit = fitWindowToScreen(
        video: video,
        rotation: _rotation,
        screen: area.size,
      );
      _window.showVideo(
        WindowFrame(
          left: area.left + fit.left,
          top: area.top + fit.top,
          size: fit.size,
        ),
      );
      return;
    }

    final size = fitWindowToScreen(
      video: video,
      rotation: _rotation,
      screen: Dimensions(
        area.size.width * _normalScale,
        area.size.height * _normalScale,
      ),
    ).size;
    // 以視窗目前的中心點為準，旋轉或手機轉向時視窗不會跳到別的地方。
    final current = _window.currentFrame();
    final centerX = current.left + current.size.width / 2;
    final centerY = current.top + current.size.height / 2;
    _window.showVideo(
      WindowFrame(
        left: _keepInside(
          centerX - size.width / 2,
          area.left,
          area.left + area.size.width - size.width,
        ),
        top: _keepInside(
          centerY - size.height / 2,
          area.top,
          area.top + area.size.height - size.height,
        ),
        size: size,
      ),
    );
  }

  double _keepInside(double value, double min, double max) =>
      max < min ? min : value.clamp(min, max).toDouble();

  @override
  void dispose() {
    _events?.cancel();
    _link?.close();
    super.dispose();
  }
}
