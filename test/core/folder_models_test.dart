import 'dart:convert';

import 'package:dupe_file_cleaner/core/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计划格式测试只创建内存模型；路径用于边界验证，不触及真实磁盘。
FileRecord _snapshot(String path, {bool directory = false}) => FileRecord(
  path: path,
  finalPath: path,
  size: directory ? 0 : 24,
  mtimeNs: 1700000000123456700,
  volumeId: 'volume',
  fileId: path,
  isDirectory: directory,
);

FolderRecord _folder(String root) => FolderRecord(
  directory: _snapshot(root, directory: true),
  directories: [
    FolderDirectoryEntry(
      relativePath: 'sub',
      record: _snapshot('$root\\sub', directory: true),
    ),
  ],
  files: [
    FolderFileEntry(
      relativePath: r'sub\data.txt',
      record: _snapshot('$root\\sub\\data.txt'),
      sha256: 'a' * 64,
    ),
  ],
);

ScanPlan _plan() {
  final keep = _folder(r'C:\scope\A');
  return ScanPlan(
    roots: [r'C:\scope', r'D:\copies'],
    options: const ScanOptions(),
    groups: [],
    folderGroups: [
      DuplicateFolderGroup(
        id: 1,
        fingerprint: folderFingerprint(keep),
        keep: keep,
        candidates: [_folder(r'D:\copies\B')],
      ),
    ],
    generatedAt: DateTime.utc(2026),
  );
}

Map<String, dynamic> _json() =>
    jsonDecode(jsonEncode(_plan().toJson())) as Map<String, dynamic>;

void main() {
  test('版本3计划保存多根目录及完整目录清单，统计由清单计算', () {
    final original = _plan();
    final json = _json();
    (json['summary'] as Map)['folder_delete_candidates'] = 900;
    final parsed = ScanPlan.fromJson(json);
    expect(parsed.roots, original.roots);
    expect(parsed.root, original.root);
    expect(parsed.folderGroups.single.keep.fileCount, 1);
    expect(parsed.folderDeleteCount, 1);
    expect(parsed.folderDuplicateBytes, 24);
    expect(parsed.toJson()['plan_version'], 3);
  });

  test('普通文件重复组可跨多个有效根目录', () {
    final keep = _snapshot(r'C:\scope\keep.txt');
    final candidate = _snapshot(r'D:\copies\delete.txt');
    final source = ScanPlan(
      roots: [r'C:\scope', r'D:\copies'],
      options: const ScanOptions(),
      groups: [
        DuplicateGroup(
          id: 1,
          size: 24,
          sha256: 'a' * 64,
          keep: keep,
          candidates: [candidate],
        ),
      ],
      generatedAt: DateTime.utc(2026),
    );
    expect(
      ScanPlan.fromJson(source.toJson()).groups.single.files,
      hasLength(2),
    );
  });

  test('旧版2单目录计划可以转换为新版roots，保留原有身份字段', () {
    final source = ScanPlan(
      root: r'C:\scope',
      options: const ScanOptions(),
      groups: [],
      generatedAt: DateTime.utc(2026),
    ).toJson();
    source['plan_version'] = 2;
    source.remove('roots');
    final parsed = ScanPlan.fromJson(source);
    expect(parsed.roots, [r'C:\scope']);
    expect(parsed.folderGroups, isEmpty);
  });

  test('计划拒绝重复或嵌套根目录，避免同一树被多次授权', () {
    final source = _json();
    source['roots'] = [r'C:\scope', r'C:\scope\sub'];
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });

  test('目录清单拒绝相对路径穿越，即使伪造后重新计算分组指纹', () {
    final source = _json();
    final group = (source['folder_groups'] as List).single as Map;
    final folder = group['keep'] as Map;
    ((folder['files'] as List).single as Map)['relative_path'] =
        r'..\escape.txt';
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });

  test('目录清单必须包含每一级父目录及正确的文件类型', () {
    final source = _json();
    final group = (source['folder_groups'] as List).single as Map;
    (group['keep'] as Map)['directories'] = [];
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });

  test('同组成员结构或摘要不一致时拒绝导入', () {
    final source = _json();
    final group = (source['folder_groups'] as List).single as Map;
    final candidate = (group['delete'] as List).single as Map;
    ((candidate['files'] as List).single as Map)['sha256'] = 'b' * 64;
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });

  test('目录清单不接受硬链接和重解析点', () {
    final source = _json();
    final group = (source['folder_groups'] as List).single as Map;
    final record =
        (((group['keep'] as Map)['files'] as List).single as Map)['record']
            as Map;
    record['link_count'] = 2;
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });

  test('跨目录组不允许相同路径或祖先后代路径重叠', () {
    final source = _json();
    final nested = _folder(r'C:\scope\A\sub');
    final childGroup = DuplicateFolderGroup(
      id: 2,
      fingerprint: folderFingerprint(nested),
      keep: nested,
      candidates: [_folder(r'D:\copies\B\sub')],
    );
    (source['folder_groups'] as List).add(childGroup.toJson());
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });

  test('文件夹根可以等于用户扫描根，但不能等于磁盘根', () {
    final original = _plan();
    final source = original.toJson();
    source['roots'] = [r'C:\scope\A', r'D:\copies\B'];
    expect(ScanPlan.fromJson(source).folderGroups, hasLength(1));
    final drive = _folder('C:\\');
    expect(() => FolderRecord.fromJson(drive.toJson()), throwsFormatException);
  });

  test('目录重叠校验允许同前缀相邻目录及跨盘目录', () {
    final folders = [
      _folder(r'C:\scope\foo'),
      _folder(r'C:\scope\foobar'),
      _folder(r'C:\scope\foo-other'),
      _folder(r'D:\copies\foo'),
    ];
    final source = ScanPlan(
      roots: [r'C:\scope', r'D:\copies'],
      options: const ScanOptions(),
      groups: [],
      folderGroups: [
        DuplicateFolderGroup(
          id: 1,
          fingerprint: folderFingerprint(folders.first),
          keep: folders.first,
          candidates: folders.skip(1).toList(),
        ),
      ],
      generatedAt: DateTime.utc(2026),
    );
    expect(
      ScanPlan.fromJson(source.toJson()).folderGroups.single.folders,
      hasLength(4),
    );
  });

  test('相邻同前缀路径不能遮挡真正的祖先后代重叠', () {
    final folders = [
      _folder(r'C:\scope\foo'),
      _folder(r'C:\scope\foo-other'),
      _folder(r'C:\scope\foo\nested'),
    ];
    final source = ScanPlan(
      root: r'C:\scope',
      options: const ScanOptions(),
      groups: [],
      folderGroups: [
        DuplicateFolderGroup(
          id: 1,
          fingerprint: folderFingerprint(folders.first),
          keep: folders.first,
          candidates: folders.skip(1).toList(),
        ),
      ],
      generatedAt: DateTime.utc(2026),
    );
    expect(() => ScanPlan.fromJson(source.toJson()), throwsFormatException);
  });

  test('目录路径自身重复时即使大小写不同仍拒绝导入', () {
    final source = _json();
    final group = (source['folder_groups'] as List).single as Map;
    group['delete'] = [_folder(r'c:\SCOPE\a').toJson()];
    expect(() => ScanPlan.fromJson(source), throwsFormatException);
  });
}
