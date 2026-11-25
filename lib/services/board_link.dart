import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

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
  const ShotReceived(this.id, this.png);

  /// 這張照片的編號，存好之後用 [BoardLink.confirmSaved] 回報。
  final int id;

  /// 照片的 PNG 內容。
  final Uint8List png;
}

/// 觀看結束了，而且不是鄉民端自己按「不看了」造成的。
final class LinkEnded extends BoardLinkEvent {
  const LinkEnded(this.message);

  /// 結束的原因，可以直接顯示給使用者。
  final String message;
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

  /// 告訴看板端：編號 [id] 的照片存好了。
  void confirmSaved(int id);

  /// 顯示收到的畫面。
  Widget buildView();

  /// 結束觀看並告訴看板端。重複呼叫不會出錯。
  Future<void> close();
}

/// 建立一條新的連線。每次觀看用一條新的。
typedef BoardLinkFactory = BoardLink Function();

/// 把看板端送來的結束原因轉成給使用者看的文字。
String describeByeReason(ByeReason reason) => switch (reason) {
  ByeReason.boardStopped => '看板端不給看了',
  ByeReason.boardUnregistered => '看板端撤銷註冊了',
  ByeReason.versionMismatch => '看板端和鄉民端的版本不同，請兩邊都更新',
  ByeReason.viewerLeft => '已結束觀看',
};

/// 把「等到逾時畫面還是沒出來」的原因轉成給使用者看的文字。
String describeConnectFailure(ConnectFailure failure) => switch (failure) {
  ConnectFailure.boardUnreachable => '連線逾時，請確認兩台裝置在同一個網路',
  ConnectFailure.boardSilent => '看板端沒有回應',
  ConnectFailure.exchangeStalled => '和看板端交換連線資訊時中斷了',
  ConnectFailure.noWorkingPath => '兩台裝置之間的網路不通。有些熱點不允許裝置互相連線，請換一個網路',
};

/// 用 WebSocket 交換連線資訊、用 WebRTC 接收畫面。
class WebRtcBoardLink implements BoardLink {
  static const _timeout = Duration(seconds: 6);

  final _events = StreamController<BoardLinkEvent>.broadcast();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  WebSocket? _socket;
  RTCPeerConnection? _connection;
  bool _closed = false;

  /// 看板端剛說「接下來那一筆資料是一張照片」，在等那筆資料。
  ShotMessage? _awaitedShot;

  /// 看板端的網路路徑常常比我們處理完它的連線資訊還早到，先留著。
  late final CandidateGate _candidates = CandidateGate(
    (candidate) async => _connection?.addCandidate(
      RTCIceCandidate(
        candidate.candidate,
        candidate.sdpMid,
        candidate.sdpMLineIndex,
      ),
    ),
  );

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
      final socket = await WebSocket.connect(board.signalUri.toString())
          .timeout(_timeout);
      if (_closed) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.listen(
        (raw) => _handling = _handling.then((_) => _onSocketMessage(raw)),
        onDone: () => _fail('和看板端的連線中斷了'),
        onError: (_) => _fail('和看板端的連線中斷了'),
        cancelOnError: true,
      );
      socket.add(JoinMessage(name: viewerName).encode());
      _events.add(const ConnectAdvanced(ConnectStage.waitingForOffer));
    } on TimeoutException {
      _fail('連線逾時，請確認兩台裝置在同一個網路');
    } on SocketException {
      _fail('連不上看板端，它可能已經撤銷註冊');
    } catch (_) {
      _fail('無法開始觀看');
    }
  }

  Future<void> _onSocketMessage(Object? raw) async {
    if (_closed) return;
    if (raw is List<int>) {
      // 二進位資料只有一種：緊接在 shot 訊息後面的那張照片。
      final shot = _awaitedShot;
      _awaitedShot = null;
      if (shot != null && raw.length == shot.bytes) {
        _events.add(
          ShotReceived(
            shot.id,
            raw is Uint8List ? raw : Uint8List.fromList(raw),
          ),
        );
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
    try {
      switch (message) {
        case HelloMessage():
          if (!message.isCompatible) {
            _fail(describeByeReason(ByeReason.versionMismatch));
          }
        case OfferMessage(:final sdp):
          _events.add(const ConnectAdvanced(ConnectStage.exchangingPaths));
          await _answer(sdp);
        case CandidateMessage():
          await _candidates.add(message);
        case CandidatesDoneMessage():
          // 只用來判斷連不上的原因，不交給視訊連線：
          // 判定連不上靠的是我們自己的逾時（見 ViewerController）。
          _events.add(const ConnectAdvanced(ConnectStage.pathsComplete));
        case ShotMessage():
          _awaitedShot = message;
        case ByeMessage(:final reason):
          _fail(describeByeReason(reason));
        case JoinMessage() ||
            AnswerMessage() ||
            RecordStartMessage() ||
            RecordStopMessage() ||
            ShotSavedMessage():
          // 這幾種只會由鄉民端送出，看板端送來就忽略。
          break;
      }
    } catch (_) {
      _fail('無法開始觀看');
    }
  }

  /// 收到看板端的連線資訊：建立只收不送的連線，並回覆。
  Future<void> _answer(String offerSdp) async {
    // 兩端都在同一個區域網路，不需要外部伺服器協助連線。
    final connection = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _connection = connection;
    connection.onTrack = (event) {
      if (event.track.kind == 'video' && event.streams.isNotEmpty) {
        _renderer.srcObject = event.streams.first;
      }
    };
    connection.onIceCandidate = (candidate) {
      final text = candidate.candidate;
      if (text == null || text.isEmpty) return;
      _socket?.add(
        CandidateMessage(
          candidate: text,
          sdpMid: candidate.sdpMid,
          sdpMLineIndex: candidate.sdpMLineIndex,
        ).encode(),
      );
    };
    connection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _fail('畫面的連線中斷了');
      }
    };
    await connection.setRemoteDescription(
      RTCSessionDescription(offerSdp, 'offer'),
    );
    await _candidates.open();
    final answer = await connection.createAnswer();
    await connection.setLocalDescription(answer);
    _socket?.add(AnswerMessage(sdp: answer.sdp!).encode());
  }

  void _reportSize() {
    if (_closed) return;
    final value = _renderer.value;
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
  void _fail(String message) {
    if (_closed) return;
    _events.add(LinkEnded(message));
    _release();
  }

  @override
  Widget buildView() => RTCVideoView(
    _renderer,
    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
  );

  @override
  void startRecording() => _socket?.add(const RecordStartMessage().encode());

  @override
  void stopRecording() => _socket?.add(const RecordStopMessage().encode());

  @override
  void confirmSaved(int id) => _socket?.add(ShotSavedMessage(id: id).encode());

  @override
  Future<void> close() async {
    if (_closed) return;
    _socket?.add(const ByeMessage(ByeReason.viewerLeft).encode());
    await _release();
  }

  Future<void> _release() async {
    if (_closed) return;
    _closed = true;
    final socket = _socket;
    final connection = _connection;
    _socket = null;
    _connection = null;
    try {
      await socket?.close();
      await connection?.close();
      _renderer.srcObject = null;
      await _renderer.dispose();
    } catch (_) {
      // 收尾時對方可能已經先斷線，這裡的錯誤不影響使用者。
    }
    await _events.close();
  }
}
