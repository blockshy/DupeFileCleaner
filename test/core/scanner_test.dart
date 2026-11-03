import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/core/scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 使用真实文件进行读取，同时用可控快照代替 Windows 原生文件信息接口。
///
/// 这里的文件身份仅用于测试：同一路径始终拥有同一个身份，测试可以通过
/// [transform] 在指定调用次数改变快照，从而稳定复现扫描过程中发生的变化。
class _TestInspector implements FileInspector {
  _TestInspector({this.transform});

  final FileRecord Function(String, int, FileRecord)? transform;
  final Map<String, int> _calls = <String, int>{};

  @override
  Future<FileRecord> inspect(String path) async {
    final absolute = p.normalize(p.absolute(path));
    final stat = await FileStat.stat(absolute);
    if (stat.type == FileSystemEntityType.notFound) {
      throw FileSystemException('测试文件不存在', absolute);
    }
    final call = (_calls[absolute] ?? 0) + 1;
    _calls[absolute] = call;
    final record = FileRecord(
      path: absolute,
      finalPath: absolute,
      size: stat.size,
      mtimeNs: stat.modified.microsecondsSinceEpoch * 1000,
      volumeId: 'test-volume',
      fileId: absolute.toLowerCase(),
      isDirectory: stat.type == FileSystemEntityType.directory,
      isReparsePoint: await FileSystemEntity.isLink(absolute),
    );
    return transform?.call(absolute, call, record) ?? record;
  }
}

