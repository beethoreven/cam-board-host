import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/material.dart';

import '../services/window_control.dart';
import '../viewer_controller.dart';

/// 鄉民端觀看看板的畫面。
class ViewingScreen extends StatefulWidget {
  const ViewingScreen({
    super.key,
    required this.controller,
    required this.window,
  });

  final ViewerController controller;
  final WindowControl window;

  @override
  State<ViewingScreen> createState() => _ViewingScreenState();
}

class _ViewingScreenState extends State<ViewingScreen> {
  /// 滑鼠在視窗上時才顯示按鈕，移開就隱藏，避免擋住投影出去的內容。
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (controller.state == ViewerState.connecting) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('正在連到「${controller.board?.name ?? ''}」'),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: controller.stop,
                child: const Text('不看了'),
              ),
            ],
          ),
        ),
      );
    }

    final view = controller.link?.buildView() ?? const SizedBox.shrink();
    return Scaffold(
      backgroundColor: Colors.black,
      body: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: Stack(
          fit: StackFit.expand,
          children: [
            widget.window.dragArea(
              // 反轉包在旋轉外面：不論轉到哪個角度，反轉的都是「看到的左右」。
              child: Transform.flip(
                key: const Key('mirror'),
                flipX: controller.mirrored,
                child: RotatedBox(
                  key: const Key('rotation'),
                  quarterTurns: controller.rotation.index,
                  child: view,
                ),
              ),
            ),
            if (_hovering)
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Material(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Wrap(
                        spacing: 4,
                        children: [
                          _ControlButton('旋轉', controller.rotate),
                          _ControlButton('左右反轉', controller.toggleMirror),
                          _ControlButton(
                            controller.maximized ? '還原大小' : '放到最大',
                            controller.toggleMaximize,
                          ),
                          _ControlButton('不看了', controller.stop),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ControlButton extends StatelessWidget {
  const _ControlButton(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(foregroundColor: Colors.white),
    child: Text(label),
  );
}
