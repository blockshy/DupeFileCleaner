import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dupe_file_cleaner/application/app_controller.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/platform/windows_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// 在真实 Windows runner 中覆盖多根目录、文件夹选择、后台导入与清理日志。
///
/// 测试仅操作工程 test_artifacts/mwf-* 内自行生成的文件。每个扫描根都位于
/// fixture 的下一层，history 和导出计划与扫描根同级，避免写日志改变待清理树。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final inspector = WindowsBridge();
  late Directory workspace;
  late Directory parent;
  late Directory fixture;
  late _FixtureBridge bridge;
  late AppController app;

  setUpAll(() async {
    if (!Platform.isWindows) {
      throw StateError('多目录工作流测试必须在真实 Windows runner 中运行。');
    }
    workspace = Directory(p.normalize(p.absolute(Directory.current.path)));
    final pubspec = File(p.join(workspace.path, 'pubspec.yaml'));
    if (!await pubspec.exists() ||
        !(await pubspec.readAsString()).contains('name: dupe_file_cleaner')) {
      throw StateError('当前目录不是本工程，拒绝创建或移除测试目录。');
    }
    parent = await Directory(p.join(workspace.path, 'test_artifacts'))
        .create(recursive: true);
    final info = await inspector.inspect(parent.path);
    if (info.isReparsePoint ||
        canonicalWindowsPath(info.finalPath) !=
            canonicalWindowsPath(parent.path)) {
      throw StateError('测试父目录是链接或被重定向，拒绝继续。');
    }
  });

  setUp(() async {
    fixture = await parent.createTemp('mwf-');
    bridge = _FixtureBridge();
    app = AppController(
      bridge: bridge,
      historyDirectory: p.join(fixture.path, 'history'),
    );
    await inspector.resetCancellation();
  });

  tearDown(() async {
    // 即使断言失败，也先等待后台任务协作停止，再处理测试自行创建的样本。
    if (app.busy) {
      await _runUntilIdle(app, app.cancel, alreadyStarted: true);
    }
    app.dispose();
    await inspector.resetCancellation();
    await inspector.setBusy(false);
    final target = p.normalize(p.absolute(fixture.path));
    if (p.dirname(target) != p.normalize(p.absolute(parent.path)) ||
        !p.basename(target).startsWith('mwf-') ||
        !p.isWithin(workspace.path, target)) {
      throw StateError('测试范围校验失败，拒绝递归清理：$target');
    }
    if (await fixture.exists()) {
      final info = await inspector.inspect(target);
      if (info.isReparsePoint ||
          canonicalWindowsPath(info.finalPath) !=
              canonicalWindowsPath(target)) {
        throw StateError('测试目录被替换或重定向，拒绝递归清理：$target');
      }
      await fixture.delete(recursive: true);
    }
  });

  testWidgets('同组多个副本可连续清理，剩余计划可导出导入并保留人工保留项', (tester) async {
    await _showHost(tester, '验证多目录扫描与完整文件夹清理');
    final roots = await _createCopies(fixture, count: 3);
    for (final root in roots) {
      app.addDirectory(root.path);
    }
    // 重复根和已包含的子目录不会增加扫描范围，也不会重复枚举文件。
    app.addDirectory(roots.first.path);
    app.addDirectory(p.join(roots.first.path, '资料'));
    expect(app.roots, roots.map((root) => root.path).toList());
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    expect(app.plan!.roots, app.roots);
    expect(app.plan!.groups, hasLength(2));
    expect(app.plan!.folderGroups, hasLength(1));

    app.setResultMode(ResultMode.folders);
    expect(app.selectedFolders, isEmpty, reason: '整目录操作必须由用户明确勾选');
    expect(app.selectedCount, 0);
    final group = app.folderGroups.single;
    expect(group.keep.path, roots.first.path);
    expect(group.keep.fileCount, 3, reason: '完整清单必须包括默认文件扫描忽略的空文件');
    expect(group.keep.directories, hasLength(2));
    app.toggleFolder(group, group.candidates.first, true);
    expect(app.selectedCount, 1);
    app.toggleFolder(group, group.candidates.first, false);

    // 选择最后一份树作为保留目录，只清理原保留目录，中间副本保持未勾选。
    final keeper = group.folders.singleWhere(
      (folder) => folder.path == roots.last.path,
    );
    app.chooseFolderKeeper(group, keeper);
    expect(app.folderKeeper(group).path, roots.last.path);
    expect(app.selectedFolders, {AppController.key(roots.first.path)});
    expect(app.selectedFileCount, 3);
    final frozen = app.selectionPlan();
    expect(frozen.groups, isEmpty, reason: '整目录计划不能夹带重复文件清理');
    expect(frozen.folderGroups.single.keep.path, roots.last.path);
    expect(frozen.folderGroups.single.candidates.single.path, roots.first.path);
    bridge.savePath = p.join(fixture.path, 'folder-selection.json');
    await app.exportPlan();
    expect(app.error, isNull);
    final exported = await _readPlan(bridge.savePath!);
    expect(exported.toJson()['plan_version'], 3);
    expect(exported.groups, isEmpty);
    expect(exported.folderDeleteCount, 1);
    expect(exported.folderGroups.single.keep.path, roots.last.path);

    await app.clean(permanent: true).timeout(const Duration(seconds: 60));
    expect(app.error, isNull);
    expect(app.busy, isFalse);
    expect(app.phase, TaskPhase.ready);
    expect(app.successCount, 1);
    expect(app.results.single['status'], 'deleted');
    expect(app.results.single['kind'], 'folder');
    expect(app.plan, isNotNull, reason: '成功清理只移除已处理成员，不能清空独立结果');
    expect(app.folderResultsValid, isTrue);
    expect(app.folderGroups, hasLength(1));
    expect(app.folderGroups.single.folders, hasLength(2));
    expect(app.folderKeeper(app.folderGroups.single).path, roots.last.path);
    expect(app.roots, roots.skip(1).map((root) => root.path).toList());
    expect(app.plan!.roots, app.roots);
    expect(
      app.plan!.groups
          .expand((item) => item.files)
          .any((file) => isPathWithinRoot(file.path, roots.first.path)),
      isFalse,
      reason: '文件结果也必须剔除已删除目录内的记录，避免继续引用旧保留文件',
    );
    expect(app.selectedFolders, isEmpty);
    expect(await roots.first.exists(), isFalse);
    await _expectCompleteTree(roots[1]);
    await _expectCompleteTree(roots.last);

    final entries = await _readLog(app.logPath!);
    expect(entries.map((entry) => entry['type']).toList(), [
      'begin',
      'intent',
      'result',
      'finish',
    ]);
    expect(entries[0]['kind'], 'folder');
    expect(entries[0]['roots'], roots.map((root) => root.path).toList());
    expect(entries[1]['kind'], 'folder');
    expect(entries[1]['path'], roots.first.path);
    expect(entries[1]['keep'], roots.last.path);
    expect(entries[2]['kind'], 'folder');
    expect(entries[2]['status'], 'deleted');
    final recorded = await _readPlan(entries[0]['plan'] as String);
    expect(recorded.groups, isEmpty);
    expect(
      recorded.folderGroups.single.candidates.single.path,
      roots.first.path,
    );
    expect(p.isWithin(p.join(fixture.path, 'history'), app.logPath!), isTrue);
    // 不重新扫描，直接选择同组剩余副本。导出的根目录和完整清单不得包含已删目录。
    final remaining = app.folderGroups.single;
    final nextCandidate = remaining.folders.singleWhere(
      (folder) => folder.path == roots[1].path,
    );
    app.toggleFolder(remaining, nextCandidate, true);
    expect(app.selectedCount, 1);
    bridge.savePath = p.join(fixture.path, 'remaining-folders.json');
    await app.exportPlan();
    expect(app.error, isNull);
    final remainingPlan = await _readPlan(bridge.savePath!);
    expect(
      remainingPlan.roots,
      roots.skip(1).map((root) => root.path).toList(),
    );
    expect(remainingPlan.folderGroups.single.keep.path, roots.last.path);
    expect(
      remainingPlan.folderGroups.single.candidates.single.path,
      roots[1].path,
    );
    bridge.openPath = bridge.savePath;
    await _runUntilIdle(app, app.importPlan);
    expect(app.error, isNull);
    expect(app.plan!.errors, isEmpty, reason: '剩余清单必须能通过真实完整内容复核');
    expect(app.folderGroups, hasLength(1));
    expect(app.folderGroups.single.keep.path, roots.last.path);
    app.selectAll(true);
    await app.clean(permanent: true).timeout(const Duration(seconds: 60));
    expect(app.error, isNull);
    expect(app.successCount, 1);
    expect(app.results.single['status'], 'deleted');
    expect(app.plan, isNotNull);
    expect(app.folderGroups, isEmpty);
    expect(app.selectedFolders, isEmpty);
    expect(app.roots, [roots.last.path]);
    expect(app.plan!.roots, app.roots);
    expect(await roots[1].exists(), isFalse);
    await _expectCompleteTree(roots.last);
    debugPrint(
      'MULTI_FOLDER_WORKFLOW_OK: two sequential cleanups without rescanning',
    );
  });

  testWidgets('文件清理后移除受影响的完整目录组，旧对象不能重新加入勾选', (tester) async {
    await _showHost(tester, '验证不同清理粒度之间的失效边界');
    final roots = await _createCopies(fixture);
    for (final root in roots) {
      app.addDirectory(root.path);
    }
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    final folderGroup = app.folderGroups.single;
    app.setResultMode(ResultMode.folders);
    app.selectAll(true);
    expect(app.selectedFolders, hasLength(1));
    app.setResultMode(ResultMode.files);
    app.selectAll(false);
    final fileGroup = app.plan!.groups.first;
    final candidate = fileGroup.candidates.single;
    app.toggleFile(fileGroup, candidate, true);
    expect(app.selectionPlan().folderGroups, isEmpty);
    await app.clean(permanent: true).timeout(const Duration(seconds: 45));
    expect(app.error, isNull);
    expect(app.results.single['status'], 'deleted');
    expect(await File(candidate.path).exists(), isFalse);
    expect(app.folderResultsValid, isTrue);
    expect(app.selectedFolders, isEmpty);
    expect(app.folderGroups, isEmpty);
    final logPath = app.logPath;
    final logContents = await File(logPath!).readAsString();

    app.setResultMode(ResultMode.folders);
    app.selectAll(true);
    app.toggleFolder(folderGroup, folderGroup.candidates.single, true);
    expect(app.selectedCount, 0);
    expect(app.selectionPlan().folderGroups, isEmpty);
    await app.clean(permanent: true);
    expect(app.logPath, logPath);
    expect(await File(logPath).readAsString(), logContents);
    for (final root in roots) {
      expect(await root.exists(), isTrue, reason: '失效目录组不得执行整个目录清理');
    }
  });

  testWidgets('多个独立目录组可逐组连续清理，其他组的人工保留项保持不变', (tester) async {
    await _showHost(tester, '验证不同重复目录组的连续清理');
    final first = await _createCopies(
      fixture,
      prefix: 'alpha',
      contentSuffix: '-A',
    );
    final second = await _createCopies(
      fixture,
      prefix: 'beta',
      contentSuffix: '-B',
    );
    for (final root in [...first, ...second]) {
      app.addDirectory(root.path);
    }
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    expect(app.folderGroups, hasLength(2));
    app.setResultMode(ResultMode.folders);
    final firstGroup = app.folderGroups.singleWhere(
      (group) => group.keep.path == first.first.path,
    );
    final secondGroup = app.folderGroups.singleWhere(
      (group) => group.keep.path == second.first.path,
    );

    // 提前修改另一组的保留项，再取消它的候选勾选，首轮只处理第一组。
    app.chooseFolderKeeper(secondGroup, secondGroup.candidates.single);
    app.toggleFolder(secondGroup, secondGroup.keep, false);
    app.toggleFolder(firstGroup, firstGroup.candidates.single, true);
    await app.clean(permanent: true).timeout(const Duration(seconds: 60));
    expect(app.error, isNull);
    expect(app.successCount, 1);
    expect(app.folderGroups, hasLength(1));
    expect(app.folderGroups.single.id, secondGroup.id);
    expect(app.folderKeeper(app.folderGroups.single).path, second.last.path);
    expect(app.selectedFolders, isEmpty);
    expect(await first.last.exists(), isFalse);
    await _expectCompleteTree(first.first, contentSuffix: '-A');
    for (final root in second) {
      await _expectCompleteTree(root, contentSuffix: '-B');
    }

    final remaining = app.folderGroups.single;
    app.toggleFolder(
      remaining,
      remaining.folders.singleWhere(
        (folder) => folder.path == second.first.path,
      ),
      true,
    );
    await app.clean(permanent: true).timeout(const Duration(seconds: 60));
    expect(app.error, isNull);
    expect(app.results.single['status'], 'deleted');
    expect(app.folderGroups, isEmpty);
    expect(app.plan, isNotNull);
    expect(await second.first.exists(), isFalse);
    await _expectCompleteTree(second.last, contentSuffix: '-B');
    await _expectCompleteTree(first.first, contentSuffix: '-A');
  });

  testWidgets('删除原文件保留项所在目录后，剩余文件组自动保护一份并可继续清理', (tester) async {
    await _showHost(tester, '验证文件夹与文件结果的增量衔接');
    final roots = await _createCopies(fixture, count: 3);
    for (final root in roots) {
      app.addDirectory(root.path);
    }
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    expect(
      app.plan!.groups.every(
        (group) => isPathWithinRoot(app.keeper(group).path, roots.first.path),
      ),
      isTrue,
      reason: '专用样本的最早修改时间位于首个根，确保覆盖原保留项被整目录清理的情况',
    );
    app.setResultMode(ResultMode.folders);
    final folders = app.folderGroups.single;
    app.chooseFolderKeeper(folders, folders.folders.last);
    expect(app.selectedFolders, {AppController.key(roots.first.path)});
    await app.clean(permanent: true).timeout(const Duration(seconds: 60));
    expect(app.error, isNull);
    expect(app.plan!.groups, hasLength(2));
    for (final group in app.plan!.groups) {
      expect(group.files, hasLength(2));
      expect(isPathWithinRoot(app.keeper(group).path, roots[1].path), isTrue);
      expect(
        app.selected,
        isNot(contains(AppController.key(app.keeper(group).path))),
      );
      expect(await File(app.keeper(group).path).exists(), isTrue);
    }

    // 切换结果页不重新扫描，原生层仍重新完整复核新的文件保留项与候选内容。
    app.setResultMode(ResultMode.files);
    app.selectAll(false);
    final group = app.plan!.groups.first;
    final keep = app.keeper(group);
    final candidate = app
        .files(group)
        .singleWhere((file) => !app.isKept(group, file));
    app.toggleFile(group, candidate, true);
    expect(app.selectionPlan().groups.single.keep.path, keep.path);
    await app.clean(permanent: true).timeout(const Duration(seconds: 45));
    expect(app.error, isNull);
    expect(app.results.single['status'], 'deleted');
    expect(await File(candidate.path).exists(), isFalse);
    expect(await File(keep.path).exists(), isTrue);
    await _expectCompleteTree(roots[1]);
  });

  testWidgets('单文件清理只移除受影响目录成员，另一组勾选可直接继续整目录清理', (tester) async {
    await _showHost(tester, '验证文件清理保留独立文件夹结果');
    final first = await _createCopies(
      fixture,
      prefix: 'alpha',
      contentSuffix: '-A',
    );
    final second = await _createCopies(
      fixture,
      prefix: 'beta',
      contentSuffix: '-B',
    );
    for (final root in [...first, ...second]) {
      app.addDirectory(root.path);
    }
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    expect(app.folderGroups, hasLength(2));
    final otherGroup = app.folderGroups.singleWhere(
      (group) => group.keep.path == second.first.path,
    );
    app.setResultMode(ResultMode.folders);
    app.toggleFolder(otherGroup, otherGroup.candidates.single, true);
    app.setResultMode(ResultMode.files);
    app.selectAll(false);
    final fileGroup = app.plan!.groups.firstWhere(
      (group) => isPathWithinRoot(app.keeper(group).path, first.first.path),
    );
    final candidate = fileGroup.candidates.single;
    app.toggleFile(fileGroup, candidate, true);
    await app.clean(permanent: true).timeout(const Duration(seconds: 45));
    expect(app.error, isNull);
    expect(await File(candidate.path).exists(), isFalse);
    expect(app.folderResultsValid, isTrue);
    expect(app.folderGroups, hasLength(1));
    expect(app.folderGroups.single.id, otherGroup.id);
    expect(app.selectedFolders, {AppController.key(second.last.path)});

    app.setResultMode(ResultMode.folders);
    expect(app.selectedCount, 1);
    await app.clean(permanent: true).timeout(const Duration(seconds: 60));
    expect(app.error, isNull);
    expect(app.results.single['status'], 'deleted');
    expect(await second.last.exists(), isFalse);
    await _expectCompleteTree(second.first, contentSuffix: '-B');
    expect(await first.last.exists(), isTrue, reason: '部分文件变化的目录不会被整目录误删');
  });

  testWidgets('版本 3 目录计划后台逐项重读，同大小同时间的内容变化仍拒绝整组', (tester) async {
    await _showHost(tester, '验证目录计划完整内容复核');
    final roots = await _createCopies(fixture);
    for (final root in roots) {
      app.addDirectory(root.path);
    }
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    app.setResultMode(ResultMode.folders);
    app.selectAll(true);
    final saved = app.selectionPlan();
    bridge.openPath = p.join(fixture.path, 'import-folder-v3.json');
    await File(bridge.openPath!)
        .writeAsString(jsonEncode(saved.toJson()), flush: true);
    await _runUntilIdle(app, app.importPlan);
    expect(app.error, isNull);
    expect(app.importedPlan, isTrue);
    expect(app.plan!.sourceVersion, 3);
    expect(app.plan!.groups, isEmpty);
    expect(app.folderGroups, hasLength(1));
    expect(app.selectedFolders, isEmpty);
    expect(app.plan!.errors, isEmpty);

    final changed = saved.folderGroups.single.candidates.single.files
        .singleWhere((entry) => entry.relativePath == p.join('资料', '正文.txt'));
    await File(changed.record.path).writeAsString(_changedContent, flush: true);
    await File(changed.record.path).setLastModified(changed.record.modifiedAt);
    final state = await inspector.inspect(changed.record.path);
    expect(state.size, changed.record.size);
    expect(state.mtimeNs, changed.record.mtimeNs);
    await _runUntilIdle(app, app.importPlan);
    expect(app.error, isNull);
    expect(app.folderGroups, isEmpty);
    expect(app.plan!.errors, hasLength(1));
    expect(app.plan!.errors.single['error'], contains('内容已变化'));
    expect(app.selectedFolders, isEmpty);
    expect(app.logPath, isNull);
    expect(await File(changed.record.path).readAsString(), _changedContent);
    await _expectCompleteTree(roots.first);
  });

  testWidgets('导入目录计划时存在未列出的新增文件，整个目录组拒绝执行', (tester) async {
    await _showHost(tester, '验证目录完整集合复核');
    final roots = await _createCopies(fixture);
    for (final root in roots) {
      app.addDirectory(root.path);
    }
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    app.setResultMode(ResultMode.folders);
    app.selectAll(true);
    final json = app.selectionPlan().toJson();
    final group =
        (json['folder_groups'] as List).single as Map<String, dynamic>;
    final candidate = (group['delete'] as List).single as Map<String, dynamic>;
    final extra = File(p.join(roots.last.path, '空目录', '新增但未列入.txt'));
    await extra.writeAsString('必须保留的额外内容', flush: true);

    // 将目录时间更新为当前快照，保证本用例真正验证完整枚举，而非仅凭目录时间拒绝。
    // 内容指纹不包含时间和身份，因此这个计划仍可通过模型格式验证。
    candidate['directory'] = (await inspector.inspect(roots.last.path))
        .toJson();
    for (final item in candidate['directories'] as List) {
      final directory = item as Map<String, dynamic>;
      final record = directory['record'] as Map<String, dynamic>;
      directory['record'] = (await inspector.inspect(record['path'] as String))
          .toJson();
    }
    expect(ScanPlan.fromJson(json).folderGroups, hasLength(1));
    bridge.openPath = p.join(fixture.path, 'import-with-extra.json');
    await File(bridge.openPath!).writeAsString(jsonEncode(json), flush: true);
    await _runUntilIdle(app, app.importPlan);
    expect(app.error, isNull);
    expect(app.plan!.groups, isEmpty);
    expect(app.folderGroups, isEmpty);
    expect(app.plan!.errors, hasLength(1));
    expect(app.plan!.errors.single['error'], contains('清单已变化'));
    expect(app.selectedFolders, isEmpty);
    expect(app.logPath, isNull);
    expect(await extra.readAsString(), '必须保留的额外内容');
    await _expectCompleteTree(roots.first);
  });
}

