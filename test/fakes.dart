import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_browser.dart';
import 'package:cam_board_host/services/board_probe.dart';

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
