import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/board_signal.dart';
import 'package:flutter_test/flutter_test.dart';

/// 用真的 WebSocket 連線測「訊息連線會自己救」。這裡的看板端是測試自己扮演的，
/// 可以故意不回應、說要傳照片卻不傳。時間都縮短，測試才跑得快。
void main() {
  late _FakeBoard board;
  BoardSignal? signal;

  setUp(() async => board = await _FakeBoard.start());
  tearDown(() async {
    await signal?.close();
    await board.stop();
  });

  BoardSignal connectTo(_FakeBoard board, {int maxAttempts = 3}) =>
      signal = BoardSignal(
        uri: Uri.parse('ws://127.0.0.1:${board.port}'),
        viewerName: '阿明',
        interval: const Duration(milliseconds: 40),
        silenceTimeout: const Duration(milliseconds: 250),
        shotTimeout: const Duration(milliseconds: 250),
        maxAttempts: maxAttempts,
      );

  Future<void> wait(int milliseconds) =>
      Future<void>.delayed(Duration(milliseconds: milliseconds));

  RawFrame frame() => RawFrame(
    width: 4,
    height: 2,
    rotation: 90,
    i420: Uint8List.fromList(List.generate(12, (i) => i)),
  );

  test('連上後帶著名稱和代號加入，並定時問看板端還在不在', () async {
    final signal = connectTo(board);
    await signal.connect();
    await wait(200);

    final join = board.connections.single.received.first as JoinMessage;
    expect(join.name, '阿明');
    expect(join.session, signal.session);
    expect(join.session, hasLength(32));
    expect(
      board.connections.single.received.whereType<PingMessage>(),
      isNotEmpty,
    );
    expect(signal.reconnects, 0);
  });

  test('看板端有在回應：不會換連線', () async {
    final signal = connectTo(board);
    await signal.connect();
    await wait(800);

    expect(board.connections, hasLength(1));
    expect(signal.reconnects, 0);
  });

  test('看板端不回應：換一條新的連線，用同一個代號接回去', () async {
    final signal = connectTo(board);
    await signal.connect();
    await wait(100);
    board.connections.single.mute();
    await wait(500);

    expect(board.connections.length, greaterThanOrEqualTo(2));
    final resume = board.connections[1].received.first as ResumeMessage;
    expect(resume.session, signal.session);
    expect(signal.reconnects, greaterThanOrEqualTo(1));
  });

  test('接回之後看板端的訊息照常收得到', () async {
    final signal = connectTo(board);
    final offers = <SignalMessage>[];
    signal.messages.listen(offers.add);
    await signal.connect();
    await wait(100);
    board.connections.single.mute();
    await wait(500);

    board.connections.last.send(const OfferMessage(sdp: '新連線上的'));
    await wait(100);

    expect((offers.single as OfferMessage).sdp, '新連線上的');
  });

  test('舊連線晚到的訊息不算數', () async {
    final signal = connectTo(board);
    final messages = <SignalMessage>[];
    signal.messages.listen(messages.add);
    await signal.connect();
    await wait(100);
    final old = board.connections.single..mute();
    await wait(500);

    old.sendEvenIfMuted(const OfferMessage(sdp: '舊連線上的'));
    await wait(100);

    expect(messages, isEmpty);
  });

  test('說要傳照片卻不傳：換連線，看板端補送後收得到', () async {
    final signal = connectTo(board);
    final shots = <({int id, RawFrame frame})>[];
    signal.shots.listen(shots.add);
    await signal.connect();
    signal.recording = true;
    await wait(100);
    // 只說要傳，資料沒有跟上（就像連線卡在半路）。
    board.connections.single.send(
      const ShotMessage(id: 7, width: 4, height: 2, rotation: 90),
    );
    await wait(500);

    expect(board.connections.length, greaterThanOrEqualTo(2));
    expect(shots, isEmpty);

    // 看板端在新連線上補送。
    board.connections.last.sendShot(7, frame());
    await wait(100);

    expect(shots.single.id, 7);
    expect(shots.single.frame.i420, frame().i420);
    expect(shots.single.frame.rotation, 90);
  });

  test('照片完整送到：不換連線', () async {
    final signal = connectTo(board);
    final shots = <({int id, RawFrame frame})>[];
    signal.shots.listen(shots.add);
    await signal.connect();
    signal.recording = true;
    await wait(100);
    board.connections.single.sendShot(1, frame());
    await wait(500);

    expect(shots.single.id, 1);
    expect(board.connections, hasLength(1));
  });

  test('沒有在抄錄時送來的照片不收', () async {
    final signal = connectTo(board);
    final shots = <({int id, RawFrame frame})>[];
    signal.shots.listen(shots.add);
    await signal.connect();
    await wait(100);
    board.connections.single.sendShot(1, frame());
    await wait(200);

    expect(shots, isEmpty);
  });

  test('連續 3 次都接不回去：放棄並說明原因', () async {
    final signal = connectTo(board);
    await signal.connect();
    await wait(100);
    // 看板端整個不見了。
    await board.stop();

    final end = await signal.ended.timeout(const Duration(seconds: 5));
    expect(end.message, '和看板端的連線中斷了');
    expect(end.reason, isNull);
  });

  test('新的連線接上了卻一直沒聲音，也算沒接回去', () async {
    board.muteNewConnections = true;
    final signal = connectTo(board);
    await signal.connect();

    final end = await signal.ended.timeout(const Duration(seconds: 5));
    expect(end.message, '和看板端的連線中斷了');
    // 第一條加上 3 次重試。
    expect(board.connections, hasLength(4));
  });

  test('救回來之後次數重新算', () async {
    final signal = connectTo(board);
    await signal.connect();
    for (var round = 0; round < 5; round++) {
      await wait(100);
      board.connections.last.mute();
      await wait(450);
    }

    var ended = false;
    unawaited(signal.ended.then((_) => ended = true));
    await wait(50);
    expect(ended, isFalse, reason: '每次都救回來了，不該放棄');
    expect(signal.reconnects, greaterThanOrEqualTo(5));
  });

  test('看板端說結束：照它給的原因結束，不重連', () async {
    final signal = connectTo(board);
    await signal.connect();
    await wait(100);
    board.connections.single.send(const ByeMessage(ByeReason.boardStopped));

    final end = await signal.ended.timeout(const Duration(seconds: 2));
    expect(end.reason, ByeReason.boardStopped);
    await wait(400);
    expect(board.connections, hasLength(1));
  });

  test('接回時看板端說不認得：結束', () async {
    board.refuseResume = true;
    final signal = connectTo(board);
    await signal.connect();
    await wait(100);
    board.connections.single.mute();

    final end = await signal.ended.timeout(const Duration(seconds: 2));
    expect(end.reason, ByeReason.boardStopped);
  });

  test('自己結束觀看：告訴看板端，之後不再重連', () async {
    final signal = connectTo(board);
    await signal.connect();
    await wait(100);
    await signal.close();
    await wait(500);

    expect(board.connections.single.received.last, isA<ByeMessage>());
    expect(board.connections, hasLength(1));
  });

  test('連不上看板端：說明原因', () async {
    final port = board.port;
    await board.stop();
    final signal = BoardSignal(
      uri: Uri.parse('ws://127.0.0.1:$port'),
      viewerName: '阿明',
    );
    await signal.connect();

    final end = await signal.ended.timeout(const Duration(seconds: 2));
    expect(end.message, contains('連不上看板端'));
  });
}

