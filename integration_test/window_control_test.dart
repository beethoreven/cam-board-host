import 'package:cam_board_core/cam_board_core.dart';
import 'package:cam_board_host/services/window_control.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// 在真的 macOS 視窗上驗證視窗控制。畫面測試用的是假視窗，
/// 這裡確認底層套件實際上照我們要求的做。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('觀看用的視窗：位置、大小照指定的來，回到清單時還原', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    await tester.pump(const Duration(milliseconds: 500));
    final window = NativeWindowControl();

    final area = window.workArea();
    expect(area.size.width, greaterThan(600));
    expect(area.size.height, greaterThan(400));

    final before = window.currentFrame();

    // 一個直的視窗，放在螢幕可用範圍的左上角往內 40。
    final target = WindowFrame(
      left: area.left + 40,
      top: area.top + 40,
      size: const Dimensions(270, 480),
    );
    window.showVideo(target);
    await tester.pump(const Duration(milliseconds: 500));
    var now = window.currentFrame();
    expect(now.left, closeTo(target.left, 2));
    expect(now.top, closeTo(target.top, 2));
    expect(now.size.width, closeTo(270, 2));
    expect(now.size.height, closeTo(480, 2));

    // 換成橫的：之前鎖住的直式比例不能把新的大小擋回去。
    final wide = WindowFrame(
      left: area.left + 40,
      top: area.top + 40,
      size: const Dimensions(640, 360),
    );
    window.showVideo(wide);
    await tester.pump(const Duration(milliseconds: 500));
    now = window.currentFrame();
    expect(now.size.width, closeTo(640, 2));
    expect(now.size.height, closeTo(360, 2));

    // 放到最大：整個可用範圍。
    window.showVideo(
      WindowFrame(left: area.left, top: area.top, size: area.size),
    );
    await tester.pump(const Duration(milliseconds: 500));
    now = window.currentFrame();
    expect(now.left, closeTo(area.left, 2));
    expect(now.top, closeTo(area.top, 2));
    expect(now.size.width, closeTo(area.size.width, 2));
    expect(now.size.height, closeTo(area.size.height, 2));

    window.showList();
    await tester.pump(const Duration(milliseconds: 500));
    now = window.currentFrame();
    expect(now.left, closeTo(before.left, 2));
    expect(now.top, closeTo(before.top, 2));
    expect(now.size.width, closeTo(before.size.width, 2));
    expect(now.size.height, closeTo(before.size.height, 2));
  });
}
