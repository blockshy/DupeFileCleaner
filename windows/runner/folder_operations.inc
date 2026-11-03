// 本文件在 windows_bridge.cpp 的匿名命名空间中包含，不单独编译。
// 整目录清理分为严格解析、完整复核及执行三阶段；在两棵树均验证通过前不修改磁盘。

using List = flutter::EncodableList;

const List& ListField(const Map& map, const char* key) {
  const auto* value = std::get_if<List>(&Field(map, key));
  if (!value) throw OperationError("skipped", std::string("清单字段必须是数组：") + key);
  return *value;
}

// Windows 文件名比较采用系统的 ordinal 忽略大小写规则，不能依赖当前区域设置。
struct PathLess {
  bool operator()(const std::wstring& left, const std::wstring& right) const {
    return CompareStringOrdinal(left.c_str(), static_cast<int>(left.size()),
                                right.c_str(), static_cast<int>(right.size()),
                                TRUE) == CSTR_LESS_THAN;
  }
};

std::wstring ValidateAbsolute(const std::string& value) {
  auto path = DisplayPath(Wide(value));
  std::replace(path.begin(), path.end(), L'/', L'\\');
  const bool drive = path.size() >= 3 &&
      ((path[0] >= L'A' && path[0] <= L'Z') || (path[0] >= L'a' && path[0] <= L'z')) &&
      path[1] == L':' && path[2] == L'\\';
  const bool unc = path.rfind(L"\\\\", 0) == 0 && path.rfind(L"\\\\.\\", 0) != 0;
  if ((!drive && !unc) || path.find(L'\0') != std::wstring::npos) {
    throw OperationError("skipped", "目录清理只接受完整的 Windows 绝对路径");
  }
  return AbsolutePath(path);
}

bool IsVolumeRoot(const std::wstring& path) {
  if (path.size() == 3 && path[1] == L':' && path[2] == L'\\') return true;
  if (path.rfind(L"\\\\", 0) == 0) {
    const size_t server_end = path.find(L'\\', 2);
    if (server_end == std::wstring::npos) return true;
    return path.find(L'\\', server_end + 1) == std::wstring::npos;
  }
  return false;
}

std::wstring ParentPath(const std::wstring& path) {
  const auto position = path.find_last_of(L'\\');
  if (position == std::wstring::npos) throw OperationError("skipped", "目录没有合法的父级路径");
  return position == 2 && path[1] == L':' ? path.substr(0, 3) : path.substr(0, position);
}

// 清单相对路径只能包含普通组件。拒绝绝对路径、上级跳转、备用数据流及别名组件。
std::wstring ValidateRelative(const std::string& text) {
  std::wstring relative = Wide(text);
  std::replace(relative.begin(), relative.end(), L'/', L'\\');
  if (relative.empty() || relative.front() == L'\\' || relative.back() == L'\\' ||
      relative.find(L':') != std::wstring::npos) {
    throw OperationError("skipped", "目录清单含有非法相对路径");
  }
  size_t start = 0;
  while (start < relative.size()) {
    const auto end = relative.find(L'\\', start);
    const auto component = relative.substr(start, end == std::wstring::npos ? end : end - start);
    if (component.empty() || component == L"." || component == L".." ||
        component.back() == L'.' || component.back() == L' ' ||
        component.find_first_of(L"<>\"|?*") != std::wstring::npos ||
        std::any_of(component.begin(), component.end(), [](wchar_t ch) { return ch < 32; })) {
      throw OperationError("skipped", "目录清单含有不支持的文件名或路径跳转");
    }
    if (end == std::wstring::npos) break;
    start = end + 1;
  }
  return relative;
}

struct TreeEntry {
  std::wstring relative;
  std::wstring path;
  Map record;
  std::string digest;
  bool directory = false;
};

struct TreeManifest {
  std::wstring path;
  Map root;
  std::vector<TreeEntry> entries;
  std::map<std::wstring, size_t, PathLess> index;
  int64_t total_bytes = 0;
  int64_t file_count = 0;
};

