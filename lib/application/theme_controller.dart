import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 管理主题偏好及其本地持久化，与扫描任务状态相互独立。
///
/// 主题立即生效，写盘按顺序执行；快速连续切换不会让旧写入覆盖最新选择。
/// [settingsFile] 和 [persist] 供测试隔离真实用户设置，生产默认使用 LocalAppData。
class ThemeController extends ChangeNotifier {
  ThemeController({
    File? settingsFile,
    this.persist = true,
    ThemeMode initialMode = ThemeMode.system,
  }) : _file =
           settingsFile ??
           File(
             p.join(
               Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
               'DupeFileCleaner',
               'settings.json',
             ),
           ),
       _mode = initialMode;

  final File _file;
  final bool persist;
  ThemeMode _mode;
  ThemeMode get mode => _mode;
  String? error;
  bool saving = false;
  bool _disposed = false;
  int _revision = 0;
  Future<void> _pending = Future<void>.value();

  /// 文件不存在视为首次使用；损坏或不可读时回退系统主题并保留可见错误。
  Future<void> load() async {
    if (!persist) return;
    final revision = _revision;
    try {
      if (!await _file.exists()) return;
      final json = jsonDecode(await _file.readAsString());
      if (json is! Map || json['theme'] is! String) {
        throw const FormatException('主题设置格式不正确');
      }
      final next = switch (json['theme']) {
        'system' => ThemeMode.system,
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => throw const FormatException('主题设置值不支持'),
      };
      // 用户已经主动切换时，较慢的启动读取不能反向覆盖新选择。
      if (_revision != revision || _disposed) return;
      _mode = next;
      error = null;
    } catch (e) {
      if (_revision != revision || _disposed) return;
      _mode = ThemeMode.system;
      error = '无法读取主题设置，已使用系统主题：$e';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> setMode(ThemeMode next) {
    _mode = next;
    error = null;
    final revision = ++_revision;
    if (!persist) {
      notifyListeners();
      return Future<void>.value();
    }
    saving = true;
    notifyListeners();
    _pending = _pending.then((_) async {
      File? temporary;
      try {
        await _file.parent.create(recursive: true);
        temporary = File(
          '${_file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
        );
        await temporary.writeAsString(
          '${jsonEncode({'version': 1, 'theme': next.name})}\n',
          flush: true,
        );
        await temporary.rename(_file.path);
        if (revision == _revision) error = null;
      } catch (e) {
        if (revision == _revision) error = '主题已切换，但无法保存设置：$e';
      } finally {
        try {
          if (temporary != null && await temporary.exists()) {
            await temporary.delete();
          }
        } catch (_) {
          /* 临时文件清理失败不覆盖原始保存错误，也不能中断后续主题写入。 */
        }
        if (revision == _revision) saving = false;
        if (!_disposed) notifyListeners();
      }
    });
    return _pending;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
