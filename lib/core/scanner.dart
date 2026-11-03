import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

/// 隔离操作系统元数据访问，以便生产环境使用 Windows 原生接口、测试使用临时文件。
abstract class FileInspector {
  Future<FileRecord> inspect(String path);
}

/// 取消是正常的用户操作，不应当混入扫描错误清单。
class ScanCancelled implements Exception {
  const ScanCancelled();

  @override
  String toString() => '扫描已取消。';
}

/// 文件从枚举到计算摘要期间发生变化时，整条记录退出候选集合。
class FileChangedDuringScan implements Exception {
  const FileChangedDuringScan(this.path);

  final String path;

  @override
  String toString() => '文件在扫描过程中发生变化：$path';
}

/// 完成“枚举 → 大小分组 → 快速摘要 → 完整 SHA-256”的只读扫描。
///
/// 应在后台 isolate 中使用。每个读取块之间都会让出事件循环，保证取消消息可以被处理；
/// 每次扫描只有一个文件正在读取，避免机械硬盘随机寻道和大量并发缓冲区占用。
class DuplicateScanner {
  DuplicateScanner({
    required this.inspector,
    this.onProgress,
    this.folderEntryLimit = maxFolderManifestEntries,
    bool Function()? isCancelled,
  }) : isCancelled = isCancelled ?? _neverCancelled {
    if (folderEntryLimit < 1 || folderEntryLimit > maxFolderManifestEntries) {
      throw ArgumentError.value(
        folderEntryLimit,
        'folderEntryLimit',
        '必须在 1 到原生上限之间',
      );
    }
  }

  static const int hashChunkSize = 4 * 1024 * 1024;
  static const int quickHashBytes = 128 * 1024;

  final FileInspector inspector;
  final void Function(Map<String, Object?>)? onProgress;
  final bool Function() isCancelled;

  /// 允许测试或调用方采用更严格的树规模限制，但不能绕过原生句柄数量上限。
  final int folderEntryLimit;

  int _bytesRead = 0;
  int _lastProgressMs = -1000;
  final Stopwatch _clock = Stopwatch();

  static bool _neverCancelled() => false;

  /// 兼容已有单目录调用；所有实际扫描都通过统一的多根目录流程完成。
  Future<ScanPlan> scan(String root, ScanOptions options) =>
      scanRoots([root], options);

