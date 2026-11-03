import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/scanner.dart';

/// Windows 原生功能的统一入口。
///
/// 文件身份和时间戳始终保留原始值，不从界面的格式化文本反推；
/// 扫描隔离区初始化 BackgroundIsolateBinaryMessenger 后也可复用此接口。
class WindowsBridge implements FileInspector {
  static const channel = MethodChannel('dupe_file_cleaner/windows');

  @override
  Future<FileRecord> inspect(String path) async {
    final value = await channel.invokeMapMethod<String, dynamic>('inspect', {
      'path': path,
    });
    if (value == null) throw StateError('系统没有返回文件信息：$path');
    return FileRecord.fromJson(value);
  }

  /// 对话框在 Windows 主线程运行，取消时返回 null。
  Future<String?> pickDirectory() => channel.invokeMethod('pickDirectory');

  /// 系统目录选择器支持 Ctrl/Shift 多选，返回取消时的空列表。
  Future<List<String>> pickDirectories() async =>
      (await channel.invokeListMethod<String>('pickDirectories')) ?? [];

  Future<String?> chooseJsonFile({required bool save}) => channel.invokeMethod(
    'chooseJsonFile',
    {'save': save, 'suggestedName': 'duplicate-plan.json'},
  );

  Future<void> reveal(String path) =>
      channel.invokeMethod('reveal', {'path': path});

  /// 忙碌时拦截窗口关闭，避免用户误以为已终止实际仍在执行的清理任务。
  Future<void> setBusy(bool busy) =>
      channel.invokeMethod('setBusy', {'busy': busy});
  Future<void> cancelNative() => channel.invokeMethod('cancelNative');
  Future<void> resetCancellation() => channel.invokeMethod('resetCancellation');

  /// 一次只提交一个候选；原生层会同时持有并重新验证保留文件。
  Future<Map<String, dynamic>> cleanFile({
    required ScanPlan plan,
    required DuplicateGroup group,
    required FileRecord candidate,
    required bool permanent,
  }) async {
    return Map<String, dynamic>.from(
      (await channel.invokeMapMethod<String, dynamic>('cleanFile', {
        'root': _rootFor(plan, candidate.path),
        'keepRoot': _rootFor(plan, group.keep.path),
        'keep': group.keep.toJson(),
        'candidate': candidate.toJson(),
        'sha256': group.sha256,
        'mode': permanent ? 'permanent' : 'recycle',
        'allowHardlinks': plan.options.includeHardlinks,
      }))!,
    );
  }

  /// 文件夹入口将完整清单传给原生层；没有任何未经验证的通用递归删除接口。
  Future<Map<String, dynamic>> cleanFolder({
    required ScanPlan plan,
    required DuplicateFolderGroup group,
    required FolderRecord candidate,
    required bool permanent,
  }) async => Map<String, dynamic>.from(
    (await channel.invokeMapMethod<String, dynamic>('cleanFolder', {
      'roots': plan.roots,
      'keep': group.keep.toJson(),
      'candidate': candidate.toJson(),
      'mode': permanent ? 'permanent' : 'recycle',
    }))!,
  );

  String _rootFor(ScanPlan plan, String path) => plan.roots.firstWhere(
    (root) => isPathWithinRoot(path, root),
    orElse: () => throw StateError('文件不在任何已授权扫描目录内：$path'),
  );
}
