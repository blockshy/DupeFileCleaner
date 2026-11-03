import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// 统一使用 Windows 路径规则，避免导入计划时依赖运行机器的默认路径风格。
final p.Context _windowsPath = p.Context(style: p.Style.windows);

/// 与 Windows 原生整目录清理保持一致：每棵树最多同时持有 8192 个子项句柄。
/// 根目录本身不计入此数；超过限制的父树不应遮蔽仍可执行的小型重复子树。
const int maxFolderManifestEntries = 8192;

/// 用于比较的路径形式：去除长路径前缀、规范化分隔符并忽略大小写。
///
/// 此结果仅用于去重和词法范围检查，不能替代原生层基于句柄的真实路径校验。
String canonicalWindowsPath(String value) {
  var path = value.replaceAll('/', r'\');
  if (path.toUpperCase().startsWith(r'\\?\UNC\')) {
    path = r'\\' + path.substring(8);
  } else if (path.startsWith(r'\\?\')) {
    path = path.substring(4);
  }
  return _windowsPath.normalize(path).toLowerCase();
}

/// 判断一个绝对文件路径是否严格位于指定根目录下。
bool isPathWithinRoot(String path, String root) {
  final candidate = canonicalWindowsPath(path);
  final base = canonicalWindowsPath(root);
  return _windowsPath.isWithin(base, candidate);
}

/// 目录目标可以等于一个扫描根；普通文件仍须严格位于根目录之内。
bool isPathWithinRoots(
  String path,
  Iterable<String> roots, {
  bool allowRoot = false,
}) => roots.any(
  (root) =>
      isPathWithinRoot(path, root) ||
      (allowRoot && canonicalWindowsPath(path) == canonicalWindowsPath(root)),
);

/// 两个路径相同或存在祖先/后代关系时，不能作为两项独立的整目录清理目标。
bool pathsOverlap(String left, String right) =>
    canonicalWindowsPath(left) == canonicalWindowsPath(right) ||
    isPathWithinRoot(left, right) ||
    isPathWithinRoot(right, left);

/// 扫描时的文件元数据快照。
///
/// 时间使用整数纳秒，文件身份使用字符串，避免 JSON 浮点数导致精度损失。
/// [volumeId] 与 [fileId] 共同标识文件；不同路径可通过硬链接指向同一文件。
class FileRecord {
  const FileRecord({
    required this.path,
    required this.finalPath,
    required this.size,
    required this.mtimeNs,
    required this.volumeId,
    required this.fileId,
    this.linkCount = 1,
    this.isDirectory = false,
    this.isReparsePoint = false,
  });

  final String path;
  final String finalPath;
  final int size;
  final int mtimeNs;
  final String volumeId;
  final String fileId;
  final int linkCount;
  final bool isDirectory;
  final bool isReparsePoint;

  /// 旧版计划未保存当前格式要求的 Windows 原生身份，执行前必须重新获取。
  bool get hasIdentity => volumeId.isNotEmpty && fileId.isNotEmpty;

  DateTime get modifiedAt =>
      DateTime.fromMicrosecondsSinceEpoch(mtimeNs ~/ 1000).toLocal();

  /// 判断是否仍为同一个未变化的文件。
  ///
  /// 同时比较真实路径和链接数，防止阶段之间新建硬链接或替换祖先目录后继续使用旧结果。
  bool sameSnapshot(FileRecord other) =>
      size == other.size &&
      mtimeNs == other.mtimeNs &&
      volumeId == other.volumeId &&
      fileId == other.fileId &&
      linkCount == other.linkCount &&
      isDirectory == other.isDirectory &&
      isReparsePoint == other.isReparsePoint &&
      canonicalWindowsPath(finalPath) == canonicalWindowsPath(other.finalPath);

  Map<String, dynamic> toJson() => {
    'path': path,
    'final_path': finalPath,
    'size': size,
    'mtime_ns': mtimeNs.toString(),
    'mtime': modifiedAt.toIso8601String(),
    'volume_id': volumeId,
    'file_id': fileId,
    'link_count': linkCount,
    'is_directory': isDirectory,
    'is_reparse_point': isReparsePoint,
  };

  /// 从原生接口或计划读取快照；[legacy] 表示版本 1 的旧版计划格式。
  ///
  /// 旧计划的 inode/device 不是本程序原生层约定的编码，因此不直接作为可信身份。
  factory FileRecord.fromJson(
    Map<String, dynamic> json, {
    bool legacy = false,
  }) {
    final path = _readString(json, 'path');
    final finalPath = legacy
        ? path
        : _readString(json, 'final_path', fallback: path);
    final size = _readInt(json, 'size');
    final mtimeNs = _readInt(json, 'mtime_ns', allowNegative: true);
    final links = _readInt(json, 'link_count', fallback: 1);
    if (links < 1) {
      throw const FormatException('link_count 必须大于零。');
    }
    final volume = legacy ? '' : _readString(json, 'volume_id', fallback: '');
    final fileId = legacy ? '' : _readString(json, 'file_id', fallback: '');
    return FileRecord(
      path: path,
      finalPath: finalPath,
      size: size,
      mtimeNs: mtimeNs,
      volumeId: volume,
      fileId: fileId,
      linkCount: links,
      isDirectory: _readBool(json, 'is_directory', fallback: false),
      isReparsePoint: _readBool(json, 'is_reparse_point', fallback: false),
    );
  }
}

/// 扫描选项默认采用保守设置，空文件与硬链接需由用户明确开启。
class ScanOptions {
  const ScanOptions({
    this.includeEmpty = false,
    this.includeHardlinks = false,
    this.detectDuplicateFolders = true,
  });

  final bool includeEmpty;
  final bool includeHardlinks;
  final bool detectDuplicateFolders;

  Map<String, dynamic> toJson() => {
    'include_empty': includeEmpty,
    'include_hardlinks': includeHardlinks,
    'detect_duplicate_folders': detectDuplicateFolders,
  };

  factory ScanOptions.fromJson(Map<String, dynamic> json) => ScanOptions(
    includeEmpty: _readBool(json, 'include_empty', fallback: false),
    includeHardlinks: _readBool(json, 'include_hardlinks', fallback: false),
    detectDuplicateFolders: _readBool(
      json,
      'detect_duplicate_folders',
      fallback: true,
    ),
  );
}

/// 一组大小及完整 SHA-256 均相同的文件。
///
/// [keep] 为推荐保留文件，[candidates] 为其余文件；界面可以在生成执行计划时重新分配。
class DuplicateGroup {
  DuplicateGroup({
    required this.id,
    required this.size,
    required this.sha256,
    required this.keep,
    required List<FileRecord> candidates,
  }) : candidates = List.unmodifiable(candidates);

  final int id;
  final int size;
  final String sha256;
  final FileRecord keep;
  final List<FileRecord> candidates;

  List<FileRecord> get files => [keep, ...candidates];
  int get duplicateBytes => size * candidates.length;

  Map<String, dynamic> toJson() => {
    'group_id': id,
    'size': size,
    'sha256': sha256,
    'keep': keep.toJson(),
    'delete': candidates.map((record) => record.toJson()).toList(),
  };

  factory DuplicateGroup.fromJson(
    Map<String, dynamic> json, {
    bool legacy = false,
  }) {
    final digest = _readString(json, 'sha256').toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('重复组的 SHA-256 格式无效。');
    }
    final id = _readInt(json, 'group_id');
    if (id < 1) {
      throw const FormatException('group_id 必须大于零。');
    }
    final records = _readList(json, 'delete');
    if (records.isEmpty) {
      throw const FormatException('重复组必须包含至少一个待清理文件。');
    }
    return DuplicateGroup(
      id: id,
      size: _readInt(json, 'size'),
      sha256: digest,
      keep: FileRecord.fromJson(_asMap(json['keep'], 'keep'), legacy: legacy),
      candidates: records
          .map(
            (value) =>
                FileRecord.fromJson(_asMap(value, 'delete'), legacy: legacy),
          )
          .toList(),
    );
  }
}

/// 整目录清单中的一个普通文件；相对路径保留原始大小写，比较时使用 Windows 规则。
class FolderFileEntry {
  const FolderFileEntry({
    required this.relativePath,
    required this.record,
    required this.sha256,
  });
  final String relativePath;
  final FileRecord record;
  final String sha256;
  Map<String, dynamic> toJson() => {
    'relative_path': relativePath,
    'record': record.toJson(),
    'sha256': sha256,
  };
  factory FolderFileEntry.fromJson(Map<String, dynamic> json) {
    final digest = _readString(json, 'sha256').toLowerCase();
    _validateDigest(digest);
    return FolderFileEntry(
      relativePath: _readString(json, 'relative_path'),
      record: FileRecord.fromJson(_asMap(json['record'], 'record')),
      sha256: digest,
    );
  }
}

/// 子目录也必须进入清单，包括没有文件的空目录，避免把不同目录结构误判相同。
class FolderDirectoryEntry {
  const FolderDirectoryEntry({
    required this.relativePath,
    required this.record,
  });
  final String relativePath;
  final FileRecord record;
  Map<String, dynamic> toJson() => {
    'relative_path': relativePath,
    'record': record.toJson(),
  };
  factory FolderDirectoryEntry.fromJson(Map<String, dynamic> json) =>
      FolderDirectoryEntry(
        relativePath: _readString(json, 'relative_path'),
        record: FileRecord.fromJson(_asMap(json['record'], 'record')),
      );
}

/// 一个完整且可复核的文件夹快照。
///
/// files 包含全部普通文件（含 0 字节文件），directories 包含所有子目录但不含根目录。
/// 遇到链接、未读出的项目或变化时，扫描器不会生成该树的快照；执行层仍须重新枚举。
class FolderRecord {
  FolderRecord({
    required this.directory,
    required List<FolderFileEntry> files,
    List<FolderDirectoryEntry> directories = const [],
  }) : files = List.unmodifiable(files),
       directories = List.unmodifiable(directories);
  final FileRecord directory;
  final List<FolderFileEntry> files;
  final List<FolderDirectoryEntry> directories;
  String get path => directory.path;
  int get totalBytes => files.fold(0, (sum, item) => sum + item.record.size);
  int get fileCount => files.length;
  Map<String, dynamic> toJson() => {
    'directory': directory.toJson(),
    'files': files.map((item) => item.toJson()).toList(),
    'directories': directories.map((item) => item.toJson()).toList(),
  };
  factory FolderRecord.fromJson(Map<String, dynamic> json) {
    final value = FolderRecord(
      directory: FileRecord.fromJson(_asMap(json['directory'], 'directory')),
      files: _readList(json, 'files')
          .map((item) => FolderFileEntry.fromJson(_asMap(item, 'file entry')))
          .toList(),
      directories: _readList(json, 'directories')
          .map(
            (item) =>
                FolderDirectoryEntry.fromJson(_asMap(item, 'directory entry')),
          )
          .toList(),
    );
    _validateFolder(value);
    return value;
  }
}

/// 一组完整相同的目录树。默认保留项由扫描器按规范路径排序确定，用户可明确更换。
class DuplicateFolderGroup {
  DuplicateFolderGroup({
    required this.id,
    required this.fingerprint,
    required this.keep,
    required List<FolderRecord> candidates,
  }) : candidates = List.unmodifiable(candidates);
  final int id;
  final String fingerprint;
  final FolderRecord keep;
  final List<FolderRecord> candidates;
  List<FolderRecord> get folders => [keep, ...candidates];
  int get duplicateBytes =>
      candidates.fold(0, (sum, item) => sum + item.totalBytes);
  Map<String, dynamic> toJson() => {
    'group_id': id,
    'fingerprint': fingerprint,
    'keep': keep.toJson(),
    'delete': candidates.map((item) => item.toJson()).toList(),
  };
  factory DuplicateFolderGroup.fromJson(Map<String, dynamic> json) {
    final id = _readInt(json, 'group_id');
    if (id < 1) throw const FormatException('目录组编号必须大于零。');
    final digest = _readString(json, 'fingerprint').toLowerCase();
    _validateDigest(digest);
    final candidates = _readList(
      json,
      'delete',
    ).map((item) => FolderRecord.fromJson(_asMap(item, 'folder'))).toList();
    if (candidates.isEmpty) throw const FormatException('目录组必须包含待清理副本。');
    final result = DuplicateFolderGroup(
      id: id,
      fingerprint: digest,
      keep: FolderRecord.fromJson(_asMap(json['keep'], 'keep')),
      candidates: candidates,
    );
    for (final folder in result.folders) {
      if (folderFingerprint(folder) != digest) {
        throw FormatException('文件夹清单与分组指纹不一致：${folder.path}');
      }
    }
    return result;
  }
}

/// 指纹仅描述目录结构和文件内容，不纳入路径前缀、时间或文件身份。
/// JSON 数组提供明确分隔，避免简单字符串拼接产生歧义；序列化顺序固定。
String folderFingerprint(FolderRecord folder) {
  final directories =
      folder.directories
          .map((item) => canonicalWindowsPath(item.relativePath))
          .toList()
        ..sort();
  final files =
      folder.files
          .map(
            (item) => <Object>[
              canonicalWindowsPath(item.relativePath),
              item.record.size,
              item.sha256,
            ],
          )
          .toList()
        ..sort((a, b) => (a.first as String).compareTo(b.first as String));
  return sha256
      .convert(utf8.encode(jsonEncode([directories, files])))
      .toString();
}

void _validateDigest(String digest) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
    throw const FormatException('SHA-256 指纹格式无效。');
  }
}

