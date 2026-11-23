import 'package:cam_board_host/services/board_browser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('pickHost', () {
    test('沒有位址時回傳 null', () {
      expect(pickHost([]), isNull);
    });

    test('同時有 IPv4 和 IPv6 時用 IPv4，不管順序', () {
      expect(pickHost(['fe80::1', '192.168.1.10']), '192.168.1.10');
      expect(pickHost(['192.168.1.10', 'fe80::1']), '192.168.1.10');
    });

    test('只有 IPv6 時就用它', () {
      expect(pickHost(['fe80::1']), 'fe80::1');
    });
  });
}
