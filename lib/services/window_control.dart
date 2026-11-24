import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/widgets.dart' show Widget;
import 'package:nativeapi/nativeapi.dart' as native;
import 'package:window_manager/window_manager.dart' show DragToMoveArea;

/// 螢幕上的一塊區域：位置加大小。
typedef ScreenArea = ({double left, double top, Dimensions size});

/// 控制鄉民端的視窗。
///
/// 用介面隔開，畫面測試才能換成假的，不需要真的視窗。
abstract interface class WindowControl {
  /// 視窗所在的螢幕上，扣掉選單列和 Dock 之後可以用的區域。
  ScreenArea workArea();

  /// 視窗目前的位置和大小。
  WindowFrame currentFrame();

  /// 切換成觀看用的視窗：沒有邊框，位置和大小照 [frame]，
  /// 使用者拉動邊緣調整大小時維持同樣的長寬比。
  void showVideo(WindowFrame frame);

  /// 切換回看板清單用的一般視窗，回到觀看之前的位置和大小。
  void showList();

  /// 把 [child] 包成「按住就能拖動視窗」的區域。觀看時視窗沒有標題列，
  /// 要靠這個才能移動。
  Widget dragArea({required Widget child});
}

/// 用 window_manager 0.6.0 底層的 nativeapi 實作。
///
/// 取得螢幕可用範圍原本該用 screen_retriever，但它的最新版要求 Flutter 3.50，
/// 而且和 window_manager 0.6.0 依賴的 nativeapi 版本衝突，所以直接用 nativeapi。
class NativeWindowControl implements WindowControl {
  native.Window get _window => native.WindowManager.instance.getCurrent()!;

  /// 進入觀看之前的視窗位置和大小，回到清單時還原。
  native.Rectangle? _listBounds;

  @override
  ScreenArea workArea() {
    final bounds = _window.bounds;
    final centerX = bounds.x + bounds.width / 2;
    final centerY = bounds.y + bounds.height / 2;
    final displays = native.DisplayManager.instance.getAll();
    try {
      // 視窗中心點落在哪個螢幕，就用那個螢幕。接投影機時通常有兩個以上。
      final display = displays.firstWhere((d) {
        final position = d.position;
        final size = d.size;
        return centerX >= position.x &&
            centerX < position.x + size.width &&
            centerY >= position.y &&
            centerY < position.y + size.height;
      }, orElse: () => displays.first);
      final area = display.workArea;
      return (
        left: area.x,
        top: area.y,
        size: Dimensions(area.width, area.height),
      );
    } finally {
      for (final display in displays) {
        display.dispose();
      }
    }
  }

  @override
  WindowFrame currentFrame() {
    final bounds = _window.bounds;
    return WindowFrame(
      left: bounds.x,
      top: bounds.y,
      size: Dimensions(bounds.width, bounds.height),
    );
  }

  @override
  void showVideo(WindowFrame frame) {
    final window = _window;
    if (_listBounds == null) {
      _listBounds = window.bounds;
      window.setFrameless(true);
    }
    // 先解除比例限制再設定大小，否則舊的比例會把新的大小擋回去。
    window.aspectRatio = 0;
    window.bounds = native.Rectangle(
      x: frame.left,
      y: frame.top,
      width: frame.size.width,
      height: frame.size.height,
    );
    window.aspectRatio = frame.size.aspectRatio;
  }

  @override
  void showList() {
    final saved = _listBounds;
    if (saved == null) return;
    _listBounds = null;
    final window = _window;
    window.aspectRatio = 0;
    window.setFrameless(false);
    window.bounds = saved;
  }

  @override
  Widget dragArea({required Widget child}) => DragToMoveArea(child: child);
}
