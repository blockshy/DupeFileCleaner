import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/models.dart';
import '../platform/windows_bridge.dart';
import 'scan_worker.dart';

/// 界面任务状态；取消是协作式的，已经成功的清理不会被当作回滚。
enum TaskPhase { idle, scanning, importing, ready, cleaning, cancelling }

/// 同一批次只执行一种粒度，避免文件清理破坏整目录计划中的保留副本。
enum ResultMode { files, folders }

/// 管理一次扫描及其人工选择，不把界面勾选直接作为删除依据。
///
/// 执行前会将选择固化成经过验证的计划，再逐个交给原生层复核。
/// 日志采用「意图 → 结果」两条记录，异常退出留下的意图需人工复核，绝不自动重试。
class AppController extends ChangeNotifier {
  AppController({WindowsBridge? bridge, this.historyDirectory})
    : native = bridge ?? WindowsBridge();
  final WindowsBridge native;

  /// 测试可以注入专用日志目录；正常启动始终使用当前用户的应用数据目录。
  final String? historyDirectory;
  final List<String> _roots = [];
  List<String> get roots => List.unmodifiable(_roots);

  /// 兼容旧单目录调用；正式扫描和执行始终使用完整 roots 集合。
  String get root => _roots.isEmpty ? '' : _roots.first;
  set root(String value) => setDirectory(value);
  bool includeEmpty = false;
  bool includeHardlinks = false;
  bool detectDuplicateFolders = true;
  ResultMode resultMode = ResultMode.files;
  bool folderResultsValid = true;
  TaskPhase phase = TaskPhase.idle;
  ScanPlan? plan;
  bool importedPlan = false;
  String? error;
  String? notice;
  String? logPath;
  String stage = '';
  String currentPath = '';
  int current = 0;
  int bytesRead = 0;
  int? total;
  final Stopwatch clock = Stopwatch();
  final Set<String> selected = {};
  final Set<String> completed = {};
  final Map<int, FileRecord> keepOverrides = {};
  final Set<String> selectedFolders = {};
  final Set<String> completedFolders = {};
  final Map<int, FolderRecord> folderKeepOverrides = {};
  final List<Map<String, dynamic>> results = [];
  ReceivePort? _events;
  SendPort? _control;
  Isolate? _worker;
  Timer? _ticker;
  bool _cancelled = false;
  bool _disposed = false;

  bool get busy => switch (phase) {
    TaskPhase.scanning ||
    TaskPhase.importing ||
    TaskPhase.cleaning ||
    TaskPhase.cancelling => true,
    _ => false,
  };
  int get selectedCount =>
      resultMode == ResultMode.files ? selected.length : selectedFolders.length;
  int get selectedFileCount => resultMode == ResultMode.files
      ? selected.length
      : folderGroups.fold<int>(
          0,
          (sum, group) =>
              sum +
              [group.keep, ...group.candidates]
                  .where((folder) => selectedFolders.contains(key(folder.path)))
                  .fold<int>(0, (n, folder) => n + folder.fileCount),
        );
  int get selectedBytes => resultMode == ResultMode.folders
      ? folderGroups.fold<int>(
          0,
          (sum, group) =>
              sum +
              [group.keep, ...group.candidates]
                  .where((folder) => selectedFolders.contains(key(folder.path)))
                  .fold<int>(0, (n, folder) => n + folder.totalBytes),
        )
      : plan?.groups.fold<int>(
              0,
              (sum, group) =>
                  sum +
                  files(group)
                      .where((f) => selected.contains(key(f.path)))
                      .fold<int>(0, (n, f) => n + f.size),
            ) ??
            0;
  int get successCount => results
      .where((r) => r['status'] == 'deleted' || r['status'] == 'recycled')
      .length;
  int get problemCount =>
      (plan?.errors.length ?? 0) + (plan?.skipped.length ?? 0);
  static String key(String path) => p.windows.normalize(path).toLowerCase();

