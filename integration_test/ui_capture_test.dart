import 'dart:io';
import 'dart:ui' as ui;

import 'package:dupe_file_cleaner/application/theme_controller.dart';
import 'package:dupe_file_cleaner/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import '../test/widget_test.dart' show createReviewController;

/// 使用 Windows 的真实字体与渲染器生成可复核截图。
/// 模型仅含测试路径，所有平台清理调用由夹具屏蔽，主题设置也不会持久化。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('导出工业工作台浅色、深色及目录结果截图', (tester) async {
    final project = Directory(p.normalize(p.absolute(Directory.current.path)));
    final pubspec = File(p.join(project.path, 'pubspec.yaml'));
    if (!await pubspec.exists() ||
        !(await pubspec.readAsString()).contains('name: dupe_file_cleaner')) {
      throw StateError('请在 DupeFileCleaner 项目根目录运行截图测试');
    }
    final output = Directory(p.join(project.path, 'test_artifacts'));
    await output.create(recursive: true);
    await binding.setSurfaceSize(const Size(1280, 820));
    final app = createReviewController();
    final themes = ThemeController(
      persist: false,
      initialMode: ThemeMode.light,
    );
    final boundaryKey = GlobalKey();
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: DupeCleanerApp(appController: app, themeController: themes),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> capture(String name) async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final rendered = await boundary.toImage(pixelRatio: 1);
        try {
          final data = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (data == null) throw StateError('截图编码失败');
          await File(p.join(output.path, name))
              .writeAsBytes(data.buffer.asUint8List(), flush: true);
        } finally {
          rendered.dispose();
        }
      }

      await capture('ui-light.png');
      await themes.setMode(ThemeMode.dark);
      await tester.pumpAndSettle();
      await capture('ui-dark.png');
      await tester.tap(find.byKey(const Key('tab-folders')));
      await tester.pumpAndSettle();
      await capture('ui-folders-dark.png');
      await themes.setMode(ThemeMode.light);
      await tester.pumpAndSettle();
      await capture('ui-folders-light.png');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await binding.setSurfaceSize(null);
      app.dispose();
      themes.dispose();
    }
  });
}
