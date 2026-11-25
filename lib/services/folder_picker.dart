import 'package:file_selector/file_selector.dart';

/// 請使用者選一個資料夾，回傳它的路徑；使用者按取消時回傳 null。
typedef FolderPicker = Future<String?> Function();

/// 用系統的選擇資料夾視窗。
Future<String?> pickFolderWithSystemDialog() =>
    getDirectoryPath(confirmButtonText: '存在這裡');