const _content = 'MULTI-ROOT-CONTENT-0001';
const _changedContent = 'MULTI-ROOT-CONTENT-0002';
const _secondContent = 'SECOND-FILE-CONTENT';

/// 各副本具有同名、同内容、同结构，但都是独立物理文件，且包含空文件和空目录。
Future<List<Directory>> _createCopies(
  Directory fixture, {
  int count = 2,
  String prefix = 'copy',
  String contentSuffix = '',
}) async {
  final roots = <Directory>[];
  for (var index = 0; index < count; index++) {
    final root = await Directory(p.join(fixture.path, '$prefix-$index'))
        .create();
    roots.add(root);
    await Directory(p.join(root.path, '资料')).create();
    await Directory(p.join(root.path, '空目录')).create();
    final content = File(p.join(root.path, '资料', '正文.txt'));
    final second = File(p.join(root.path, '附加.txt'));
    await content.writeAsString('$_content$contentSuffix', flush: true);
    await second.writeAsString('$_secondContent$contentSuffix', flush: true);
    await File(p.join(root.path, '占位.empty')).writeAsBytes([], flush: true);
    // 使用整秒修改时间，避免 Dart DateTime 的微秒精度影响同时间内容篡改测试。
    await content.setLastModified(DateTime.utc(2020 + index, 1, 1));
    await second.setLastModified(DateTime.utc(2020 + index, 1, 1));
  }
  return roots;
}

