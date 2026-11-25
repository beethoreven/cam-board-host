import 'dart:async';
import 'dart:typed_data';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_browser.dart';
import 'package:cam_board_host/services/board_link.dart';
import 'package:cam_board_host/services/board_probe.dart';
import 'package:cam_board_host/services/shot_store.dart';
import 'package:cam_board_host/services/viewer_name_store.dart';
import 'package:cam_board_host/services/window_control.dart';
import 'package:cam_board_host/viewer_controller.dart';
import 'package:flutter/widgets.dart';

/// 一張 2×2、整張同一個亮度的畫面。
RawFrame grayFrame([int luma = 126]) => RawFrame(
  width: 2,
  height: 2,
  rotation: 0,
  i420: Uint8List.fromList([luma, luma, luma, luma, 128, 128]),
);

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

  void Function()? _onStopped;

  @override
  set onStopped(void Function()? handler) => _onStopped = handler;

  /// 模擬搜尋自己停掉。
  void emitStopped() => _onStopped?.call();
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
  String? joinedAs;
  bool closed = false;

  /// 送給看板端的抄錄相關通知，照順序：'start'、'stop'、'received 3'。
  final List<String> recordingSignals = [];

  @override
  Stream<BoardLinkEvent> get events => _events.stream;

  /// 模擬收到畫面，或畫面大小改變。
  void emitVideo(double width, double height) =>
      _events.add(VideoSizeChanged(Dimensions(width, height)));

  /// 模擬連線又往前一步。
  void emitAdvanced(ConnectStage stage) => _events.add(ConnectAdvanced(stage));

  /// 模擬看板端拍了一張照片傳過來。
  void emitShot(int id, [RawFrame? frame]) =>
      _events.add(ShotReceived(id, frame ?? grayFrame()));

  /// 模擬觀看被迫結束。
  void emitEnded(String message, {ByeReason? reason}) =>
      _events.add(LinkEnded(message, reason: reason));

  @override
  Future<void> connect(BoardInfo board, {required String viewerName}) async {
    connectedTo = board;
    joinedAs = viewerName;
  }

  @override
  void startRecording() => recordingSignals.add('start');

  @override
  void stopRecording() => recordingSignals.add('stop');

  @override
  void confirmReceived(int id) => recordingSignals.add('received $id');

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

/// 假的存檔：不寫檔案，只記下要求存的每一張。
class FakeShotStore implements ShotStore {
  bool failOnCreate = false;
  bool failOnSave = false;

  /// 建立過的資料夾，完整路徑。
  final List<String> folders = [];

  /// 存過的每一張。
  final List<
    ({
      String folder,
      String fileName,
      RawFrame frame,
      ViewRotation rotation,
      bool mirrored,
    })
  >
  saved = [];

  @override
  Future<String?> createFolder(String parent, String name) async {
    if (failOnCreate) throw Exception('這個位置不能寫入');
    final path = '$parent/$name';
    if (folders.contains(path)) return null;
    folders.add(path);
    return path;
  }

  /// 因為抄錄沒開始成而被收掉的資料夾。
  final List<String> discarded = [];

  @override
  Future<void> discardFolder(String folder) async => discarded.add(folder);

  @override
  Future<void> save({
    required String folder,
    required String fileName,
    required RawFrame frame,
    required ViewRotation rotation,
    required bool mirrored,
  }) async {
    if (failOnSave) throw Exception('磁碟滿了');
    saved.add((
      folder: folder,
      fileName: fileName,
      frame: frame,
      rotation: rotation,
      mirrored: mirrored,
    ));
  }
}

class FakeViewerNameStore implements ViewerNameStore {
  FakeViewerNameStore([this.saved]);

  String? saved;

  @override
  Future<String?> load() async => saved;

  @override
  Future<void> save(String name) async => saved = name;
}

/// 建立 [ViewerController] 並記下它用過的每一條連線。
class ViewerHarness {
  ViewerHarness({this.connectTimeout = const Duration(seconds: 10)});

  final Duration connectTimeout;
  final window = FakeWindow();
  final shots = FakeShotStore();
  final nameStore = FakeViewerNameStore();
  final List<FakeBoardLink> links = [];

  /// 使用者在選資料夾視窗選的位置；null 代表按了取消。
  String? pickedFolder = '/Users/me/Documents';
  int pickCount = 0;

  /// 選資料夾的視窗要等這個完成才關，用來模擬使用者選了很久。
  Completer<void>? pickGate;

  /// 抄錄開始的時間。
  DateTime now = DateTime(2026, 11, 25, 14, 30, 5);

  late final ViewerController controller = ViewerController(
    createLink: () {
      final link = FakeBoardLink();
      links.add(link);
      return link;
    },
    window: window,
    shots: shots,
    pickFolder: () async {
      pickCount++;
      await pickGate?.future;
      return pickedFolder;
    },
    nameStore: nameStore,
    defaultName: '測試用的 Mac',
    now: () => now,
    connectTimeout: connectTimeout,
  );

  FakeBoardLink get link => links.last;
}