void _validateRelativePath(String value) {
  final slash = value.replaceAll('/', r'\');
  if (value.isEmpty ||
      _windowsPath.isAbsolute(slash) ||
      _windowsPath.isRootRelative(slash) ||
      slash.contains(':') ||
      RegExp(r'[\x00-\x1f]').hasMatch(value) ||
      slash
          .split(r'\')
          .any(
            (part) =>
                part.isEmpty ||
                part == '.' ||
                part == '..' ||
                part.endsWith(' ') ||
                part.endsWith('.'),
          )) {
    throw FormatException('目录清单含无效相对路径：$value');
  }
}

void _validateFolder(FolderRecord folder) {
  _validateAbsolutePath(folder.path, '目录路径');
  _validateAbsolutePath(folder.directory.finalPath, '目录真实路径');
  if (!folder.directory.isDirectory ||
      folder.directory.isReparsePoint ||
      !folder.directory.hasIdentity ||
      canonicalWindowsPath(folder.path) !=
          canonicalWindowsPath(folder.directory.finalPath)) {
    throw FormatException('目录快照不完整或通过链接访问：${folder.path}');
  }
  // 不允许把整个磁盘或共享根作为目录清理目标，即使其清单看似与别处相同。
  if (_windowsPath.dirname(canonicalWindowsPath(folder.path)) ==
      canonicalWindowsPath(folder.path)) {
    throw const FormatException('不能整目录清理磁盘或共享根。');
  }
  if (folder.files.isEmpty) throw const FormatException('纯空文件夹不作为重复文件夹清理。');
  final names = <String>{};
  final directoryNames = <String>{};
  void check(String relative, FileRecord record, bool directory) {
    _validateRelativePath(relative);
    final normalized = canonicalWindowsPath(relative);
    if (!names.add(normalized)) throw FormatException('目录清单路径重复：$relative');
    if (directory) directoryNames.add(normalized);
    if (record.isDirectory != directory ||
        record.isReparsePoint ||
        !record.hasIdentity ||
        (!directory && record.linkCount != 1) ||
        canonicalWindowsPath(record.path) !=
            canonicalWindowsPath(_windowsPath.join(folder.path, relative)) ||
        canonicalWindowsPath(record.finalPath) !=
            canonicalWindowsPath(record.path)) {
      throw FormatException('目录清单快照、相对路径或链接状态不一致：$relative');
    }
  }

  for (final entry in folder.directories) {
    check(entry.relativePath, entry.record, true);
  }
  for (final entry in folder.files) {
    check(entry.relativePath, entry.record, false);
    _validateDigest(entry.sha256);
  }
  for (final name in names) {
    var parent = _windowsPath.dirname(name);
    while (parent != '.') {
      if (!directoryNames.contains(parent)) {
        throw FormatException('目录清单遗漏父目录：$parent');
      }
      parent = _windowsPath.dirname(parent);
    }
  }
}

/// 可序列化的扫描结果与清理计划。
///
/// 计划本身只是执行依据；实际清理仍必须在 Windows 原生层重新检查文件内容与身份。
class ScanPlan {
  ScanPlan({
    String? root,
    List<String>? roots,
    required this.options,
    required List<DuplicateGroup> groups,
    List<DuplicateFolderGroup> folderGroups = const [],
    List<Map<String, String>> errors = const [],
    List<Map<String, String>> skipped = const [],
    this.scannedFiles = 0,
    this.scannedBytes = 0,
    this.visitedEntries = 0,
    this.elapsedMs = 0,
    required this.generatedAt,
    this.sourceVersion = 3,
  }) : roots = List.unmodifiable(roots ?? [?root]),
       groups = List.unmodifiable(groups),
       folderGroups = List.unmodifiable(folderGroups),
       errors = List.unmodifiable(errors.map(Map<String, String>.unmodifiable)),
       skipped = List.unmodifiable(
         skipped.map(Map<String, String>.unmodifiable),
       ) {
    if (this.roots.isEmpty) throw ArgumentError('扫描计划必须包含至少一个根目录。');
  }

  static const int currentVersion = 3;

  final List<String> roots;

  /// 兼容旧单目录调用；新版执行与路径验证必须使用完整的 roots。
  String get root => roots.first;
  final ScanOptions options;
  final List<DuplicateGroup> groups;
  final List<DuplicateFolderGroup> folderGroups;
  final List<Map<String, String>> errors;
  final List<Map<String, String>> skipped;
  final int scannedFiles;
  final int scannedBytes;
  final int visitedEntries;
  final int elapsedMs;
  final DateTime generatedAt;

  /// 仅用于提示导入来源，新的序列化格式始终写为版本 3。
  final int sourceVersion;

  int get deleteCount =>
      groups.fold(0, (sum, group) => sum + group.candidates.length);
  int get duplicateBytes =>
      groups.fold(0, (sum, group) => sum + group.duplicateBytes);
  int get folderDeleteCount =>
      folderGroups.fold(0, (sum, group) => sum + group.candidates.length);
  int get folderDuplicateBytes =>
      folderGroups.fold(0, (sum, group) => sum + group.duplicateBytes);
  bool get needsIdentityRefresh =>
      groups.any((group) => group.files.any((record) => !record.hasIdentity));

  Map<String, dynamic> toJson() => {
    'plan_version': currentVersion,
    'generated_at': generatedAt.toIso8601String(),
    'root': root,
    'roots': roots,
    'duplicate_definition': 'same size and same SHA-256 digest',
    // 导出时保留项可能经过人工更换，执行以每组 keep 记录为准。
    'keep_rule': 'explicit keep record; initial recommendation: oldest mtime_ns, then normalized absolute path order',
    'options': options.toJson(),
    'summary': {
      'visited_entries': visitedEntries,
      'scanned_files': scannedFiles,
      'scanned_bytes': scannedBytes,
      'duplicate_groups': groups.length,
      'delete_candidates': deleteCount,
      'reclaimable_bytes': duplicateBytes,
      'duplicate_folder_groups': folderGroups.length,
      'folder_delete_candidates': folderDeleteCount,
      'folder_duplicate_bytes': folderDuplicateBytes,
      'errors': errors.length,
      'skipped': skipped.length,
      'elapsed_ms': elapsedMs,
    },
    'groups': groups.map((group) => group.toJson()).toList(),
    'folder_groups': folderGroups.map((group) => group.toJson()).toList(),
    'errors': errors,
    'skipped': skipped,
  };

  /// 读取并验证计划，不信任文件内的重复数量、待删数量或容量合计。
  ///
  /// 先检查格式和路径集合，再由执行层进行实际文件检查，防止修改过的 JSON
  /// 把同一路径同时列入保留与删除列表，或通过多个组重复操作同一文件。
  factory ScanPlan.fromJson(Map<String, dynamic> json) {
    final version = _readInt(json, 'plan_version');
    if (version != 1 && version != 2 && version != currentVersion) {
      throw FormatException('不支持的计划版本：$version。');
    }
    final roots = version < 3
        ? [_readString(json, 'root')]
        : _readList(json, 'roots').map((value) {
            if (value is! String) throw const FormatException('扫描根目录必须为字符串。');
            return value;
          }).toList();
    if (roots.isEmpty) throw const FormatException('扫描根目录不能为空。');
    for (var i = 0; i < roots.length; i++) {
      _validateAbsolutePath(roots[i], '根目录');
      for (var j = 0; j < i; j++) {
        if (pathsOverlap(roots[i], roots[j])) {
          throw const FormatException('计划根目录重复或相互嵌套。');
        }
      }
    }
    final groups = _readList(json, 'groups')
        .map(
          (value) => DuplicateGroup.fromJson(
            _asMap(value, 'groups'),
            legacy: version == 1,
          ),
        )
        .toList();
    final groupIds = <int>{};
    final paths = <String>{};
    for (final group in groups) {
      if (!groupIds.add(group.id)) {
        throw FormatException('重复组编号 ${group.id} 重复。');
      }
      for (final record in group.files) {
        _validateAbsolutePath(record.path, '文件路径');
        _validateAbsolutePath(record.finalPath, '真实路径');
        if (!isPathWithinRoots(record.path, roots) ||
            !isPathWithinRoots(record.finalPath, roots)) {
          throw FormatException('文件不在计划根目录内：${record.path}');
        }
        if (!paths.add(canonicalWindowsPath(record.path))) {
          throw FormatException('保留与待清理路径重复，或跨组路径冲突：${record.path}');
        }
        if (record.size != group.size) {
          throw FormatException('重复组内文件大小不一致：${record.path}');
        }
        if (record.isDirectory || record.isReparsePoint) {
          throw FormatException('计划不能清理目录或重解析点：${record.path}');
        }
        if (version >= 2 && !record.hasIdentity) {
          throw FormatException('计划缺少文件身份：${record.path}');
        }
      }
    }
    final folderGroups = version < 3 || json['folder_groups'] == null
        ? <DuplicateFolderGroup>[]
        : _readList(json, 'folder_groups')
              .map(
                (value) => DuplicateFolderGroup.fromJson(
                  _asMap(value, 'folder_groups'),
                ),
              )
              .toList();
    final folderIds = <int>{};
    final folderPaths = <String>[];
    for (final group in folderGroups) {
      if (!folderIds.add(group.id)) throw const FormatException('重复文件夹组编号冲突。');
      for (final folder in group.folders) {
        if (!isPathWithinRoots(folder.path, roots, allowRoot: true) ||
            !isPathWithinRoots(
              folder.directory.finalPath,
              roots,
              allowRoot: true,
            )) {
          throw FormatException('目录目标超出扫描范围：${folder.path}');
        }
        final path = canonicalWindowsPath(folder.path);
        folderPaths.add(path.endsWith(r'\') ? path : '$path\\');
      }
    }
    // 目录路径统一补充分隔符后，祖先路径与其后代在排序结果中必然连续。
    // 仅比较相邻项即可发现任意重叠，避免大量重复叶目录在主线程触发 O(N²) 校验。
    // 补充分隔符也区分 foo 与 foobar，并防止 foo-other 干扰 foo/sub 的祖先检测。
    folderPaths.sort();
    for (var index = 1; index < folderPaths.length; index++) {
      if (folderPaths[index].startsWith(folderPaths[index - 1])) {
        throw FormatException('目录清理目标之间重复或存在祖先后代关系：${folderPaths[index]}');
      }
    }
    final summary = json['summary'] == null
        ? <String, dynamic>{}
        : _asMap(json['summary'], 'summary');
    final generated = DateTime.tryParse(_readString(json, 'generated_at'));
    if (generated == null) {
      throw const FormatException('generated_at 时间格式无效。');
    }
    var elapsedMs = _readInt(summary, 'elapsed_ms', fallback: 0);
    if (version == 1 && summary['elapsed_seconds'] is num) {
      final seconds = summary['elapsed_seconds'] as num;
      if (seconds.isFinite && seconds >= 0) {
        elapsedMs = (seconds * 1000).round();
      }
    }
    return ScanPlan(
      roots: roots,
      options: ScanOptions.fromJson(
        json['options'] == null ? {} : _asMap(json['options'], 'options'),
      ),
      groups: groups,
      folderGroups: folderGroups,
      errors: _readDiagnostics(json['errors'], 'error'),
      skipped: _readDiagnostics(json['skipped'], 'reason'),
      scannedFiles: _readInt(summary, 'scanned_files', fallback: 0),
      scannedBytes: _readInt(summary, 'scanned_bytes', fallback: 0),
      visitedEntries: _readInt(summary, 'visited_entries', fallback: 0),
      elapsedMs: elapsedMs,
      generatedAt: generated,
      sourceVersion: version,
    );
  }
}

/// 拒绝相对路径、备用数据流、控制字符及容易产生 Windows 路径别名的尾随点/空格。
void _validateAbsolutePath(String value, String label) {
  final normalized = canonicalWindowsPath(value);
  if (!_windowsPath.isAbsolute(normalized) ||
      _windowsPath.isRootRelative(normalized) ||
      normalized.startsWith(r'\\.\') ||
      RegExp(r'[\x00-\x1f]').hasMatch(value)) {
    throw FormatException('$label 必须是有效的 Windows 绝对路径。');
  }
  final remainder = RegExp(r'^[a-z]:\\').hasMatch(normalized)
      ? normalized.substring(3)
      : normalized;
  if (remainder.contains(':') ||
      normalized
          .split(r'\')
          .any((part) => part.endsWith(' ') || part.endsWith('.'))) {
    throw FormatException('$label 包含不支持的路径别名或备用数据流。');
  }
}

Map<String, dynamic> _asMap(Object? value, String field) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw FormatException('$field 必须是 JSON 对象。');
  }
  return Map<String, dynamic>.from(value);
}

String _readString(Map<String, dynamic> map, String key, {String? fallback}) {
  final value = map[key];
  if (value == null && fallback != null) return fallback;
  if (value is! String || (value.isEmpty && fallback == null)) {
    throw FormatException('$key 必须是非空字符串。');
  }
  return value;
}

int _readInt(
  Map<String, dynamic> map,
  String key, {
  int? fallback,
  bool allowNegative = false,
}) {
  final value = map[key];
  if (value == null && fallback != null) return fallback;
  final parsed = value is int
      ? value
      : value is String && RegExp(r'^-?\d+$').hasMatch(value)
      ? int.tryParse(value)
      : null;
  if (parsed == null || (!allowNegative && parsed < 0)) {
    throw FormatException('$key 必须是${allowNegative ? '' : '非负'}整数。');
  }
  return parsed;
}

bool _readBool(Map<String, dynamic> map, String key, {required bool fallback}) {
  final value = map[key];
  if (value == null) return fallback;
  if (value is! bool) throw FormatException('$key 必须是布尔值。');
  return value;
}

List<dynamic> _readList(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value is! List) throw FormatException('$key 必须是数组。');
  return value;
}

List<Map<String, String>> _readDiagnostics(Object? value, String messageKey) {
  if (value == null) return [];
  if (value is! List) throw const FormatException('诊断记录必须是数组。');
  return value.map((item) {
    final map = _asMap(item, 'diagnostic');
    return {
      'path': _readString(map, 'path', fallback: ''),
      messageKey: _readString(map, messageKey),
    };
  }).toList();
}
