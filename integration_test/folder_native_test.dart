import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/platform/windows_bridge.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

/// 整目录与多根目录的真实 Windows 验证。
/// 所有修改、回收及删除仅作用于本次在工程 test_artifacts/folder-* 生成的样本。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final native = WindowsBridge();
  late Directory workspace;
  late Directory parent;
  late Directory fixture;

  setUpAll(() async {
    workspace = Directory(p.normalize(p.absolute(Directory.current.path)));
    // 使用公开项目标识确认测试工作目录；所有真实文件操作还必须位于下方的专用样本目录。
    // 检查项目声明而非任意同名文件，防止在错误目录中创建或清理测试数据。
    final manifest = File(p.join(workspace.path, 'pubspec.yaml'));
    if (!Platform.isWindows ||
        !await manifest.exists() ||
        !RegExp(
          r'^name:\s*dupe_file_cleaner\s*$',
          multiLine: true,
        ).hasMatch(await manifest.readAsString())) {
      throw StateError('整目录原生测试必须在本项目 Windows 工作目录运行。');
    }
    parent = await Directory(p.join(workspace.path, 'test_artifacts'))
        .create(recursive: true);
    final info = await native.inspect(parent.path);
    if (info.isReparsePoint ||
        canonicalWindowsPath(info.finalPath) !=
            canonicalWindowsPath(parent.path)) {
      throw StateError('测试父目录发生路径重定向，拒绝操作。');
    }
  });

  setUp(() async {
    fixture = await parent.createTemp('folder-');
    await native.resetCancellation();
  });

  tearDown(() async {
    await native.resetCancellation();
    final target = p.normalize(fixture.absolute.path);
    if (p.dirname(target) != p.normalize(parent.absolute.path) ||
        !p.basename(target).startsWith('folder-') ||
        !p.isWithin(workspace.path, target)) {
      throw StateError('测试清理路径超出本次样本范围。');
    }
    if (await fixture.exists()) {
      final info = await native.inspect(target);
      if (info.isReparsePoint ||
          canonicalWindowsPath(info.finalPath) !=
              canonicalWindowsPath(target)) {
        throw StateError('测试根目录身份或位置已改变，拒绝递归清理。');
      }
      await fixture.delete(recursive: true);
    }
  });

  testWidgets('保留与候选分属两个扫描根时仍正确清理单个副本', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keepPath = p.join(pair.$1.path, '文档.txt');
    final candidatePath = p.join(pair.$2.path, '文档.txt');
    final result = await WindowsBridge.channel.invokeMapMethod<String, dynamic>(
      'cleanFile',
      {
        'keepRoot': pair.$1.path,
        'root': pair.$2.path,
        'keep': (await native.inspect(keepPath)).toJson(),
        'candidate': (await native.inspect(candidatePath)).toJson(),
        'sha256': sha256.convert(await File(keepPath).readAsBytes()).toString(),
        'mode': 'permanent',
        'allowHardlinks': false,
      },
    );
    expect(result!['status'], 'deleted', reason: result.toString());
    expect(await File(keepPath).exists(), isTrue);
    expect(await File(candidatePath).exists(), isFalse);
  });

  testWidgets('完整重复目录永久清理保留另一棵树并移除空子目录', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final before = await _manifest(pair.$1, native);
    final result = await _clean(pair, native);
    expect(result['status'], 'deleted', reason: result.toString());
    expect(result['kind'], 'folder');
    expect(result['file_count'], 3);
    expect(result['completed_files'], 3);
    expect((result['entries'] as List).length, 6);
    expect(await pair.$2.exists(), isFalse);
    final after = await _manifest(pair.$1, native);
    expect(after, before);
  });

  testWidgets('本地固定盘完整重复目录必须成功回收并保持保留树', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final result = await _clean(pair, native, mode: 'recycle');
    // 本地固定盘是受支持的正路径，必须实际回收，不能用允许失败的断言掩盖功能失效。
    debugPrint('FOLDER_RECYCLE_RESULT ${jsonEncode(result)}');
    expect(result['status'], 'recycled', reason: result.toString());
    expect(await pair.$2.exists(), isFalse);
    expect(await File(p.join(pair.$1.path, '文档.txt')).readAsString(), _content);
  });

  testWidgets('回收时文件被写入句柄占用则整项拒绝，不能降级永久删除', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keep = await _manifest(pair.$1, native);
    final candidate = await _manifest(pair.$2, native);
    final occupied = await File(p.join(pair.$2.path, '文档.txt'))
        .open(mode: FileMode.append);
    try {
      final result = await _invoke(pair, keep, candidate, mode: 'recycle');
      expect(result['status'], 'error', reason: result.toString());
      expect(result['entries'], isEmpty);
      expect(await pair.$2.exists(), isTrue);
      expect(await File(p.join(pair.$2.path, '资料', '数据.bin')).length(), 1024);
    } finally {
      await occupied.close();
    }
    expect(await File(p.join(pair.$2.path, '文档.txt')).readAsString(), _content);
    expect(await File(p.join(pair.$1.path, '文档.txt')).readAsString(), _content);
  });

  testWidgets('扫描后新增文件时整目录清理必须在删除任何项目之前拒绝', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keep = await _manifest(pair.$1, native);
    final candidate = await _manifest(pair.$2, native);
    final addition = File(p.join(pair.$2.path, '新增且独有.txt'));
    await addition.writeAsString('不能丢失的新内容');
    final result = await _invoke(pair, keep, candidate);
    expect(result['status'], 'skipped', reason: result.toString());
    expect(result['entries'], isEmpty);
    expect(await addition.readAsString(), '不能丢失的新内容');
    expect(await File(p.join(pair.$2.path, '文档.txt')).exists(), isTrue);
  });

  testWidgets('清单遗漏空文件也不允许整目录清理', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keep = await _manifest(pair.$1, native);
    final candidate = await _manifest(pair.$2, native);
    for (final manifest in [keep, candidate]) {
      (manifest['files'] as List).removeWhere(
        (e) => (e as Map)['relative_path'] == '空文件.txt',
      );
    }
    final result = await _invoke(pair, keep, candidate);
    expect(result['status'], 'skipped', reason: result.toString());
    expect(result['entries'], isEmpty);
    expect(await File(p.join(pair.$2.path, '空文件.txt')).exists(), isTrue);
  });

  for (final changeKeep in [false, true]) {
    testWidgets('${changeKeep ? '保留' : '候选'}目录中文件同大小同时间但内容变化时拒绝整组', (
      tester,
    ) async {
      await _host(tester);
      final pair = await _trees(fixture);
      final keep = await _manifest(pair.$1, native);
      final candidate = await _manifest(pair.$2, native);
      final file = File(
        p.join(changeKeep ? pair.$1.path : pair.$2.path, '文档.txt'),
      );
      final originalTime = await file.lastModified();
      final data = await file.readAsBytes();
      data[0] = data[0] ^ 1;
      await file.writeAsBytes(data, flush: true);
      await file.setLastModified(originalTime);
      final result = await _invoke(pair, keep, candidate);
      expect(result['status'], 'skipped', reason: result.toString());
      expect(result['reason'], contains('SHA-256'));
      expect(result['entries'], isEmpty);
      expect(await pair.$1.exists(), isTrue);
      expect(await pair.$2.exists(), isTrue);
    });
  }

  testWidgets('篡改目录清单的相对上级跳转被拒绝', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keep = await _manifest(pair.$1, native);
    final candidate = await _manifest(pair.$2, native);
    (candidate['files'] as List).first['relative_path'] = '../越界.txt';
    final result = await _invoke(pair, keep, candidate);
    expect(result['status'], 'skipped', reason: result.toString());
    expect(await pair.$2.exists(), isTrue);
  });

  testWidgets('同一目录以及超出扫描根的目录均不能清理', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keep = await _manifest(pair.$1, native);
    final candidate = await _manifest(pair.$2, native);
    final same = await _invoke(pair, keep, keep);
    expect(same['status'], 'skipped');
    final outside = await _invoke(pair, keep, candidate, roots: [pair.$1.path]);
    expect(outside['status'], 'skipped');
    expect(await pair.$1.exists(), isTrue);
    expect(await pair.$2.exists(), isTrue);
  });

  testWidgets('子目录被替换成 junction 后拒绝整目录清理', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    final keep = await _manifest(pair.$1, native);
    final candidate = await _manifest(pair.$2, native);
    final linkPath = p.join(pair.$2.path, '资料');
    final outsidePath = p.join(fixture.path, '连接点目标');
    for (final path in [linkPath, outsidePath]) {
      if (!p.isWithin(fixture.path, path)) throw StateError('连接点测试路径越界。');
    }
    await Directory(linkPath).rename(outsidePath);
    try {
      // 路径经环境变量传递，不把任何路径文本拼接成 PowerShell 指令。
      final creation = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'New-Item -ItemType Junction -Path $env:DUPE_FOLDER_LINK '
              r'-Target $env:DUPE_FOLDER_TARGET -ErrorAction Stop | Out-Null',
        ],
        workingDirectory: fixture.path,
        environment: {
          'DUPE_FOLDER_LINK': linkPath,
          'DUPE_FOLDER_TARGET': outsidePath,
        },
      );
      expect(creation.exitCode, 0, reason: creation.stderr.toString());
      expect((await native.inspect(linkPath)).isReparsePoint, isTrue);
      // 更新根目录时间以便直接检验子目录重解析保护，而不是仅被根时间变化挡住。
      candidate['directory'] = (await native.inspect(pair.$2.path)).toJson();
      final result = await _invoke(pair, keep, candidate);
      expect(result['status'], 'skipped', reason: result.toString());
      expect(result['reason'], contains('重解析'));
      expect(result['entries'], isEmpty);
      expect(await File(p.join(outsidePath, '数据.bin')).length(), 1024);
      expect(await File(p.join(pair.$2.path, '文档.txt')).exists(), isTrue);
    } finally {
      if (await FileSystemEntity.type(linkPath, followLinks: false) !=
          FileSystemEntityType.notFound) {
        if (!(await native.inspect(linkPath)).isReparsePoint) {
          throw StateError('测试连接点已被替换，拒绝删除。');
        }
        // 非递归移除连接点本身，目标仍必须存在；之后才允许外层清理本次fixture。
        await Directory(linkPath).delete(recursive: false);
      }
      expect(await File(p.join(outsidePath, '数据.bin')).exists(), isTrue);
    }
  });

  testWidgets('预先取消整目录操作不会清理任何样本', (tester) async {
    await _host(tester);
    final pair = await _trees(fixture);
    await native.cancelNative();
    final result = await _clean(pair, native);
    expect(result['status'], 'cancelled');
    expect(result['entries'], isEmpty);
    expect(await pair.$1.exists(), isTrue);
    expect(await pair.$2.exists(), isTrue);
  });
}

