import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dupe_file_cleaner/application/app_controller.dart';
import 'package:dupe_file_cleaner/application/theme_controller.dart';
import 'package:dupe_file_cleaner/core/models.dart';
import 'package:dupe_file_cleaner/main.dart';

/// 测试控制器仅记录用户确认，绝不调用原生删除或实际磁盘扫描。
/// 截图集成测试复用此夹具，以保持视觉检查与交互测试的数据一致。
class ReviewTestController extends AppController {
  bool? lastPermanent;
  ResultMode? lastMode;
  int executions = 0;

  @override
  Future<void> clean({required bool permanent}) async {
    executions++;
    lastPermanent = permanent;
    lastMode = resultMode;
  }
}

// 固定示例时间为 2026-10-01 08:30 UTC；截图和界面测试不读取本机文件时间。
const _sampleTimestampNs = 1790843400000000000;

FileRecord _record(
  String path, {
  int timestamp = _sampleTimestampNs,
  int size = 1024,
  bool directory = false,
}) => FileRecord(
  path: path,
  finalPath: path,
  size: directory ? 0 : size,
  mtimeNs: timestamp,
  volumeId: 'test-volume',
  fileId: path,
  isDirectory: directory,
);

FolderRecord _folder(String path) => FolderRecord(
  directory: _record(path, directory: true),
  files: [
    FolderFileEntry(
      relativePath: r'assets\part.bin',
      record: _record('$path\\assets\\part.bin'),
      sha256: 'b' * 64,
    ),
    FolderFileEntry(
      relativePath: 'marker.txt',
      record: _record('$path\\marker.txt', size: 0),
      sha256: 'c' * 64,
    ),
  ],
  directories: [
    FolderDirectoryEntry(
      relativePath: 'assets',
      record: _record('$path\\assets', directory: true),
    ),
    FolderDirectoryEntry(
      relativePath: 'empty',
      record: _record('$path\\empty', directory: true),
    ),
  ],
);

ReviewTestController createReviewController() {
  final app = ReviewTestController();
  app.addDirectory(r'D:\sample');
  app.addDirectory(r'E:\archive');
  final keep = _record(r'D:\sample\original.txt');
  final candidate = _record(
    r'E:\archive\copy.txt',
    timestamp: _sampleTimestampNs + 3600000000000,
  );
  final folder = _folder(r'D:\sample\package');
  app.plan = ScanPlan(
    roots: app.roots,
    options: const ScanOptions(),
    groups: [
      DuplicateGroup(
        id: 1,
        size: 1024,
        sha256: 'a' * 64,
        keep: keep,
        candidates: [candidate],
      ),
    ],
    folderGroups: [
      DuplicateFolderGroup(
        id: 1,
        fingerprint: folderFingerprint(folder),
        keep: folder,
        candidates: [_folder(r'E:\archive\package')],
      ),
    ],
    generatedAt: DateTime(2026, 10, 28),
    scannedFiles: 6,
    scannedBytes: 4096,
  );
  app.phase = TaskPhase.ready;
  app.selectAll(true);
  return app;
}

