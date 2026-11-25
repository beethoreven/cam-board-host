import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 記住鄉民端使用者取的名稱，下次開啟時帶回來。
abstract interface class ViewerNameStore {
  /// 上次存的名稱；從來沒存過時是 null。
  Future<String?> load();

  Future<void> save(String name);
}

class PrefsViewerNameStore implements ViewerNameStore {
  static const _key = 'viewer_name';

  @override
  Future<String?> load() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> save(String name) async =>
      (await SharedPreferences.getInstance()).setString(_key, name);
}

/// 使用者沒取名稱時用的預設值：這台電腦的名稱。
String computerName() {
  final host = Platform.localHostname;
  final name = host.endsWith('.local')
      ? host.substring(0, host.length - '.local'.length)
      : host;
  return name.isEmpty ? '鄉民端' : name;
}
