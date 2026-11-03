import 'dart:convert';

import 'package:dupe_file_cleaner/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造不会访问磁盘的固定 Windows 路径样本，专门验证计划文件边界。
FileRecord _record(String filename, {String? path}) {
  final location = path ?? 'C:\\sample\\$filename';
  return FileRecord(
    path: location,
    finalPath: location,
    size: 12,
    mtimeNs: 1700000000123456700,
    volumeId: 'volume-1',
    fileId: filename,
  );
}

ScanPlan _validPlan() => ScanPlan(
  root: r'C:\sample',
  options: const ScanOptions(),
  groups: <DuplicateGroup>[
    DuplicateGroup(
      id: 1,
      size: 12,
      sha256: List<String>.filled(64, 'a').join(),
      keep: _record('keep.txt'),
      candidates: <FileRecord>[_record('delete.txt')],
    ),
  ],
  errors: <Map<String, String>>[],
  skipped: <Map<String, String>>[],
  scannedFiles: 2,
  scannedBytes: 24,
  visitedEntries: 2,
  elapsedMs: 10,
  generatedAt: DateTime.utc(2024, 1, 1),
);

/// 通过真实 JSON 往返获得可独立修改的测试输入，避免修改模型共享对象。
Map<String, dynamic> _jsonPlan() =>
    jsonDecode(jsonEncode(_validPlan().toJson())) as Map<String, dynamic>;

void main() {
  test('版本 3 计划往返保留精确时间、文件身份和清理分组', () {
    final decoded = ScanPlan.fromJson(_jsonPlan());

    expect(decoded.sourceVersion, 3);
    expect(decoded.toJson()['plan_version'], 3);
    expect(decoded.root, r'C:\sample');
    expect(decoded.groups, hasLength(1));
    expect(decoded.groups.single.keep.mtimeNs, 1700000000123456700);
    expect(decoded.groups.single.keep.fileId, 'keep.txt');
    expect(decoded.groups.single.candidates.single.fileId, 'delete.txt');
    expect(decoded.scannedFiles, 2);
  });

  test('保留文件不得同时出现在本组待清理列表，即使路径大小写不同', () {
    final json = _jsonPlan();
    final group = (json['groups'] as List).single as Map<String, dynamic>;
    final candidate = (group['delete'] as List).single as Map<String, dynamic>;
    candidate['path'] = r'c:\SAMPLE\KEEP.txt';
    candidate['final_path'] = r'c:\SAMPLE\KEEP.txt';

    expect(() => ScanPlan.fromJson(json), throwsA(isA<FormatException>()));
  });

  test('路径带有上级目录跳转而越出扫描根目录时拒绝导入', () {
    final json = _jsonPlan();
    final group = (json['groups'] as List).single as Map<String, dynamic>;
    final candidate = (group['delete'] as List).single as Map<String, dynamic>;
    candidate['path'] = r'C:\sample\..\outside\delete.txt';
    candidate['final_path'] = r'C:\outside\delete.txt';

    expect(() => ScanPlan.fromJson(json), throwsA(isA<FormatException>()));
  });

  test('具有相同前缀的相邻目录不能当作根目录内部', () {
    final json = _jsonPlan();
    final group = (json['groups'] as List).single as Map<String, dynamic>;
    final candidate = (group['delete'] as List).single as Map<String, dynamic>;
    candidate['path'] = r'C:\sample-other\delete.txt';
    candidate['final_path'] = r'C:\sample-other\delete.txt';

    expect(() => ScanPlan.fromJson(json), throwsA(isA<FormatException>()));
  });

  test('相对路径、目录项和格式错误的摘要不能成为清理目标', () {
    final relative = _jsonPlan();
    final relativeGroup =
        (relative['groups'] as List).single as Map<String, dynamic>;
    final relativeCandidate =
        (relativeGroup['delete'] as List).single as Map<String, dynamic>;
    relativeCandidate['path'] = r'sample\delete.txt';
    expect(() => ScanPlan.fromJson(relative), throwsA(isA<FormatException>()));

    final directory = _jsonPlan();
    final directoryGroup =
        (directory['groups'] as List).single as Map<String, dynamic>;
    final directoryCandidate =
        (directoryGroup['delete'] as List).single as Map<String, dynamic>;
    directoryCandidate['is_directory'] = true;
    expect(() => ScanPlan.fromJson(directory), throwsA(isA<FormatException>()));

    final badHash = _jsonPlan();
    final hashGroup =
        (badHash['groups'] as List).single as Map<String, dynamic>;
    hashGroup['sha256'] = 'not-a-sha256-digest';
    expect(() => ScanPlan.fromJson(badHash), throwsA(isA<FormatException>()));
  });

  test('同一路径跨组重复使用时拒绝导入，避免重复清理或保留冲突', () {
    final json = _jsonPlan();
    final groups = json['groups'] as List;
    final copied =
        jsonDecode(jsonEncode(groups.single)) as Map<String, dynamic>;
    copied['group_id'] = 2;
    groups.add(copied);

    expect(() => ScanPlan.fromJson(json), throwsA(isA<FormatException>()));
  });

  test('待清理文件大小必须与分组和保留文件一致', () {
    final json = _jsonPlan();
    final group = (json['groups'] as List).single as Map<String, dynamic>;
    final candidate = (group['delete'] as List).single as Map<String, dynamic>;
    candidate['size'] = 999;

    expect(() => ScanPlan.fromJson(json), throwsA(isA<FormatException>()));
  });

  test('版本 1 计划可以读取，但旧平台身份不能直接作为新版删除凭证', () {
    final json = _jsonPlan();
    json['plan_version'] = 1;
    final group = (json['groups'] as List).single as Map<String, dynamic>;
    final records = <Map<String, dynamic>>[
      group['keep'] as Map<String, dynamic>,
      ...(group['delete'] as List).cast<Map<String, dynamic>>(),
    ];
    for (final record in records) {
      record.remove('volume_id');
      record.remove('file_id');
      record.remove('final_path');
      record['device'] = 123;
      record['inode'] = 456;
      record['mtime_ns'] = 1700000000123456700;
    }

    final decoded = ScanPlan.fromJson(json);

    expect(decoded.groups.single.keep.fileId, isEmpty);
    expect(decoded.groups.single.keep.volumeId, isEmpty);
    expect(decoded.groups.single.keep.mtimeNs, 1700000000123456700);
  });

  test('未知计划版本拒绝导入，防止误读未来格式', () {
    final json = _jsonPlan()..['plan_version'] = 999;

    expect(() => ScanPlan.fromJson(json), throwsA(isA<FormatException>()));
  });
}
