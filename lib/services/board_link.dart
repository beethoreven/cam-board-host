import 'dart:async';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'board_signal.dart';
import 'debug_log.dart';

export 'board_signal.dart' show describeByeReason;

/// 觀看過程中發生的事。
sealed class BoardLinkEvent {
  const BoardLinkEvent();
}

/// 收到畫面，或畫面的大小變了（例如手機轉向）。第一次出現代表開始看得到了。
final class VideoSizeChanged extends BoardLinkEvent {
  const VideoSizeChanged(this.size);

  /// 畫面顯示出來的寬高，已經把手機的方向算進去。
  final Dimensions size;
}

/// 連線又往前一步。畫面遲遲不出來時，靠這個判斷卡在哪裡。
final class ConnectAdvanced extends BoardLinkEvent {
  const ConnectAdvanced(this.stage);

  final ConnectStage stage;
}

/// 看板端拍了一張照片傳過來（只有抄錄中才會收到）。
final class ShotReceived extends BoardLinkEvent {
  const ShotReceived(this.id, this.frame);

  /// 這張照片的編號，用 [BoardLink.confirmReceived] 回報收到了。
  final int id;

  /// 照片的畫面，還沒壓縮，也還沒轉正。
  final RawFrame frame;
}

/// 觀看結束了，而且不是鄉民端自己按「不看了」造成的。
final class LinkEnded extends BoardLinkEvent {
  const LinkEnded(this.message, {this.reason});

  /// 結束的原因，可以直接顯示給使用者。
  final String message;

  /// 看板端明確說出的結束原因。連線中斷這類沒有人說「結束」的情況是 null。
  final ByeReason? reason;
}

/// 鄉民端對一個看板的連線：交換連線資訊、接收畫面。
abstract interface class BoardLink {
  Stream<BoardLinkEvent> get events;

  /// 連到看板並要求觀看，[viewerName] 是報給看板端的鄉民名稱。
  /// 連不上時會從 [events] 送出 [LinkEnded]。
  Future<void> connect(BoardInfo board, {required String viewerName});

  /// 告訴看板端：我開始抄錄了，之後拍的照片請傳給我。
  void startRecording();

  /// 告訴看板端：我抄錄完了。
  void stopRecording();

  /// 告訴看板端：編號 [id] 的照片完整收到了。
  void confirmReceived(int id);

  /// 顯示收到的畫面。
  Widget buildView();

  /// 結束觀看並告訴看板端。重複呼叫不會出錯。
  Future<void> close();
}

/// 建立一條新的連線。每次觀看用一條新的。
typedef BoardLinkFactory = BoardLink Function();

/// 把「等到逾時畫面還是沒出來」的原因轉成給使用者看的文字。
String describeConnectFailure(ConnectFailure failure) => switch (failure) {
  ConnectFailure.boardUnreachable => '連線逾時，請確認兩台裝置在同一個網路',
  ConnectFailure.boardSilent => '看板端沒有回應',
  ConnectFailure.exchangeStalled => '和看板端交換連線資訊時中斷了',
  ConnectFailure.noWorkingPath => '兩台裝置之間的網路不通。有些熱點不允許裝置互相連線，請換一個網路',
};

/// 用 WebSocket 交換連線資訊、用 WebRTC 接收畫面。
///
/// 兩條連線各自會救（規則在 core 的 `recovery.dart`）：訊息連線卡住時由
/// [BoardSignal] 換一條新的接回去；視訊連續幾秒沒有新畫面時，這裡把視訊連線
/// 整條重建（請看板端重送連線資訊）。畫面元件兩者都不動，所以視窗不會閃回清單。
class WebRtcBoardLink implements BoardLink {
  final _events = StreamController<BoardLinkEvent>.broadcast();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  BoardSignal? _signal;
  RTCPeerConnection? _connection;
  StreamSubscription<SignalMessage>? _messages;
  StreamSubscription<({int id, RawFrame frame})>? _shots;
  bool _closed = false;

  /// 建立過幾條視訊連線，只用來在紀錄裡分辨是哪一條。
  static int _created = 0;

  /// 查問題用的紀錄，同時也是每秒讀統計的來源。
  ConnectionLog? _log;

  /// 判斷畫面有沒有停住，以及連續重建了幾次都沒救回來。
  final VideoStallDetector _stall = VideoStallDetector();
  final RecoveryAttempts _videoAttempts = RecoveryAttempts();
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _stallTimer;

  /// 目前這條視訊連線解出了幾張畫面（從每秒的統計讀來）。
  int _framesDecoded = 0;

  /// 這一次觀看曾經有過畫面。在那之前畫面出不來，由上層的連線逾時處理
  /// （它分得出卡在哪一步），這裡不重建。
  bool _everHadPicture = false;

  /// 已經請看板端重建、還在等新的連線資訊。
  bool _restarting = false;

  /// 上一次記下「已經幾秒沒有新畫面」是記到第幾秒，避免同一秒記兩次。
  int _notedStall = 0;