void main() {
  late Directory fixtureRoot;
  late Directory testDirectory;

  setUp(() async {
    // 测试数据全部创建在当前工程 build 目录下，不扫描或清理用户真实目录。
    fixtureRoot = Directory(
      p.join(Directory.current.path, 'build', 'core_test_fixtures'),
    );
    await fixtureRoot.create(recursive: true);
    testDirectory = await fixtureRoot.createTemp('case_');
  });

  tearDown(() async {
    // 仅允许删除本次 setUp 创建的直接子目录，防止测试辅助逻辑误清理其他路径。
    final parent = p.normalize(p.absolute(fixtureRoot.path));
    final target = p.normalize(p.absolute(testDirectory.path));
    if (p.dirname(target) != parent ||
        !p.basename(target).startsWith('case_')) {
      throw StateError('拒绝清理不属于当前测试的目录：$target');
    }
    if (await testDirectory.exists()) {
      await testDirectory.delete(recursive: true);
    }
  });

  test('相同内容不同文件名归为一组，并保留最后修改时间最早的一份', () async {
    final oldest = File(p.join(testDirectory.path, 'old.txt'));
    final newer = File(p.join(testDirectory.path, 'renamed.bin'));
    final unique = File(p.join(testDirectory.path, 'unique.txt'));
    const content = '用于验证内容判重的中文内容';
    await oldest.writeAsString(content);
    await newer.writeAsString(content);
    await unique.writeAsString('这是另一份内容，不能归入重复组');
    await oldest.setLastModified(DateTime.utc(2020, 1, 1));
    await newer.setLastModified(DateTime.utc(2024, 1, 1));

    final plan = await DuplicateScanner(inspector: _TestInspector())
        .scan(testDirectory.path, const ScanOptions());

    expect(plan.groups, hasLength(1));
    final group = plan.groups.single;
    expect(group.keep.path, p.normalize(oldest.path));
    expect(group.candidates.single.path, p.normalize(newer.path));
    expect(group.sha256, sha256.convert(await oldest.readAsBytes()).toString());
    expect(plan.scannedFiles, 3);
    expect(plan.errors, isEmpty);
  });

  test('修改时间相同时按规范化后的路径排序保留，结果不受枚举顺序影响', () async {
    final pathB = File(p.join(testDirectory.path, 'b.txt'));
    final pathA = File(p.join(testDirectory.path, 'a.txt'));
    final timestamp = DateTime.utc(2023, 8, 9);
    // 故意先写入 b，再写入 a，让文件创建顺序与预期保留顺序不同。
    await pathB.writeAsString('相同内容');
    await pathA.writeAsString('相同内容');
    await pathB.setLastModified(timestamp);
    await pathA.setLastModified(timestamp);

    final plan = await DuplicateScanner(inspector: _TestInspector())
        .scan(testDirectory.path, const ScanOptions());

    expect(plan.groups.single.keep.path, p.normalize(pathA.path));
  });

  test('首尾快速摘要相同但中间内容不同，完整 SHA-256 不会误判重复', () async {
    // 两个文件首尾各 128 KiB 完全相同，只有中间一字节不同。
    final firstBytes = List<int>.filled(400 * 1024, 7);
    final secondBytes = List<int>.of(firstBytes)..[200 * 1024] = 9;
    await File(p.join(testDirectory.path, 'first.bin'))
        .writeAsBytes(firstBytes);
    await File(p.join(testDirectory.path, 'second.bin'))
        .writeAsBytes(secondBytes);

    final plan = await DuplicateScanner(inspector: _TestInspector())
        .scan(testDirectory.path, const ScanOptions());

    expect(plan.scannedFiles, 2);
    expect(plan.groups, isEmpty);
    expect(plan.errors, isEmpty);
  });

  test('空文件默认跳过，显式包含后可以形成重复组', () async {
    await File(p.join(testDirectory.path, 'first.empty')).writeAsBytes(<int>[]);
    await File(p.join(testDirectory.path, 'second.empty'))
        .writeAsBytes(<int>[]);

    final excluded = await DuplicateScanner(inspector: _TestInspector())
        .scan(testDirectory.path, const ScanOptions());
    final included = await DuplicateScanner(inspector: _TestInspector())
        .scan(testDirectory.path, const ScanOptions(includeEmpty: true));

    expect(excluded.groups, isEmpty);
    expect(excluded.skipped, hasLength(2));
    expect(included.groups, hasLength(1));
    expect(included.groups.single.size, 0);
  });

  test('取消请求终止扫描，并以专用异常区分正常取消和失败', () async {
    await File(p.join(testDirectory.path, 'sample.txt'))
        .writeAsString('sample');
    final scanner = DuplicateScanner(
      inspector: _TestInspector(),
      isCancelled: () => true,
    );

    await expectLater(
      scanner.scan(testDirectory.path, const ScanOptions()),
      throwsA(isA<ScanCancelled>()),
    );
  });

  test('枚举与哈希阶段之间快照发生变化时跳过文件，不生成可清理项', () async {
    final changed = File(p.join(testDirectory.path, 'changed.txt'));
    final stable = File(p.join(testDirectory.path, 'stable.txt'));
    await changed.writeAsString('相同内容');
    await stable.writeAsString('相同内容');
    final inspector = _TestInspector(
      transform: (path, call, record) {
        if (path == p.normalize(changed.path) && call >= 2) {
          // 无须在测试中制造不确定的并发写入，直接模拟修改时间发生变化。
          return FileRecord(
            path: record.path,
            finalPath: record.finalPath,
            size: record.size,
            mtimeNs: record.mtimeNs + 1000000,
            volumeId: record.volumeId,
            fileId: record.fileId,
            linkCount: record.linkCount,
            isDirectory: record.isDirectory,
            isReparsePoint: record.isReparsePoint,
          );
        }
        return record;
      },
    );

    final plan = await DuplicateScanner(inspector: inspector)
        .scan(testDirectory.path, const ScanOptions());

    expect(plan.groups, isEmpty);
    final issues = <Map<String, String>>[...plan.errors, ...plan.skipped];
    expect(
      issues.any((issue) => issue['path'] == p.normalize(changed.path)),
      isTrue,
    );
  });

  test('根目录被识别为重解析点时直接拒绝扫描', () async {
    final inspector = _TestInspector(
      transform: (path, call, record) => FileRecord(
        path: record.path,
        finalPath: record.finalPath,
        size: record.size,
        mtimeNs: record.mtimeNs,
        volumeId: record.volumeId,
        fileId: record.fileId,
        isDirectory: record.isDirectory,
        isReparsePoint: true,
      ),
    );

    await expectLater(
      DuplicateScanner(inspector: inspector)
          .scan(testDirectory.path, const ScanOptions()),
      throwsA(isA<Exception>()),
    );
  });
}