TreeManifest ParseTree(const Map& value) {
  TreeManifest result;
  result.root = MapField(value, "directory");
  result.path = ValidateAbsolute(StringField(result.root, "path"));
  if (IsVolumeRoot(result.path)) throw OperationError("skipped", "禁止清理磁盘根目录或共享根目录");
  if (!BoolField(result.root, "is_directory") || BoolField(result.root, "is_reparse_point")) {
    throw OperationError("skipped", "目录清单的根记录不是普通目录");
  }
  const List& files = ListField(value, "files");
  const List& directories = ListField(value, "directories");
  // 同时持有两棵树的句柄以阻止写入。限制每棵树的项目数，避免耗尽进程句柄资源。
  constexpr size_t kMaximumTreeEntries = 8192;
  if (files.empty() || files.size() + directories.size() > kMaximumTreeEntries) {
    throw OperationError("skipped", "整目录清理要求至少一个文件，且每个目录树最多 8192 个文件及子目录");
  }
  auto append = [&](const Value& raw, bool directory) {
    const auto* item = std::get_if<Map>(&raw);
    if (!item) throw OperationError("skipped", "目录清单项目必须是对象");
    TreeEntry entry;
    entry.relative = ValidateRelative(StringField(*item, "relative_path"));
    entry.record = MapField(*item, "record");
    entry.path = ValidateAbsolute(StringField(entry.record, "path"));
    entry.directory = directory;
    const std::wstring expected_path = result.path + L"\\" + entry.relative;
    if (!EqualPath(entry.path, expected_path) ||
        !EqualPath(ValidateAbsolute(StringField(entry.record, "final_path")), expected_path) ||
        BoolField(entry.record, "is_directory") != directory ||
        BoolField(entry.record, "is_reparse_point")) {
      throw OperationError("skipped", "目录清单的相对路径、真实位置或项目类型不一致");
    }
    if (!result.index.emplace(entry.relative, result.entries.size()).second) {
      throw OperationError("skipped", "目录清单包含大小写别名或重复项目");
    }
    if (!directory) {
      entry.digest = StringField(*item, "sha256");
      if (entry.digest.size() != 64 || entry.digest.find_first_not_of("0123456789abcdef") != std::string::npos ||
          IntField(entry.record, "size") < 0 || IntField(entry.record, "link_count") != 1) {
        throw OperationError("skipped", "目录清单含有无效摘要、长度或硬链接文件");
      }
      const int64_t bytes = IntField(entry.record, "size");
      if (bytes > std::numeric_limits<int64_t>::max() - result.total_bytes) {
        throw OperationError("skipped", "目录容量超出支持范围");
      }
      result.total_bytes += bytes;
      ++result.file_count;
    }
    result.entries.push_back(std::move(entry));
  };
  for (const auto& item : directories) append(item, true);
  for (const auto& item : files) append(item, false);
  for (const auto& entry : result.entries) {
    auto separator = entry.relative.find_last_of(L'\\');
    if (separator == std::wstring::npos) continue;
    const auto parent = result.index.find(entry.relative.substr(0, separator));
    if (parent == result.index.end() || !result.entries[parent->second].directory) {
      throw OperationError("skipped", "目录清单缺少必要的父目录，拒绝不完整清理");
    }
  }
  return result;
}

void CompareTrees(const TreeManifest& keep, const TreeManifest& candidate) {
  if (EqualPath(keep.path, candidate.path) || WithinRoot(keep.path, candidate.path) ||
      WithinRoot(candidate.path, keep.path)) {
    throw OperationError("skipped", "保留目录与候选目录不能相同，也不能互为祖先和后代");
  }
  if (keep.entries.size() != candidate.entries.size() || keep.file_count != candidate.file_count) {
    throw OperationError("skipped", "两个目录的完整文件或子目录清单不同");
  }
  for (const auto& entry : keep.entries) {
    const auto other = candidate.index.find(entry.relative);
    if (other == candidate.index.end()) throw OperationError("skipped", "两个目录的相对路径结构不同");
    const auto& match = candidate.entries[other->second];
    if (entry.directory != match.directory || (!entry.directory &&
        (entry.digest != match.digest || IntField(entry.record, "size") != IntField(match.record, "size")))) {
      throw OperationError("skipped", "两个目录包含不同类型或不同内容的项目");
    }
  }
}