  List<DuplicateFolderGroup> get folderGroups =>
      folderResultsValid ? plan?.folderGroups ?? [] : [];
  FolderRecord folderKeeper(DuplicateFolderGroup group) =>
      folderKeepOverrides[group.id] ?? group.keep;
  bool isFolderKept(DuplicateFolderGroup group, FolderRecord folder) =>
      key(folderKeeper(group).path) == key(folder.path);

  /// 清理后分组会替换为新的不可变对象；旧界面回调只能操作当前计划中仍存在的成员。
  DuplicateFolderGroup? _currentFolderGroup(int id, String path) {
    for (final group in folderGroups) {
      if (group.id == id &&
          group.folders.any((f) => key(f.path) == key(path))) {
        return group;
      }
    }
    return null;
  }

  DuplicateGroup? _currentFileGroup(int id, String path) {
    for (final group in plan?.groups ?? <DuplicateGroup>[]) {
      if (group.id == id && group.files.any((f) => key(f.path) == key(path))) {
        return group;
      }
    }
    return null;
  }

  void setResultMode(ResultMode mode) {
    if (busy || mode == resultMode) return;
    resultMode = mode;
    notifyListeners();
  }

  void chooseFolderKeeper(DuplicateFolderGroup group, FolderRecord folder) {
    final currentGroup = _currentFolderGroup(group.id, folder.path);
    if (busy ||
        currentGroup == null ||
        !folderResultsValid ||
        completedFolders.contains(key(folder.path))) {
      return;
    }
    final previous = folderKeeper(currentGroup);
    folderKeepOverrides[group.id] = currentGroup.folders.firstWhere(
      (item) => key(item.path) == key(folder.path),
    );
    if (!completedFolders.contains(key(previous.path))) {
      selectedFolders.add(key(previous.path));
    }
    selectedFolders.remove(key(folder.path));
    notifyListeners();
  }

  void toggleFolder(
    DuplicateFolderGroup group,
    FolderRecord folder,
    bool value,
  ) {
    final currentGroup = _currentFolderGroup(group.id, folder.path);
    if (busy ||
        currentGroup == null ||
        !folderResultsValid ||
        isFolderKept(currentGroup, folder) ||
        completedFolders.contains(key(folder.path))) {
      return;
    }
    if (value) {
      selectedFolders.add(key(folder.path));
    } else {
      selectedFolders.remove(key(folder.path));
    }
    notifyListeners();
  }

  List<FileRecord> files(DuplicateGroup group) => [
    group.keep,
    ...group.candidates,
  ];
  FileRecord keeper(DuplicateGroup group) =>
      keepOverrides[group.id] ?? group.keep;
  bool isKept(DuplicateGroup group, FileRecord file) =>
      key(keeper(group).path) == key(file.path);

  /// 修改扫描配置即使旧计划失效，避免界面显示的新条件与实际清理范围不一致。
  void setDirectory(String value) {
    if (busy || (_roots.length == 1 && value == root)) return;
    _roots
      ..clear()
      ..addAll(value.trim().isEmpty ? [] : [value.trim()]);
    _discardPlan();
    notifyListeners();
  }

  /// 只接收完整绝对路径，并合并重复/嵌套扫描范围。磁盘访问权限在扫描时统一核对。
  void addDirectory(String value) {
    if (busy) return;
    var input = value.trim();
    if (input.startsWith('"') && input.endsWith('"') && input.length > 1) {
      input = input.substring(1, input.length - 1);
    }
    if (!p.windows.isAbsolute(input) || p.windows.isRootRelative(input)) {
      reportError('请输入包含盘符的完整文件夹路径或 UNC 路径。');
      return;
    }
    final normalized = p.windows.normalize(input);
    if (_roots.any(
      (existing) =>
          key(existing) == key(normalized) ||
          isPathWithinRoot(normalized, existing),
    )) {
      notice = '该目录已包含在当前扫描范围中。';
      notifyListeners();
      return;
    }
    _roots.removeWhere((existing) => isPathWithinRoot(existing, normalized));
    _roots.add(normalized);
    _discardPlan();
    notifyListeners();
  }

  void removeDirectory(String value) {
    if (busy) return;
    _roots.removeWhere((existing) => key(existing) == key(value));
    _discardPlan();
    notifyListeners();
  }