  /// 多个根目录共用候选池，因此可以识别分别位于不同磁盘或文件夹中的副本。
  /// 重复根和被父根覆盖的子根只遍历一次，并保留其余根的输入顺序。
  Future<ScanPlan> scanRoots(List<String> roots, ScanOptions options) async {
    _clock
      ..reset()
      ..start();
    _bytesRead = 0;
    _lastProgressMs = -1000;
    final uniqueRoots = <String>[];
    for (final value in roots) {
      final absolute = p.normalize(p.absolute(value));
      if (!uniqueRoots.any(
        (old) => canonicalWindowsPath(old) == canonicalWindowsPath(absolute),
      )) {
        uniqueRoots.add(absolute);
      }
    }
    final effectiveRoots = uniqueRoots
        .where(
          (value) => !uniqueRoots.any(
            (other) =>
                canonicalWindowsPath(value) != canonicalWindowsPath(other) &&
                isPathWithinRoot(value, other),
          ),
        )
        .toList();
    if (effectiveRoots.isEmpty) throw const FileSystemException('请至少选择一个扫描目录。');

    final errors = <Map<String, String>>[];
    final skipped = <Map<String, String>>[];
    final sizeGroups = <int, List<FileRecord>>{};
    final stack = <_FolderNode>[];
    final nodes = <_FolderNode>[];
    final ownerByFile = <String, _FolderNode>{};
    final visitedDirectories = <String>{};
    final fileDigests = <String, String>{};
    var visitedEntries = 0;
    var scannedFiles = 0;
    var scannedBytes = 0;
    for (final root in effectiveRoots) {
      _checkCancelled();
      final record = await inspector.inspect(root);
      if (!record.isDirectory ||
          record.isReparsePoint ||
          !record.hasIdentity ||
          canonicalWindowsPath(record.finalPath) !=
              canonicalWindowsPath(root)) {
        throw FileSystemException('扫描根目录无效、无法获取身份或通过链接访问。', root);
      }
      final node = _FolderNode(record);
      stack.add(node);
      nodes.add(node);
    }

    _report('enumerating', 0, force: true);
    while (stack.isNotEmpty) {
      _checkCancelled();
      final node = stack.removeLast();
      final directory = node.directory.path;
      try {
        final currentDirectory = await inspector.inspect(directory);
        if (!node.directory.sameSnapshot(currentDirectory)) {
          node.complete = false;
          skipped.add({'path': directory, 'reason': '目录在扫描期间被替换或发生变化。'});
          continue;
        }
        if (!visitedDirectories.add(
          '${currentDirectory.volumeId}:${currentDirectory.fileId}',
        )) {
          node.complete = false;
          skipped.add({'path': directory, 'reason': '同一目录已访问，已避免重复遍历。'});
          continue;
        }
        // 逐层枚举可显式捕获权限错误；任何遗漏都会使此目录失去整目录清理资格。
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false)) {
          _checkCancelled();
          visitedEntries++;
          _report('enumerating', visitedEntries, path: entity.path);
          try {
            final info = await inspector.inspect(entity.path);
            _checkCancelled();
            if (entity is Link || info.isReparsePoint) {
              node.complete = false;
              skipped.add({
                'path': info.path,
                'reason': '已跳过重解析点；所属目录树不会整目录清理。',
              });
              continue;
            }
            if (!isPathWithinRoots(info.path, effectiveRoots) ||
                !isPathWithinRoots(info.finalPath, effectiveRoots) ||
                canonicalWindowsPath(info.path) !=
                    canonicalWindowsPath(info.finalPath) ||
                !info.hasIdentity) {
              node.complete = false;
              skipped.add({'path': info.path, 'reason': '文件位置或身份不可靠，已跳过。'});
              continue;
            }
            if (info.isDirectory) {
              final child = _FolderNode(info, parent: node);
              node.children.add(child);
              nodes.add(child);
              stack.add(child);
              continue;
            }
            // 目录清单独立于文件过滤选项：空文件不能因为未勾选选项而从目录比较中消失。
            node.files.add(info);
            ownerByFile[canonicalWindowsPath(info.path)] = node;
            if (info.linkCount > 1) node.complete = false;
            if (info.size == 0 && !options.includeEmpty) {
              skipped.add({
                'path': info.path,
                'reason': '文件判重默认跳过 0 字节文件；目录完整性比较仍包含它。',
              });
              continue;
            }
            if (info.linkCount > 1 && !options.includeHardlinks) {
              skipped.add({
                'path': info.path,
                'reason': '默认跳过硬链接（当前链接数 ${info.linkCount}）。',
              });
              continue;
            }
            sizeGroups.putIfAbsent(info.size, () => []).add(info);
            scannedFiles++;
            scannedBytes += info.size;
          } on ScanCancelled {
            rethrow;
          } catch (error) {
            node.complete = false;
            errors.add({'path': entity.path, 'error': error.toString()});
          }
        }
      } on ScanCancelled {
        rethrow;
      } catch (error) {
        node.complete = false;
        errors.add({'path': directory, 'error': error.toString()});
      }
    }
    _report('enumerating', visitedEntries, force: true);

    final quickCandidates = _candidateFiles(sizeGroups);
    final quickGroups = <String, List<FileRecord>>{};
    _report('quick_hash', 0, total: quickCandidates.length, force: true);
    for (var index = 0; index < quickCandidates.length; index++) {
      _checkCancelled();
      final info = quickCandidates[index];
      try {
        final digest = await _hashStable(
          info,
          quick: true,
          stage: 'quick_hash',
          current: index,
          total: quickCandidates.length,
        );
        quickGroups.putIfAbsent('${info.size}:$digest', () => []).add(info);
      } on ScanCancelled {
        rethrow;
      } catch (error) {
        ownerByFile[canonicalWindowsPath(info.path)]?.complete = false;
        errors.add({'path': info.path, 'error': error.toString()});
      }
      _report(
        'quick_hash',
        index + 1,
        total: quickCandidates.length,
        path: info.path,
      );
    }
    _report(
      'quick_hash',
      quickCandidates.length,
      total: quickCandidates.length,
      force: true,
    );

    final fullCandidates = _candidateFiles(quickGroups);
    final fullGroups = <String, List<FileRecord>>{};
    _report('full_hash', 0, total: fullCandidates.length, force: true);
    for (var index = 0; index < fullCandidates.length; index++) {
      _checkCancelled();
      final info = fullCandidates[index];
      try {
        final digest = await _hashStable(
          info,
          quick: false,
          stage: 'full_hash',
          current: index,
          total: fullCandidates.length,
        );
        fileDigests[canonicalWindowsPath(info.path)] = digest;
        fullGroups.putIfAbsent('${info.size}:$digest', () => []).add(info);
      } on ScanCancelled {
        rethrow;
      } catch (error) {
        ownerByFile[canonicalWindowsPath(info.path)]?.complete = false;
        errors.add({'path': info.path, 'error': error.toString()});
      }
      _report(
        'full_hash',
        index + 1,
        total: fullCandidates.length,
        path: info.path,
      );
    }
    _report(
      'full_hash',
      fullCandidates.length,
      total: fullCandidates.length,
      force: true,
    );

    final pendingGroups = <DuplicateGroup>[];
    for (final entry in fullGroups.entries) {
      final files = entry.value;
      if (files.length < 2) continue;
      files.sort((left, right) {
        final order = left.mtimeNs.compareTo(right.mtimeNs);
        return order != 0
            ? order
            : canonicalWindowsPath(left.path)
                  .compareTo(canonicalWindowsPath(right.path));
      });
      pendingGroups.add(
        DuplicateGroup(
          id: 1,
          size: files.first.size,
          sha256: entry.key.substring(entry.key.indexOf(':') + 1),
          keep: files.first,
          candidates: files.sublist(1),
        ),
      );
    }
    pendingGroups.sort(
      (left, right) =>
          canonicalWindowsPath(left.keep.path)
              .compareTo(canonicalWindowsPath(right.keep.path)),
    );
    final groups = [
      for (var i = 0; i < pendingGroups.length; i++)
        DuplicateGroup(
          id: i + 1,
          size: pendingGroups[i].size,
          sha256: pendingGroups[i].sha256,
          keep: pendingGroups[i].keep,
          candidates: pendingGroups[i].candidates,
        ),
    ];

    final folderGroups = options.detectDuplicateFolders
        ? await _findDuplicateFolders(nodes, fileDigests, errors, skipped)
        : <DuplicateFolderGroup>[];
    _checkCancelled();
    _clock.stop();
    _report(
      'completed',
      fullCandidates.length,
      total: fullCandidates.length,
      force: true,
    );
    return ScanPlan(
      roots: effectiveRoots,
      options: options,
      groups: groups,
      folderGroups: folderGroups,
      errors: errors,
      skipped: skipped,
      scannedFiles: scannedFiles,
      scannedBytes: scannedBytes,
      visitedEntries: visitedEntries,
      elapsedMs: _clock.elapsedMilliseconds,
      generatedAt: DateTime.now(),
    );
  }

  /// 通过紧凑的树摘要筛选完整重复目录，最终入选的互不重叠目录才展开执行清单。
  ///
  /// 每个节点仅记录直接文件和子目录的摘要，避免为每一级祖先复制全部后代路径。
  /// 结构摘要先筛掉不可能重复的树，内容摘要再复用已有文件哈希；两者均包含空目录。
  /// 不完整节点会向祖先传播失效状态，超出原生规模限制的父树则只退出候选，
  /// 其中较小、完整的子树仍可继续参与比较。
  Future<List<DuplicateFolderGroup>> _findDuplicateFolders(
    List<_FolderNode> nodes,
    Map<String, String> digests,
    List<Map<String, String>> errors,
    List<Map<String, String>> skipped,
  ) async {
    final summaries = <_FolderNode, _FolderSummary>{};
    final byStructure = <String, List<_FolderNode>>{};
    final ordered = [...nodes]
      ..sort(
        (a, b) => b.directory.path.length.compareTo(a.directory.path.length),
      );
    for (final node in ordered) {
      _checkCancelled();
      if (node.children.any((child) => !child.complete)) node.complete = false;
      if (!node.complete) continue;
      try {
        if (!node.directory.sameSnapshot(
          await inspector.inspect(node.directory.path),
        )) {
          throw FileChangedDuringScan(node.directory.path);
        }
      } on ScanCancelled {
        rethrow;
      } catch (error) {
        node.complete = false;
        errors.add({'path': node.directory.path, 'error': error.toString()});
        continue;
      }

      // Windows 可显式启用区分大小写目录；遇到大小写折叠后的同名项时保守跳过，
      // 避免扫描成功却在主线程反序列化时因重复清单路径导致整份计划失败。
      final names = <String>{};
      if ([...node.files, ...node.children.map((child) => child.directory)].any(
        (entry) => !names.add(canonicalWindowsPath(p.basename(entry.path))),
      )) {
        node.complete = false;
        errors.add({
          'path': node.directory.path,
          'error': '目录含大小写折叠后重名的项目，不能整目录清理。',
        });
        continue;
      }
      final summary = _FolderSummary(
        entryCount:
            node.files.length +
            node.children.fold<int>(
              0,
              (count, child) => count + 1 + summaries[child]!.entryCount,
            ),
        fileCount:
            node.files.length +
            node.children.fold<int>(
              0,
              (count, child) => count + summaries[child]!.fileCount,
            ),
        structure: _treeDigest(node, summaries),
      );
      summaries[node] = summary;
      final canonical = canonicalWindowsPath(node.directory.path);
      if (summary.fileCount == 0 ||
          summary.entryCount > folderEntryLimit ||
          p.windows.dirname(canonical) == canonical) {
        continue;
      }
      byStructure.putIfAbsent(summary.structure, () => []).add(node);
    }
    for (final entry in summaries.entries) {
      if (entry.value.entryCount > folderEntryLimit &&
          (summaries[entry.key.parent]?.entryCount ?? 0) <= folderEntryLimit) {
        skipped.add({
          'path': entry.key.directory.path,
          'reason':
              '目录包含 ${entry.value.entryCount} 个子项，超过整目录清理上限 $folderEntryLimit；仍检查符合上限的子文件夹。',
        });
      }
    }
    final candidates = byStructure.values
        .where((items) => items.length > 1)
        .expand((items) => items)
        .toList();

    // 多个候选可能互为祖先/后代。一次遍历它们的并集即可收集所需文件，
    // 不再为每个祖先重复遍历、保存或重新检查相同子树。
    final neededNodes = <_FolderNode>{};
    final needed = <String, FileRecord>{};
    final pending = [...candidates];
    while (pending.isNotEmpty) {
      _checkCancelled();
      final node = pending.removeLast();
      if (!neededNodes.add(node)) continue;
      pending.addAll(node.children);
      for (final file in node.files) {
        needed[canonicalWindowsPath(file.path)] = file;
      }
    }
    final failed = <String>{};
    var current = 0;
    _report('folder_hash', 0, total: needed.length, force: true);
    for (final entry in needed.entries) {
      _checkCancelled();
      try {
        if (digests.containsKey(entry.key)) {
          // 复用摘要之前也检查原始快照，避免较早的文件摘要覆盖后续变化。
          if (!entry.value.sameSnapshot(
            await inspector.inspect(entry.value.path),
          )) {
            throw FileChangedDuringScan(entry.value.path);
          }
        } else {
          digests[entry.key] = await _hashStable(
            entry.value,
            quick: false,
            stage: 'folder_hash',
            current: current,
            total: needed.length,
          );
        }
      } on ScanCancelled {
        rethrow;
      } catch (error) {
        failed.add(entry.key);
        errors.add({'path': entry.value.path, 'error': error.toString()});
      }
      current++;
      _report(
        'folder_hash',
        current,
        total: needed.length,
        path: entry.value.path,
      );
    }
    // 从叶子向上计算内容树摘要；一次目录快照复核即可使失败传播到所有候选祖先。
    for (final node in ordered) {
      _checkCancelled();
      if (!neededNodes.contains(node) ||
          node.files.any(
            (file) => failed.contains(canonicalWindowsPath(file.path)),
          ) ||
          node.children.any((child) => summaries[child]!.content == null)) {
        continue;
      }
      try {
        if (!node.directory.sameSnapshot(
          await inspector.inspect(node.directory.path),
        )) {
          throw FileChangedDuringScan(node.directory.path);
        }
        summaries[node]!.content = _treeDigest(
          node,
          summaries,
          digests: digests,
        );
      } on ScanCancelled {
        rethrow;
      } catch (error) {
        errors.add({'path': node.directory.path, 'error': error.toString()});
      }
    }
    final exactGroups = <String, List<_FolderNode>>{};
    for (final node in candidates) {
      final content = summaries[node]!.content;
      if (content != null) {
        exactGroups.putIfAbsent(content, () => []).add(node);
      }
    }
    final matching =
        exactGroups.entries.where((entry) => entry.value.length > 1).toList()
          ..sort((a, b) {
            final countA = summaries[a.value.first]!.entryCount;
            final countB = summaries[b.value.first]!.entryCount;
            final count = countB.compareTo(countA);
            return count != 0
                ? count
                : canonicalWindowsPath(a.value.first.directory.path).compareTo(
                    canonicalWindowsPath(b.value.first.directory.path),
                  );
          });
    final occupied = _FolderCoverage();
    final result = <DuplicateFolderGroup>[];
    for (final entry in matching) {
      // 先保留最大完整副本；被已选父目录覆盖的子目录不再另列为可删除组。
      final available =
          entry.value
              .where((node) => !occupied.overlaps(node.directory.path))
              .toList()
            ..sort(
              (a, b) =>
                  canonicalWindowsPath(a.directory.path)
                      .compareTo(canonicalWindowsPath(b.directory.path)),
            );
      if (available.length < 2) continue;
      final folders = <FolderRecord>[];
      for (final node in available) {
        occupied.add(node.directory.path);
        folders.add(_buildFolderManifest(node, digests));
      }
      result.add(
        DuplicateFolderGroup(
          id: result.length + 1,
          // 执行计划沿用既有扁平清单指纹，Merkle 摘要只作为扫描器内部索引。
          fingerprint: folderFingerprint(folders.first),
          keep: folders.first,
          candidates: folders.skip(1).toList(),
        ),
      );
    }
    _report('folder_hash', needed.length, total: needed.length, force: true);
    return result;
  }

  /// 对直接文件及子目录摘要排序后编码，名称、类型、大小及内容的边界均明确可辨。
  /// 不传 digests 时仅计算结构，传入时递归引用子节点已经完成的内容摘要。
  String _treeDigest(
    _FolderNode node,
    Map<_FolderNode, _FolderSummary> summaries, {
    Map<String, String>? digests,
  }) {
    final files =
        node.files
            .map(
              (file) => <Object>[
                canonicalWindowsPath(p.basename(file.path)),
                file.size,
                if (digests != null) digests[canonicalWindowsPath(file.path)]!,
              ],
            )
            .toList()
          ..sort((a, b) => (a.first as String).compareTo(b.first as String));
    final directories =
        node.children
            .map(
              (child) => <Object>[
                canonicalWindowsPath(p.basename(child.directory.path)),
                digests == null
                    ? summaries[child]!.structure
                    : summaries[child]!.content!,
              ],
            )
            .toList()
          ..sort((a, b) => (a.first as String).compareTo(b.first as String));
    return sha256
        .convert(utf8.encode(jsonEncode([directories, files])))
        .toString();
  }

  /// 仅最终被选中的互不重叠目录展开相对路径清单，因此每个磁盘项目最多输出一次。
  FolderRecord _buildFolderManifest(
    _FolderNode root,
    Map<String, String> digests,
  ) {
    final files = <FolderFileEntry>[];
    final directories = <FolderDirectoryEntry>[];
    final pending = <({_FolderNode node, String prefix})>[
      (node: root, prefix: ''),
    ];
    while (pending.isNotEmpty) {
      _checkCancelled();
      final current = pending.removeLast();
      for (final file in current.node.files) {
        files.add(
          FolderFileEntry(
            relativePath: p.join(current.prefix, p.basename(file.path)),
            record: file,
            sha256: digests[canonicalWindowsPath(file.path)]!,
          ),
        );
      }
      for (final child in current.node.children) {
        final relative = p.join(
          current.prefix,
          p.basename(child.directory.path),
        );
        directories.add(
          FolderDirectoryEntry(relativePath: relative, record: child.directory),
        );
        pending.add((node: child, prefix: relative));
      }
    }
    return FolderRecord(
      directory: root.directory,
      files: files,
      directories: directories,
    );
  }

  /// 只保留至少有两个成员的分组，独有大小或独有快速摘要的文件无需再读。
  List<FileRecord> _candidateFiles<K>(Map<K, List<FileRecord>> groups) => groups
      .values
      .where((files) => files.length >= 2)
      .expand((files) => files)
      .toList();

  /// 以最初枚举快照作为唯一基线，读取前后都对比，防止阶段之间变化被忽略。
  Future<String> _hashStable(
    FileRecord expected, {
    required bool quick,
    required String stage,
    required int current,
    required int total,
  }) async {
    _checkCancelled();
    final before = await inspector.inspect(expected.path);
    if (!expected.sameSnapshot(before)) {
      throw FileChangedDuringScan(expected.path);
    }
    final digestSink = _DigestSink();
    final hasher = sha256.startChunkedConversion(digestSink);
    final handle = await File(expected.path).open();
    try {
      if (quick) {
        // 将大小编码为固定 16 字节的小端整数后纳入摘要，避免不同长度样本共用快速索引。
        final sizePrefix = ByteData(16)
          ..setUint64(0, expected.size, Endian.little);
        hasher.add(sizePrefix.buffer.asUint8List());
        await _readChunk(
          handle,
          hasher,
          quickHashBytes,
          expected.path,
          stage,
          current,
          total,
        );
        if (expected.size > quickHashBytes) {
          final tailStart = expected.size - quickHashBytes;
          await handle.setPosition(
            tailStart > quickHashBytes ? tailStart : quickHashBytes,
          );
          await _readChunk(
            handle,
            hasher,
            quickHashBytes,
            expected.path,
            stage,
            current,
            total,
          );
        }
      } else {
        while (await _readChunk(
              handle,
              hasher,
              hashChunkSize,
              expected.path,
              stage,
              current,
              total,
            ) >
            0) {
          // 每块读取已进行取消检查，持续读取到 EOF 后再确认整个文件的快照。
        }
      }
    } finally {
      await handle.close();
      hasher.close();
    }
    _checkCancelled();
    final after = await inspector.inspect(expected.path);
    if (!expected.sameSnapshot(after)) {
      throw FileChangedDuringScan(expected.path);
    }
    return digestSink.value.toString();
  }

  Future<int> _readChunk(
    RandomAccessFile handle,
    ByteConversionSink hasher,
    int count,
    String path,
    String stage,
    int current,
    int total,
  ) async {
    _checkCancelled();
    final bytes = await handle.read(count);
    if (bytes.isNotEmpty) {
      hasher.add(bytes);
      _bytesRead += bytes.length;
      _report(stage, current, total: total, path: path);
    }
    // 在 hash CPU 计算后让出执行权，后台 isolate 可以及时收取取消消息。
    await Future<void>.delayed(Duration.zero);
    _checkCancelled();
    return bytes.length;
  }

  void _checkCancelled() {
    if (isCancelled()) throw const ScanCancelled();
  }

  /// 限流普通进度消息，阶段切换与最终状态始终发送。
  void _report(
    String stage,
    int current, {
    int? total,
    String? path,
    bool force = false,
  }) {
    final now = _clock.elapsedMilliseconds;
    if (!force && now - _lastProgressMs < 120) return;
    _lastProgressMs = now;
    onProgress?.call({
      'stage': stage,
      'current': current,
      'total': total,
      'path': path ?? '',
      'bytesRead': _bytesRead,
      'elapsedMs': now,
    });
  }
}