void VerifyDirectorySnapshot(const Snapshot& actual, const Map& expected, bool check_time = true) {
  if (!actual.directory() || actual.reparse() ||
      !EqualPath(actual.final_path, ValidateAbsolute(StringField(expected, "path"))) ||
      !EqualPath(actual.final_path, ValidateAbsolute(StringField(expected, "final_path"))) ||
      actual.file_id != StringField(expected, "file_id") ||
      actual.volume_id != StringField(expected, "volume_id") ||
      StringField(expected, "file_id").empty() || StringField(expected, "volume_id").empty()) {
    throw OperationError("skipped", "目录身份、真实位置或重解析状态已变化");
  }
  if (check_time && std::to_string(actual.mtime_ns) != StringField(expected, "mtime_ns")) {
    throw OperationError("skipped", "目录修改时间已变化，需要重新扫描");
  }
}

struct TreeLocks {
  Handle root;
  std::vector<Handle> entries;
};

// 先打开父目录，再打开文件，确保任何祖先连接点都会在读取实际文件前被拒绝。
TreeLocks LockTree(const TreeManifest& manifest, bool candidate, bool permanent,
                   const std::atomic<bool>& cancelled) {
  TreeLocks locks;
  const DWORD share = candidate ? FILE_SHARE_READ | FILE_SHARE_DELETE : FILE_SHARE_READ;
  const DWORD delete_access = candidate && permanent ? DELETE : 0;
  // Handle 不可复制；将返回值直接构造成拥有者，避免裸句柄在异常路径泄漏。
  Handle root = OpenFile(manifest.path, FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY | delete_access, share);
  VerifyDirectorySnapshot(ReadSnapshot(root.get()), manifest.root);
  locks.root = std::move(root);
  locks.entries.reserve(manifest.entries.size());
  for (size_t i = 0; i < manifest.entries.size(); ++i) locks.entries.emplace_back();
  std::vector<size_t> order;
  for (size_t i = 0; i < manifest.entries.size(); ++i) order.push_back(i);
  std::sort(order.begin(), order.end(), [&](size_t left, size_t right) {
    const auto& a = manifest.entries[left];
    const auto& b = manifest.entries[right];
    if (a.directory != b.directory) return a.directory;
    return a.relative.size() < b.relative.size();
  });
  for (const size_t index : order) {
    CheckCancelled(cancelled);
    const auto& entry = manifest.entries[index];
    Handle handle = OpenFile(entry.path, (entry.directory ? FILE_READ_ATTRIBUTES | FILE_LIST_DIRECTORY : GENERIC_READ) | delete_access, share);
    const auto actual = ReadSnapshot(handle.get());
    if (entry.directory) VerifyDirectorySnapshot(actual, entry.record);
    else VerifyRecord(actual, entry.record, manifest.path, false);
    locks.entries[index] = std::move(handle);
  }
  return locks;
}