  /// 看板端的網路路徑常常比我們處理完它的連線資訊還早到，先留著。
  /// 每一條視訊連線各用一個。
  CandidateGate _candidates = CandidateGate((_) async {});

  /// 訊息一則處理完才處理下一則。處理連線資訊要一段時間，
  /// 不排隊的話後面的訊息會在它做到一半時插進來。
  Future<void> _handling = Future.value();

  @override
  Stream<BoardLinkEvent> get events => _events.stream;

  @override
  Future<void> connect(BoardInfo board, {required String viewerName}) async {
    try {
      await _renderer.initialize();
      _renderer.onResize = _reportSize;
    } catch (_) {
      _fail('無法開始觀看');
      return;
    }
    if (_closed) return;
    final signal = BoardSignal(uri: board.signalUri, viewerName: viewerName);
    _signal = signal;
    _messages = signal.messages.listen(
      (message) => _handling = _handling.then((_) => _onMessage(message)),
    );
    _shots = signal.shots.listen((shot) {
      if (!_closed) _events.add(ShotReceived(shot.id, shot.frame));
    });
    unawaited(
      signal.ended.then((end) => _fail(end.message, reason: end.reason)),
    );
    await signal.connect();
    if (_closed) return;
    _events.add(const ConnectAdvanced(ConnectStage.waitingForOffer));
    _stallTimer = Timer.periodic(heartbeatInterval, (_) => _checkStall());
  }

  Future<void> _onMessage(SignalMessage message) async {
    if (_closed) return;
    try {
      switch (message) {
        case OfferMessage(:final sdp):
          _events.add(const ConnectAdvanced(ConnectStage.exchangingPaths));
          await _answer(sdp);
        case CandidateMessage():
          await _candidates.add(message);
        case CandidatesDoneMessage():
          // 只用來判斷連不上的原因，不交給視訊連線：
          // 判定連不上靠的是我們自己的逾時（見 ViewerController）。
          _events.add(const ConnectAdvanced(ConnectStage.pathsComplete));
        default:
          // 其他種類 BoardSignal 已經處理掉了，不會送到這裡。
          break;
      }
    } catch (e) {
      debugPrint('處理看板端的訊息失敗：$e');
      // 曾經有畫面的話當成視訊壞了，照規則重建；一開始就失敗才直接結束。
      if (_everHadPicture) {
        await _restartVideo('處理連線資訊失敗');
      } else {
        _fail('無法開始觀看');
      }
    }
  }

