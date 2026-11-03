import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../core/models.dart';
import '../core/scanner.dart';
import '../platform/windows_bridge.dart';

/// 后台任务入口；消息只传可序列化数据，避免主界面与任务共享可变状态。
@pragma('vm:entry-point')
Future<void> scanWorker(Map<String, Object?> message) async {
  final output = message['port'] as SendPort;
  final control = ReceivePort();
  var cancelled = false;
  control.listen((value) {
    if (value == 'cancel') cancelled = true;
  });
  output.send({'type': 'control', 'port': control.sendPort});
  try {
    BackgroundIsolateBinaryMessenger.ensureInitialized(
      message['token'] as RootIsolateToken,
    );
    final inspector = WindowsBridge();
    final ScanPlan plan;
    if (message['action'] == 'import') {
      final source = File(message['path'] as String);
      // 计划是元数据文件；限制输入大小，避免意外打开大型文件耗尽内存。
      if (await source.length() > 64 * 1024 * 1024) {
        throw const FormatException('计划文件超过 64 MiB，请缩小扫描范围后重新导出。');
      }
      final value = jsonDecode(await source.readAsString());
      if (value is! Map<String, dynamic>) {
        throw const FormatException('计划必须是 JSON 对象。');
      }
      plan = await _verifyImportedPlan(
        ScanPlan.fromJson(value),
        inspector,
        () => cancelled,
        (data) => output.send({'type': 'progress', ...data}),
      );
    } else {
      final scanner = DuplicateScanner(
        inspector: inspector,
        onProgress: (data) => output.send({'type': 'progress', ...data}),
        isCancelled: () => cancelled,
      );
      plan = await scanner.scanRoots(
        message['roots'] is List
            ? List<String>.from(message['roots'] as List)
            : [message['root'] as String],
        ScanOptions(
          includeEmpty: message['includeEmpty'] as bool,
          includeHardlinks: message['includeHardlinks'] as bool,
          detectDuplicateFolders:
              message['detectDuplicateFolders'] as bool? ?? true,
        ),
      );
    }
    if (cancelled) {
      output.send({'type': 'cancelled'});
    } else {
      output.send({'type': 'complete', 'plan': plan.toJson()});
    }
  } on ScanCancelled {
    output.send({'type': 'cancelled'});
  } catch (error) {
    output.send({'type': 'error', 'message': error.toString()});
  } finally {
    control.close();
  }
}