  Future<void> chooseDirectories() async {
    if (busy) return;
    try {
      for (final directory in await native.pickDirectories()) {
        addDirectory(directory);
      }
    } catch (e) {
      reportError(e);
    }
  }

  void setScanOptions({
    bool? includeEmpty,
    bool? includeHardlinks,
    bool? detectDuplicateFolders,
  }) {
    if (busy) return;
    final nextEmpty = includeEmpty ?? this.includeEmpty;
    final nextLinks = includeHardlinks ?? this.includeHardlinks;
    final nextFolders = detectDuplicateFolders ?? this.detectDuplicateFolders;
    if (nextEmpty == this.includeEmpty &&
        nextLinks == this.includeHardlinks &&
        nextFolders == this.detectDuplicateFolders) {
      return;
    }
    this.includeEmpty = nextEmpty;
    this.includeHardlinks = nextLinks;
    this.detectDuplicateFolders = nextFolders;
    _discardPlan();
    notifyListeners();
  }

  void _discardPlan() {
    plan = null;
    importedPlan = false;
    selected.clear();
    completed.clear();
    keepOverrides.clear();
    selectedFolders.clear();
    completedFolders.clear();
    folderKeepOverrides.clear();
    folderResultsValid = true;
    results.clear();
    logPath = null;
    notice = null;
    error = null;
    phase = TaskPhase.idle;
  }

  /// 保留对象切换时，旧保留文件成为候选，新保留文件从清理集合中移除。
  void chooseKeeper(DuplicateGroup group, FileRecord file) {
    final currentGroup = _currentFileGroup(group.id, file.path);
    if (busy || currentGroup == null || completed.contains(key(file.path))) {
      return;
    }
    final previous = keeper(currentGroup);
    keepOverrides[group.id] = currentGroup.files.firstWhere(
      (item) => key(item.path) == key(file.path),
    );
    if (!completed.contains(key(previous.path))) {
      selected.add(key(previous.path));
    }
    selected.remove(key(file.path));
    notifyListeners();
  }

  void toggleFile(DuplicateGroup group, FileRecord file, bool value) {
    final currentGroup = _currentFileGroup(group.id, file.path);
    if (busy ||
        currentGroup == null ||
        isKept(currentGroup, file) ||
        completed.contains(key(file.path))) {
      return;
    }
    if (value) {
      selected.add(key(file.path));
    } else {
      selected.remove(key(file.path));
    }
    notifyListeners();
  }

  void selectAll(bool value) {
    if (busy || plan == null) return;
    if (resultMode == ResultMode.folders) {
      selectedFolders.clear();
      if (value && folderResultsValid) {
        for (final group in folderGroups) {
          selectedFolders.addAll(
            [group.keep, ...group.candidates]
                .where(
                  (folder) =>
                      !isFolderKept(group, folder) &&
                      !completedFolders.contains(key(folder.path)),
                )
                .map((folder) => key(folder.path)),
          );
        }
      }
      notifyListeners();
      return;
    }
    selected.clear();
    if (value) {
      for (final group in plan!.groups) {
        selected.addAll(
          files(group)
              .where(
                (f) => !isKept(group, f) && !completed.contains(key(f.path)),
              )
              .map((f) => key(f.path)),
        );
      }
    }
    notifyListeners();
  }

  Future<void> chooseDirectory() async {
    if (busy) return;
    try {
      final path = await native.pickDirectory();
      if (path != null) {
        setDirectory(path);
      }
    } catch (e) {
      reportError(e);
    }
  }

  Future<void> startScan() async {
    if (busy) return;
    if (_roots.isEmpty) {
      reportError('请至少添加一个扫描目录。');
      return;
    }
    await _startWorker({
      'action': 'scan',
      'roots': List<String>.of(_roots),
      'includeEmpty': includeEmpty,
      'includeHardlinks': includeHardlinks,
      'detectDuplicateFolders': detectDuplicateFolders,
    }, TaskPhase.scanning);
  }