// 重新枚举磁盘，而不是只检查清单列出的文件，才能发现新增、缺失或改名的项目。
void VerifyInventory(const TreeManifest& manifest, const std::atomic<bool>& cancelled) {
  std::set<std::wstring, PathLess> found;
  std::vector<std::wstring> pending{L""};
  while (!pending.empty()) {
    CheckCancelled(cancelled);
    const auto relative_directory = pending.back();
    pending.pop_back();
    const auto folder = manifest.path + (relative_directory.empty() ? L"" : L"\\" + relative_directory);
    WIN32_FIND_DATAW entry{};
    HANDLE search = FindFirstFileW((ExtendedPath(folder) + L"\\*").c_str(), &entry);
    if (search == INVALID_HANDLE_VALUE) {
      const DWORD error = GetLastError();
      if (error == ERROR_FILE_NOT_FOUND) continue;
      throw OperationError("skipped", "无法完整枚举目录：" + SystemError(error));
    }
    struct FindCloser { HANDLE handle; ~FindCloser() { FindClose(handle); } } closer{search};
    do {
      CheckCancelled(cancelled);
      const std::wstring name = entry.cFileName;
      if (name == L"." || name == L"..") continue;
      const auto relative = relative_directory.empty() ? name : relative_directory + L"\\" + name;
      const auto expected = manifest.index.find(relative);
      const bool directory = (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
      if ((entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 ||
          expected == manifest.index.end() || manifest.entries[expected->second].directory != directory ||
          !found.insert(relative).second) {
        throw OperationError("skipped", "目录清单已变化：检测到新增、改名、类型变化或链接项目");
      }
      if (directory) pending.push_back(relative);
    } while (FindNextFileW(search, &entry));
    if (GetLastError() != ERROR_NO_MORE_FILES) throw OperationError("skipped", "目录枚举未能完整结束");
  }
  if (found.size() != manifest.entries.size()) throw OperationError("skipped", "目录中的部分文件或子目录已缺失");
}

void VerifyLockedTree(const TreeManifest& manifest, TreeLocks& locks, bool hash,
                       const std::atomic<bool>& cancelled) {
  VerifyDirectorySnapshot(ReadSnapshot(locks.root.get()), manifest.root);
  VerifyInventory(manifest, cancelled);
  for (size_t i = 0; i < manifest.entries.size(); ++i) {
    CheckCancelled(cancelled);
    const auto& entry = manifest.entries[i];
    const Snapshot actual = ReadSnapshot(locks.entries[i].get());
    if (entry.directory) VerifyDirectorySnapshot(actual, entry.record);
    else {
      VerifyRecord(actual, entry.record, manifest.path, false);
      if (hash && HashHandle(locks.entries[i].get(), cancelled) != entry.digest) {
        throw OperationError("skipped", "目录中的文件 SHA-256 已变化：" + Utf8(entry.relative));
      }
    }
  }
  // 完整读取可能耗时较长，因此再次检查清单，避免读取期间新增文件被忽略。
  VerifyInventory(manifest, cancelled);
}

std::wstring MatchScanRoot(const std::wstring& path, const List& roots) {
  if (roots.empty()) throw OperationError("skipped", "清理计划缺少扫描根目录");
  std::wstring match;
  for (const auto& value : roots) {
    const auto* text = std::get_if<std::string>(&value);
    if (!text) throw OperationError("skipped", "扫描根目录必须是字符串");
    const auto root = ValidateAbsolute(*text);
    if (EqualPath(root, path) || WithinRoot(path, root)) {
      Handle directory = OpenFile(root, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
      const auto info = ReadSnapshot(directory.get());
      if (!info.directory() || info.reparse() || !EqualPath(info.final_path, root)) {
        throw OperationError("skipped", "扫描根目录已变为链接或真实位置不一致");
      }
      if (match.empty() || root.size() > match.size()) match = root;
    }
  }
  if (match.empty()) throw OperationError("skipped", "目录不在任何已选择的扫描根目录内");
  return match;
}

// 原生整目录操作的唯一入口。永久模式只处理清单中已验证的句柄，绝不使用递归删除。
Map CleanFolder(const Map& arguments, HWND window, const std::atomic<bool>& cancelled) {
  std::string path;
  int64_t bytes = 0;
  int64_t file_count = 0;
  int64_t deleted_files = 0;
  List completed;
  auto response = [&](const std::string& status, const std::string& reason) {
    return Map{{Value("status"), Value(status)}, {Value("path"), Value(path)},
      {Value("reason"), Value(reason)}, {Value("size"), Value(bytes)},
      {Value("kind"), Value("folder")}, {Value("file_count"), Value(file_count)},
      {Value("completed_files"), Value(deleted_files)}, {Value("entries"), Value(completed)}};
  };
  try {
    TreeManifest keep = ParseTree(MapField(arguments, "keep"));
    TreeManifest candidate = ParseTree(MapField(arguments, "candidate"));
    path = Utf8(candidate.path);
    bytes = candidate.total_bytes;
    file_count = candidate.file_count;
    const auto mode = StringField(arguments, "mode");
    if (mode != "recycle" && mode != "permanent") throw OperationError("skipped", "未知整目录清理方式");
    const bool permanent = mode == "permanent";
    CompareTrees(keep, candidate);
    MatchScanRoot(keep.path, ListField(arguments, "roots"));
    MatchScanRoot(candidate.path, ListField(arguments, "roots"));
    CheckCancelled(cancelled);
    // 文件夹本身可能就是扫描根，因此独立保护其父目录；这不会把父目录加入清理范围。
    auto keep_parents = LockParentChain(keep.path, ParentPath(keep.path));
    auto candidate_parents = LockParentChain(candidate.path, ParentPath(candidate.path));
    auto keep_locks = LockTree(keep, false, permanent, cancelled);
    auto candidate_locks = LockTree(candidate, true, permanent, cancelled);
    if (ReadSnapshot(keep_locks.root.get()).file_id == ReadSnapshot(candidate_locks.root.get()).file_id &&
        ReadSnapshot(keep_locks.root.get()).volume_id == ReadSnapshot(candidate_locks.root.get()).volume_id) {
      throw OperationError("skipped", "保留目录与候选目录指向同一文件系统对象");
    }
    VerifyLockedTree(keep, keep_locks, true, cancelled);
    VerifyLockedTree(candidate, candidate_locks, true, cancelled);
    // 第二棵树读取可能很久，在首次修改前重新核对两边的目录及文件集合。
    VerifyLockedTree(keep, keep_locks, false, cancelled);
    VerifyLockedTree(candidate, candidate_locks, false, cancelled);
    CheckCancelled(cancelled);
    if (!permanent) {
      // Shell 回收保留目录结构。校验期间，候选文件句柄禁止写入，保留树始终禁止写入和删除。
      // Windows 不允许重命名仍有后代句柄打开的目录，即使这些句柄允许 FILE_SHARE_DELETE；
      // 因此只能在最终 PreDeleteItem 复核通过后释放候选后代句柄，根句柄仍持续保留。
      // 从释放到 Shell 移动之间存在内容和名称的竞争窗口，不能将目录回收宣称为原子操作。
      bool preflight_accepted = false;
      bool candidate_descendants_released = false;
      bool successful_operation = false;
      try {
        RecycleFile(candidate.root, candidate.path, false, window, cancelled, [&]() {
          if (candidate_descendants_released) {
            // Shell 可以重复进入回调。重新锁定和完整读取候选树，不能信任上一次释放后的状态；
            // 新根句柄先打开，旧根句柄后释放，确保保护根身份的句柄始终存在。
            auto renewed = LockTree(candidate, true, false, cancelled);
            candidate_locks = std::move(renewed);
          }
          VerifyLockedTree(keep, keep_locks, false, cancelled);
          VerifyLockedTree(candidate, candidate_locks, candidate_descendants_released, cancelled);
          for (auto& handle : candidate_locks.entries) handle.Reset();
          candidate_descendants_released = true;
          preflight_accepted = true;
        }, &successful_operation);
      } catch (...) {
        bool changed = successful_operation;
        if (preflight_accepted && !changed) {
          // 取消可能发生在 Shell 已经移动目录之后。忽略取消标志进行一次只读状态核对，
          // 若目录或清单已变化，则记录“不确定”细目，要求重新扫描，避免静默遗失部分结果。
          const std::atomic<bool> inspect_without_cancellation{false};
          try {
            // 预回调已释放后代句柄；必须重新建立完整句柄集合，不能访问已关闭的旧句柄。
            auto inspected = LockTree(candidate, true, false, inspect_without_cancellation);
            VerifyLockedTree(candidate, inspected, true, inspect_without_cancellation);
          } catch (...) {
            changed = true;
          }
        }
        if (changed) {
          completed.emplace_back(Map{{Value("path"), Value(path)},
            {Value("status"), Value("unconfirmed")}, {Value("kind"), Value("folder")},
            {Value("size"), Value(bytes)},
            {Value("reason"), Value("Shell 已报告操作成功或目录状态已改变，但完整回收结果未确认；请重新扫描并检查回收站")}});
        }
        throw;
      }
      return response("recycled", "完整目录已移入 Windows 回收站；操作前已复核完整内容，Shell 移动阶段不具备原子性");
    }
    auto delete_handle = [&](Handle& handle, const std::wstring& target, bool directory, int64_t size) {
      CheckCancelled(cancelled);
      FILE_DISPOSITION_INFO disposition{};
      disposition.DeleteFile = TRUE;
      CheckWin32(SetFileInformationByHandle(handle.get(), FileDispositionInfo, &disposition, sizeof(disposition)),
                   directory ? "目录非空或无法安全删除" : "删除已复核文件失败");
      handle.Reset();
      if (!directory) ++deleted_files;
      completed.emplace_back(Map{{Value("path"), Value(Utf8(target))},
        {Value("status"), Value("deleted")}, {Value("kind"), Value(directory ? "directory" : "file")},
        {Value("size"), Value(size)}});
    };
    for (size_t i = 0; i < candidate.entries.size(); ++i) {
      const auto& entry = candidate.entries[i];
      if (entry.directory) continue;
      // 删除前再核对当前句柄；内容在最初打开后一直受共享模式保护。
      VerifyRecord(ReadSnapshot(candidate_locks.entries[i].get()), entry.record, candidate.path, false);
      delete_handle(candidate_locks.entries[i], entry.path, false, IntField(entry.record, "size"));
    }
    std::vector<size_t> directory_order;
    for (size_t i = 0; i < candidate.entries.size(); ++i) if (candidate.entries[i].directory) directory_order.push_back(i);
    std::sort(directory_order.begin(), directory_order.end(), [&](size_t left, size_t right) {
      return candidate.entries[left].relative.size() > candidate.entries[right].relative.size();
    });
    for (const size_t i : directory_order) {
      VerifyDirectorySnapshot(ReadSnapshot(candidate_locks.entries[i].get()), candidate.entries[i].record, false);
      delete_handle(candidate_locks.entries[i], candidate.entries[i].path, true, 0);
    }
    VerifyDirectorySnapshot(ReadSnapshot(candidate_locks.root.get()), candidate.root, false);
    delete_handle(candidate_locks.root, candidate.path, true, 0);
    return response("deleted", "清单内文件已按句柄删除，空目录已自底向上移除");
  } catch (const OperationError& error) {
    return response(completed.empty() ? error.status() : "partial",
      completed.empty() ? error.reason() : "操作可能已部分完成；请检查处理明细与回收站，并重新扫描。原因：" + error.reason());
  } catch (const std::exception& error) {
    return response(completed.empty() ? "error" : "partial",
      completed.empty() ? std::string(error.what()) : std::string("部分项目已处理；请重新扫描。原因：") + error.what());
  }
}

// 原生多选目录对话框支持 Ctrl/Shift 选择；取消返回空数组，不影响现有扫描位置。
Value PickDirectories(HWND window) {
  ComPtr<IFileOpenDialog> dialog;
  CheckHr(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                           IID_PPV_ARGS(&dialog)), "创建多目录选择对话框失败");
  FILEOPENDIALOGOPTIONS options{};
  CheckHr(dialog->GetOptions(&options), "读取目录选择选项失败");
  CheckHr(dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST),
            "设置多目录选择选项失败");
  CheckHr(dialog->SetTitle(L"选择扫描目录（支持 Ctrl / Shift 多选）"), "设置选择窗口标题失败");
  const HRESULT shown = dialog->Show(window);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return Value(List{});
  CheckHr(shown, "选择扫描目录失败");
  ComPtr<IShellItemArray> items;
  CheckHr(dialog->GetResults(&items), "获取选择目录失败");
  DWORD count = 0;
  CheckHr(items->GetCount(&count), "获取目录数量失败");
  List paths;
  for (DWORD i = 0; i < count; ++i) {
    ComPtr<IShellItem> item;
    CheckHr(items->GetItemAt(i, &item), "读取所选目录失败");
    PWSTR raw = nullptr;
    CheckHr(item->GetDisplayName(SIGDN_FILESYSPATH, &raw), "读取目录路径失败");
    paths.emplace_back(Utf8(raw));
    CoTaskMemFree(raw);
  }
  return Value(paths);
}
