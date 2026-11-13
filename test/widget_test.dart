import 'package:cam_board_host/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('啟動後顯示「鄉民端」', (tester) async {
    await tester.pumpWidget(const CamBoardApp());
    expect(find.text('鄉民端'), findsOneWidget);
  });
}