  Future<void> importPlan() async {
    if (busy) return;
    try {
      final path = await native.chooseJsonFile(save: false);
      if (path != null) {
        await _startWorker({
          'action': 'import',
          'path': path,
        }, TaskPhase.importing);
      }
    } catch (e) {
      reportError(e);
    }
  }

  Future<void> _startWorker(
    Map<String, Object?> request,
    TaskPhase next,
  ) async {
    _begin(next);
    try {
      await native.setBusy(true);
      _events = ReceivePort();
      _events!.listen((dynamic message) async {
        if (_disposed) return;
        if (message is List) {
          await _workerFailure(message.first.toString());
          return;
        }
        if (message is! Map) return;
        switch (message['type']) {
          case 'control':
            _control = message['port'] as SendPort;
            if (_cancelled) _control!.send('cancel');
          case 'progress':
            stage = message['stage'] as String? ?? stage;
            current = message['current'] as int? ?? 0;
            bytesRead = message['bytesRead'] as int? ?? bytesRead;
            total = message['total'] as int?;
            currentPath = message['path'] as String? ?? '';
            notifyListeners();
          case 'complete':
            try {
              if (!_cancelled) {
                _acceptPlan(
                  ScanPlan.fromJson(
                    Map<String, dynamic>.from(message['plan'] as Map),
                  ),
                );
              } else {
                notice = '任务已取消，未执行任何清理。';
              }
              await _finish();
            } catch (e) {
              await _workerFailure(e.toString());
            }
          case 'cancelled':
            notice = '任务已取消，未执行任何清理。';
            await _finish();
          case 'error':
            await _workerFailure(message['message'].toString());
        }
      });
      _worker = await Isolate.spawn(
        scanWorker,
        {
          ...request,
          'token': RootIsolateToken.instance!,
          'port': _events!.sendPort,
        },
        onError: _events!.sendPort,
        errorsAreFatal: true,
      );
    } catch (e) {
      await _workerFailure(e.toString());
    }
  }

  void _acceptPlan(ScanPlan next) {
    importedPlan = phase == TaskPhase.importing;
    plan = next;
    _roots
      ..clear()
      ..addAll(next.roots);
    includeEmpty = next.options.includeEmpty;
    includeHardlinks = next.options.includeHardlinks;
    detectDuplicateFolders = next.options.detectDuplicateFolders;
    // 文件夹专用计划导入后直接展示对应结果，避免落在空的文件列表中。
    if (importedPlan && next.groups.isEmpty && next.folderGroups.isNotEmpty) {
      resultMode = ResultMode.folders;
    }
    keepOverrides.clear();
    folderKeepOverrides.clear();
    selectedFolders.clear();
    completedFolders.clear();
    folderResultsValid = true;
    completed.clear();
    results.clear();
    logPath = null;
    selected.clear();
    for (final group in next.groups) {
      selected.addAll(group.candidates.map((f) => key(f.path)));
    }
    notice = importedPlan
        ? '计划复核完成：${next.groups.length} 组重复文件，${next.folderGroups.length} 组重复文件夹。'
        : '扫描完成：${next.groups.length} 组重复文件，${next.folderGroups.length} 组完整重复文件夹。请选择清理项。';
    if (next.errors.isNotEmpty) {
      notice = '$notice 有 ${next.errors.length} 项未能完成，请查看详情。';
    }
  }

