import 'dart:convert';
import 'dart:io';

import 'package:dupe_file_cleaner/application/theme_controller.dart';
import 'package:dupe_file_cleaner/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 设置测试全部使用工程内独立临时目录，绝不读取或覆盖真实 LocalAppData。
void main() {
  late Directory fixture;
  late File settings;
  setUp(() async {
    final parent = Directory(p.join(Directory.current.path, 'test_artifacts'));
    await parent.create(recursive: true);
    fixture = await parent.createTemp('theme-');
    settings = File(p.join(fixture.path, 'settings.json'));
  });
  tearDown(() async {
    // 删除前再次验证绝对路径仍位于本次测试产物根目录，避免扩大清理范围。
    final allowed = p.normalize(p.absolute('test_artifacts'));
    final target = p.normalize(p.absolute(fixture.path));
    if (!p.isWithin(allowed, target)) throw StateError('主题测试清理路径越界');
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  test('浅色与深色正文、次要文字和主按钮满足可读性对比度', () {
    double contrast(Color a, Color b) {
      final first = a.computeLuminance();
      final second = b.computeLuminance();
      return first > second
          ? (first + .05) / (second + .05)
          : (second + .05) / (first + .05);
    }

    for (final brightness in Brightness.values) {
      final colors = buildIndustrialTheme(brightness).colorScheme;
      expect(
        contrast(colors.onSurface, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.onSurfaceVariant, colors.surface),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.onSurfaceVariant, colors.surfaceContainerLow),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(colors.primary, colors.onPrimary),
        greaterThanOrEqualTo(4.5),
      );
    }
  });

  test('首次启动跟随系统，保存后新控制器恢复主题', () async {
    final first = ThemeController(settingsFile: settings);
    addTearDown(first.dispose);
    await first.load();
    expect(first.mode, ThemeMode.system);
    expect(first.error, isNull);
    await first.setMode(ThemeMode.dark);
    expect(first.error, isNull);
    final restored = ThemeController(settingsFile: settings);
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.mode, ThemeMode.dark);
    expect(jsonDecode(await settings.readAsString())['theme'], 'dark');
  });

  test('快速连续切换按顺序保存，最终选择不会被旧任务覆盖', () async {
    final themes = ThemeController(settingsFile: settings);
    addTearDown(themes.dispose);
    await Future.wait([
      themes.setMode(ThemeMode.dark),
      themes.setMode(ThemeMode.light),
      themes.setMode(ThemeMode.system),
    ]);
    expect(themes.mode, ThemeMode.system);
    expect(themes.saving, isFalse);
    expect(themes.error, isNull);
    expect(jsonDecode(await settings.readAsString())['theme'], 'system');
    expect(await fixture.list().length, 1);
  });

  test('损坏或未知主题偏好回退系统并提供可见错误', () async {
    for (final payload in ['broken json', '{"theme":"unknown"}']) {
      await settings.writeAsString(payload);
      final themes = ThemeController(
        settingsFile: settings,
        initialMode: ThemeMode.dark,
      );
      await themes.load();
      expect(themes.mode, ThemeMode.system);
      expect(themes.error, contains('无法读取主题设置'));
      themes.dispose();
    }
  });

  test('写入失败仍应用主题并报告错误，后续保存能够恢复', () async {
    await Directory(settings.path).create();
    final themes = ThemeController(settingsFile: settings);
    addTearDown(themes.dispose);
    await themes.setMode(ThemeMode.dark);
    expect(themes.mode, ThemeMode.dark);
    expect(themes.saving, isFalse);
    expect(themes.error, contains('无法保存设置'));
    await Directory(settings.path).delete();
    await themes.setMode(ThemeMode.light);
    expect(themes.error, isNull);
    expect(jsonDecode(await settings.readAsString())['theme'], 'light');
  });

  test('非持久化模式不访问设置文件', () async {
    final themes = ThemeController(settingsFile: settings, persist: false);
    addTearDown(themes.dispose);
    await themes.setMode(ThemeMode.dark);
    await themes.load();
    expect(themes.mode, ThemeMode.dark);
    expect(await settings.exists(), isFalse);
  });
}
