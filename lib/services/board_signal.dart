import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/foundation.dart';

/// 鄉民端對看板端的「訊息連線」（WebSocket），會自己救：
///
/// - 每隔一下問看板端「你還在嗎」，太久沒有任何回應就換一條新的連線，
///   用同一個代號接回原本那一次觀看（[ResumeMessage]）。
/// - 看板端說要傳照片、資料卻遲遲不到時也一樣換一條；接回之後看板端會再送一次。
/// - 連續幾次都接不回去才放棄，從 [ended] 通知。
///
/// 規則和數值在 core 的 `recovery.dart`。這裡不碰視訊，所以可以用真的連線單獨測。
class BoardSignal {
  BoardSignal({
    required this.uri,
    required this.viewerName,
    this.interval = heartbeatInterval,
    this.silenceTimeout = heartbeatTimeout,
    this.shotTimeout = shotDataTimeout,
    this.connectTimeout = const Duration(seconds: 6),
    int maxAttempts = maxRecoveryAttempts,
  }) : _attempts = RecoveryAttempts(limit: maxAttempts),
       _heartbeat = Heartbeat(timeout: silenceTimeout);

  final Uri uri;
  final String viewerName;

  /// 多久問一次「你還在嗎」。
  final Duration interval;

  /// 多久沒有任何回應就換連線。換連線時，新連線也最多等這麼久。
  final Duration silenceTimeout;

  /// 說好要來的照片多久沒到就換連線。
  final Duration shotTimeout;

  /// 第一次連線最多等多久。
  final Duration connectTimeout;

  /// 這一次觀看的代號，接回時用。
  final String session = _newSession();

  final RecoveryAttempts _attempts;
  final Heartbeat _heartbeat;
  final Stopwatch _clock = Stopwatch();
  final _messages = StreamController<SignalMessage>.broadcast();
  final _shots = StreamController<({int id, RawFrame frame})>.broadcast();
  final _ended = Completer<({String message, ByeReason? reason})>();

  WebSocket? _socket;
  StreamSubscription<Object?>? _subscription;

  /// 目前是第幾條連線。舊連線晚到的訊息和斷線通知靠它分辨出來，不能算數。
  int _generation = 0;
  Timer? _timer;
  bool _closed = false;
  bool _reconnecting = false;

  /// 我們告訴過看板端「正在抄錄」。沒有在抄錄時送來的照片一律不收。
  bool _recording = false;

  /// 看板端剛說「接下來那一筆資料是一張照片」，在等那筆資料；以及從什麼時候開始等。
  ShotMessage? _awaitedShot;
  Duration _awaitedSince = Duration.zero;

  /// 訊息一則處理完才交出下一則，順序才不會亂。
  Future<void> _handling = Future.value();

  /// 看板端送來、要交給視訊那一層處理的訊息（連線資訊、網路路徑等）。
  Stream<SignalMessage> get messages => _messages.stream;

  /// 完整收到的照片。同一張可能因為補送而出現兩次，由上層用編號去重。
  Stream<({int id, RawFrame frame})> get shots => _shots.stream;

  /// 這條訊息連線救不回來了，或看板端說結束了。只會完成一次；
  /// 自己呼叫 [close] 不會完成它。
  Future<({String message, ByeReason? reason})> get ended => _ended.future;

  /// 成功換過幾次連線（查問題和測試用）。
  int get reconnects => _generation > 0 ? _generation - 1 : 0;

  static String _newSession() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// 連到看板並要求觀看。連不上時從 [ended] 通知。
  Future<void> connect() async {
    _clock.start();
    try {
      final socket = await WebSocket.connect(uri.toString())
          .timeout(connectTimeout);
      if (_closed) {
        await socket.close();
        return;
      }
      _attach(socket);
      send(JoinMessage(name: viewerName, session: session));
      _timer = Timer.periodic(interval, (_) => _tick());
    } on TimeoutException {
      _end('連線逾時，請確認兩台裝置在同一個網路');
    } on SocketException {
      _end('連不上看板端，它可能已經撤銷註冊');
    } catch (_) {
      _end('無法開始觀看');
    }
  }

  void _attach(WebSocket socket) {
    final generation = ++_generation;
    _socket = socket;
    _subscription = socket.listen(
      (raw) => _handling = _handling.then((_) => _onRaw(generation, raw)),
      onDone: () => _socketGone(generation),
      onError: (_) => _socketGone(generation),
      cancelOnError: true,
    );
  }

  void send(SignalMessage message) {
    try {
      _socket?.add(message.encode());
    } catch (_) {
      // 連線剛好在關：不用處理，沒回應的話接下來會換連線。
    }
  }

  /// 告訴看板端開始或結束抄錄。接回連線時看板端記得這個狀態，不用重送。
  set recording(bool on) {
    _recording = on;
    if (!on) _awaitedShot = null;
    send(on ? const RecordStartMessage() : const RecordStopMessage());
  }

  void _tick() {
    if (_closed || _reconnecting) return;
    final now = _clock.elapsed;
    final shot = _awaitedShot;
    if (shot != null && now - _awaitedSince >= shotTimeout) {
      _reconnect('照片 ${shot.id} 的資料等了 ${shotTimeout.inSeconds} 秒還沒到');
    } else if (_heartbeat.silent(now)) {
      _reconnect('看板端 ${silenceTimeout.inSeconds} 秒沒有回應');
    } else {
      send(PingMessage(_heartbeat.ask(now)));
    }
  }

  void _socketGone(int generation) {
    if (_closed || generation != _generation) return;
    _reconnect('連線斷了');
  }

