import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/core/scanner.dart';
import 'package:dupe_file_cleaner/platform/windows_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// 真实 Windows 集成验证。
///
/// 本文件只操作本次测试在工程 test_artifacts/native-* 下生成的文件。
/// 永久删除、内容修改和回收站操作均使用这些专用样本，不接受外部文件路径输入。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final bridge = WindowsBridge();
  late Directory workspace;
  late Directory fixtureParent;
  late Directory fixture;

  setUpAll(() async {
    if (!Platform.isWindows) {
      throw StateError('本集成测试必须通过 flutter test -d windows 在 Windows 上执行。');
    }
    workspace = Directory(p.normalize(p.absolute(Directory.current.path)));
    final pubspec = File(p.join(workspace.path, 'pubspec.yaml'));
    if (!await pubspec.exists() ||
        !(await pubspec.readAsString()).contains('name: dupe_file_cleaner')) {
      throw StateError('当前目录不是 DupeFileCleaner 工程，拒绝创建或清理测试文件。');
    }
    fixtureParent = Directory(p.join(workspace.path, 'test_artifacts'));
    await fixtureParent.create(recursive: true);
    // 如果预先存在的 test_artifacts 被改成链接，就停止测试，不能写入未知实际位置。
    final parentInfo = await bridge.inspect(fixtureParent.path);
    if (parentInfo.isReparsePoint ||
        canonicalWindowsPath(parentInfo.finalPath) !=
            canonicalWindowsPath(fixtureParent.path)) {
      throw StateError('测试目录是链接或实际路径发生变化，拒绝继续。');
    }
  });

  setUp(() async {
    // createTemp 由系统追加唯一后缀，防止连续运行共享或覆盖上次测试的样本。
    fixture = await fixtureParent.createTemp('native-');
    await bridge.resetCancellation();
  });

  tearDown(() async {
    await bridge.resetCancellation();
    final parent = p.normalize(p.absolute(fixtureParent.path));
    final target = p.normalize(p.absolute(fixture.path));
    if (p.dirname(target) != parent ||
        !p.basename(target).startsWith('native-') ||
        !p.isWithin(workspace.path, target)) {
      throw StateError('测试目录范围校验失败，拒绝递归清理：$target');
    }
    if (await fixture.exists()) {
      final info = await bridge.inspect(target);
      if (info.isReparsePoint ||
          canonicalWindowsPath(info.finalPath) !=
              canonicalWindowsPath(target)) {
        throw StateError('测试目录被替换为链接，拒绝递归清理：$target');
      }
      await fixture.delete(recursive: true);
    }
  });

  testWidgets('原生 inspect 返回中文路径、精确时间和稳定文件身份', (tester) async {
    await _showTestHost(tester, '检查 Windows 文件身份');
    final file = File(p.join(fixture.path, '中文 样本.txt'));
    await file.writeAsString('Windows 文件身份与时间测试', flush: true);
    await file.setLastModified(DateTime.utc(2024, 1, 2, 3, 4, 5, 123, 456));

    final first = await bridge.inspect(file.path);
    final second = await bridge.inspect(file.path);
    final directory = await bridge.inspect(fixture.path);
    final stat = await file.stat();

    expect(canonicalWindowsPath(first.path), canonicalWindowsPath(file.path));
    expect(first.finalPath, isNotEmpty);
    expect(first.size, await file.length());
    expect(first.hasIdentity, isTrue);
    expect(first.fileId, second.fileId);
    expect(first.volumeId, second.volumeId);
    expect(first.sameSnapshot(second), isTrue);
    expect(first.linkCount, 1);
    expect(first.isDirectory, isFalse);
    expect(first.isReparsePoint, isFalse);
    expect(directory.isDirectory, isTrue);
    // NTFS 文件时间的单位是 100 ns；常规 Dart stat 可能只提供较粗的显示精度。
    expect(first.mtimeNs % 100, 0);
    expect(
      (first.mtimeNs - stat.modified.microsecondsSinceEpoch * 1000).abs(),
      lessThan(Duration.microsecondsPerSecond * 1000),
    );
    expect(first.toJson()['mtime_ns'], first.mtimeNs.toString());
    expect(FileRecord.fromJson(first.toJson()).mtimeNs, first.mtimeNs);
  });

  testWidgets('真实 Windows 扫描按内容分组并保留最后修改时间最早的一份', (tester) async {
    await _showTestHost(tester, '检查实际文件扫描');
    final pair = await _makePair(fixture, bridge);
    await File(p.join(fixture.path, '不同内容.txt')).writeAsString('独有文件');
    final nested = await Directory(p.join(fixture.path, '子目录')).create();
    final third = File(p.join(nested.path, '第三份.bin'));
    await third.writeAsString(_sampleContent);
    await third.setLastModified(DateTime.utc(2025, 1, 1));

    final plan = await DuplicateScanner(inspector: bridge)
        .scan(fixture.path, const ScanOptions());

    expect(plan.groups, hasLength(1));
    expect(plan.groups.single.keep.path, pair.keeper.path);
    expect(plan.groups.single.candidates, hasLength(2));
    expect(
      plan.groups.single.sha256,
      sha256.convert(utf8.encode(_sampleContent)).toString(),
    );
    expect(plan.scannedFiles, 4);
    expect(plan.errors, isEmpty);
    expect(plan.needsIdentityRefresh, isFalse);
    expect(ScanPlan.fromJson(plan.toJson()).deleteCount, 2);
  });

  testWidgets('永久删除只清理经过复核的副本，保留文件内容不变', (tester) async {
    await _showTestHost(tester, '验证永久删除副本');
    final pair = await _makePair(fixture, bridge);

    final result = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.candidates.single,
      permanent: true,
    );

    expect(result['status'], 'deleted', reason: result.toString());
    expect(await pair.candidate.exists(), isFalse);
    expect(await pair.keeper.exists(), isTrue);
    expect(await pair.keeper.readAsString(), _sampleContent);
  });

  testWidgets('保留文件内容变化时跳过，即使大小与修改时间恢复为原值', (tester) async {
    await _showTestHost(tester, '验证保留文件内容保护');
    final pair = await _makePair(fixture, bridge);
    await pair.keeper.writeAsString(_changedContent, flush: true);
    await pair.keeper.setLastModified(pair.group.keep.modifiedAt);
    final changedSnapshot = await bridge.inspect(pair.keeper.path);
    expect(changedSnapshot.size, pair.group.keep.size);
    expect(changedSnapshot.mtimeNs, pair.group.keep.mtimeNs);

    final result = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.candidates.single,
      permanent: true,
    );

    expect(result['status'], 'skipped', reason: result.toString());
    expect(result['reason'], contains('SHA-256'));
    expect(await pair.keeper.readAsString(), _changedContent);
    expect(await pair.candidate.readAsString(), _sampleContent);
  });

  testWidgets('候选内容变化时跳过，即使大小与修改时间恢复为原值', (tester) async {
    await _showTestHost(tester, '验证候选文件内容保护');
    final pair = await _makePair(fixture, bridge);
    await pair.candidate.writeAsString(_changedContent, flush: true);
    await pair.candidate.setLastModified(
      pair.group.candidates.single.modifiedAt,
    );
    final changedSnapshot = await bridge.inspect(pair.candidate.path);
    expect(changedSnapshot.size, pair.group.candidates.single.size);
    expect(changedSnapshot.mtimeNs, pair.group.candidates.single.mtimeNs);

    final result = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.candidates.single,
      permanent: true,
    );

    expect(result['status'], 'skipped', reason: result.toString());
    expect(await pair.keeper.readAsString(), _sampleContent);
    expect(result['reason'], contains('SHA-256'));
    expect(await pair.candidate.readAsString(), _changedContent);
  });

  testWidgets('原生层拒绝把保留文件作为清理目标', (tester) async {
    await _showTestHost(tester, '验证同路径保护');
    final pair = await _makePair(fixture, bridge);

    // 刻意绕过 Dart 计划导入验证，直接验证原生接口自身仍然有保护。
    final result = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.keep,
      permanent: true,
    );

    expect(result['status'], 'skipped', reason: result.toString());
    expect(await pair.keeper.readAsString(), _sampleContent);
    expect(await pair.candidate.exists(), isTrue);
  });

  testWidgets('候选路径被替换为同大小同时间的新文件时按身份拒绝清理', (tester) async {
    await _showTestHost(tester, '验证文件身份替换保护');
    final pair = await _makePair(fixture, bridge);
    final plannedCandidate = pair.group.candidates.single;
    // 将旧文件移到同一测试目录并保留，避免文件系统立即复用旧文件 ID。
    final savedOriginal = await pair.candidate.rename(
      p.join(fixture.path, 'original-candidate-saved.txt'),
    );
    await pair.candidate.writeAsString(_sampleContent, flush: true);
    await pair.candidate.setLastModified(plannedCandidate.modifiedAt);
    final replacement = await bridge.inspect(pair.candidate.path);
    expect(replacement.size, plannedCandidate.size);
    expect(replacement.mtimeNs, plannedCandidate.mtimeNs);
    expect(replacement.fileId, isNot(plannedCandidate.fileId));

    final result = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: plannedCandidate,
      permanent: true,
    );

    expect(result['status'], 'skipped', reason: result.toString());
    expect(result['reason'], contains('身份'));
    expect(await pair.keeper.readAsString(), _sampleContent);
    expect(await pair.candidate.readAsString(), _sampleContent);
    expect(await savedOriginal.readAsString(), _sampleContent);
  });

  testWidgets('祖先目录被替换为 junction 后禁止逃逸清理，并在扫描中跳过连接点', (tester) async {
    await _showTestHost(tester, '验证目录连接点保护');
    final inside = await Directory(p.join(fixture.path, 'scan-root')).create();
    final child = await Directory(p.join(inside.path, 'child')).create();
    final outside = await Directory(p.join(fixture.path, 'outside-target'))
        .create();
    final pair = await _makePair(inside, bridge);
    final nestedCandidate = await pair.candidate.rename(
      p.join(child.path, 'candidate.txt'),
    );
    final originalRecord = await bridge.inspect(nestedCandidate.path);
    final group = DuplicateGroup(
      id: 1,
      size: pair.group.size,
      sha256: pair.group.sha256,
      keep: pair.group.keep,
      candidates: [originalRecord],
    );
    final plan = ScanPlan(
      root: inside.path,
      options: const ScanOptions(),
      groups: [group],
      generatedAt: DateTime.now(),
    );

    // 原目录与逃逸目标都保留在本次 fixture 内，不指向真实用户目录。
    final savedDirectory = await child.rename(
      p.join(fixture.path, 'saved-original-child'),
    );
    final escapedCandidate = File(p.join(outside.path, 'candidate.txt'));
    await escapedCandidate.writeAsString(_sampleContent, flush: true);
    await escapedCandidate.setLastModified(originalRecord.modifiedAt);
    final linkPath = child.path;
    _requireFixtureChild(linkPath, fixture.path);
    _requireFixtureChild(outside.path, fixture.path);

    try {
      // 用环境变量传路径，避免将路径拼接进 PowerShell 代码；New-Item 只创建测试连接点。
      final creation = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'New-Item -ItemType Junction -Path $env:DUPE_TEST_JUNCTION_LINK '
              r'-Target $env:DUPE_TEST_JUNCTION_TARGET -ErrorAction Stop | Out-Null',
        ],
        workingDirectory: fixture.path,
        environment: {
          'DUPE_TEST_JUNCTION_LINK': linkPath,
          'DUPE_TEST_JUNCTION_TARGET': outside.path,
        },
      );
      expect(creation.exitCode, 0, reason: creation.stderr.toString());
      expect((await bridge.inspect(linkPath)).isReparsePoint, isTrue);

      final result = await bridge.cleanFile(
        plan: plan,
        group: group,
        candidate: originalRecord,
        permanent: true,
      );
      expect(result['status'], 'skipped', reason: result.toString());
      expect(result['reason'], contains('重解析点'));
      expect(await escapedCandidate.readAsString(), _sampleContent);
      expect(await pair.keeper.readAsString(), _sampleContent);
      expect(
        await File(p.join(savedDirectory.path, 'candidate.txt')).readAsString(),
        _sampleContent,
      );

      final scanned = await DuplicateScanner(inspector: bridge)
          .scan(inside.path, const ScanOptions());
      expect(scanned.groups, isEmpty);
      expect(
        scanned.skipped.any(
          (item) =>
              canonicalWindowsPath(item['path']!) ==
              canonicalWindowsPath(linkPath),
        ),
        isTrue,
      );
    } finally {
      // 只移除连接点本身，禁止递归删除链接路径；再次验证目标文件仍然存在。
      if (await FileSystemEntity.type(linkPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _requireFixtureChild(linkPath, fixture.path);
        final info = await bridge.inspect(linkPath);
        if (!info.isReparsePoint) {
          throw StateError('测试连接点已被替换为普通目录，拒绝删除：$linkPath');
        }
        await Directory(linkPath).delete(recursive: false);
      }
      expect(await escapedCandidate.exists(), isTrue);
    }
  });

  testWidgets('原生层拒绝计划根目录外的候选文件', (tester) async {
    await _showTestHost(tester, '验证根目录范围保护');
    final inside = await Directory(p.join(fixture.path, 'scan-root')).create();
    final pair = await _makePair(inside, bridge);
    // “根目录外”仍严格限制在本次 fixture 内，不使用任何真实用户目录。
    final outside = File(p.join(fixture.path, 'outside.txt'));
    await outside.writeAsString(_sampleContent, flush: true);
    final outsideRecord = await bridge.inspect(outside.path);

    // 多目录桥接层已提前拒绝越界；仍直接调用原生通道验证第二道范围保护。
    await expectLater(
      bridge.cleanFile(
        plan: pair.plan,
        group: pair.group,
        candidate: outsideRecord,
        permanent: true,
      ),
      throwsStateError,
    );
    final result = (await WindowsBridge.channel
        .invokeMapMethod<String, dynamic>('cleanFile', {
          'root': pair.plan.root,
          'keepRoot': pair.plan.root,
          'keep': pair.group.keep.toJson(),
          'candidate': outsideRecord.toJson(),
          'sha256': pair.group.sha256,
          'mode': 'permanent',
          'allowHardlinks': false,
        }))!;

    expect(result['status'], 'skipped', reason: result.toString());
    expect(await outside.readAsString(), _sampleContent);
    expect(await pair.keeper.exists(), isTrue);
    expect(await pair.candidate.exists(), isTrue);
  });

  testWidgets('cancelNative 中止尚未执行的清理，重置后可正常继续', (tester) async {
    await _showTestHost(tester, '验证原生取消');
    final pair = await _makePair(fixture, bridge);
    await bridge.cancelNative();

    final cancelled = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.candidates.single,
      permanent: true,
    );

    expect(cancelled['status'], 'cancelled', reason: cancelled.toString());
    expect(await pair.keeper.exists(), isTrue);
    expect(await pair.candidate.exists(), isTrue);
    await bridge.resetCancellation();
    final resumed = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.candidates.single,
      permanent: true,
    );
    expect(resumed['status'], 'deleted', reason: resumed.toString());
    expect(await pair.keeper.readAsString(), _sampleContent);
  });

  testWidgets('回收站操作明确报告结果，不支持回收时不得降级永久删除', (tester) async {
    await _showTestHost(tester, '验证 Windows 回收站');
    final pair = await _makePair(fixture, bridge);

    final result = await bridge.cleanFile(
      plan: pair.plan,
      group: pair.group,
      candidate: pair.group.candidates.single,
      permanent: false,
    );

    final status = result['status'];
    expect(
      status,
      anyOf('recycled', 'skipped', 'error'),
      reason: result.toString(),
    );
    expect(await pair.keeper.readAsString(), _sampleContent);
    if (status == 'recycled') {
      expect(await pair.candidate.exists(), isFalse);
    } else {
      expect(
        await pair.candidate.exists(),
        isTrue,
        reason: '无法确认回收成功时，测试候选必须仍然存在；不能静默改为永久删除。$result',
      );
      expect(result['reason'], isNotEmpty);
    }
    // 输出真实结果供构建记录核对；回收的测试样本留在系统回收站，不主动清空回收站。
    debugPrint('NATIVE_RECYCLE_RESULT ${jsonEncode(result)}');
  });
}

