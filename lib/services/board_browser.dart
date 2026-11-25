import 'dart:async';

import 'package:bonsoir/bonsoir.dart';
import 'package:cam_board_core/cam_board_core.dart';

/// 搜尋的結果：一個看板出現了，或消失了。
sealed class BoardBrowserEvent {
  const BoardBrowserEvent(this.id);

  /// 搜尋機制給這個看板的識別名稱。出現和消失靠它對應。
  final String id;
}

final class BoardFound extends BoardBrowserEvent {
  const BoardFound(super.id, this.board);

  final BoardInfo board;
}

final class BoardLost extends BoardBrowserEvent {
  const BoardLost(super.id);
}

/// 在區域網路上搜尋看板。
///
/// 用介面隔開，畫面測試才能換成假的，不需要真的網路。
abstract interface class BoardBrowser {
  Stream<BoardBrowserEvent> get events;

  Future<void> start();

  /// 沒有在搜尋時呼叫也不會出錯。
  Future<void> stop();

  /// 搜尋自己停掉時呼叫（不是我們叫它停的）。不通報的話，清單會一直是空的，
  /// 看起來跟「沒有看板註冊」一模一樣。
  set onStopped(void Function()? handler);
}

/// 用 mDNS（Bonjour）搜尋。
class BonsoirBoardBrowser implements BoardBrowser {
  final _events = StreamController<BoardBrowserEvent>.broadcast();
  BonsoirDiscovery? _discovery;
  StreamSubscription<BonsoirDiscoveryEvent>? _subscription;
  void Function()? _onStopped;

  @override
  set onStopped(void Function()? handler) => _onStopped = handler;

  @override
  Stream<BoardBrowserEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    await stop();
    final discovery = BonsoirDiscovery(type: boardServiceType);
    await discovery.initialize();
    _discovery = discovery;
    // 文件要求先開始聽事件，再開始搜尋，否則會漏掉一開始就存在的看板。
    _subscription = discovery.eventStream!.listen((event) {
      switch (event) {
        case BonsoirDiscoveryServiceFoundEvent(:final service):
          // 剛找到時只有名稱，要解析之後才有位址和埠。
          service.resolve(discovery.serviceResolver);
        case BonsoirDiscoveryServiceResolvedEvent(:final service):
        case BonsoirDiscoveryServiceUpdatedEvent(:final service):
          final host = pickHost(service.hostAddresses);
          if (host == null) return;
          _events.add(
            BoardFound(
              service.name,
              BoardInfo(
                name: service.name,
                host: host,
                port: service.port,
                protocol: int.tryParse(service.attributes['protocol'] ?? ''),
              ),
            ),
          );
        case BonsoirDiscoveryServiceLostEvent(:final service):
          _events.add(BoardLost(service.name));
        case BonsoirDiscoveryStoppedEvent():
          // 我們自己停的那一次已經先把 _discovery 清掉了。
          if (identical(_discovery, discovery)) _onStopped?.call();
        default:
          break;
      }
    });
    await discovery.start();
  }

  @override
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final discovery = _discovery;
    _discovery = null;
    await discovery?.stop();
  }
}

/// 一個看板可能同時回報 IPv4 和 IPv6 位址。優先用 IPv4：
/// 手機熱點上的 IPv6 多半是只在單一介面有效的位址，連線時還要額外指定介面。
String? pickHost(List<String> addresses) {
  if (addresses.isEmpty) return null;
  return addresses.firstWhere(
    (address) => !address.contains(':'),
    orElse: () => addresses.first,
  );
}
