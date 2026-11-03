import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'application/app_controller.dart';
import 'application/theme_controller.dart';
import 'ui/app_theme.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DupeCleanerApp());
}

/// 应用拥有默认控制器的生命周期；测试或嵌入场景可注入控制器避免真实文件操作。
class DupeCleanerApp extends StatefulWidget {
  const DupeCleanerApp({super.key, this.themeController, this.appController});
  final ThemeController? themeController;
  final AppController? appController;

  @override
  State<DupeCleanerApp> createState() => _DupeCleanerAppState();
}

class _DupeCleanerAppState extends State<DupeCleanerApp> {
  late final ThemeController themes =
      widget.themeController ?? ThemeController();

  @override
  void initState() {
    super.initState();
    if (widget.themeController == null) unawaited(themes.load());
  }

  @override
  void dispose() {
    if (widget.themeController == null) themes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: themes,
    builder: (context, _) => MaterialApp(
      title: 'DupeFile Cleaner',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      theme: buildIndustrialTheme(Brightness.light),
      darkTheme: buildIndustrialTheme(Brightness.dark),
      themeMode: themes.mode,
      home: HomePage(controller: widget.appController, themeController: themes),
    ),
  );
}