/// 内容长度完全相同，用来确保变化测试能够触发完整 SHA-256 复核。
const _sampleContent = 'DUPLICATE-CONTENT-0001';
const _changedContent = 'DUPLICATE-CONTENT-0002';

/// 创建两个真实副本及由真实原生快照组成的计划。
///
/// 固定整秒修改时间便于内容变更测试恢复时间戳，从而验证哈希校验确实参与了决策。
Future<_FilePair> _makePair(Directory directory, WindowsBridge bridge) async {
  final keeper = File(p.join(directory.path, 'keep-保留.txt'));
  final candidate = File(p.join(directory.path, 'duplicate-副本.txt'));
  await keeper.writeAsString(_sampleContent, flush: true);
  await candidate.writeAsString(_sampleContent, flush: true);
  await keeper.setLastModified(DateTime.utc(2020, 1, 1));
  await candidate.setLastModified(DateTime.utc(2024, 1, 1));
  final keepRecord = await bridge.inspect(keeper.path);
  final candidateRecord = await bridge.inspect(candidate.path);
  final group = DuplicateGroup(
    id: 1,
    size: keepRecord.size,
    sha256: sha256.convert(utf8.encode(_sampleContent)).toString(),
    keep: keepRecord,
    candidates: [candidateRecord],
  );
  final plan = ScanPlan(
    root: directory.path,
    options: const ScanOptions(),
    groups: [group],
    scannedFiles: 2,
    scannedBytes: keepRecord.size * 2,
    visitedEntries: 2,
    generatedAt: DateTime.now(),
  );
  return _FilePair(
    keeper: keeper,
    candidate: candidate,
    plan: plan,
    group: group,
  );
}

/// 保持最小 Flutter 界面，让集成测试运行于真实 Windows runner 和插件通道。
Future<void> _showTestHost(WidgetTester tester, String label) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: Text(label))),
    ),
  );
  await tester.pump();
}

class _FilePair {
  const _FilePair({
    required this.keeper,
    required this.candidate,
    required this.plan,
    required this.group,
  });

  final File keeper;
  final File candidate;
  final ScanPlan plan;
  final DuplicateGroup group;
}

/// 所有连接点创建或移除前都验证绝对路径严格位于本次随机 fixture 内。
void _requireFixtureChild(String path, String fixturePath) {
  final root = p.normalize(p.absolute(fixturePath));
  final candidate = p.normalize(p.absolute(path));
  if (!p.isWithin(root, candidate)) {
    throw StateError('拒绝在本次测试目录外操作连接点：$candidate');
  }
}