/// 測試扮演的看板端：每條連進來的連線都記下來，可以個別讓它不再回應。
class _FakeBoard {
  _FakeBoard._(this._server);

  final HttpServer _server;
  final List<_Connection> connections = [];

  /// 新連進來的連線一開始就不回應（連 hello 都不送）。
  bool muteNewConnections = false;

  /// 收到接回的要求時回「結束」。
  bool refuseResume = false;

  int get port => _server.port;

  static Future<_FakeBoard> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final board = _FakeBoard._(server);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      final connection = _Connection(socket, board);
      if (board.muteNewConnections) connection.mute();
      board.connections.add(connection);
      connection.send(const HelloMessage(name: '教室白板'));
    });
    return board;
  }

  Future<void> stop() async {
    for (final connection in connections) {
      await connection.socket.close().catchError((Object _) {});
    }
    await _server.close(force: true);
  }
}

class _Connection {
  _Connection(this.socket, _FakeBoard board) {
    socket.listen((raw) {
      final message = SignalMessage.decode(raw as String);
      received.add(message);
      if (message is PingMessage) send(PongMessage(message.n));
      if (message is ResumeMessage && board.refuseResume) {
        send(const ByeMessage(ByeReason.boardStopped));
      }
    }, onError: (Object _) {});
  }

  final WebSocket socket;
  final List<SignalMessage> received = [];
  bool _muted = false;

  /// 從現在起這條連線不再送任何東西，就像卡住了一樣。
  void mute() => _muted = true;

  void send(SignalMessage message) {
    if (!_muted) sendEvenIfMuted(message);
  }

  void sendEvenIfMuted(SignalMessage message) {
    try {
      socket.add(message.encode());
    } catch (_) {}
  }

  void sendShot(int id, RawFrame frame) {
    send(
      ShotMessage(
        id: id,
        width: frame.width,
        height: frame.height,
        rotation: frame.rotation,
      ),
    );
    if (!_muted) socket.add(frame.i420);
  }
}
