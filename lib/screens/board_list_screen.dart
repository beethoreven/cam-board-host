import 'package:cam_board_core/cam_board_core.dart';
import 'package:flutter/material.dart';

import '../board_list_controller.dart';

/// 鄉民端的看板清單。
class BoardListScreen extends StatefulWidget {
  const BoardListScreen({
    super.key,
    required this.controller,
    required this.onWatch,
    this.notice,
  });

  final BoardListController controller;

  /// 點了清單上的一個看板。
  final void Function(BoardInfo board) onWatch;

  /// 上一次觀看被迫結束的原因，例如「看板端不給看了」。沒有時是 null。
  final String? notice;

  @override
  State<BoardListScreen> createState() => _BoardListScreenState();
}

class _BoardListScreenState extends State<BoardListScreen> {
  final _address = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  @override
  void dispose() {
    _address.dispose();
    super.dispose();
  }

  Future<void> _addManual() async {
    if (await widget.controller.addManual(_address.text)) _address.clear();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('看板清單')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => Column(
          children: [
            if (widget.notice case final notice?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(notice),
              ),
            if (controller.searchError case final error?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: controller.boards.isEmpty
                  ? const Center(child: Text('還沒有看板註冊'))
                  : ListView(
                      children: [
                        for (final board in controller.boards)
                          ListTile(
                            leading: const Icon(Icons.videocam_outlined),
                            title: Text(board.name),
                            subtitle: Text(board.address),
                            onTap: () => widget.onWatch(board),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _address,
                      enabled: !controller.probing,
                      decoration: InputDecoration(
                        labelText: '手動輸入位址',
                        hintText: '看板端畫面上顯示的位址',
                        border: const OutlineInputBorder(),
                        errorText: controller.manualError,
                        errorMaxLines: 2,
                      ),
                      onSubmitted: (_) => _addManual(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FilledButton(
                      onPressed: controller.probing ? null : _addManual,
                      child: const Text('加入'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