/// crypto 的分块摘要接收器，只保存最终摘要而不保留文件内容。
class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 枚举阶段的内部树节点；complete 只允许从 true 变为 false，防止不完整树重新入选。
class _FolderNode {
  _FolderNode(this.directory, {this.parent});
  final FileRecord directory;
  final _FolderNode? parent;
  final List<FileRecord> files = [];
  final List<_FolderNode> children = [];
  bool complete = true;
}

/// 节点摘要只保存常量数量的统计和摘要，不持有扁平后代清单。
/// content 为 null 表示尚未完成内容复核，或某个后代已经失效。
class _FolderSummary {
  _FolderSummary({
    required this.entryCount,
    required this.fileCount,
    required this.structure,
  });
  final int entryCount;
  final int fileCount;
  final String structure;
  String? content;
}

/// 为已经选择的完整副本建立路径及祖先索引，避免每个候选都遍历此前所有候选。
/// 查询与插入的成本只随路径深度变化；它只做词法覆盖判断，不进行文件系统访问。
class _FolderCoverage {
  final Set<String> _paths = {};
  final Set<String> _ancestors = {};

  bool overlaps(String path) {
    var current = canonicalWindowsPath(path);
    if (_ancestors.contains(current)) return true;
    while (true) {
      if (_paths.contains(current)) return true;
      final parent = p.windows.dirname(current);
      if (parent == current) return false;
      current = parent;
    }
  }

  void add(String path) {
    var current = canonicalWindowsPath(path);
    _paths.add(current);
    while (true) {
      final parent = p.windows.dirname(current);
      if (parent == current) return;
      _ancestors.add(parent);
      current = parent;
    }
  }
}