Future<void> _desktopSize(
  WidgetTester tester, {
  Size size = const Size(1280, 820),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<ThemeController> _showReview(
  WidgetTester tester,
  ReviewTestController app, {
  ThemeMode mode = ThemeMode.light,
  Size size = const Size(1280, 820),
}) async {
  await _desktopSize(tester, size: size);
  final themes = ThemeController(persist: false, initialMode: mode);
  addTearDown(app.dispose);
  addTearDown(themes.dispose);
  await tester.pumpWidget(
    DupeCleanerApp(appController: app, themeController: themes),
  );
  await tester.pumpAndSettle();
  return themes;
}

void main() {
  testWidgets('初始界面不触发原生接口，未选择文件时禁止清理', (tester) async {
    await _showReview(tester, ReviewTestController());
    expect(find.text('尚无扫描结果'), findsOneWidget);
    expect(find.text('开始扫描'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cleanButton')))
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('最小桌面窗口下${mode.name}主题与结果没有溢出', (tester) async {
      await _showReview(
        tester,
        createReviewController(),
        mode: mode,
        size: const Size(1064, 681),
      );
      expect(
        Theme.of(tester.element(find.byType(Scaffold))).brightness,
        mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('tab-folders')));
      await tester.pumpAndSettle();
      expect(find.text('清理选中文件夹'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('设置支持浅色、深色及跟随系统，实时应用主题', (tester) async {
    final themes = await _showReview(
      tester,
      ReviewTestController(),
      size: const Size(1064, 681),
    );
    await tester.tap(find.byKey(const Key('settingsButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-dark')));
    await tester.pumpAndSettle();
    expect(themes.mode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.byType(Scaffold))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.byKey(const Key('theme-system')));
    await tester.pumpAndSettle();
    expect(themes.mode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });

  testWidgets('可添加多个目录，重复和嵌套范围自动合并，移除后计数更新', (tester) async {
    final app = ReviewTestController();
    await _showReview(tester, app);
    Future<void> addPath(String path) async {
      await tester.enterText(find.byKey(const Key('directoryInput')), path);
      await tester.tap(find.byKey(const Key('addPathButton')));
      await tester.pumpAndSettle();
    }

    await addPath(r'D:\sample\sub');
    await addPath(r'E:\archive');
    expect(app.roots, [r'D:\sample\sub', r'E:\archive']);
    await addPath(r'D:\sample');
    expect(app.roots.length, 2);
    expect(app.roots, contains(r'D:\sample'));
    await addPath(r'd:\SAMPLE\child');
    expect(app.roots.length, 2);
    expect(find.text('2 个目录'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey(r'remove-E:\archive')));
    await tester.pumpAndSettle();
    expect(app.roots, [r'D:\sample']);
    expect(find.text('1 个目录'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更换保留项会取消新保留文件的清理勾选', (tester) async {
    final app = createReviewController();
    await _showReview(tester, app);
    final group = app.plan!.groups.single;
    final candidate = group.candidates.single;
    await tester.tap(find.byKey(ValueKey('keep-${candidate.path}')));
    await tester.pumpAndSettle();
    expect(app.keeper(group), candidate);
    expect(app.selected.contains(AppController.key(candidate.path)), isFalse);
    expect(app.selected.contains(AppController.key(group.keep.path)), isTrue);
    expect(find.text('你指定的保留文件'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('最小窗口中结果、详情与确认对话框均无溢出', (tester) async {
    await _showReview(
      tester,
      createReviewController(),
      size: const Size(1064, 681),
    );
    await tester.tap(find.text('详情与日志'));
    await tester.pumpAndSettle();
    expect(find.text('扫描详情与执行日志'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cleanButton')));
    await tester.pumpAndSettle();
    expect(find.text(r'D:\sample'), findsWidgets);
    expect(find.text(r'E:\archive'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('默认确认仅调用回收站模式，打开对话框不会直接清理', (tester) async {
    final app = createReviewController();
    await _showReview(tester, app);
    await tester.tap(find.byKey(const Key('cleanButton')));
    await tester.pumpAndSettle();
    expect(find.text('确认移入回收站'), findsOneWidget);
    expect(app.executions, 0);
    await tester.tap(find.byKey(const Key('confirmCleanup')));
    await tester.pumpAndSettle();
    expect(app.executions, 1);
    expect(app.lastPermanent, isFalse);
    expect(app.lastMode, ResultMode.files);
  });

  testWidgets('永久删除必须精确输入 DELETE 后才能提交', (tester) async {
    final app = createReviewController();
    await _showReview(tester, app, size: const Size(1064, 681));
    await tester.tap(find.byKey(const Key('cleanButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('permanentSwitch')));
    await tester.pumpAndSettle();
    expect(find.text('确认永久删除'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirmCleanup')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('deleteConfirmation')),
      'delete',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirmCleanup')))
          .onPressed,
      isNull,
    );
    await tester.enterText(
      find.byKey(const Key('deleteConfirmation')),
      'DELETE',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirmCleanup')))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('confirmCleanup')));
    await tester.pumpAndSettle();
    expect(app.executions, 1);
    expect(app.lastPermanent, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('目录默认未选，清单包含空文件及空子目录，确认只提交目录模式', (tester) async {
    final app = createReviewController();
    await _showReview(tester, app, size: const Size(1064, 681));
    await tester.tap(find.byKey(const Key('tab-folders')));
    await tester.pumpAndSettle();
    expect(app.selectedCount, 0);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cleanButton')))
          .onPressed,
      isNull,
    );
    final group = app.folderGroups.single;
    final candidate = group.candidates.single;
    await tester.tap(find.byKey(ValueKey('manifest-${candidate.path}')));
    await tester.pumpAndSettle();
    expect(find.text(r'assets\part.bin'), findsOneWidget);
    expect(find.text('marker.txt'), findsOneWidget);
    expect(find.text('empty'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('folder-check-${candidate.path}')));
    await tester.pumpAndSettle();
    expect(app.selectedCount, 1);
    expect(app.selectedFileCount, 2);
    await tester.tap(find.byKey(const Key('cleanButton')));
    await tester.pumpAndSettle();
    expect(find.text('将处理 1 个文件夹，包含 2 个文件。'), findsOneWidget);
    expect(app.executions, 0);
    await tester.tap(find.byKey(const Key('confirmCleanup')));
    await tester.pumpAndSettle();
    expect(app.executions, 1);
    expect(app.lastMode, ResultMode.folders);
    expect(app.lastPermanent, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('切换文件夹保留项始终保护一份，文件与目录勾选分别保存', (tester) async {
    final app = createReviewController();
    await _showReview(tester, app);
    await tester.tap(find.byKey(const Key('tab-folders')));
    await tester.pumpAndSettle();
    final group = app.folderGroups.single;
    final candidate = group.candidates.single;
    await tester.tap(find.byKey(ValueKey('folder-keep-${candidate.path}')));
    await tester.pumpAndSettle();
    expect(app.folderKeeper(group), candidate);
    expect(app.selectedFolders, {AppController.key(group.keep.path)});
    expect(
      find.byKey(ValueKey('folder-check-${candidate.path}')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('tab-files')));
    await tester.pumpAndSettle();
    expect(app.selectedCount, 1);
    expect(app.selectedFileCount, 1);
  });

  testWidgets('显式标记失效的文件夹结果提示重扫', (tester) async {
    final app = createReviewController()..folderResultsValid = false;
    await _showReview(tester, app);
    await tester.tap(find.byKey(const Key('tab-folders')));
    await tester.pumpAndSettle();
    expect(find.text('文件夹结果需要重新扫描'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cleanButton')))
          .onPressed,
      isNull,
    );
  });
}
