import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// 查問題用的紀錄。只留紀錄，不改變任何行為。

/// 超過這個大小就把舊的那份改名成 `.old`，重新開一份。
const _maxLogBytes = 20 * 1024 * 1024;

/// 從現在起，所有 `debugPrint` 的內容都另外寫一份到檔案（每一行帶時間），
/// 回傳檔案的路徑；開不了檔案時回傳 null，紀錄照常只印出來。
///
/// 寫成檔案是因為印出來的紀錄留不久：手機的 logcat 幾分鐘就被洗掉，
/// 電腦上的只在執行它的終端機裡。
String? startDebugLogFile(String fileName) {
  try {
    final file = File('${Directory.systemTemp.path}/$fileName');
    if (file.existsSync() && file.lengthSync() > _maxLogBytes) {
      file.renameSync('${file.path}.old');
    }
    final out = file.openSync(mode: FileMode.append);
    final print = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      print(message, wrapWidth: wrapWidth);
      try {
        out.writeStringSync('${DateTime.now().toIso8601String()} $message\n');
      } catch (_) {
        // 紀錄寫不進去不能影響程式本身。
      }
    };
    debugPrint('==== 開始記錄：${file.path}');
    return file.path;
  } catch (_) {
    return null;
  }
}

/// 每秒把一條視訊連線的統計記下來，連線狀態一變也記。
///
/// 統計是 WebRTC 自己的數字（送出、收到、遺失、重送、估計的頻寬、解出幾張…），
/// 都是從連線開始累計的；要看某一段時間的量，拿前後兩筆相減。
class ConnectionLog {
  ConnectionLog(this._connection, this._label, this._types);

  final RTCPeerConnection _connection;

  /// 這條連線在紀錄裡的名字。
  final String _label;

  /// 要記哪幾種統計（例如 `inbound-rtp`、`candidate-pair`）。
  final Set<String> _types;
  Timer? _timer;
  bool _sampling = false;

  void start() {
    debugPrint('連線 $_label：開始記錄');
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _sample());
  }

  void stop() {
    if (_timer == null) return;
    _timer?.cancel();
    _timer = null;
    debugPrint('連線 $_label：停止記錄');
  }

  /// 連線狀態變了（[kind] 是哪一種狀態，[state] 是變成什麼）。
  void stateChanged(String kind, Object state) {
    debugPrint('連線 $_label：$kind → ${_shortName(state)}');
  }

  Future<void> _sample() async {
    // 上一次還沒讀完就不再讀，免得卡住時越疊越多。
    if (_sampling) {
      debugPrint('統計 $_label：上一次還沒讀完，跳過這一次');
      return;
    }
    _sampling = true;
    try {
      final reports = await _connection.getStats().timeout(
        const Duration(seconds: 3),
      );
      for (final report in reports) {
        if (!_types.contains(report.type)) continue;
        // 沒被選用的網路路徑不記，數量多又都是零。
        if (report.type == 'candidate-pair' &&
            report.values['nominated'] != true) {
          continue;
        }
        debugPrint('統計 $_label ${report.type} ${_format(report.values)}');
      }
    } catch (e) {
      debugPrint('統計 $_label：讀不到（$e）');
    } finally {
      _sampling = false;
    }
  }

  static String _format(Map<dynamic, dynamic> values) {
    final keys = values.keys.map((key) => '$key').toList()..sort();
    return [
      for (final key in keys)
        // 太長的字串（識別碼之類）對查問題沒有幫助。
        if ('${values[key]}'.length <= 48) '$key=${values[key]}',
    ].join(' ');
  }

  static String _shortName(Object state) {
    final text = '$state';
    return text.contains('.') ? text.substring(text.indexOf('.') + 1) : text;
  }
}