  /// 只将当前选中的候选写入执行计划；显示统计不能控制实际删除数量。
  ScanPlan selectionPlan() {
    final original = plan!;
    if (resultMode == ResultMode.folders) {
      if (!folderResultsValid) throw StateError('文件已被清理，必须重新扫描后再处理整文件夹。');
      final folders = <DuplicateFolderGroup>[];
      for (final group in folderGroups) {
        final candidates = [group.keep, ...group.candidates]
            .where(
              (folder) =>
                  selectedFolders.contains(key(folder.path)) &&
                  !isFolderKept(group, folder) &&
                  !completedFolders.contains(key(folder.path)),
            )
            .toList();
        if (candidates.isNotEmpty) {
          folders.add(
            DuplicateFolderGroup(
              id: group.id,
              fingerprint: group.fingerprint,
              keep: folderKeeper(group),
              candidates: candidates,
            ),
          );
        }
      }
      final data = original.toJson();
      data['groups'] = <dynamic>[];
      data['folder_groups'] = folders.map((g) => g.toJson()).toList();
      return ScanPlan.fromJson(data);
    }
    final groups = <DuplicateGroup>[];
    for (final group in original.groups) {
      final candidates = files(group)
          .where(
            (f) =>
                selected.contains(key(f.path)) &&
                !isKept(group, f) &&
                !completed.contains(key(f.path)),
          )
          .toList();
      if (candidates.isNotEmpty) {
        groups.add(
          DuplicateGroup(
            id: group.id,
            size: group.size,
            sha256: group.sha256,
            keep: keeper(group),
            candidates: candidates,
          ),
        );
      }
    }
    final data = original.toJson();
    data['groups'] = groups.map((g) => g.toJson()).toList();
    data['folder_groups'] = <dynamic>[];
    return ScanPlan.fromJson(data);
  }

  Future<void> exportPlan() async {
    if (busy || plan == null) return;
    try {
      final path = await native.chooseJsonFile(save: true);
      if (path == null) return;
      if (plan!.groups.any(
            (g) => files(g).any((f) => key(f.path) == key(path)),
          ) ||
          plan!.folderGroups.any(
            (group) => [group.keep, ...group.candidates].any(
              (folder) =>
                  key(folder.path) == key(path) ||
                  isPathWithinRoot(path, folder.path),
            ),
          )) {
        throw StateError('计划应保存到重复文件及完整重复文件夹之外，避免修改待复核内容。');
      }
      await _writeJson(path, selectionPlan().toJson());
      notice = '已导出当前勾选的清理计划：$path';
      notifyListeners();
    } catch (e) {
      reportError(e);
    }
  }