  /// 收到看板端的連線資訊：建立只收不送的連線，並回覆。
  /// 重建時也是走這裡，舊的那條先收掉。
  Future<void> _answer(String offerSdp) async {
    await _dropConnection();
    // 兩端都在同一個區域網路，不需要外部伺服器協助連線。
    final connection = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    // 建立連線的這段時間觀看可能已經結束了（逾時、按了「不看了」）。
    // 這時沒有人會再來收這條連線，要自己關掉。
    if (_closed) {
      await connection.close();
      return;
    }
    _connection = connection;
    _videoConnections++;
    _restarting = false;
    _framesDecoded = 0;
    _stall.connectionStarted(_clock.elapsed);
    final number = ++_created;
    final log = ConnectionLog(
      connection,
      '鄉民端#$number',
      const {'inbound-rtp', 'candidate-pair', 'transport'},
      onStats: (reports) {
        if (!identical(_connection, connection)) return;
        for (final report in reports) {
          if (report.type != 'inbound-rtp') continue;
          final frames = report.values['framesDecoded'];
          if (frames is num) _framesDecoded = frames.toInt();
        }
      },
    );
    _log = log;
    final candidates = CandidateGate(
      (candidate) async => connection.addCandidate(
        RTCIceCandidate(
          candidate.candidate,
          candidate.sdpMid,
          candidate.sdpMLineIndex,
        ),
      ),
    );
    _candidates = candidates;
    connection.onIceConnectionState = (state) => log.stateChanged('ICE', state);
    connection.onSignalingState = (state) => log.stateChanged('交換連線資訊', state);
    connection.onIceGatheringState = (state) =>
        log.stateChanged('找網路路徑', state);
    connection.onTrack = (event) {
      debugPrint('連線 鄉民端#$number：收到 ${event.track.kind} 軌');
      if (!identical(_connection, connection)) return;
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        _renderer.srcObject = event.streams.first;
      }
    };
    connection.onIceCandidate = (candidate) {
      final text = candidate.candidate;
      if (text == null || text.isEmpty) return;
      if (!identical(_connection, connection)) return;
      _signal?.send(
        CandidateMessage(
          candidate: text,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ),
      );
    };
    connection.onConnectionState = (state) {
      log.stateChanged('整體', state);
      if (!identical(_connection, connection)) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        // 曾經有畫面：照規則重建。一開始就連不上：交給上層的連線逾時去說明原因。
        if (_everHadPicture) {
          _restartVideo('視訊連線失敗');
        } else {
          _fail('畫面的連線中斷了');
        }
      }
    };
    await connection.setRemoteDescription(
      RTCSessionDescription(offerSdp, 'offer'),
    );
    await candidates.open();
    final answer = await connection.createAnswer();
    await connection.setLocalDescription(answer);
    _signal?.send(AnswerMessage(sdp: answer.sdp!));
    log.start();
  }

  /// 測試用：讓訊息連線卡住（見 [BoardSignal.debugStall]）。
  @visibleForTesting
  // ignore: invalid_use_of_visible_for_testing_member
  void debugStallSignal() => _signal?.debugStall();

  /// 測試用：把視訊連線硬關掉，不通知任何人，就像畫面突然不再進來。
  @visibleForTesting
  Future<void> debugBreakVideo() async => _connection?.close();

  /// 測試用：視訊連線重建過幾次、訊息連線換過幾次、目前這條視訊解出幾張。
  @visibleForTesting
  int get debugVideoConnections => _videoConnections;
  int _videoConnections = 0;

  @visibleForTesting
  int get debugSignalReconnects => _signal?.reconnects ?? 0;

  @visibleForTesting
  int get debugFramesDecoded => _framesDecoded;

  /// 每秒看一次畫面有沒有在動。
  void _checkStall() {
    if (_closed) return;
    final stalled = _stall.sample(_framesDecoded, _clock.elapsed);
    // 還沒到要重建的程度，但已經停了一陣子：留一筆，之後看得出「差一點」。
    final still = _stall.stalledFor(_clock.elapsed).inSeconds;
    if (_everHadPicture && !stalled && still >= 2 && still != _notedStall) {
      _notedStall = still;
      debugPrint('視訊：已經 $still 秒沒有新畫面（累計解出 $_framesDecoded 張）');
    } else if (still == 0 && _notedStall > 0) {
      debugPrint('視訊：畫面又在動了（之前停了 $_notedStall 秒）');
      _notedStall = 0;
    }
    if (_stall.hasPicture) {
      if (!_everHadPicture) debugPrint('視訊：有畫面了');
      _everHadPicture = true;
      if (!stalled && _videoAttempts.failedInARow > 0) {
        debugPrint('視訊：重建之後畫面回來了');
        _videoAttempts.succeeded();
      }
    }
    if (stalled && _everHadPicture) {
      _restartVideo('${videoStallTimeout.inSeconds} 秒沒有新畫面');
    }
  }

  /// 把視訊連線整條重建：收掉舊的，請看板端重送連線資訊。
  Future<void> _restartVideo(String why) async {
    if (_closed) return;
    if (_videoAttempts.exhausted) {
      _fail('畫面的連線中斷了');
      return;
    }
    _videoAttempts.failed();
    debugPrint('視訊：$why，重建（連續第 ${_videoAttempts.failedInARow} 次）');
    _restarting = true;
    // 從現在重新等：等不到新的連線資訊或新的畫面，時間到會再試一次。
    _framesDecoded = 0;
    _stall.connectionStarted(_clock.elapsed);
    await _dropConnection();
    _signal?.send(const VideoRestartMessage());
  }

  /// 收掉目前的視訊連線（畫面元件留著，停在最後一張）。
  Future<void> _dropConnection() async {
    final connection = _connection;
    _connection = null;
    _log?.stop();
    _log = null;
    _candidates = CandidateGate((_) async {});
    if (connection == null) return;
    try {
      await connection.close();
    } catch (_) {
      // 已經壞掉的連線關不乾淨沒關係。
    }
  }

  void _reportSize() {
    if (_closed) return;
    final value = _renderer.value;
    debugPrint('畫面大小變了：${value.width}×${value.height}，要轉 ${value.rotation} 度');
    if (value.width <= 0 || value.height <= 0) return;
    // 手機直拿時，畫面資料本身是橫的，另外帶一個「要轉幾度」的資訊。
    final sideways = value.rotation == 90 || value.rotation == 270;
    _events.add(
      VideoSizeChanged(
        sideways
            ? Dimensions(value.height, value.width)
            : Dimensions(value.width, value.height),
      ),
    );
  }

  /// 觀看被迫結束：通知上層，並把資源收掉。
  void _fail(String message, {ByeReason? reason}) {
    if (_closed) return;
    debugPrint('觀看被結束：$message${_restarting ? '（視訊正在重建）' : ''}');
    _events.add(LinkEnded(message, reason: reason));
    _release();
  }

  @override
  Widget buildView() => RTCVideoView(
    _renderer,
    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
  );

  @override
  void startRecording() => _signal?.recording = true;

  @override
  void stopRecording() => _signal?.recording = false;

  @override
  void confirmReceived(int id) => _signal?.send(ShotReceivedMessage(id: id));

  @override
  Future<void> close() async {
    if (_closed) return;
    await _release();
  }

  Future<void> _release() async {
    if (_closed) return;
    _closed = true;
    _stallTimer?.cancel();
    await _messages?.cancel();
    await _shots?.cancel();
    final signal = _signal;
    _signal = null;
    try {
      await signal?.close();
      await _dropConnection();
      _renderer.srcObject = null;
      await _renderer.dispose();
    } catch (_) {
      // 收尾時對方可能已經先斷線，這裡的錯誤不影響使用者。
    }
    await _events.close();
  }
}
