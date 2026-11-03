import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dupe_file_cleaner/application/app_controller.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/platform/windows_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// 验证实际控制器、后台 isolate、Windows 平台通道与持久化日志组成的完整流程。
///
/// 所有文件都由本测试在工程 test_artifacts/wf-* 中创建；历史日志目录也显式
/// 注入到该目录内。文件选择器由专用桥接子类替代，绝不打开真实用户文件对话框。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final inspector = WindowsBridge();
  late Directory workspace;
  late Directory parent;
  late Directory fixture;
  late Directory scanRoot;
  late _FixtureBridge bridge;
  late AppController app;

  setUpAll(() async {
    if (!Platform.isWindows) {
      throw StateError('工作流集成测试必须在真实 Windows runner 中运行。');
    }
    workspace = Directory(p.normalize(p.absolute(Directory.current.path)));
    final pubspec = File(p.join(workspace.path, 'pubspec.yaml'));
    if (!await pubspec.exists() ||
        !(await pubspec.readAsString()).contains('name: dupe_file_cleaner')) {
      throw StateError('当前目录不是 DupeFileCleaner 工程，拒绝操作测试样本。');
    }
    parent = Directory(p.join(workspace.path, 'test_artifacts'));
    await parent.create(recursive: true);
    final info = await inspector.inspect(parent.path);
    if (info.isReparsePoint ||
        canonicalWindowsPath(info.finalPath) !=
            canonicalWindowsPath(parent.path)) {
      throw StateError('测试父目录存在重解析或路径重定向，拒绝继续。');
    }
  });

  setUp(() async {
    fixture = await parent.createTemp('wf-');
    scanRoot = await Directory(p.join(fixture.path, 'scan')).create();
    bridge = _FixtureBridge();
    app = AppController(
      bridge: bridge,
      historyDirectory: p.join(fixture.path, 'history'),
    );
    await inspector.resetCancellation();
  });

  tearDown(() async {
    // 测试断言提前失败时也先协作取消，避免移除仍由后台 isolate 读取的文件。
    if (app.busy) {
      await _runUntilIdle(app, app.cancel, alreadyStarted: true);
    }
    app.dispose();
    await inspector.resetCancellation();
    await inspector.setBusy(false);

    final target = p.normalize(p.absolute(fixture.path));
    if (p.dirname(target) != p.normalize(p.absolute(parent.path)) ||
        !p.basename(target).startsWith('wf-') ||
        !p.isWithin(workspace.path, target)) {
      throw StateError('测试目录范围校验失败，拒绝递归清理：$target');
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

  testWidgets('后台扫描、人工保留选择、实际清理和逐项日志形成完整闭环', (tester) async {
    await _showHost(tester, '验证扫描、人工选择与执行日志');
    final samples = await _writeSamples(scanRoot);
    app.setDirectory(scanRoot.path);
    await _runUntilIdle(app, app.startScan);

    expect(app.error, isNull);
    expect(app.phase, TaskPhase.ready);
    expect(app.plan!.groups, hasLength(1));
    final group = app.plan!.groups.single;
    expect(group.keep.path, samples.oldest.path);
    expect(app.selectedCount, 2);
    expect(app.plan!.needsIdentityRefresh, isFalse);

    // 改为保留最新副本，并把中间副本从本次清理中取消勾选。
    // 最终只允许删除本测试生成的旧副本，另两份内容都必须保留。
    final newest = group.files.singleWhere(
      (f) => f.path == samples.newest.path,
    );
    final middle = group.files.singleWhere(
      (f) => f.path == samples.middle.path,
    );
    app.chooseKeeper(group, newest);
    app.toggleFile(group, middle, false);
    expect(app.keeper(group).path, samples.newest.path);
    expect(app.selected, {AppController.key(samples.oldest.path)});
    final frozen = app.selectionPlan();
    expect(frozen.groups.single.keep.path, samples.newest.path);
    expect(frozen.groups.single.candidates.single.path, samples.oldest.path);

    await app.clean(permanent: true).timeout(const Duration(seconds: 45));
    expect(app.busy, isFalse);
    expect(app.error, isNull);
    expect(app.successCount, 1);
    expect(app.results.single['status'], 'deleted');
    expect(app.completed, {AppController.key(samples.oldest.path)});
    expect(app.selected, isEmpty);
    expect(await samples.oldest.exists(), isFalse);
    expect(await samples.middle.readAsString(), _content);
    expect(await samples.newest.readAsString(), _content);

    final log = File(app.logPath!);
    expect(p.isWithin(p.join(fixture.path, 'history'), log.path), isTrue);
    final entries = (await log.readAsLines())
        .map((line) => Map<String, dynamic>.from(jsonDecode(line) as Map))
        .toList();
    expect(entries.map((e) => e['type']).toList(), [
      'begin',
      'intent',
      'result',
      'finish',
    ]);
    expect(
      entries.every((e) => DateTime.tryParse(e['at'] as String) != null),
      isTrue,
    );
    expect(entries[0]['mode'], 'permanent');
    expect(entries[0]['root'], scanRoot.path);
    expect(entries[1]['path'], samples.oldest.path);
    expect(entries[1]['keep'], samples.newest.path);
    expect(entries[2]['path'], samples.oldest.path);
    expect(entries[2]['status'], 'deleted');
    expect(entries[2]['size'], await samples.newest.length());
    expect(entries[3]['cancelled'], isFalse);
    expect(entries[3]['processed'], 1);
    expect(entries[3]['succeeded'], 1);

    final savedPlanFile = File(entries[0]['plan'] as String);
    expect(
      p.isWithin(p.join(fixture.path, 'history'), savedPlanFile.path),
      isTrue,
    );
    final savedPlan = ScanPlan.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(await savedPlanFile.readAsString()) as Map,
      ),
    );
    expect(savedPlan.groups.single.keep.path, samples.newest.path);
    expect(savedPlan.groups.single.candidates.single.path, samples.oldest.path);

    // 完成项不能通过全选、切换 keeper 或后续导出重新进入执行集合。
    final oldRecord = group.keep;
    app.chooseKeeper(group, oldRecord);
    expect(app.keeper(group).path, samples.newest.path);
    app.selectAll(true);
    expect(app.selected, {AppController.key(samples.middle.path)});
    bridge.savePath = p.join(fixture.path, 'remaining-plan.json');
    await app.exportPlan();
    expect(app.error, isNull);
    final remaining = ScanPlan.fromJson(
      Map<String, dynamic>.from(
        jsonDecode(await File(bridge.savePath!).readAsString()) as Map,
      ),
    );
    expect(remaining.deleteCount, 1);
    expect(remaining.groups.single.keep.path, samples.newest.path);
    expect(remaining.groups.single.candidates.single.path, samples.middle.path);
    debugPrint(
      'WORKFLOW_JOURNAL_OK ${entries.length} records; one verified deletion',
    );
  });

  testWidgets('旧版 v1 计划通过后台复核补齐身份，并拒绝内容已变的同大小文件', (tester) async {
    await _showHost(tester, '验证旧版计划导入');
    final samples = await _writeSamples(scanRoot);
    app.setDirectory(scanRoot.path);
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    final scanned = app.plan!;

    // 用原生扫描结果构造版本 1 的字段形式：整数纳秒、device/inode，
    // 不提供本程序专用的 volume_id/file_id/final_path，确保走身份补齐路径。
    final legacy = scanned.toJson();
    legacy['plan_version'] = 1;
    for (final rawGroup in legacy['groups'] as List) {
      final group = rawGroup as Map<String, dynamic>;
      for (final rawRecord in [group['keep'], ...group['delete'] as List]) {
        final record = rawRecord as Map<String, dynamic>;
        record['mtime_ns'] = int.parse(record['mtime_ns'] as String);
        record['device'] = 0;
        record['inode'] = 0;
        record.remove('volume_id');
        record.remove('file_id');
        record.remove('final_path');
        record.remove('is_directory');
        record.remove('is_reparse_point');
      }
    }
    expect(ScanPlan.fromJson(legacy).needsIdentityRefresh, isTrue);
    bridge.openPath = p.join(fixture.path, 'legacy-v1-plan.json');
    await File(bridge.openPath!).writeAsString(jsonEncode(legacy), flush: true);
    await _runUntilIdle(app, app.importPlan);

    expect(app.error, isNull);
    expect(app.plan!.groups, hasLength(1));
    expect(app.plan!.needsIdentityRefresh, isFalse);
    expect(app.plan!.groups.single.files.every((f) => f.hasIdentity), isTrue);
    expect(app.plan!.groups.single.sha256, scanned.groups.single.sha256);
    expect(app.plan!.groups.single.keep.path, samples.oldest.path);
    // 旧版计划完成真实复核后，统一输出当前多目录版本。
    expect(app.plan!.toJson()['plan_version'], 3);

    // 保持大小与修改时间不变，只改内容。再次导入必须完整哈希并跳过整组，
    // 不能因为元数据匹配就把旧计划当成可执行结果。
    final changedRecord = scanned.groups.single.files.singleWhere(
      (f) => f.path == samples.middle.path,
    );
    await samples.middle.writeAsString(_changedContent, flush: true);
    await samples.middle.setLastModified(changedRecord.modifiedAt);
    expect(await samples.middle.length(), changedRecord.size);
    final changedState = await inspector.inspect(samples.middle.path);
    expect(changedState.mtimeNs, changedRecord.mtimeNs);
    await _runUntilIdle(app, app.importPlan);
    expect(app.error, isNull);
    expect(app.plan!.groups, isEmpty);
    expect(app.plan!.errors, hasLength(1));
    expect(app.plan!.errors.single['error'], contains('内容已变化'));
    expect(app.selected, isEmpty);
    expect(app.completed, isEmpty);
    expect(app.logPath, isNull);
    expect(await samples.oldest.readAsString(), _content);
    expect(await samples.middle.readAsString(), _changedContent);
    expect(await samples.newest.readAsString(), _content);
  });

  testWidgets('改变目录或扫描选项立即使旧计划和人工选择失效', (tester) async {
    await _showHost(tester, '验证扫描配置与清理范围一致');
    final samples = await _writeSamples(scanRoot);
    app.setDirectory(scanRoot.path);
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    final group = app.plan!.groups.single;
    app.chooseKeeper(
      group,
      group.files.singleWhere((f) => f.path == samples.newest.path),
    );
    expect(app.keepOverrides, isNotEmpty);

    final another = await Directory(p.join(fixture.path, 'another-root'))
        .create();
    app.setDirectory(another.path);
    _expectNoExecutablePlan(app);
    expect(app.root, another.path);

    app.setDirectory(scanRoot.path);
    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    expect(app.plan, isNotNull);
    app.setScanOptions(includeEmpty: true);
    _expectNoExecutablePlan(app);
    expect(app.includeEmpty, isTrue);

    await _runUntilIdle(app, app.startScan);
    expect(app.error, isNull);
    expect(app.plan, isNotNull);
    app.setScanOptions(includeHardlinks: true);
    _expectNoExecutablePlan(app);
    expect(app.includeHardlinks, isTrue);

    // 失效后即使调用清理入口，也不得生成日志或触碰原来的文件。
    await app.clean(permanent: true);
    expect(app.logPath, isNull);
    expect(await samples.oldest.readAsString(), _content);
    expect(await samples.middle.readAsString(), _content);
    expect(await samples.newest.readAsString(), _content);
  });

  testWidgets('在后台扫描启动时立即取消，不发布可执行计划也不修改任何样本', (tester) async {
    await _showHost(tester, '验证后台任务协作取消');
    // 使用较大、相同内容的样本覆盖耗时扫描入口，但取消时序不依赖机器磁盘速度。
    // startScan 的同步部分先进入 busy；随即 cancel，早于等待 spawn 返回。
    final block = Uint8List(2 * 1024 * 1024);
    for (var i = 0; i < block.length; i++) {
      block[i] = i % 251;
    }
    final files = [
      File(p.join(scanRoot.path, 'large-a.bin')),
      File(p.join(scanRoot.path, 'large-b.bin')),
    ];
    for (final file in files) {
      final handle = await file.open(mode: FileMode.write);
      try {
        for (var i = 0; i < 4; i++) {
          await handle.writeFrom(block);
        }
        await handle.flush();
      } finally {
        await handle.close();
      }
    }
    app.setDirectory(scanRoot.path);
    await _runUntilIdle(app, () async {
      final started = app.startScan();
      expect(app.busy, isTrue);
      await app.cancel();
      await started;
    });
    expect(app.error, isNull);
    _expectNoExecutablePlan(app);
    expect(app.notice, contains('取消'));
    for (final file in files) {
      expect(await file.exists(), isTrue);
      expect(await file.length(), 8 * 1024 * 1024);
    }
    expect(await Directory(p.join(fixture.path, 'history')).exists(), isFalse);
  });
}