  Future<void> clean({required bool permanent}) async {
    if (busy || selectedCount == 0 || plan == null) return;
    final cleaningFolders = resultMode == ResultMode.folders;
    late final ScanPlan frozen;
    try {
      frozen = selectionPlan();
    } catch (e) {
      reportError(e);
      return;
    }
    _begin(TaskPhase.cleaning);
    results.clear();
    RandomAccessFile? journal;
    final changes = _CleanupChanges();
    var partiallyCompleted = false;
    try {
      await native.setBusy(true);
      await native.resetCancellation();
      final folder = Directory(
        historyDirectory ??
            p.join(
              Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
              'DupeFileCleaner',
              'history',
            ),
      );
      await folder.create(recursive: true);
      final stamp = DateTime.now().toUtc().microsecondsSinceEpoch;
      final savedPlan = p.join(folder.path, 'plan-$stamp.json');
      await _writeJson(savedPlan, frozen.toJson());
      logPath = p.join(folder.path, 'cleanup-$stamp.jsonl');
      journal = await File(logPath!).open(mode: FileMode.write);
      await _append(journal, {
        'type': 'begin',
        'plan': savedPlan,
        'mode': permanent ? 'permanent' : 'recycle',
        'root': frozen.root,
        'roots': frozen.roots,
        'kind': cleaningFolders ? 'folder' : 'file',
      });
      total = cleaningFolders
          ? frozen.folderGroups.fold<int>(0, (n, g) => n + g.candidates.length)
          : frozen.groups.fold<int>(0, (n, g) => n + g.candidates.length);
      stage = cleaningFolders
          ? '完整复核文件夹并清理'
          : permanent
          ? '正在复核并永久删除'
          : '正在复核并移入回收站';

      // 将两种任务转换为同一执行队列，但每个队列只含一种粒度，彼此不交叉。
      final tasks =
          <
            ({
              int groupId,
              String path,
              String keep,
              Future<Map<String, dynamic>> Function() run,
            })
          >[];
      if (cleaningFolders) {
        for (final group in frozen.folderGroups) {
          for (final candidate in group.candidates) {
            tasks.add((
              groupId: group.id,
              path: candidate.path,
              keep: group.keep.path,
              run: () => native.cleanFolder(
                plan: frozen,
                group: group,
                candidate: candidate,
                permanent: permanent,
              ),
            ));
          }
        }
      } else {
        for (final group in frozen.groups) {
          for (final candidate in group.candidates) {
            tasks.add((
              groupId: group.id,
              path: candidate.path,
              keep: group.keep.path,
              run: () => native.cleanFile(
                plan: frozen,
                group: group,
                candidate: candidate,
                permanent: permanent,
              ),
            ));
          }
        }
      }
      for (final task in tasks) {
        if (_cancelled) break;
        currentPath = task.path;
        notifyListeners();
        // 先保存操作意图；完整目录的 result 还携带原生逐项结果，部分完成时必须重扫。
        await _append(journal, {
          'type': 'intent',
          'path': task.path,
          'keep': task.keep,
          'kind': cleaningFolders ? 'folder' : 'file',
        });
        late final Map<String, dynamic> result;
        try {
          result = await task.run();
        } catch (_) {
          // 意图已经落盘、原生调用却没有返回时，不能假定目标未变；只隔离该任务关联结果。
          changes.markUncertain(
            cleaningFolders,
            task.groupId,
            task.path,
            task.keep,
          );
          rethrow;
        }
        results.add(result);
        if (result['status'] == 'deleted' || result['status'] == 'recycled') {
          if (cleaningFolders) {
            completedFolders.add(key(task.path));
            selectedFolders.remove(key(task.path));
            changes.deletedFolders.add(task.path);
          } else {
            completed.add(key(task.path));
            selected.remove(key(task.path));
            changes.deletedFiles.add(task.path);
          }
        } else if (!{
          'skipped',
          'error',
          'cancelled',
        }.contains(result['status'])) {
          // partial 或未知状态都要求停止本批次，但不能影响与该任务无关的分组。
          changes.markUncertain(
            cleaningFolders,
            task.groupId,
            task.path,
            task.keep,
          );
          partiallyCompleted = true;
        }
        // 成功事实先写入 changes，再尝试保存日志；即使日志失败，finally 仍会更新剩余结果。
        await _append(journal, {'type': 'result', ...result});
        current++;
        notifyListeners();
        if (result['status'] == 'cancelled') {
          _cancelled = true;
          break;
        }
        if (partiallyCompleted) {
          break;
        }
      }
      await _append(journal, {
        'type': 'finish',
        'cancelled': _cancelled,
        'processed': current,
        'succeeded': successCount,
        'partial': partiallyCompleted,
      });
      notice =
          '${_cancelled || partiallyCompleted ? '清理已停止' : '清理完成'}：成功 $successCount 项，其他 ${results.length - successCount} 项。日志已保存。';
    } catch (e) {
      error = '清理已停止：$e。请查看日志后再决定是否重试。';
    } finally {
      if (changes.hasChanges) {
        // 每批只重建一次结果，避免清理大量候选时反复复制整个计划。
        _applyCleanupChanges(changes);
        final explanation = changes.hasUncertain
            ? '结果不确定的相关分组已移除，需要重新扫描；其他结果保持可用。'
            : '已更新受影响的结果，其余副本可继续选择清理。';
        notice = notice == null ? explanation : '$notice $explanation';
      }
      try {
        await journal?.close();
      } catch (_) {
        /* 已展示写入失败，仍需恢复界面状态。 */
      }
      await _finish();
    }
  }

