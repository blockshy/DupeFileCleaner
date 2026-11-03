import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../application/app_controller.dart';
import '../application/theme_controller.dart';
import '../core/models.dart';

/// 工作台只管理视图与过滤条件，扫描范围、保留关系和清理选择由控制器统一维护。
/// 文件与文件夹使用独立结果页，确认框明确标识当前操作的对象类型。
class HomePage extends StatefulWidget {
  const HomePage({super.key, this.controller, this.themeController});
  final AppController? controller;
  final ThemeController? themeController;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final AppController app = widget.controller ?? AppController();
  late final ThemeController themes =
      widget.themeController ?? ThemeController(persist: false);
  final directory = TextEditingController();
  String query = '';
  String sort = 'space';
  int? activeFile;
  int? activeFolder;
  ColorScheme get colors => Theme.of(context).colorScheme;
  TextStyle get muted => Theme.of(context).textTheme.bodySmall!;
  bool get folders => app.resultMode == ResultMode.folders;
  @override
  void dispose() {
    if (widget.controller == null) app.dispose();
    if (widget.themeController == null) themes.dispose();
    directory.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([app, themes]),
    builder: (context, _) => Scaffold(
      body: Column(
        children: [
          _toolbar(),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _sourcesPanel(),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: colors.outlineVariant,
                ),
                Expanded(
                  child: Column(
                    children: [
                      _resultTabs(),
                      _summary(),
                      if (app.busy) _progress(),
                      if (app.error != null ||
                          app.notice != null ||
                          themes.error != null)
                        _notice(),
                      Expanded(child: _resultContent()),
                      _actionBar(),
                    ],
                  ),
                ),
              ],
            ),
          ),
          _statusBar(),
        ],
      ),
    ),
  );
  Widget _toolbar() => Container(
    height: 49,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    decoration: BoxDecoration(
      color: colors.surface,
      border: Border(bottom: BorderSide(color: colors.outlineVariant)),
    ),
    child: Row(
      children: [
        Icon(Icons.copy_all_outlined, size: 20, color: colors.primary),
        const SizedBox(width: 9),
        const Text(
          'DupeFile Cleaner',
          style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
        const SizedBox(width: 14),
        Text('重复文件管理', style: muted),
        const Spacer(),
        TextButton.icon(
          onPressed: app.busy ? null : app.importPlan,
          icon: const Icon(Icons.file_open_outlined, size: 16),
          label: const Text('导入计划'),
        ),
        TextButton.icon(
          onPressed: app.busy || app.plan == null ? null : app.exportPlan,
          icon: const Icon(Icons.ios_share_outlined, size: 16),
          label: const Text('导出计划'),
        ),
        const SizedBox(width: 10),
        SizedBox(
          height: 20,
          child: VerticalDivider(color: colors.outlineVariant),
        ),
        TextButton.icon(
          key: const Key('settingsButton'),
          onPressed: _showSettings,
          icon: const Icon(Icons.settings_outlined, size: 16),
          label: const Text('设置'),
        ),
      ],
    ),
  );

  /// 目录列表独立滚动，任务按钮和关键选项在较小窗口中始终可见。
  Widget _sourcesPanel() => SizedBox(
    width: 268,
    child: ColoredBox(
      color: colors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '扫描目录',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                Text('${app.roots.length} 个目录', style: muted),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: OutlinedButton.icon(
              key: const Key('addDirectoriesButton'),
              onPressed: app.busy ? null : app.chooseDirectories,
              icon: const Icon(Icons.create_new_folder_outlined, size: 16),
              label: const Text('添加文件夹…'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('directoryInput'),
                    controller: directory,
                    enabled: !app.busy,
                    style: const TextStyle(fontSize: 11),
                    onSubmitted: (_) => _addTypedDirectory(),
                    decoration: const InputDecoration(
                      hintText: '粘贴完整路径',
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const Key('addPathButton'),
                  tooltip: '添加输入的目录',
                  onPressed: app.busy ? null : _addTypedDirectory,
                  icon: const Icon(Icons.add, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: app.roots.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text(
                      '添加需要比较的文件夹。\n支持跨目录查重，重叠范围会自动合并。',
                      style: muted.copyWith(height: 1.8),
                    ),
                  )
                : ListView.separated(
                    itemCount: app.roots.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: colors.outlineVariant.withValues(alpha: .55),
                    ),
                    itemBuilder: (_, i) {
                      final path = app.roots[i];
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(
                                Icons.folder_outlined,
                                size: 17,
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    p.windows.basename(path).isEmpty
                                        ? path
                                        : p.windows.basename(path),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Tooltip(
                                    message: path,
                                    child: Text(
                                      path,
                                      style: muted.copyWith(fontSize: 10),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '移除扫描目录',
                              key: ValueKey('remove-$path'),
                              onPressed: app.busy
                                  ? null
                                  : () => app.removeDirectory(path),
                              icon: const Icon(Icons.close, size: 15),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '扫描选项',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
                ),
                const SizedBox(height: 8),
                _option(
                  '包含空文件',
                  app.includeEmpty,
                  (v) => app.setScanOptions(includeEmpty: v),
                  hint: '普通文件查重包含 0 字节文件。完整文件夹比对始终检查空文件。',
                ),
                _option(
                  '包含硬链接',
                  app.includeHardlinks,
                  (v) => app.setScanOptions(includeHardlinks: v),
                  hint: '高级选项。硬链接逻辑大小不代表实际可释放容量。',
                ),
                _option(
                  '检测完整重复文件夹',
                  app.detectDuplicateFolders,
                  (v) => app.setScanOptions(detectDuplicateFolders: v),
                  hint: '比较相对路径、全部内容及空子目录；含链接或读取错误的文件夹不参与整目录清理。',
                ),
                const SizedBox(height: 9),
                FilledButton.icon(
                  key: const Key('scanButton'),
                  onPressed: app.busy
                      ? null
                      : () {
                          activeFile = null;
                          activeFolder = null;
                          app.startScan();
                        },
                  icon: const Icon(Icons.search, size: 16),
                  label: Text(app.plan == null ? '开始扫描' : '重新扫描'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  void _addTypedDirectory() {
    final path = directory.text.trim();
    if (path.isEmpty) return;
    app.addDirectory(path);
    if (app.error == null) directory.clear();
  }

  Widget _option(
    String label,
    bool value,
    ValueChanged<bool> changed, {
    required String hint,
  }) => Tooltip(
    message: hint,
    child: Row(
      children: [
        SizedBox(
          width: 27,
          height: 30,
          child: Checkbox(
            value: value,
            onChanged: app.busy ? null : (v) => changed(v!),
          ),
        ),
        const SizedBox(width: 5),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 11))),
        Icon(Icons.info_outline, size: 13, color: colors.onSurfaceVariant),
      ],
    ),
  );
  Widget _resultTabs() => Container(
    height: 43,
    color: colors.surface,
    child: Row(
      children: [
        _tab('重复文件', ResultMode.files, app.plan?.groups.length ?? 0),
        _tab('重复文件夹', ResultMode.folders, app.folderGroups.length),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Text('只读扫描 / 校验后清理', style: muted.copyWith(fontSize: 10)),
        ),
      ],
    ),
  );
  Widget _tab(String text, ResultMode mode, int count) {
    final active = app.resultMode == mode;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey('tab-${mode.name}'),
        onTap: app.busy
            ? null
            : () {
                app.setResultMode(mode);
                setState(() => query = '');
              },
        child: Container(
          height: 43,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? colors.primary : colors.outlineVariant,
                width: active ? 2 : 1,
              ),
            ),
          ),
          child: Text(
            '$text  $count',
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              color: active ? colors.primary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _summary() => Container(
    height: 35,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      border: Border(
        top: BorderSide(color: colors.outlineVariant),
        bottom: BorderSide(color: colors.outlineVariant),
      ),
    ),
    child: Row(
      children: [
        _metric('有效文件', '${app.plan?.scannedFiles ?? 0}'),
        _metric('扫描容量', formatBytes(app.plan?.scannedBytes ?? 0)),
        _metric('已选大小', formatBytes(app.selectedBytes)),
        const Spacer(),
        Text('逻辑大小', style: muted.copyWith(fontSize: 10)),
      ],
    ),
  );
  Widget _metric(String title, String value) => Padding(
    padding: const EdgeInsets.only(right: 22),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$title  ', style: muted.copyWith(fontSize: 11)),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    ),
  );
  Widget _progress() => Container(
    padding: const EdgeInsets.fromLTRB(14, 7, 14, 10),
    color: colors.surface,
    child: Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                stageLabel(app.stage),
                style: const TextStyle(fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              '${app.current}${app.total == null ? '' : ' / ${app.total}'} · ${formatBytes(app.bytesRead)} · ${app.clock.elapsed.inSeconds}s',
              style: muted,
            ),
            const SizedBox(width: 10),
            TextButton(
              onPressed: app.phase == TaskPhase.cancelling ? null : app.cancel,
              child: Text(app.phase == TaskPhase.cancelling ? '正在停止' : '取消'),
            ),
          ],
        ),
        LinearProgressIndicator(
          minHeight: 2,
          value: app.total == null || app.total == 0
              ? null
              : (app.current / app.total!).clamp(0, 1),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            app.currentPath.isEmpty ? '准备任务…' : app.currentPath,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted.copyWith(fontSize: 10),
          ),
        ),
      ],
    ),
  );
  Widget _notice() {
    final error = app.error ?? themes.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(bottom: BorderSide(color: colors.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(
            error == null ? Icons.info_outline : Icons.error_outline,
            color: error == null ? colors.onSurfaceVariant : colors.error,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error ?? app.notice!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: error == null ? colors.onSurfaceVariant : colors.error,
              ),
            ),
          ),
          TextButton(
            onPressed: error == themes.error && themes.error != null
                ? _showSettings
                : _showDetails,
            child: const Text('详情'),
          ),
        ],
      ),
    );
  }

  Widget _resultContent() {
    if (folders && !app.folderResultsValid && app.plan != null) {
      return _empty('文件夹结果需要重新扫描', '文件已发生清理，旧文件夹清单不再用于整目录操作。');
    }
    final count = folders
        ? app.folderGroups.length
        : (app.plan?.groups.length ?? 0);
    if (count == 0) {
      if (app.busy) return _empty('正在分析文件', '结果将在扫描完成后显示。');
      if (app.plan == null) return _empty('尚无扫描结果', '在左侧添加一个或多个文件夹，然后开始扫描。');
      return _empty(
        folders ? '没有完整重复的文件夹' : '没有重复文件',
        folders ? '仅完整目录结构及全部文件内容一致的文件夹会出现在这里。' : '当前扫描范围内没有符合条件的重复文件。',
      );
    }
    return Column(
      children: [
        _filterBar(),
        Expanded(child: folders ? _folderResults() : _fileResults()),
      ],
    );
  }

  Widget _filterBar() => Container(
    height: 45,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    color: colors.surface,
    child: Row(
      children: [
        SizedBox(
          width: 230,
          child: TextField(
            key: ValueKey('search-${app.resultMode.name}'),
            onChanged: (v) => setState(() => query = v),
            style: const TextStyle(fontSize: 11),
            decoration: const InputDecoration(
              hintText: '筛选名称或路径',
              prefixIcon: Icon(Icons.search, size: 16),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
          ),
        ),
        const Spacer(),
        Text('排序  ', style: muted),
        DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: sort,
            isDense: true,
            style: Theme.of(context).textTheme.bodySmall,
            onChanged: (v) => setState(() => sort = v!),
            items: const [
              DropdownMenuItem(value: 'space', child: Text('重复容量')),
              DropdownMenuItem(value: 'count', child: Text('副本数量')),
              DropdownMenuItem(value: 'name', child: Text('路径名称')),
            ],
          ),
        ),
      ],
    ),
  );
  Widget _fileResults() {
    final groups = app.plan!.groups
        .where(
          (g) =>
              query.isEmpty ||
              g.files.any(
                (f) => f.path.toLowerCase().contains(query.toLowerCase()),
              ),
        )
        .toList();
    groups.sort(
      (a, b) => switch (sort) {
        'count' => b.files.length.compareTo(a.files.length),
        'name' => a.keep.path.toLowerCase().compareTo(
          b.keep.path.toLowerCase(),
        ),
        _ => b.duplicateBytes.compareTo(a.duplicateBytes),
      },
    );
    final current =
        groups.where((g) => g.id == activeFile).firstOrNull ??
        groups.firstOrNull;
    if (current == null) return _empty('没有匹配结果', '调整筛选条件后重试。');
    return Row(
      children: [
        SizedBox(
          width: 206,
          child: ListView.builder(
            itemCount: groups.length,
            itemBuilder: (_, i) {
              final group = groups[i];
              return _groupRow(
                active: group.id == current.id,
                onTap: () => setState(() => activeFile = group.id),
                title: p.windows.basename(app.keeper(group).path),
                subtitle:
                    '${group.files.length} 份 · 每份 ${formatBytes(group.size)}',
                detail: '重复 ${formatBytes(group.duplicateBytes)}',
                icon: Icons.description_outlined,
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailHeader(
                '文件组 ${current.id}',
                '${current.files.length} 个文件 / 内容一致',
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: current.files.length,
                  itemBuilder: (_, i) => _fileRow(current, current.files[i]),
                ),
              ),
              _digestFooter(current.sha256),
            ],
          ),
        ),
      ],
    );
  }

  Widget _folderResults() {
    final groups = app.folderGroups
        .where(
          (g) =>
              query.isEmpty ||
              [
                g.keep,
                ...g.candidates,
              ].any((f) => f.path.toLowerCase().contains(query.toLowerCase())),
        )
        .toList();
    groups.sort(
      (a, b) => switch (sort) {
        'count' => b.candidates.length.compareTo(a.candidates.length),
        'name' => a.keep.path.toLowerCase().compareTo(
          b.keep.path.toLowerCase(),
        ),
        _ => (b.keep.totalBytes * b.candidates.length).compareTo(
          a.keep.totalBytes * a.candidates.length,
        ),
      },
    );
    final current =
        groups.where((g) => g.id == activeFolder).firstOrNull ??
        groups.firstOrNull;
    if (current == null) return _empty('没有匹配结果', '调整筛选条件后重试。');
    final records = [current.keep, ...current.candidates];
    return Row(
      children: [
        SizedBox(
          width: 206,
          child: ListView.builder(
            itemCount: groups.length,
            itemBuilder: (_, i) {
              final group = groups[i];
              return _groupRow(
                active: group.id == current.id,
                onTap: () => setState(() => activeFolder = group.id),
                title: p.windows.basename(app.folderKeeper(group).path),
                subtitle:
                    '${group.candidates.length + 1} 个文件夹 · ${group.keep.fileCount} 个文件',
                detail: '每份 ${formatBytes(group.keep.totalBytes)}',
                icon: Icons.folder_outlined,
              );
            },
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _detailHeader('文件夹组 ${current.id}', '结构、相对路径及全部内容一致'),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
                child: Text(
                  '整目录清理需主动勾选；默认按路径排序保留首份。',
                  style: muted.copyWith(fontSize: 10),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: records.length,
                  itemBuilder: (_, i) => _folderRow(current, records[i]),
                ),
              ),
              _digestFooter(current.fingerprint, label: '目录指纹'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _groupRow({
    required bool active,
    required VoidCallback onTap,
    required String title,
    required String subtitle,
    required String detail,
    required IconData icon,
  }) => Material(
    color: active ? colors.primary.withValues(alpha: .10) : colors.surface,
    child: InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 11, 10, 11),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              width: 2,
              color: active ? colors.primary : Colors.transparent,
            ),
            bottom: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .6),
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: active ? colors.primary : colors.onSurfaceVariant,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: muted.copyWith(fontSize: 10),
            ),
            const SizedBox(height: 3),
            Text(detail, style: muted.copyWith(fontSize: 10)),
          ],
        ),
      ),
    ),
  );
  Widget _detailHeader(String title, String subtitle) => Container(
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 14),
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      border: Border(bottom: BorderSide(color: colors.outlineVariant)),
    ),
    child: Row(
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            subtitle,
            style: muted.copyWith(fontSize: 10),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
  Widget _fileRow(DuplicateGroup group, FileRecord file) {
    final kept = app.isKept(group, file);
    final done = app.completed.contains(AppController.key(file.path));
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 10, 10, 8),
      decoration: BoxDecoration(
        color: kept ? colors.primary.withValues(alpha: .05) : colors.surface,
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant.withValues(alpha: .7),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 29,
            height: 24,
            child: kept
                ? Icon(Icons.lock_outline, size: 16, color: colors.primary)
                : Checkbox(
                    value: app.selected.contains(AppController.key(file.path)),
                    onChanged: app.busy || done
                        ? null
                        : (v) => app.toggleFile(group, file, v!),
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.windows.basename(file.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _label(
                      kept
                          ? '保留'
                          : done
                          ? '已处理'
                          : '候选',
                      selected: kept,
                    ),
                  ],
                ),
                const SizedBox(height: 5),
                Tooltip(
                  message: '扫描目录：${_sourceRoot(file.path)}\n${file.path}',
                  child: SelectableText(
                    file.path,
                    maxLines: 2,
                    style: muted.copyWith(fontSize: 10),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${formatBytes(file.size)}  /  ${formatDate(file.modifiedAt)}${file.linkCount > 1 ? '  /  硬链接 ${file.linkCount}' : ''}',
                  style: muted.copyWith(fontSize: 10),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (kept)
                      Expanded(
                        child: Text(
                          app.keepOverrides.containsKey(group.id)
                              ? '你指定的保留文件'
                              : app.importedPlan
                              ? '导入计划指定的保留文件'
                              : '按最早修改时间及路径排序推荐',
                          style: muted.copyWith(fontSize: 10),
                        ),
                      )
                    else
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            key: ValueKey('keep-${file.path}'),
                            onPressed: app.busy || done
                                ? null
                                : () => app.chooseKeeper(group, file),
                            child: const Text(
                              '改为保留',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: '在资源管理器中定位',
                      onPressed: done ? null : () => _reveal(file.path),
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                    ),
                    IconButton(
                      tooltip: '复制路径',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: file.path)),
                      icon: const Icon(Icons.copy_outlined, size: 14),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderRow(DuplicateFolderGroup group, FolderRecord folder) {
    final kept = app.isFolderKept(group, folder);
    final done = app.completedFolders.contains(AppController.key(folder.path));
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 12, 10, 10),
      decoration: BoxDecoration(
        color: kept ? colors.primary.withValues(alpha: .05) : colors.surface,
        border: Border(
          bottom: BorderSide(
            color: colors.outlineVariant.withValues(alpha: .7),
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 29,
            height: 24,
            child: kept
                ? Icon(Icons.lock_outline, size: 16, color: colors.primary)
                : Checkbox(
                    key: ValueKey('folder-check-${folder.path}'),
                    value: app.selectedFolders.contains(
                      AppController.key(folder.path),
                    ),
                    onChanged: app.busy || done
                        ? null
                        : (v) => app.toggleFolder(group, folder, v!),
                  ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        p.windows.basename(folder.path),
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _label(
                      kept
                          ? '保留整个文件夹'
                          : done
                          ? '已处理'
                          : '完整副本',
                      selected: kept,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SelectableText(
                  folder.path,
                  style: muted.copyWith(fontSize: 10),
                  maxLines: 2,
                ),
                const SizedBox(height: 7),
                Text(
                  '${folder.fileCount} 个文件  /  ${folder.directories.length} 个子目录  /  ${formatBytes(folder.totalBytes)}',
                  style: muted.copyWith(fontSize: 10),
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (!kept)
                      TextButton(
                        key: ValueKey('folder-keep-${folder.path}'),
                        onPressed: app.busy || done
                            ? null
                            : () => app.chooseFolderKeeper(group, folder),
                        child: const Text(
                          '改为保留',
                          style: TextStyle(fontSize: 11),
                        ),
                      ),
                    TextButton(
                      key: ValueKey('manifest-${folder.path}'),
                      onPressed: () => _showManifest(folder),
                      child: const Text(
                        '查看完整清单',
                        style: TextStyle(fontSize: 11),
                      ),
                    ),
                    IconButton(
                      tooltip: '在资源管理器中定位',
                      onPressed: done ? null : () => _reveal(folder.path),
                      icon: const Icon(Icons.folder_open_outlined, size: 16),
                    ),
                    IconButton(
                      tooltip: '复制路径',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: folder.path)),
                      icon: const Icon(Icons.copy_outlined, size: 14),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _label(String text, {bool selected = false}) => Text(
    text,
    style: TextStyle(
      fontSize: 10,
      color: selected ? colors.primary : colors.onSurfaceVariant,
      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
    ),
  );
  Widget _digestFooter(String digest, {String label = 'SHA-256'}) => Container(
    height: 31,
    padding: const EdgeInsets.only(left: 12, right: 4),
    decoration: BoxDecoration(
      color: colors.surfaceContainerLow,
      border: Border(top: BorderSide(color: colors.outlineVariant)),
    ),
    child: Row(
      children: [
        Text('$label  ', style: muted.copyWith(fontSize: 10)),
        Expanded(
          child: Text(
            digest,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: muted.copyWith(fontFamily: 'Consolas', fontSize: 10),
          ),
        ),
        IconButton(
          tooltip: '复制完整摘要',
          onPressed: () => Clipboard.setData(ClipboardData(text: digest)),
          icon: const Icon(Icons.copy_outlined, size: 13),
        ),
      ],
    ),
  );
  Widget _empty(String title, String description) => ColoredBox(
    color: colors.surface,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              folders ? Icons.folder_outlined : Icons.manage_search_outlined,
              size: 30,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(description, style: muted, textAlign: TextAlign.center),
          ],
        ),
      ),
    ),
  );
  Widget _actionBar() => Container(
    height: 53,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    decoration: BoxDecoration(
      color: colors.surface,
      border: Border(top: BorderSide(color: colors.outlineVariant)),
    ),
    child: Row(
      children: [
        TextButton(
          key: const Key('selectAllButton'),
          onPressed: app.busy || app.plan == null
              ? null
              : () => app.selectAll(app.selectedCount == 0),
          child: Text(app.selectedCount == 0 ? '全选候选' : '取消全选'),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            folders
                ? '已选 ${app.selectedCount} 个文件夹 / ${app.selectedFileCount} 个文件'
                : '已选 ${app.selectedCount} 个文件',
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        TextButton.icon(
          onPressed: _showDetails,
          icon: const Icon(Icons.receipt_long_outlined, size: 16),
          label: const Text('详情与日志'),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          key: const Key('cleanButton'),
          onPressed: app.busy || app.selectedCount == 0
              ? null
              : _confirmCleanup,
          icon: Icon(
            folders ? Icons.folder_delete_outlined : Icons.recycling,
            size: 16,
          ),
          label: Text(folders ? '清理选中文件夹' : '清理选中文件'),
        ),
      ],
    ),
  );
  Widget _statusBar() => Container(
    height: 26,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    decoration: BoxDecoration(
      color: colors.surfaceContainer,
      border: Border(top: BorderSide(color: colors.outlineVariant)),
    ),
    child: Row(
      children: [
        Icon(
          app.busy ? Icons.pending_outlined : Icons.check_circle_outline,
          size: 12,
          color: colors.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        Text(app.busy ? '任务进行中' : '就绪', style: muted.copyWith(fontSize: 10)),
        const SizedBox(width: 18),
        Text(
          '异常 / 跳过 ${app.problemCount}',
          style: muted.copyWith(fontSize: 10),
        ),
        const Spacer(),
        Text(
          '本机处理  ·  Windows x64  ·  v1.1.1',
          style: muted.copyWith(fontSize: 10),
        ),
      ],
    ),
  );
  Future<void> _reveal(String path) async {
    try {
      await app.native.reveal(path);
    } catch (e) {
      app.reportError(e);
    }
  }

  /// 跨目录结果的路径提示保留来源根目录，方便区分工作副本和归档副本。
  String _sourceRoot(String path) => (app.plan?.roots ?? app.roots).firstWhere(
    (root) =>
        isPathWithinRoot(path, root) ||
        canonicalWindowsPath(path) == canonicalWindowsPath(root),
    orElse: () => '未匹配扫描范围',
  );

  /// 清理确认只提交当前结果页，整目录与单文件不会在同一操作中混用。
  /// 永久删除采用明确的文字确认；默认仍是可恢复的回收站操作。
  Future<void> _confirmCleanup() async {
    final isFolder = folders;
    var permanent = false;
    var confirmation = '';
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(permanent ? '确认永久删除' : '确认移入回收站'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isFolder
                        ? '将处理 ${app.selectedCount} 个文件夹，包含 ${app.selectedFileCount} 个文件。'
                        : '将处理 ${app.selectedCount} 个重复文件。',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text('逻辑大小：${formatBytes(app.selectedBytes)}'),
                  const SizedBox(height: 16),
                  Text('扫描范围', style: muted),
                  const SizedBox(height: 4),
                  for (final root in app.plan!.roots)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: SelectableText(
                        root,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    isFolder
                        ? '执行前会重新核对整个目录的结构、文件身份与内容。每组始终保留一份；完成后保留其余结果，可继续选择清理。'
                        : '执行前会重新核对文件身份与完整内容。每组始终保留一份；文件变化时将跳过该项。',
                    style: muted,
                  ),
                  const Divider(height: 24),
                  SwitchListTile.adaptive(
                    key: const Key('permanentSwitch'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('永久删除'),
                    subtitle: const Text('开启后无法通过回收站恢复'),
                    value: permanent,
                    onChanged: (value) => update(() {
                      permanent = value;
                      confirmation = '';
                    }),
                  ),
                  if (permanent) ...[
                    const SizedBox(height: 8),
                    TextField(
                      key: const Key('deleteConfirmation'),
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: '输入 DELETE 确认永久删除',
                      ),
                      onChanged: (value) => update(() => confirmation = value),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const Key('confirmCleanup'),
              onPressed: !permanent || confirmation == 'DELETE'
                  ? () => Navigator.pop(dialogContext, permanent)
                  : null,
              child: Text(permanent ? '永久删除' : '移入回收站'),
            ),
          ],
        ),
      ),
    );
    if (result != null && mounted) await app.clean(permanent: result);
  }

  /// 设置面板共享应用级主题控制器，选择后立即预览并异步保存。
  Future<void> _showSettings() => showDialog<void>(
    context: context,
    builder: (dialogContext) => ListenableBuilder(
      listenable: themes,
      builder: (context, _) => AlertDialog(
        title: const Text('设置'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('界面主题', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _themeChoice(
                    ThemeMode.system,
                    '跟随系统',
                    Icons.brightness_auto_outlined,
                  ),
                  _themeChoice(
                    ThemeMode.light,
                    '浅色',
                    Icons.light_mode_outlined,
                  ),
                  _themeChoice(ThemeMode.dark, '深色', Icons.dark_mode_outlined),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                themes.saving ? '正在保存主题偏好…' : '主题偏好在本机保存，下次启动时自动恢复。',
                style: muted,
              ),
              if (themes.error != null) ...[
                const SizedBox(height: 12),
                SelectableText(
                  themes.error!,
                  style: TextStyle(color: colors.error, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      ),
    ),
  );

  Widget _themeChoice(ThemeMode mode, String title, IconData icon) =>
      ChoiceChip(
        key: Key('theme-${mode.name}'),
        avatar: Icon(icon, size: 16),
        label: Text(title),
        selected: themes.mode == mode,
        onSelected: (_) => unawaited(themes.setMode(mode)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      );

  /// 展示参与目录一致性判断的完整清单，空子目录也列出，便于用户核对边界。
  Future<void> _showManifest(FolderRecord folder) => showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('文件夹内容清单'),
      content: SizedBox(
        width: 740,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              folder.path,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              '${folder.fileCount} 个文件 / ${folder.directories.length} 个子目录 / ${formatBytes(folder.totalBytes)}',
              style: muted,
            ),
            const Divider(height: 20),
            Expanded(
              child: ListView.builder(
                itemCount: folder.directories.length + folder.files.length,
                itemBuilder: (context, index) {
                  if (index < folder.directories.length) {
                    return ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.folder_outlined, size: 18),
                      title: SelectableText(
                        folder.directories[index].relativePath,
                      ),
                      trailing: Text('目录', style: muted),
                    );
                  }
                  final entry = folder.files[index - folder.directories.length];
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.insert_drive_file_outlined,
                      size: 18,
                    ),
                    title: SelectableText(entry.relativePath),
                    subtitle: Text(
                      '${formatBytes(entry.record.size)}  ·  SHA-256 ${entry.sha256}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted.copyWith(fontSize: 10),
                    ),
                    trailing: IconButton(
                      tooltip: '复制文件摘要',
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: entry.sha256)),
                      icon: const Icon(Icons.copy_outlined, size: 15),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('关闭'),
        ),
      ],
    ),
  );

  /// 汇总扫描异常、跳过项及执行结果；原生部分完成结果的逐项记录也可追溯。
  Future<void> _showDetails() => showDialog<void>(
    context: context,
    builder: (dialogContext) {
      final entries = <({String path, String status, String detail})>[
        for (final item in app.plan?.errors ?? <Map<String, String>>[])
          (
            path: item['path'] ?? '',
            status: '扫描失败',
            detail: item['error'] ?? item['reason'] ?? item.toString(),
          ),
        for (final item in app.plan?.skipped ?? <Map<String, String>>[])
          (
            path: item['path'] ?? '',
            status: '已跳过',
            detail: item['reason'] ?? item.toString(),
          ),
        for (final item in app.results)
          (
            path: '${item['path'] ?? ''}',
            status: statusLabel('${item['status'] ?? ''}'),
            detail: [
              if (item['reason'] != null) '${item['reason']}',
              if (item['error'] != null) '${item['error']}',
              if (item['items'] != null) '${item['items']}',
              if (item['entries'] != null) '${item['entries']}',
            ].join('\n'),
          ),
      ];
      return AlertDialog(
        title: const Text('扫描详情与执行日志'),
        content: SizedBox(
          width: 780,
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (app.error != null) ...[
                SelectableText(
                  app.error!,
                  style: TextStyle(color: colors.error),
                ),
                const SizedBox(height: 12),
              ],
              if (app.logPath != null) ...[
                Row(
                  children: [
                    Expanded(child: SelectableText(app.logPath!, style: muted)),
                    IconButton(
                      tooltip: '在资源管理器中定位日志',
                      onPressed: () => _reveal(app.logPath!),
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                    ),
                  ],
                ),
                const Divider(),
              ],
              Expanded(
                child: entries.isEmpty
                    ? Center(child: Text('暂无异常或执行记录', style: muted))
                    : ListView.separated(
                        itemCount: entries.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = entries[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  entry.status,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                SelectableText(entry.path),
                                if (entry.detail.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  SelectableText(entry.detail, style: muted),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
          ),
        ],
      );
    },
  );
}

/// 字节数以二进制单位显示，与 Windows 常见的文件属性语义一致。
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var amount = bytes / 1024;
  var index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index++;
  }
  return '${amount.toStringAsFixed(amount >= 100 ? 0 : 1)} ${units[index]}';
}

String formatDate(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
String stageLabel(String stage) => switch (stage) {
  'enumerating' => '枚举目录',
  'size' => '按大小分组',
  'quick_hash' => '快速内容筛选',
  'full_hash' => '完整内容校验',
  'folder_hash' => '核对完整目录',
  'completed' => '扫描完成',
  _ => stage,
};
String statusLabel(String status) => switch (status) {
  'deleted' => '已永久删除',
  'recycled' => '已移入回收站',
  'skipped' => '已跳过',
  'failed' => '执行失败',
  'cancelled' => '已取消',
  'partial' => '部分完成，需重新扫描',
  _ => status,
};
