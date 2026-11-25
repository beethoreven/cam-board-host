import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

import 'services/board_link.dart';
import 'services/folder_picker.dart';
import 'services/shot_store.dart';
import 'services/viewer_name_store.dart';
import 'services/window_control.dart';

/// 鄉民端觀看一個看板的流程：把 core 的規則（[ViewerSession]、視窗大小計算）
/// 接上連線和視窗。
class ViewerController extends ChangeNotifier {
  ViewerController({
    required this._createLink,
    required this._window,
    required this._shots,
    required this._pickFolder,
    required this._nameStore,
    required this._defaultName,
    this._now = DateTime.now,
    this._connectTimeout = connectTimeout,
  });

  /// 沒有放到最大時，視窗最多佔螢幕可用範圍的比例。
  static const _normalScale = 0.6;

  final BoardLinkFactory _createLink;
  final WindowControl _window;
  final ShotStore _shots;
  final FolderPicker _pickFolder;
  final ViewerNameStore _nameStore;

  /// 使用者沒取名稱時用的名稱（這台電腦的名稱）。
  final String _defaultName;
  final DateTime Function() _now;
  final ViewerRecording _recording = ViewerRecording();
  bool _pickingFolder = false;

  /// 照片一張存完才存下一張，檔名的流水號才不會亂。
  Future<void> _saving = Future.value();

  /// 從點了看板到畫面出現最多等多久。
  final Duration _connectTimeout;
  final ViewerSession _session = ViewerSession();
  ConnectProgress _progress = ConnectProgress();
  Timer? _connectTimer;
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

  /// 名稱欄位裡的文字。使用者沒取過名稱時是這台電腦的名稱。
  String get viewerNameInput => _viewerNameInput ?? _defaultName;
  String? _viewerNameInput;

  /// 報給看板端的名稱。欄位被清空時用這台電腦的名稱。
  String get viewerName {
    final typed = viewerNameInput.trim();
    return typed.isEmpty ? _defaultName : typed;
  }

  /// 讀回上次存的名稱。
  Future<void> loadViewerName() async {
    _viewerNameInput = await _nameStore.load();
    notifyListeners();
  }

  /// 使用者改了名稱欄位。
  Future<void> setViewerName(String name) async {
    _viewerNameInput = name;
    await _nameStore.save(name);
  }

  /// 正在抄錄。
  bool get recording => _recording.active;

  /// 這次抄錄存放照片的資料夾。沒有在抄錄時是 null。
  String? get recordingFolder => _recording.folder;

  /// 這次抄錄已經存了幾張。
  int get savedCount => _recording.savedCount;

  /// 抄錄出了什麼問題（建不了資料夾、存不了檔），可以直接顯示。沒有問題時是 null。
  String? get recordingError => _recordingError;
  String? _recordingError;

  /// 「我要抄錄」：請使用者選一個位置，在裡面建立這次抄錄的資料夾，
  /// 之後看板端每拍一張就存一張。只有觀看中才能開始。
  Future<void> startRecording() async {
    if (state != ViewerState.watching || recording || _pickingFolder) return;
    _recordingError = null;
    _pickingFolder = true;
    final String? parent;
    try {
      parent = await _pickFolder();
    } finally {
      _pickingFolder = false;
    }
    // 使用者按了取消，或選資料夾的這段時間觀看已經結束了。
    final board = _board;
    if (parent == null || state != ViewerState.watching || board == null) {
      return;
    }
    try {
      final folder = await _shots.createFolder(
        parent,
        recordingFolderName(board.name, _now()),
      );
      if (state != ViewerState.watching) return;
      _recording.start(folder);
      _link?.startRecording();
    } catch (_) {
      _recordingError = '沒辦法在這個位置建立資料夾，請換一個位置';
    }
    notifyListeners();
  }

  /// 「抄錄完了」。
  void stopRecording() {
    if (!recording) return;
    _recording.stop();
    _link?.stopRecording();
    notifyListeners();
  }

  /// 看板端傳來一張照片：先告訴看板端收到了（它這時就顯示誰抄錄了），再存下來。
  /// 轉成 PNG 要一點時間，不讓看板端等；存不進去時由鄉民端自己顯示原因。
  void _onShot(int id, RawFrame frame) {
    final folder = _recording.folder;
    final link = _link;
    if (folder == null || link == null) return;
    link.confirmReceived(id);
    // 存成收到那一刻鄉民端看到的樣子。
    final rotation = _rotation;
    final mirrored = _mirrored;
    _saving = _saving.then((_) async {
      // 排隊等存檔的時候抄錄已經結束（或換了一次新的抄錄）就不存了。
      if (_recording.folder != folder) return;
      try {
        await _shots.save(
          folder: folder,
          fileName: _recording.nextFileName(),
          frame: frame,
          rotation: rotation,
          mirrored: mirrored,
        );
        _recording.saved();
        _recordingError = null;
      } catch (_) {
        _recordingError = '照片存不進去，請確認資料夾還在、磁碟還有空間';
      }
      notifyListeners();
    });
  }

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
    _progress = ConnectProgress();
    final link = _createLink();
    _link = link;
    _events = link.events.listen(_onEvent);
    _connectTimer = Timer(_connectTimeout, _onConnectTimeout);
    notifyListeners();
    await link.connect(board, viewerName: viewerName);
  }

  void _onEvent(BoardLinkEvent event) {
    switch (event) {
      case VideoSizeChanged(:final size):
        if (state == ViewerState.browsing) return;
        _video = size;
        if (state == ViewerState.connecting) {
          _session.videoArrived();
          _connectTimer?.cancel();
        }
        _applyWindow();
        notifyListeners();
      case ConnectAdvanced(:final stage):
        _progress.advanceTo(stage);
      case ShotReceived(:final id, :final frame):
        _onShot(id, frame);
      case LinkEnded(:final message):
        _finish(ByeReason.boardStopped, notice: message);
    }
  }

  /// 等太久畫面還是沒出來：不再等，回到清單並說明卡在哪裡。
  void _onConnectTimeout() {
    if (state != ViewerState.connecting) return;
    final link = _link;
    _finish(
      ByeReason.boardStopped,
      notice: describeConnectFailure(_progress.failureOnTimeout),
    );
    link?.close();
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
    _connectTimer?.cancel();
    _connectTimer = null;
    // 觀看結束，抄錄也跟著結束。連線已經要關了，不用另外通知看板端。
    _recording.stop();
    _recordingError = null;
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
    _connectTimer?.cancel();
    _events?.cancel();
    _link?.close();
    super.dispose();
  }
}