  /// 根据已知执行结果更新剩余计划，保留分组编号及与操作无关的人工选择。
  ///
  /// 成功删除只剪去消失的成员；不确定结果则隔离关联分组。这里不刷新磁盘快照，
  /// 防止把外部内容变化“认可”为新结果；下次执行仍由原生层重新检查身份和完整内容。
  void _applyCleanupChanges(_CleanupChanges changes) {
    final original = plan;
    if (original == null) return;
    bool inside(String path, String directory) =>
        key(path) == key(directory) || isPathWithinRoot(path, directory);
    bool removedByFolder(String path) =>
        changes.deletedFolders.any((directory) => inside(path, directory));
    final remainingFiles = <DuplicateGroup>[];
    for (final group in original.groups) {
      if (changes.uncertainFileGroups.contains(group.id) ||
          group.files.any(
            (file) => changes.uncertainFolderPaths.any(
              (directory) => inside(file.path, directory),
            ),
          )) {
        continue;
      }
      final survivors = group.files
          .where(
            (file) =>
                !completed.contains(key(file.path)) &&
                !removedByFolder(file.path),
          )
          .toList();
      if (survivors.length < 2) continue;
      var retained = keeper(group);
      if (!survivors.any((file) => key(file.path) == key(retained.path))) {
        // 原文件保留项可能随整个目录被删；从仍然存在的副本中补选，并保护其不被勾选。
        survivors.sort((a, b) {
          final time = a.mtimeNs.compareTo(b.mtimeNs);
          return time != 0 ? time : key(a.path).compareTo(key(b.path));
        });
        retained = survivors.first;
        keepOverrides.remove(group.id);
      }
      remainingFiles.add(
        DuplicateGroup(
          id: group.id,
          size: group.size,
          sha256: group.sha256,
          keep: retained,
          candidates: survivors
              .where((file) => key(file.path) != key(retained.path))
              .toList(),
        ),
      );
    }

    final remainingFolders = <DuplicateFolderGroup>[];
    for (final group in original.folderGroups) {
      if (changes.uncertainFolderGroups.contains(group.id)) continue;
      final survivors = group.folders
          .where(
            (folder) =>
                !removedByFolder(folder.path) &&
                !changes.deletedFiles.any(
                  (path) => inside(path, folder.path),
                ) &&
                !changes.uncertainFilePaths.any(
                  (path) => inside(path, folder.path),
                ),
          )
          .toList();
      if (survivors.length < 2) continue;
      var retained = folderKeeper(group);
      if (!survivors.any((folder) => key(folder.path) == key(retained.path))) {
        // 单文件清理可能破坏原保留目录；只有至少两棵完整副本尚存时才保留目录组。
        survivors.sort((a, b) => key(a.path).compareTo(key(b.path)));
        retained = survivors.first;
        folderKeepOverrides.remove(group.id);
      }
      remainingFolders.add(
        DuplicateFolderGroup(
          id: group.id,
          fingerprint: group.fingerprint,
          keep: retained,
          candidates: survivors
              .where((folder) => key(folder.path) != key(retained.path))
              .toList(),
        ),
      );
    }

    // 已被完整删除的扫描根必须同时从计划移除，否则再次导入剩余计划会检查不存在的根。
    // 不确定且已经没有任何结果引用的目标根也退出计划，其余扫描范围继续保留。
    final retainedPaths = [
      for (final group in remainingFiles)
        ...group.files.map((file) => file.path),
      for (final group in remainingFolders)
        ...group.folders.map((folder) => folder.path),
    ];
    var roots = original.roots
        .where(
          (root) =>
              !removedByFolder(root) &&
              !(changes.uncertainFolderPaths.any(
                    (path) => inside(root, path),
                  ) &&
                  !retainedPaths.any((path) => inside(path, root))),
        )
        .toList();
    if (roots.isEmpty) {
      // 全部结果均已隔离时保留尚未确认删除的扫描范围，供用户主动重新扫描。
      roots = original.roots.where((root) => !removedByFolder(root)).toList();
    }
    plan = ScanPlan(
      roots: roots,
      options: original.options,
      groups: remainingFiles,
      folderGroups: remainingFolders,
      errors: original.errors,
      skipped: original.skipped,
      scannedFiles: original.scannedFiles,
      scannedBytes: original.scannedBytes,
      visitedEntries: original.visitedEntries,
      elapsedMs: original.elapsedMs,
      generatedAt: original.generatedAt,
      sourceVersion: original.sourceVersion,
    );
    _roots
      ..clear()
      ..addAll(roots);
    final fileKeepers = {
      for (final group in remainingFiles) group.id: group.keep,
    };
    final folderKeepers = {
      for (final group in remainingFolders) group.id: group.keep,
    };
    keepOverrides.removeWhere(
      (id, file) => key(fileKeepers[id]?.path ?? '') != key(file.path),
    );
    folderKeepOverrides.removeWhere(
      (id, folder) => key(folderKeepers[id]?.path ?? '') != key(folder.path),
    );
    selected.retainAll({
      for (final group in remainingFiles)
        ...group.candidates.map((file) => key(file.path)),
    });
    selectedFolders.retainAll({
      for (final group in remainingFolders)
        ...group.candidates.map((folder) => key(folder.path)),
    });
  }