const _content = '这是整目录清理测试，保留原始内容。';

Future<void> _host(WidgetTester tester) => tester.pumpWidget(
  const MaterialApp(
    home: Scaffold(body: Center(child: Text('整目录原生安全验证'))),
  ),
);

Future<(Directory, Directory)> _trees(Directory fixture) async {
  final keep = await Directory(p.join(fixture.path, '保留目录')).create();
  final candidate = await Directory(p.join(fixture.path, '重复目录')).create();
  for (final directory in [keep, candidate]) {
    await Directory(p.join(directory.path, '资料')).create();
    await Directory(p.join(directory.path, '空目录')).create();
    await File(p.join(directory.path, '文档.txt')).writeAsString(_content);
    await File(p.join(directory.path, '空文件.txt')).writeAsString('');
    await File(p.join(directory.path, '资料', '数据.bin'))
        .writeAsBytes(List<int>.generate(1024, (i) => i % 251));
    await File(p.join(directory.path, '文档.txt'))
        .setLastModified(DateTime.utc(2024, 1, 1));
  }
  return (keep, candidate);
}

/// 清单由真实 Windows 快照生成，目录最后读取，避免样本构建期间的时间戳变化。
Future<Map<String, dynamic>> _manifest(
  Directory directory,
  WindowsBridge native,
) async {
  final files = <Map<String, dynamic>>[];
  final directories = <Map<String, dynamic>>[];
  final entries = await directory
      .list(recursive: true, followLinks: false)
      .toList();
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    final record = await native.inspect(entry.path);
    final value = <String, dynamic>{
      'relative_path': p
          .relative(entry.path, from: directory.path)
          .replaceAll(r'\', '/'),
      'record': record.toJson(),
    };
    if (record.isDirectory) {
      directories.add(value);
    } else {
      value['sha256'] = sha256
          .convert(await File(entry.path).readAsBytes())
          .toString();
      files.add(value);
    }
  }
  return {
    'directory': (await native.inspect(directory.path)).toJson(),
    'files': files,
    'directories': directories,
  };
}

Future<Map<String, dynamic>> _clean(
  (Directory, Directory) pair,
  WindowsBridge native, {
  String mode = 'permanent',
}) async => _invoke(
  pair,
  await _manifest(pair.$1, native),
  await _manifest(pair.$2, native),
  mode: mode,
);

Future<Map<String, dynamic>> _invoke(
  (Directory, Directory) pair,
  Map<String, dynamic> keep,
  Map<String, dynamic> candidate, {
  String mode = 'permanent',
  List<String>? roots,
}) async {
  final result = await WindowsBridge.channel.invokeMapMethod<String, dynamic>(
    'cleanFolder',
    {
      'roots': roots ?? [pair.$1.path, pair.$2.path],
      'keep': keep,
      'candidate': candidate,
      'mode': mode,
    },
  );
  return Map<String, dynamic>.from(result!);
}