const _content = 'WORKFLOW-SAMPLE-CONTENT-01';
const _changedContent = 'WORKFLOW-SAMPLE-CONTENT-02';

/// 三个独立物理文件使用固定整秒时间，便于精确验证保留规则与内容变更复核。
Future<_Samples> _writeSamples(Directory root) async {
  final files = [
    File(p.join(root.path, 'oldest-原始.txt')),
    File(p.join(root.path, 'middle-副本.txt')),
    File(p.join(root.path, 'newest-副本.txt')),
  ];
  for (var i = 0; i < files.length; i++) {
    await files[i].writeAsString(_content, flush: true);
    await files[i].setLastModified(DateTime.utc(2020 + i * 2, 1, 1));
  }
  return _Samples(files[0], files[1], files[2]);
}

/// 先监听再启动，等待控制器真正结束任务，而不是只等待 Isolate.spawn 返回。
/// 超时保留清晰的阶段信息；不使用固定延时推测任务何时完成。
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
        '工作流没有结束：phase=${app.phase.name}, stage=${app.stage}, error=${app.error}',
      ),
    );
  } finally {
    app.removeListener(observe);
  }
}

void _expectNoExecutablePlan(AppController app) {
  expect(app.busy, isFalse);
  expect(app.phase, TaskPhase.idle);
  expect(app.plan, isNull);
  expect(app.selected, isEmpty);
  expect(app.completed, isEmpty);
  expect(app.keepOverrides, isEmpty);
  expect(app.results, isEmpty);
  expect(app.logPath, isNull);
}

Future<void> _showHost(WidgetTester tester, String label) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: Text(label))),
    ),
  );
  await tester.pump();
}

/// 只替换交互式选择器，其余方法仍调用实际 Windows 原生层。
class _FixtureBridge extends WindowsBridge {
  String? openPath;
  String? savePath;

  @override
  Future<String?> chooseJsonFile({required bool save}) async =>
      save ? savePath : openPath;
}

class _Samples {
  const _Samples(this.oldest, this.middle, this.newest);
  final File oldest;
  final File middle;
  final File newest;
}
