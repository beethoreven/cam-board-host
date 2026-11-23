import 'dart:async';
import 'dart:io';

import 'package:cam_board_core/cam_board_core.dart';

/// 連不上看板，或對方不是看板。[message] 可以直接顯示給使用者。
class BoardProbeException implements Exception {
  const BoardProbeException(this.message);

  final String message;

  @override
  String toString() => 'BoardProbeException: $message';
}

/// 試連一個位址，確認對方真的是看板，並取得它的名稱。
///
/// 失敗時丟 [BoardProbeException]。
typedef BoardProbe = Future<String> Function(BoardInfo board);

/// 實際用 WebSocket 連過去，等看板端報上名字。
Future<String> probeBoard(
  BoardInfo board, {
  Duration timeout = const Duration(seconds: 4),
}) async {
  WebSocket? socket;
  try {
    socket = await WebSocket.connect(board.signalUri.toString())
        .timeout(timeout);
    final first = await socket.first.timeout(timeout);
    final message = SignalMessage.decode(first as String);
    if (message is! HelloMessage) {
      throw const BoardProbeException('這個位址上不是看板');
    }
    if (!message.isCompatible) {
      throw const BoardProbeException('看板端和鄉民端的版本不同，請兩邊都更新');
    }
    return message.name;
  } on BoardProbeException {
    rethrow;
  } on TimeoutException {
    throw const BoardProbeException('連線逾時，請確認兩台裝置在同一個網路');
  } on SocketException {
    throw const BoardProbeException('連不上，請確認位址正確、看板端已經註冊');
  } catch (_) {
    throw const BoardProbeException('這個位址上不是看板');
  } finally {
    await socket?.close();
  }
}
