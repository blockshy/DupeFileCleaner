import 'dart:io';

import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 使用工程内真实临时文件，提供可注入错误/链接状态的元数据读取器。
class _InventoryInspector implements FileInspector {
  _InventoryInspector({this.transform});
  final FileRecord Function(String, FileRecord)? transform;
  @override
  Future<FileRecord> inspect(String path) async {
    final absolute = p.normalize(p.absolute(path));
    final stat = await FileStat.stat(absolute);
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException('不存在', absolute);
    }
    final record = FileRecord(
      path: absolute,
      finalPath: absolute,
      size: stat.size,
      mtimeNs: stat.modified.microsecondsSinceEpoch * 1000,
      volumeId: 'test-volume',
      fileId: absolute.toLowerCase(),
      isDirectory: stat.type == FileSystemEntityType.directory,
    );
    return transform?.call(absolute, record) ?? record;
  }
}

void main() {
  late Directory parent;
  late Directory fixture;
  setUp(() async {
    parent = await Directory(
      p.join(Directory.current.path, 'build', 'folder_test_fixtures'),
    ).create(recursive: true);
    fixture = await parent.createTemp('tree_');
  });
  tearDown(() async {
    final target = p.normalize(p.absolute(fixture.path));
    if (p.dirname(target) != p.normalize(p.absolute(parent.path)) ||
        !p.basename(target).startsWith('tree_')) {
      throw StateError('拒绝清理非本测试目录。');
    }
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  Future<Directory> tree(
    String name, {
    bool emptyDirectory = true,
    bool emptyFile = true,
  }) async {
    final root = await Directory(p.join(fixture.path, name)).create();
    await Directory(p.join(root.path, '资料')).create();
    await File(p.join(root.path, '资料', '内容.txt')).writeAsString('目录一致性测试内容');
    if (emptyDirectory) await Directory(p.join(root.path, '空目录')).create();
    if (emptyFile) await File(p.join(root.path, '占位.empty')).writeAsBytes([]);
    return root;
  }

  test('多根目录共享文件判重池，可找出不同目录中的同内容文件', () async {
    final a = await Directory(p.join(fixture.path, 'A')).create();
    final b = await Directory(p.join(fixture.path, 'B')).create();
    await File(p.join(a.path, '原件.txt')).writeAsString('跨根重复内容');
    await File(p.join(b.path, '不同名字.txt')).writeAsString('跨根重复内容');
    final plan = await DuplicateScanner(inspector: _InventoryInspector())
        .scanRoots([b.path, a.path], const ScanOptions());
    expect(plan.roots, [b.path, a.path]);
    expect(plan.groups, hasLength(1));
    expect(plan.groups.single.files, hasLength(2));
    expect(plan.folderGroups, isEmpty, reason: '目录相对文件名不同，不能整目录清理');
  });

  test('重复及嵌套扫描根仅遍历一次，并保留剩余输入顺序', () async {
    final a = await tree('A');
    final b = await tree('B');
    final plan = await DuplicateScanner(inspector: _InventoryInspector())
        .scanRoots([
          p.join(a.path, '资料'),
          b.path,
          a.path,
          a.path,
        ], const ScanOptions());
    expect(plan.roots, [b.path, a.path]);
    expect(plan.scannedFiles, 2);
    expect(plan.groups.single.files, hasLength(2));
    expect(plan.folderGroups, hasLength(1));
  });

  test('完整目录比较包含被文件扫描忽略的空文件和空子目录，并只输出最大副本', () async {
    final a = await tree('A');
    final b = await tree('B');
    final plan = await DuplicateScanner(inspector: _InventoryInspector())
        .scan(fixture.path, const ScanOptions());
    expect(plan.scannedFiles, 2, reason: '文件判重仍按默认规则跳过两个空文件');
    expect(plan.folderGroups, hasLength(1));
    final group = plan.folderGroups.single;
    expect(group.keep.path, a.path);
    expect(group.candidates.single.path, b.path);
    expect(group.keep.fileCount, 2);
    expect(
      group.keep.directories.map((e) => e.relativePath),
      containsAll(['资料', '空目录']),
    );
    expect(group.keep.files.any((e) => e.record.size == 0), isTrue);
    expect(
      ScanPlan.fromJson(plan.toJson()).folderGroups.single.fingerprint,
      group.fingerprint,
    );
  });

  test('空子目录结构不同的父目录不合并，但完整相同子目录仍可识别', () async {
    final a = await tree('A');
    final b = await tree('B', emptyDirectory: false);
    final plan = await DuplicateScanner(inspector: _InventoryInspector())
        .scanRoots([a.path, b.path], const ScanOptions());
    expect(
      plan.folderGroups
          .expand((g) => g.folders)
          .any((f) => f.path == a.path || f.path == b.path),
      isFalse,
    );
    expect(plan.folderGroups.single.keep.path, p.join(a.path, '资料'));
  });

  test('任一额外文件都会阻止父目录整组匹配', () async {
    final a = await tree('A');
    final b = await tree('B');
    await File(p.join(b.path, '额外.txt')).writeAsString('仅存在B');
    final plan = await DuplicateScanner(inspector: _InventoryInspector())
        .scanRoots([a.path, b.path], const ScanOptions());
    expect(
      plan.folderGroups
          .expand((g) => g.folders)
          .any((f) => f.path == a.path || f.path == b.path),
      isFalse,
    );
  });

  test('重解析点不会从清单静默消失，所在目录及祖先都不能整目录清理', () async {
    final a = await tree('A');
    final b = await tree('B');
    final link = p.join(b.path, '占位.empty');
    final inspector = _InventoryInspector(
      transform: (path, record) => path == link
          ? FileRecord(
              path: record.path,
              finalPath: record.finalPath,
              size: record.size,
              mtimeNs: record.mtimeNs,
              volumeId: record.volumeId,
              fileId: record.fileId,
              isReparsePoint: true,
            )
          : record,
    );
    final plan = await DuplicateScanner(inspector: inspector)
        .scanRoots([a.path, b.path], const ScanOptions());
    expect(
      plan.folderGroups.expand((g) => g.folders).any((f) => f.path == b.path),
      isFalse,
    );
    expect(plan.skipped.any((e) => e['path'] == link), isTrue);
  });

  test('无法读取的文件使所属完整树失效，不会当作不存在而误判', () async {
    final a = await tree('A');
    final b = await tree('B');
    final unreadable = p.join(b.path, '占位.empty');
    final inspector = _InventoryInspector(
      transform: (path, record) {
        if (path == unreadable) throw const FileSystemException('模拟访问被拒绝');
        return record;
      },
    );
    final plan = await DuplicateScanner(inspector: inspector)
        .scanRoots([a.path, b.path], const ScanOptions());
    expect(
      plan.folderGroups.expand((g) => g.folders).any((f) => f.path == b.path),
      isFalse,
    );
    expect(plan.errors.any((e) => e['path'] == unreadable), isTrue);
  });

  test('纯空目录不作为重复文件夹，含零字节文件的完整目录可以匹配', () async {
    final a = await Directory(p.join(fixture.path, 'A')).create();
    final b = await Directory(p.join(fixture.path, 'B')).create();
    final scanner = DuplicateScanner(inspector: _InventoryInspector());
    expect(
      (await scanner.scanRoots([
        a.path,
        b.path,
      ], const ScanOptions())).folderGroups,
      isEmpty,
    );
    await File(p.join(a.path, 'marker')).writeAsBytes([]);
    await File(p.join(b.path, 'marker')).writeAsBytes([]);
    final plan = await scanner.scanRoots([a.path, b.path], const ScanOptions());
    expect(plan.groups, isEmpty);
    expect(plan.folderGroups, hasLength(1));
    expect(plan.folderGroups.single.keep.totalBytes, 0);
  });

  test('关闭目录检测时仍正常执行跨根文件判重', () async {
    final a = await tree('A');
    final b = await tree('B');
    final plan = await DuplicateScanner(inspector: _InventoryInspector())
        .scanRoots([
          a.path,
          b.path,
        ], const ScanOptions(detectDuplicateFolders: false));
    expect(plan.groups, hasLength(1));
    expect(plan.folderGroups, isEmpty);
  });

  test('超过执行项数上限的父树不会遮蔽仍可清理的重复子树', () async {
    final a = await tree('A');
    final b = await tree('B');
    // 用更严格的限制覆盖同一个生产判断分支，避免测试创建上万个无关样本。
    // 此树共有 2 个文件、2 个目录；上限 3 时仅“资料”子树能够执行。
    final plan = await DuplicateScanner(
      inspector: _InventoryInspector(),
      folderEntryLimit: 3,
    ).scanRoots([a.path, b.path], const ScanOptions());
    expect(plan.folderGroups, hasLength(1));
    expect(plan.folderGroups.single.keep.path, p.join(a.path, '资料'));
    expect(
      plan.folderGroups.single.candidates.single.path,
      p.join(b.path, '资料'),
    );
    expect(
      plan.skipped.where((entry) => entry['reason']!.contains('超过整目录清理上限')),
      hasLength(2),
    );
    final boundary = await DuplicateScanner(
      inspector: _InventoryInspector(),
      folderEntryLimit: 4,
    ).scanRoots([a.path, b.path], const ScanOptions());
    expect(boundary.folderGroups.single.keep.path, a.path);
    expect(maxFolderManifestEntries, 8192);
    expect(
      () => DuplicateScanner(
        inspector: _InventoryInspector(),
        folderEntryLimit: maxFolderManifestEntries + 1,
      ),
      throwsArgumentError,
    );
  });

  test('深层唯一结构不额外读取文件内容，每个目录仅复核固定次数', () async {
    final root = await Directory(p.join(fixture.path, 'deep')).create();
    var leaf = root;
    // 短目录名保持绝对路径低于传统 MAX_PATH，测试针对树深度而非长路径能力。
    for (var index = 0; index < 55; index++) {
      leaf = await Directory(p.join(leaf.path, 'd')).create();
    }
    await File(p.join(leaf.path, 'only.txt')).writeAsString('唯一的叶子文件');
    final inspections = <String, int>{};
    final progress = <Map<String, Object?>>[];
    final plan = await DuplicateScanner(
      inspector: _InventoryInspector(
        transform: (path, record) {
          if (record.isDirectory) {
            inspections.update(path, (count) => count + 1, ifAbsent: () => 1);
          }
          return record;
        },
      ),
      onProgress: progress.add,
    ).scan(root.path, const ScanOptions());
    expect(plan.errors, isEmpty);
    expect(plan.folderGroups, isEmpty);
    expect(plan.groups, isEmpty);
    expect(progress.last['bytesRead'], 0, reason: '没有重复结构时不应计算目录文件内容摘要');
    expect(inspections, hasLength(56));
    expect(inspections.values.every((count) => count <= 3), isTrue);
  });

  test('深层重复结构仅输出最大完整副本，目录复核次数不随祖先数量增长', () async {
    final roots = <Directory>[];
    for (final name in ['A', 'B']) {
      final root = await Directory(p.join(fixture.path, name)).create();
      roots.add(root);
      var leaf = root;
      for (var index = 0; index < 40; index++) {
        leaf = await Directory(p.join(leaf.path, 'd')).create();
      }
      await File(p.join(leaf.path, 'same.txt')).writeAsString('共享叶子内容');
    }
    final inspections = <String, int>{};
    final plan = await DuplicateScanner(
      inspector: _InventoryInspector(
        transform: (path, record) {
          if (record.isDirectory) {
            inspections.update(path, (count) => count + 1, ifAbsent: () => 1);
          }
          return record;
        },
      ),
    ).scanRoots(roots.map((root) => root.path).toList(), const ScanOptions());
    expect(plan.errors, isEmpty);
    expect(plan.folderGroups, hasLength(1));
    expect(plan.folderGroups.single.keep.path, roots.first.path);
    expect(plan.folderGroups.single.keep.directories, hasLength(40));
    expect(inspections, hasLength(82));
    expect(inspections.values.every((count) => count <= 4), isTrue);
    expect(ScanPlan.fromJson(plan.toJson()).folderGroups, hasLength(1));
  });
}
