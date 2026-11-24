import 'dart:async';
import 'dart:io';

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

/// 觀看結束了，而且不是鄉民端自己按「不看了」造成的。
final class LinkEnded extends BoardLinkEvent {
  const LinkEnded(this.message);

  /// 結束的原因，可以直接顯示給使用者。
  final String message;
}

/// 鄉民端對一個看板的連線：交換連線資訊、接收畫面。
abstract interface class BoardLink {
  Stream<BoardLinkEvent> get events;

  /// 連到看板並要求觀看。連不上時會從 [events] 送出 [LinkEnded]。
  Future<void> connect(BoardInfo board);

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

/// 用 WebSocket 交換連線資訊、用 WebRTC 接收畫面。
class WebRtcBoardLink implements BoardLink {
  static const _timeout = Duration(seconds: 6);

  final _events = StreamController<BoardLinkEvent>.broadcast();
  final RTCVideoRenderer _renderer = RTCVideoRenderer();
  WebSocket? _socket;
  RTCPeerConnection? _connection;
  bool _closed = false;

  @override
  Stream<BoardLinkEvent> get events => _events.stream;

  @override
  Future<void> connect(BoardInfo board) async {
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
        _onSocketMessage,
        onDone: () => _fail('和看板端的連線中斷了'),
        onError: (_) => _fail('和看板端的連線中斷了'),
        cancelOnError: true,
      );
      socket.add(const JoinMessage().encode());
    } on TimeoutException {
      _fail('連線逾時，請確認兩台裝置在同一個網路');
    } on SocketException {
      _fail('連不上看板端，它可能已經撤銷註冊');
    } catch (_) {
      _fail('無法開始觀看');
    }
  }

  Future<void> _onSocketMessage(Object? raw) async {
    if (raw is! String || _closed) return;
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
          await _answer(sdp);
        case CandidateMessage():
          await _connection?.addCandidate(
            RTCIceCandidate(
              message.candidate,
              message.sdpMid,
              message.sdpMLineIndex,
            ),
          );
        case ByeMessage(:final reason):
          _fail(describeByeReason(reason));
        case JoinMessage() || AnswerMessage():
          // 這兩種只會由鄉民端送出，看板端送來就忽略。
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