Future<void> _expectCompleteTree(
  Directory root, {
  String contentSuffix = '',
}) async {
  expect(
    await File(p.join(root.path, '资料', '正文.txt')).readAsString(),
    '$_content$contentSuffix',
  );
  expect(
    await File(p.join(root.path, '附加.txt')).readAsString(),
    '$_secondContent$contentSuffix',
  );
  expect(await File(p.join(root.path, '占位.empty')).length(), 0);
  expect(await Directory(p.join(root.path, '空目录')).exists(), isTrue);
}

Future<ScanPlan> _readPlan(String path) async => ScanPlan.fromJson(
  Map<String, dynamic>.from(jsonDecode(await File(path).readAsString()) as Map),
);

Future<List<Map<String, dynamic>>> _readLog(String path) async =>
    (await File(path).readAsLines())
        .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
        .toList();

/// 监听真实状态变化，等待后台 isolate 结束；不以固定延时推测扫描是否完成。
Future<void> _runUntilIdle(
  AppController app,
  Future<void> Function() start, {
  bool alreadyStarted = false,
}) async {
  final done = Completer<void>();
  var sawBusy = alreadyStarted || app.busy;
  void observe() {
    if (app.busy) sawBusy = true;
    if (sawBusy && !app.busy && !done.isCompleted) done.complete();
  }

  app.addListener(observe);
  try {
    await start();
    observe();
    if (!sawBusy) {
      throw StateError(
        '任务未进入执行状态：${app.error ?? app.notice ?? app.phase.name}',
      );
    }
    await done.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () => throw TimeoutException(
        '多目录工作流未结束：phase=${app.phase.name}, stage=${app.stage}, error=${app.error}',
      ),
    );
  } finally {
    app.removeListener(observe);
  }
}

Future<void> _showHost(WidgetTester tester, String label) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: Text(label))),
    ),
  );
  await tester.pump();
}

/// 仅替换交互式文件选择器；后台扫描、元数据读取和清理均经过真实平台通道。
class _FixtureBridge extends WindowsBridge {
  String? openPath;
  String? savePath;
  @override
  Future<String?> chooseJsonFile({required bool save}) async =>
      save ? savePath : openPath;
}