  Future<void> cancel() async {
    if (!busy || _cancelled) return;
    _cancelled = true;
    phase = TaskPhase.cancelling;
    _control?.send('cancel');
    try {
      await native.cancelNative();
    } catch (e) {
      error = '取消请求：$e';
    }
    notifyListeners();
  }

  void _begin(TaskPhase next) {
    if (next == TaskPhase.scanning || next == TaskPhase.importing) {
      // 新任务开始即清除旧选择，防止失败后界面显示新目录、清理却作用于旧计划。
      plan = null;
      importedPlan = false;
      selected.clear();
      completed.clear();
      keepOverrides.clear();
      selectedFolders.clear();
      completedFolders.clear();
      folderKeepOverrides.clear();
      folderResultsValid = true;
      results.clear();
      logPath = null;
    }
    error = null;
    notice = null;
    _cancelled = false;
    stage = next == TaskPhase.importing ? '正在读取并复核计划' : '准备任务';
    currentPath = '';
    current = 0;
    bytesRead = 0;
    total = null;
    phase = next;
    clock
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed) notifyListeners();
    });
    notifyListeners();
  }

  Future<void> _workerFailure(String message) async {
    error = message;
    await _finish();
  }

  Future<void> _finish() async {
    clock.stop();
    _ticker?.cancel();
    _events?.close();
    _events = null;
    _control = null;
    // 正常完成的隔离区会自行退出；这里释放引用，不在文件读取中途强杀。
    _worker = null;
    try {
      await native.setBusy(false);
    } catch (e) {
      error ??= e.toString();
    }
    phase = plan == null ? TaskPhase.idle : TaskPhase.ready;
    if (!_disposed) notifyListeners();
  }

  void reportError(Object value) {
    error = value.toString();
    notifyListeners();
  }

  /// 同目录临时文件后重命名，防止写到一半留下看似完整的 JSON 计划。
  Future<void> _writeJson(String path, Map<String, dynamic> value) async {
    final temporary = File(
      '$path.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.writeAsString(
        '${const JsonEncoder.withIndent('  ').convert(value)}\n',
        flush: true,
      );
      await temporary.rename(path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> _append(
    RandomAccessFile file,
    Map<String, dynamic> entry,
  ) async {
    await file.writeString(
      '${jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), ...entry})}\n',
    );
    await file.flush();
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    _control?.send('cancel');
    _events?.close();
    _worker?.kill(priority: Isolate.beforeNextEvent);
    super.dispose();
  }
}

/// 记录本批次已经发生的变化，独立于日志写入结果；不确定目标必须在返回界面前隔离。
class _CleanupChanges {
  final Set<String> deletedFiles = {};
  final Set<String> deletedFolders = {};
  final Set<int> uncertainFileGroups = {};
  final Set<int> uncertainFolderGroups = {};
  final Set<String> uncertainFilePaths = {};
  final Set<String> uncertainFolderPaths = {};
  bool get hasUncertain =>
      uncertainFileGroups.isNotEmpty || uncertainFolderGroups.isNotEmpty;
  bool get hasChanges =>
      deletedFiles.isNotEmpty || deletedFolders.isNotEmpty || hasUncertain;

  void markUncertain(bool folders, int groupId, String path, String keep) {
    if (folders) {
      uncertainFolderGroups.add(groupId);
      uncertainFolderPaths.addAll([path, keep]);
    } else {
      uncertainFileGroups.add(groupId);
      uncertainFilePaths.addAll([path, keep]);
    }
  }
}
