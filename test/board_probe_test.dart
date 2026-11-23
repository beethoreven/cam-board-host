import 'dart:io';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// 這裡架一個真的 WebSocket 伺服器來扮演看板端，確認試連的行為。
void main() {
  late HttpServer server;

  /// 啟動伺服器，連線建立後送出 [firstMessage]（null 表示什麼都不送）。
  Future<BoardInfo> serve(String? firstMessage) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      if (firstMessage != null) socket.add(firstMessage);
    });
    return BoardInfo(name: '?', host: '127.0.0.1', port: server.port);
  }

  tearDown(() => server.close(force: true));

  Matcher throwsProbe(String fragment) => throwsA(
    isA<BoardProbeException>().having(
      (e) => e.message,
      'message',
      contains(fragment),
    ),
  );

  test('對方是看板時回傳它的名稱', () async {
    final board = await serve(const HelloMessage(name: '教室白板').encode());
    expect(await probeBoard(board), '教室白板');
  });

  test('對方送來的不是問候訊息', () async {
    final board = await serve(const OfferMessage(sdp: 'v=0').encode());
    expect(probeBoard(board), throwsProbe('不是看板'));
  });

  test('對方送來看不懂的內容', () async {
    final board = await serve('hello there');
    expect(probeBoard(board), throwsProbe('不是看板'));
  });

  test('對方的版本不同', () async {
    final board = await serve(
      const HelloMessage(name: '教室白板', protocol: 999).encode(),
    );
    expect(probeBoard(board), throwsProbe('版本不同'));
  });

  test('對方連上了卻一直不說話', () async {
    final board = await serve(null);
    expect(
      probeBoard(board, timeout: const Duration(milliseconds: 200)),
      throwsProbe('逾時'),
    );
  });

  test('那個位址上沒有任何程式', () async {
    final board = await serve(null);
    await server.close(force: true);
    expect(probeBoard(board), throwsProbe('連不上'));
  });
}
