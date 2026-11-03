import 'dart:convert';
import 'dart:io';

import 'package:dupe_file_cleaner/application/app_controller.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/platform/windows_bridge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 清理状态测试只替换原生接口，不扫描、回收或删除任何候选路径。
///
/// 模型中的 D:\state-test 是纯内存路径；唯一真实写入是本工程 test_artifacts
/// 下本次创建的计划与日志，测试结束时验证范围后再清除这些专用临时文件。
void main() {
  late Directory fixture;
  late _ResultBridge bridge;
  late AppController app;

  setUp(() async {
    final parent = Directory(p.join(Directory.current.path, 'test_artifacts'));
    await parent.create(recursive: true);
    fixture = await parent.createTemp('cleanup-state-');
    bridge = _ResultBridge();
    app = _createController(bridge, p.join(fixture.path, 'history'));
  });

  tearDown(() async {
    app.dispose();
    final allowed = p.normalize(p.absolute('test_artifacts'));
    final target = p.normalize(p.absolute(fixture.path));
    if (!p.isWithin(allowed, target) ||
        !p.basename(target).startsWith('cleanup-state-')) {
      throw StateError('清理状态测试临时目录越界，拒绝递归删除');
    }
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  test('文件夹部分完成仅隔离关联组，独立保留项与勾选不受影响', () async {
    bridge.status = 'partial';
    final unaffectedFiles = _selectedFrom(app.selected, 'b-');
    final unaffectedFolders = _selectedFrom(app.selectedFolders, 'b-');

    await app.clean(permanent: true);

    expect(bridge.folderCalls, [_candidateA]);
    expect(app.busy, isFalse);
    expect(app.phase, TaskPhase.ready);
    expect(app.plan, isNotNull);
    expect(app.folderResultsValid, isTrue);
    expect(app.folderGroups.map((group) => group.id), [2]);
    expect(app.plan!.groups.map((group) => group.id), [2]);
    expect(app.selected, unaffectedFiles);
    expect(app.selectedFolders, unaffectedFolders);
    _expectIndependentKeepers(app);
    expect(app.results.single['status'], 'partial');

    // 独立组仍可生成有效执行计划，无须因为另一棵树的未知状态重新扫描全部目录。
    expect(app.selectionPlan().folderGroups.single.id, 2);
    expect(app.selectionPlan().folderGroups.single.candidates, hasLength(2));
    final entries = await _readLog(app.logPath!);
    expect(entries.last['partial'], isTrue);
  });

  test('原生调用抛出未知异常时隔离整个相交文件组，不自动重选该组保留项', () async {
    bridge.failure = StateError('模拟原生调用在返回状态前失去连接');
    final unaffectedFiles = _selectedFrom(app.selected, 'b-');
    final unaffectedFolders = _selectedFrom(app.selectedFolders, 'b-');

    await app.clean(permanent: false);

    expect(bridge.folderCalls, [_candidateA]);
    expect(app.error, contains('失去连接'));
    expect(app.busy, isFalse);
    expect(app.phase, TaskPhase.ready);
    expect(app.folderGroups.map((group) => group.id), [2]);
    // 组 1 还有两份树外文件，仍必须整体隔离；未知删除结果不能当作确认删除来补保留项。
    expect(app.plan!.groups.map((group) => group.id), [2]);
    expect(app.selected, unaffectedFiles);
    expect(app.selectedFolders, unaffectedFolders);
    _expectIndependentKeepers(app);
  });

  for (final status in ['cancelled', 'error', 'skipped']) {
    test('明确返回 $status 时保留未成功结果与选择，下一次仍可重试', () async {
      bridge.status = status;
      final fileSelection = Set<String>.from(app.selected);
      final folderSelection = Set<String>.from(app.selectedFolders);

      await app.clean(permanent: true);

      expect(app.busy, isFalse);
      expect(app.phase, TaskPhase.ready);
      expect(app.folderResultsValid, isTrue);
      expect(app.folderGroups.map((group) => group.id), [1, 2]);
      expect(app.plan!.groups.map((group) => group.id), [1, 2]);
      expect(app.selected, fileSelection);
      expect(app.selectedFolders, folderSelection);
      _expectIndependentKeepers(app);
      expect(app.completedFolders, isEmpty);

      // 模拟占用解除或用户重新发起；只选择先前失败的目标，验证其仍可正常执行。
      app.selectAll(false);
      final retryGroup = app.folderGroups.singleWhere((group) => group.id == 1);
      app.toggleFolder(
        retryGroup,
        retryGroup.folders.singleWhere((folder) => folder.path == _candidateA),
        true,
      );
      bridge.status = 'deleted';
      await app.clean(permanent: true);
      expect(app.error, isNull);
      expect(app.results.single['status'], 'deleted');
      expect(
        app.folderGroups
            .expand((group) => group.folders)
            .map((folder) => folder.path),
        isNot(contains(_candidateA)),
      );
      expect(app.folderGroups, hasLength(2), reason: '同组尚有两份完整副本，独立组也应继续保留');
      _expectIndependentKeepers(app);
    });
  }

  test('原生已成功但结果日志序列化失败时，仍移除成功目标并保留后续选择', () async {
    bridge.status = 'deleted';
    // 不修改产品日志 API，也不破坏已打开文件：用测试专属的不可 JSON 编码字段
    // 模拟 result 写入前序列化异常，覆盖成功事实与日志保存之间的失败边界。
    bridge.unencodableResult = true;
    final unaffectedFiles = _selectedFrom(app.selected, 'b-');
    final unaffectedFolders = _selectedFrom(app.selectedFolders, 'b-');

    await app.clean(permanent: true);

    expect(bridge.folderCalls, [_candidateA]);
    expect(app.error, isNotNull);
    expect(app.successCount, 1);
    expect(app.results.single['status'], 'deleted');
    expect(app.folderGroups, hasLength(2));
    expect(
      app.folderGroups
          .expand((group) => group.folders)
          .map((folder) => folder.path),
      isNot(contains(_candidateA)),
    );
    final relatedFiles = app.plan!.groups.singleWhere((group) => group.id == 1);
    expect(relatedFiles.files, hasLength(2));
    expect(
      relatedFiles.files.any(
        (file) => isPathWithinRoot(file.path, _candidateA),
      ),
      isFalse,
    );
    expect(app.selected, containsAll(unaffectedFiles));
    expect(
      app.selected,
      isNot(contains(AppController.key(app.keeper(relatedFiles).path))),
    );
    expect(app.selectedFolders, unaffectedFolders);
    _expectIndependentKeepers(app);
    final entries = await _readLog(app.logPath!);
    expect(entries.map((entry) => entry['type']), ['begin', 'intent']);
  });
}

const _root = r'D:\state-test';
const _candidateA = r'D:\state-test\a-1';
const _keeperB = r'D:\state-test\b-2';

FileRecord _file(String path, {int time = 1, bool directory = false}) =>
    FileRecord(
      path: path,
      finalPath: path,
      size: directory ? 0 : 16,
      mtimeNs: time,
      volumeId: 'unit-volume',
      fileId: path,
      isDirectory: directory,
    );

FolderRecord _folder(String path, String digest, int time) => FolderRecord(
  directory: _file(path, time: time, directory: true),
  files: [
    FolderFileEntry(
      relativePath: 'payload.bin',
      record: _file('$path\\payload.bin', time: time),
      sha256: digest,
    ),
  ],
);

/// 组 A 与组 B 完全独立；文件组 1 只有保留项位于 A 的待删目录中，另两份在树外。
/// 这个交叉关系同时验证成功时可保留幸存副本、未知状态时必须隔离整个关联文件组。
AppController _createController(_ResultBridge bridge, String history) {
  final app = AppController(bridge: bridge, historyDirectory: history);
  app.addDirectory(_root);
  final a = List.generate(
    3,
    (index) => _folder('$_root\\a-$index', 'a' * 64, index + 1),
  );
  final b = List.generate(
    3,
    (index) => _folder('$_root\\b-$index', 'b' * 64, index + 10),
  );
  final relatedFiles = DuplicateGroup(
    id: 1,
    size: 16,
    sha256: 'a' * 64,
    keep: a[1].files.single.record,
    candidates: [
      _file('$_root\\outside-x.bin', time: 30),
      _file('$_root\\outside-y.bin', time: 40),
    ],
  );
  final independentFiles = DuplicateGroup(
    id: 2,
    size: 16,
    sha256: 'b' * 64,
    keep: b.first.files.single.record,
    candidates: b.skip(1).map((folder) => folder.files.single.record).toList(),
  );
  final groups = [
    DuplicateFolderGroup(
      id: 1,
      fingerprint: folderFingerprint(a.first),
      keep: a.first,
      candidates: a.skip(1).toList(),
    ),
    DuplicateFolderGroup(
      id: 2,
      fingerprint: folderFingerprint(b.first),
      keep: b.first,
      candidates: b.skip(1).toList(),
    ),
  ];
  // 夹具也必须经过生产计划解析器，防止测试利用无效清单绕过真实状态边界。
  app.plan = ScanPlan.fromJson(
    ScanPlan(
      roots: app.roots,
      options: const ScanOptions(),
      groups: [relatedFiles, independentFiles],
      folderGroups: groups,
      generatedAt: DateTime.utc(2026, 10, 28),
    ).toJson(),
  );
  app.phase = TaskPhase.ready;
  app.selectAll(true);
  final fileGroup = app.plan!.groups.last;
  app.chooseKeeper(fileGroup, fileGroup.candidates.last);
  app.setResultMode(ResultMode.folders);
  final folderGroup = app.folderGroups.last;
  app.chooseFolderKeeper(folderGroup, folderGroup.candidates.last);
  app.toggleFolder(folderGroup, folderGroup.candidates.first, true);
  final firstGroup = app.folderGroups.first;
  app.toggleFolder(firstGroup, firstGroup.candidates.first, true);
  return app;
}

Set<String> _selectedFrom(Set<String> selection, String component) =>
    selection.where((path) => path.contains('\\$component')).toSet();

void _expectIndependentKeepers(AppController app) {
  final files = app.plan!.groups.singleWhere((group) => group.id == 2);
  final folders = app.folderGroups.singleWhere((group) => group.id == 2);
  expect(app.keeper(files).path, '$_keeperB\\payload.bin');
  expect(app.folderKeeper(folders).path, _keeperB);
  expect(
    app.selected,
    isNot(contains(AppController.key(app.keeper(files).path))),
  );
  expect(app.selectedFolders, isNot(contains(AppController.key(_keeperB))));
}

Future<List<Map<String, dynamic>>> _readLog(String path) async =>
    (await File(path).readAsLines())
        .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
        .toList();

/// 假原生层只回报结果和记录调用，不访问模型里的候选路径。
class _ResultBridge extends WindowsBridge {
  String status = 'deleted';
  Object? failure;
  bool unencodableResult = false;
  final List<String> folderCalls = [];

  @override
  Future<void> setBusy(bool busy) async {}
  @override
  Future<void> resetCancellation() async {}
  @override
  Future<void> cancelNative() async {}

  @override
  Future<Map<String, dynamic>> cleanFolder({
    required ScanPlan plan,
    required DuplicateFolderGroup group,
    required FolderRecord candidate,
    required bool permanent,
  }) async {
    folderCalls.add(candidate.path);
    if (failure != null) throw failure!;
    return {
      'path': candidate.path,
      'status': status,
      'kind': 'folder',
      'size': candidate.totalBytes,
      'reason': '测试结果：$status',
      if (unencodableResult) 'test_only_unencodable': Object(),
    };
  }
}