  /// 換一條新的連線接回去。
  Future<void> _reconnect(String why) async {
    if (_closed || _reconnecting) return;
    if (_attempts.exhausted) {
      _end('和看板端的連線中斷了');
      return;
    }
    _reconnecting = true;
    _attempts.failed();
    debugPrint('訊息連線：$why，換一條新的（連續第 ${_attempts.failedInARow} 次）');
    final stale = _socket;
    _socket = null;
    // 舊的那條多半已經卡住，正常的關閉流程可能等不到對方回應，這裡不等它。
    unawaited(stale?.close().catchError((Object _) => null));
    // 沒收完的那張不等了：接回之後看板端會從頭再說一次、再送一次。
    _awaitedShot = null;
    // 從現在重新算「多久沒有回應」，新連線連不上或接上了卻沒聲音，都會再試下一次。
    _heartbeat
      ..reset()
      ..ask(_clock.elapsed);
    try {
      final socket = await WebSocket.connect(uri.toString())
          .timeout(silenceTimeout);
      if (_closed) {
        await socket.close();
        return;
      }
      _attach(socket);
      send(ResumeMessage(session: session));
    } catch (e) {
      debugPrint('訊息連線：新的那條連不上（$e）');
      // 連不上：讓它跟「沒有回應」一樣，下一輪直接再試（或放棄）。
      _heartbeat
        ..reset()
        ..ask(_clock.elapsed - silenceTimeout);
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _onRaw(int generation, Object? raw) async {
    if (_closed || generation != _generation) return;
    // 收到任何東西都代表看板端到這裡的方向是通的。
    _heartbeat.heard();
    if (_attempts.failedInARow > 0) {
      debugPrint('訊息連線：新的連線有回應了');
      _attempts.succeeded();
    }
    if (raw is List<int>) {
      // 二進位資料只有一種：緊接在 shot 訊息後面的那張照片。
      final shot = _awaitedShot;
      _awaitedShot = null;
      debugPrint(
        '收到 ${raw.length} bytes 的資料，'
        '${shot == null ? '但沒有在等照片' : '在等照片 ${shot.id}（應該是 ${shot.bytes} bytes）'}',
      );
      if (shot != null && raw.length == shot.bytes) {
        _shots.add((
          id: shot.id,
          frame: RawFrame(
            width: shot.width,
            height: shot.height,
            rotation: shot.rotation,
            i420: raw is Uint8List ? raw : Uint8List.fromList(raw),
          ),
        ));
      }
      return;
    }
    if (raw is! String) return;
    final SignalMessage message;
    try {
      message = SignalMessage.decode(raw);
    } on FormatException {
      return;
    }
    switch (message) {
      case HelloMessage():
        if (!message.isCompatible) {
          _end(
            describeByeReason(ByeReason.versionMismatch),
            reason: ByeReason.versionMismatch,
          );
        }
      case PongMessage():
        // 已經算過「有回應」了。
        break;
      case ShotMessage():
        debugPrint(
          '看板端說要傳照片 ${message.id}'
          '${_recording ? '' : '，但沒有在抄錄，不收'}'
          '${_awaitedShot == null ? '' : '；上一張（${_awaitedShot!.id}）的資料還沒到'}',
        );
        if (_recording) {
          _awaitedShot = message;
          _awaitedSince = _clock.elapsed;
        }
      case ByeMessage(:final reason):
        _end(describeByeReason(reason), reason: reason);
      case OfferMessage() || CandidateMessage() || CandidatesDoneMessage():
        _messages.add(message);
      case JoinMessage() ||
          AnswerMessage() ||
          RecordStartMessage() ||
          RecordStopMessage() ||
          ShotReceivedMessage() ||
          ResumeMessage() ||
          PingMessage() ||
          VideoRestartMessage():
        // 這幾種只會由鄉民端送出，看板端送來就忽略。
        break;
    }
  }

  /// 測試用：讓目前這條連線從現在起不再讀進任何東西，就像卡在半路一樣。
  /// 實機上沒辦法叫網路卡住，用這個來驗證「換一條接回去」整段流程。
  @visibleForTesting
  void debugStall() => _subscription?.pause();

  /// 被迫結束：通知上層，並把資源收掉。
  void _end(String message, {ByeReason? reason}) {
    if (_closed) return;
    debugPrint(
      '訊息連線結束：$message'
      '${_awaitedShot == null ? '' : '（照片 ${_awaitedShot!.id} 的資料還沒到）'}',
    );
    _ended.complete((message: message, reason: reason));
    _release();
  }

  /// 結束觀看並告訴看板端。重複呼叫不會出錯。
  Future<void> close() async {
    if (_closed) return;
    send(const ByeMessage(ByeReason.viewerLeft));
    await _release();
  }

  Future<void> _release() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    final socket = _socket;
    _socket = null;
    try {
      // 對方不回應時，正常的關閉流程會卡住，所以只等一下。
      await socket?.close().timeout(const Duration(seconds: 1));
    } catch (_) {
      // 收尾時對方可能已經先斷線，這裡的錯誤不影響使用者。
    }
    await _messages.close();
    await _shots.close();
  }
}

/// 把看板端送來的結束原因轉成給使用者看的文字。
String describeByeReason(ByeReason reason) => switch (reason) {
  ByeReason.boardStopped => '看板端不給看了',
  ByeReason.boardUnregistered => '看板端撤銷註冊了',
  ByeReason.versionMismatch => '看板端和鄉民端的版本不同，請兩邊都更新',
  ByeReason.viewerLeft => '已結束觀看',
};