/// 导入不等于信任：所有版本计划都重新读取全部内容，旧版身份字段仅在校验通过后补齐。
/// 任一组成员变化即放弃整组，防止原保留文件失效后仍安排删除其他副本。
Future<ScanPlan> _verifyImportedPlan(
  ScanPlan source,
  WindowsBridge inspector,
  bool Function() cancelled,
  void Function(Map<String, Object?>) progress,
) async {
  for (final path in source.roots) {
    final root = await inspector.inspect(path);
    if (!root.isDirectory ||
        root.isReparsePoint ||
        canonicalWindowsPath(root.finalPath) != canonicalWindowsPath(path)) {
      throw StateError('计划根目录无效或属于链接目录：$path');
    }
  }
  final valid = <DuplicateGroup>[];
  final validFolders = <DuplicateFolderGroup>[];
  final errors = <Map<String, String>>[...source.errors];
  final total =
      source.groups.fold<int>(0, (n, g) => n + g.candidates.length + 1) +
      source.folderGroups.fold<int>(
        0,
        (n, group) =>
            n + group.folders.fold<int>(0, (m, folder) => m + folder.fileCount),
      );
  var current = 0;

  Future<FileRecord> verifyFile(
    FileRecord record,
    String digest, {
    required bool allowHardlinks,
  }) async {
    if (cancelled()) throw const ScanCancelled();
    progress({
      'stage': '正在复核导入计划',
      'current': current,
      'total': total,
      'path': record.path,
    });
    final before = await inspector.inspect(record.path);
    if (before.isDirectory ||
        before.isReparsePoint ||
        !source.roots.any((root) => isPathWithinRoot(before.finalPath, root)) ||
        canonicalWindowsPath(before.finalPath) !=
            canonicalWindowsPath(record.finalPath) ||
        before.size != record.size ||
        before.mtimeNs != record.mtimeNs ||
        (record.hasIdentity &&
            (before.fileId != record.fileId ||
                before.volumeId != record.volumeId)) ||
        (!allowHardlinks && before.linkCount > 1)) {
      throw StateError('文件身份、大小、修改时间或链接状态已变化：${record.path}');
    }
    final hash = await sha256
        .bind(_cancellableRead(record.path, cancelled))
        .first;
    final after = await inspector.inspect(record.path);
    if (hash.toString() != digest || !before.sameSnapshot(after)) {
      throw StateError('文件内容已变化：${record.path}');
    }
    current++;
    return after;
  }

  for (final group in source.groups) {
    final checked = <FileRecord>[];
    try {
      for (final record in [group.keep, ...group.candidates]) {
        checked.add(
          await verifyFile(
            record,
            group.sha256,
            allowHardlinks: source.options.includeHardlinks,
          ),
        );
      }
      valid.add(
        DuplicateGroup(
          id: group.id,
          size: group.size,
          sha256: group.sha256,
          keep: checked.first,
          candidates: checked.skip(1).toList(),
        ),
      );
    } on ScanCancelled {
      rethrow;
    } catch (error) {
      errors.add({'path': group.keep.path, 'error': '整组跳过：$error'});
    }
  }

  // 目录计划必须复核“完整集合”，仅校验清单中已有文件会漏掉扫描之后新增的内容。
  for (final group in source.folderGroups) {
    try {
      final checked = <FolderRecord>[];
      for (final folder in group.folders) {
        if (cancelled()) throw const ScanCancelled();
        final before = await inspector.inspect(folder.path);
        if (!folder.directory.sameSnapshot(before) ||
            !before.isDirectory ||
            before.isReparsePoint) {
          throw StateError('文件夹身份或修改时间发生变化：${folder.path}');
        }
        await _verifyTreeInventory(folder, inspector, cancelled);
        final dirs = <FolderDirectoryEntry>[];
        for (final entry in folder.directories) {
          final actual = await inspector.inspect(entry.record.path);
          if (!entry.record.sameSnapshot(actual) ||
              !actual.isDirectory ||
              actual.isReparsePoint) {
            throw StateError('子目录已变化：${entry.record.path}');
          }
          dirs.add(
            FolderDirectoryEntry(
              relativePath: entry.relativePath,
              record: actual,
            ),
          );
        }
        final files = <FolderFileEntry>[];
        for (final entry in folder.files) {
          final actual = await verifyFile(
            entry.record,
            entry.sha256,
            allowHardlinks: false,
          );
          files.add(
            FolderFileEntry(
              relativePath: entry.relativePath,
              record: actual,
              sha256: entry.sha256,
            ),
          );
        }
        await _verifyTreeInventory(folder, inspector, cancelled);
        final after = await inspector.inspect(folder.path);
        if (!before.sameSnapshot(after)) {
          throw StateError('复核过程中目录发生变化：${folder.path}');
        }
        checked.add(
          FolderRecord(directory: after, files: files, directories: dirs),
        );
      }
      validFolders.add(
        DuplicateFolderGroup(
          id: group.id,
          fingerprint: group.fingerprint,
          keep: checked.first,
          candidates: checked.skip(1).toList(),
        ),
      );
    } on ScanCancelled {
      rethrow;
    } catch (error) {
      errors.add({'path': group.keep.path, 'error': '整文件夹组跳过：$error'});
    }
  }
  // 再经过模型验证，以原生规范化后的路径检查跨组冲突。
  final json = source.toJson();
  json['plan_version'] = ScanPlan.currentVersion;
  json['groups'] = valid.map((g) => g.toJson()).toList();
  json['folder_groups'] = validFolders.map((g) => g.toJson()).toList();
  json['errors'] = errors;
  return ScanPlan.fromJson(json);
}

/// 不跟随链接，逐层读取目录，并确保没有新增、缺失或文件/目录类型互换的项目。
Future<void> _verifyTreeInventory(
  FolderRecord folder,
  WindowsBridge inspector,
  bool Function() cancelled,
) async {
  final expected = <String, bool>{
    for (final entry in folder.files)
      canonicalWindowsPath(entry.relativePath): false,
    for (final entry in folder.directories)
      canonicalWindowsPath(entry.relativePath): true,
  };
  final seen = <String>{};
  final pending = <String>[folder.path];
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    await for (final entity in Directory(current).list(followLinks: false)) {
      if (cancelled()) throw const ScanCancelled();
      final actual = await inspector.inspect(entity.path);
      final relative = canonicalWindowsPath(
        p.windows.relative(entity.path, from: folder.path),
      );
      if (actual.isReparsePoint ||
          entity is Link ||
          !isPathWithinRoot(actual.finalPath, folder.path) ||
          !expected.containsKey(relative) ||
          expected[relative] != actual.isDirectory ||
          !seen.add(relative)) {
        throw StateError('文件夹清单已变化或含有链接：${entity.path}');
      }
      if (actual.isDirectory) pending.add(entity.path);
    }
  }
  if (seen.length != expected.length) {
    throw StateError('文件夹内有项目缺失：${folder.path}');
  }
}

Stream<List<int>> _cancellableRead(
  String path,
  bool Function() cancelled,
) async* {
  await for (final chunk in File(path).openRead()) {
    if (cancelled()) throw ScanCancelled();
    yield chunk;
  }
}
