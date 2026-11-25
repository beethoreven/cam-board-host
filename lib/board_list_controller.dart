import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

import 'services/board_browser.dart';
import 'services/board_probe.dart';

/// 鄉民端的看板清單流程：把搜尋結果和手動輸入接到 core 的 [BoardDirectory]。
class BoardListController extends ChangeNotifier {
  BoardListController({required this._browser, required this._probe}) {
    _browser.onStopped = () {
      _searchError = '自動搜尋停止了（可能沒有區域網路的權限），請改用手動輸入位址';
      notifyListeners();
    };
  }

  final BoardBrowser _browser;
  final BoardProbe _probe;
  final BoardDirectory _directory = BoardDirectory();
  StreamSubscription<BoardBrowserEvent>? _subscription;

  List<BoardInfo> get boards => _directory.boards;

  /// 自動搜尋沒辦法啟動時的原因，可以直接顯示。這時仍然可以手動輸入位址。
  String? get searchError => _searchError;
  String? _searchError;

  /// 上一次手動輸入失敗的原因，可以直接顯示。
  String? get manualError => _manualError;
  String? _manualError;

  /// 正在試連手動輸入的位址。
  bool get probing => _probing;
  bool _probing = false;

  /// 開始搜尋看板。重複呼叫只會開始一次，因為清單畫面在每次觀看結束後都會重新出現。
  Future<void> start() async {
    if (_subscription != null) return;
    _subscription = _browser.events.listen((event) {
      switch (event) {
        case BoardFound(:final id, :final board):
          _directory.found(id, board);
        case BoardLost(:final id):
          _directory.lost(id);
      }
      notifyListeners();
    });
    try {
      await _browser.start();
    } catch (_) {
      _searchError = '自動搜尋無法啟動，請改用手動輸入位址';
      notifyListeners();
    }
  }

  /// 手動加入一個看板。成功回傳 true，輸入框可以清空。
  Future<bool> addManual(String input) async {
    if (_probing) return false;
    _manualError = null;

    final BoardInfo target;
    try {
      target = BoardInfo.parseAddress(input);
    } on FormatException catch (e) {
      _manualError = e.message;
      notifyListeners();
      return false;
    }

    _probing = true;
    notifyListeners();
    try {
      final name = await _probe(target);
      final added = _directory.addManual(
        BoardInfo(name: name, host: target.host, port: target.port),
      );
      if (!added) _manualError = '這個看板已經在清單上了';
      return added;
    } on BoardProbeException catch (e) {
      _manualError = e.message;
      return false;
    } finally {
      _probing = false;
      notifyListeners();
    }
  }

  /// 這個看板是不是手動加入的。只有這種可以由使用者移除。
  bool isManual(BoardInfo board) => _directory.isManual(board);

  /// 移除一個手動加入的看板（看板端換了位址、或已經不在了）。
  void removeManual(BoardInfo board) {
    _directory.removeManual(board);
    notifyListeners();
  }

  @override
  void dispose() {
    _browser.onStopped = null;
    _subscription?.cancel();
    _browser.stop();
    super.dispose();
  }
}
