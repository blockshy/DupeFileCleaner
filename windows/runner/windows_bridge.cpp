#include "windows_bridge.h"

#include <bcrypt.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <functional>
#include <iomanip>
#include <limits>
#include <map>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using Result = flutter::MethodResult<Value>;
using Microsoft::WRL::ComPtr;

// 将系统句柄交给 RAII 管理，异常、取消和提前返回都会释放文件锁。
class Handle {
 public:
  explicit Handle(HANDLE value = INVALID_HANDLE_VALUE) : value_(value) {}
  ~Handle() { Reset(); }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  Handle(Handle&& other) noexcept : value_(other.value_) {
    other.value_ = INVALID_HANDLE_VALUE;
  }
  Handle& operator=(Handle&& other) noexcept {
    if (this != &other) {
      Reset();
      value_ = other.value_;
      other.value_ = INVALID_HANDLE_VALUE;
    }
    return *this;
  }
  HANDLE get() const { return value_; }
  void Reset() {
    if (value_ != INVALID_HANDLE_VALUE && value_ != nullptr) CloseHandle(value_);
    value_ = INVALID_HANDLE_VALUE;
  }

 private:
  HANDLE value_;
};

// “跳过”表示输入已变化或不满足安全约束；“错误”表示操作系统拒绝了操作。
class OperationError : public std::runtime_error {
 public:
  OperationError(std::string status, std::string reason)
      : std::runtime_error(reason), status_(std::move(status)), reason_(std::move(reason)) {}
  const std::string& status() const { return status_; }
  const std::string& reason() const { return reason_; }

 private:
  std::string status_;
  // 原因文本由异常自身持有，跨 throw/catch 后仍保持完整有效的 UTF-8 数据。
  std::string reason_;
};

std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                        text.data(), static_cast<int>(text.size()),
                                        nullptr, 0);
  if (length <= 0) throw std::runtime_error("路径不是有效的 UTF-8 文本");
  std::wstring value(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                      static_cast<int>(text.size()), value.data(), length);
  return value;
}

std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  const int length = WideCharToMultiByte(CP_UTF8, 0, text.data(),
                                        static_cast<int>(text.size()), nullptr,
                                        0, nullptr, nullptr);
  std::string value(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()),
                      value.data(), length, nullptr, nullptr);
  return value;
}

std::string SystemError(DWORD code) {
  wchar_t* buffer = nullptr;
  const DWORD length = FormatMessageW(
      FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
          FORMAT_MESSAGE_IGNORE_INSERTS,
      nullptr, code, 0, reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
  std::string message = length ? Utf8(std::wstring(buffer, length)) : "未知错误";
  if (buffer) LocalFree(buffer);
  while (!message.empty() && (message.back() == '\r' || message.back() == '\n')) {
    message.pop_back();
  }
  return message + "（代码 " + std::to_string(code) + "）";
}

void CheckWin32(BOOL success, const std::string& context) {
  if (!success) throw std::runtime_error(context + "：" + SystemError(GetLastError()));
}

void CheckHr(HRESULT result, const std::string& context) {
  if (FAILED(result)) {
    throw std::runtime_error(context + "：" + SystemError(static_cast<DWORD>(result)));
  }
}

const Value& Field(const Map& map, const char* key) {
  const auto found = map.find(Value(key));
  if (found == map.end()) throw std::runtime_error(std::string("缺少字段：") + key);
  return found->second;
}

std::string StringField(const Map& map, const char* key) {
  const auto* value = std::get_if<std::string>(&Field(map, key));
  if (!value) throw std::runtime_error(std::string("字段必须是字符串：") + key);
  return *value;
}

int64_t IntField(const Map& map, const char* key) {
  const Value& value = Field(map, key);
  if (const auto* integer = std::get_if<int64_t>(&value)) return *integer;
  if (const auto* integer = std::get_if<int32_t>(&value)) return *integer;
  throw std::runtime_error(std::string("字段必须是整数：") + key);
}

bool BoolField(const Map& map, const char* key, bool fallback = false) {
  const auto found = map.find(Value(key));
  if (found == map.end()) return fallback;
  const auto* value = std::get_if<bool>(&found->second);
  if (!value) throw std::runtime_error(std::string("字段必须是布尔值：") + key);
  return *value;
}

const Map& MapField(const Map& map, const char* key) {
  const auto* value = std::get_if<Map>(&Field(map, key));
  if (!value) throw std::runtime_error(std::string("字段必须是对象：") + key);
  return *value;
}

// 内部始终使用带扩展前缀的绝对路径打开句柄，保证中文和长路径可用。
// 面向 Dart 的路径去掉此前缀，便于文件列表和资源管理器显示。
std::wstring DisplayPath(std::wstring path) {
  if (path.rfind(L"\\\\?\\UNC\\", 0) == 0) return L"\\\\" + path.substr(8);
  if (path.rfind(L"\\\\?\\", 0) == 0) return path.substr(4);
  return path;
}

std::wstring AbsolutePath(const std::wstring& path) {
  if (path.empty() || path.find(L'\0') != std::wstring::npos) {
    throw std::runtime_error("路径为空或含有空字符");
  }
  const DWORD length = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (length == 0) throw std::runtime_error("无法规范化路径");
  std::wstring result(static_cast<size_t>(length), L'\0');
  const DWORD written = GetFullPathNameW(path.c_str(), length, result.data(), nullptr);
  if (written == 0 || written >= length) throw std::runtime_error("无法规范化路径");
  result.resize(written);
  result = DisplayPath(result);
  while (result.size() > 3 && result.back() == L'\\') result.pop_back();
  return result;
}

std::wstring ExtendedPath(const std::wstring& path) {
  const std::wstring full = AbsolutePath(path);
  if (full.rfind(L"\\\\", 0) == 0) return L"\\\\?\\UNC\\" + full.substr(2);
  return L"\\\\?\\" + full;
}

bool EqualPath(const std::wstring& left, const std::wstring& right) {
  return CompareStringOrdinal(left.c_str(), static_cast<int>(left.size()),
                              right.c_str(), static_cast<int>(right.size()),
                              TRUE) == CSTR_EQUAL;
}

bool WithinRoot(const std::wstring& path, std::wstring root) {
  if (root.empty()) return false;
  if (root.back() != L'\\') root.push_back(L'\\');
  return path.size() > root.size() &&
         CompareStringOrdinal(path.c_str(), static_cast<int>(root.size()),
                              root.c_str(), static_cast<int>(root.size()),
                              TRUE) == CSTR_EQUAL;
}

std::wstring FinalPath(HANDLE handle) {
  const DWORD length = GetFinalPathNameByHandleW(handle, nullptr, 0, FILE_NAME_NORMALIZED);
  if (!length) throw std::runtime_error("无法读取文件的最终路径：" + SystemError(GetLastError()));
  std::wstring path(static_cast<size_t>(length + 1), L'\0');
  const DWORD written = GetFinalPathNameByHandleW(
      handle, path.data(), length + 1, FILE_NAME_NORMALIZED);
  if (!written || written > length) throw std::runtime_error("无法读取文件的最终路径");
  path.resize(written);
  return DisplayPath(path);
}

Handle OpenFile(const std::wstring& path, DWORD access, DWORD share) {
  Handle handle(CreateFileW(ExtendedPath(path).c_str(), access, share, nullptr,
                            OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT |
                                               FILE_FLAG_BACKUP_SEMANTICS,
                            nullptr));
  if (handle.get() == INVALID_HANDLE_VALUE) {
    throw std::runtime_error("无法打开文件：" + SystemError(GetLastError()));
  }
  return handle;
}

std::string HexBytes(const unsigned char* bytes, size_t length) {
  std::ostringstream stream;
  stream << std::hex << std::setfill('0');
  for (size_t i = 0; i < length; ++i) stream << std::setw(2) << static_cast<unsigned>(bytes[i]);
  return stream.str();
}

struct Snapshot {
  std::wstring final_path;
  int64_t size = 0;
  int64_t mtime_ns = 0;
  std::string volume_id;
  std::string file_id;
  DWORD link_count = 0;
  DWORD attributes = 0;

  bool directory() const { return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0; }
  bool reparse() const { return (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0; }
};

Snapshot ReadSnapshot(HANDLE handle) {
  BY_HANDLE_FILE_INFORMATION information{};
  CheckWin32(GetFileInformationByHandle(handle, &information), "读取文件信息失败");
  Snapshot result;
  result.final_path = FinalPath(handle);
  const uint64_t size = (static_cast<uint64_t>(information.nFileSizeHigh) << 32) |
                        information.nFileSizeLow;
  if (size > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
    throw std::runtime_error("文件大小超出支持范围");
  }
  result.size = static_cast<int64_t>(size);
  const uint64_t ticks = (static_cast<uint64_t>(information.ftLastWriteTime.dwHighDateTime) << 32) |
                         information.ftLastWriteTime.dwLowDateTime;
  constexpr int64_t kEpochOffset = 116444736000000000LL;
  if (ticks > static_cast<uint64_t>(std::numeric_limits<int64_t>::max())) {
    throw std::runtime_error("文件时间超出支持范围");
  }
  const int64_t unix_ticks = static_cast<int64_t>(ticks) - kEpochOffset;
  if (unix_ticks > std::numeric_limits<int64_t>::max() / 100 ||
      unix_ticks < std::numeric_limits<int64_t>::min() / 100) {
    throw std::runtime_error("文件时间超出纳秒时间戳支持范围");
  }
  result.mtime_ns = unix_ticks * 100;
  result.link_count = information.nNumberOfLinks;
  result.attributes = information.dwFileAttributes;

  // 优先读取 128 位文件 ID，以兼容 NTFS/ReFS；部分磁盘只支持传统 64 位 ID。
  FILE_ID_INFO identity{};
  if (GetFileInformationByHandleEx(handle, FileIdInfo, &identity, sizeof(identity))) {
    result.volume_id = std::to_string(identity.VolumeSerialNumber);
    result.file_id = HexBytes(identity.FileId.Identifier, sizeof(identity.FileId.Identifier));
  } else {
    result.volume_id = std::to_string(information.dwVolumeSerialNumber);
    const uint64_t id = (static_cast<uint64_t>(information.nFileIndexHigh) << 32) |
                        information.nFileIndexLow;
    std::ostringstream formatted;
    formatted << std::hex << std::setfill('0') << std::setw(16) << id;
    result.file_id = formatted.str();
  }
  return result;
}

Map SnapshotMap(const std::wstring& path, const Snapshot& snapshot) {
  return {{Value("path"), Value(Utf8(AbsolutePath(path)))},
          {Value("final_path"), Value(Utf8(snapshot.final_path))},
          {Value("size"), Value(snapshot.size)},
          {Value("mtime_ns"), Value(std::to_string(snapshot.mtime_ns))},
          {Value("volume_id"), Value(snapshot.volume_id)},
          {Value("file_id"), Value(snapshot.file_id)},
          {Value("link_count"), Value(static_cast<int64_t>(snapshot.link_count))},
          {Value("is_directory"), Value(snapshot.directory())},
          {Value("is_reparse_point"), Value(snapshot.reparse())}};
}

void CheckCancelled(const std::atomic<bool>& cancelled) {
  if (cancelled.load()) throw OperationError("cancelled", "操作已取消，尚未执行的文件保持原状");
}

// 摘要在同一个已打开句柄上完成，避免校验 A 文件却随后删除同一路径下的 B 文件。
// 本层也重新计算 keeper 的摘要，不相信传入计划或上一次候选文件的校验结果。
std::string HashHandle(HANDLE handle, const std::atomic<bool>& cancelled) {
  struct HashResources {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    std::vector<unsigned char> object;
    ~HashResources() {
      if (hash) BCryptDestroyHash(hash);
      if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
    }
  } resources;
  if (BCryptOpenAlgorithmProvider(&resources.algorithm, BCRYPT_SHA256_ALGORITHM,
                                 nullptr, 0) < 0) {
    throw std::runtime_error("无法初始化 SHA-256 算法");
  }
  DWORD object_length = 0;
  DWORD written = 0;
  if (BCryptGetProperty(resources.algorithm, BCRYPT_OBJECT_LENGTH,
                        reinterpret_cast<PUCHAR>(&object_length), sizeof(object_length),
                        &written, 0) < 0) {
    throw std::runtime_error("无法获取 SHA-256 工作缓冲区");
  }
  resources.object.resize(object_length);
  if (BCryptCreateHash(resources.algorithm, &resources.hash, resources.object.data(),
                       object_length, nullptr, 0, 0) < 0) {
    throw std::runtime_error("无法创建 SHA-256 摘要");
  }
  LARGE_INTEGER offset{};
  CheckWin32(SetFilePointerEx(handle, offset, nullptr, FILE_BEGIN), "定位文件失败");
  std::vector<unsigned char> buffer(4 * 1024 * 1024);
  for (;;) {
    CheckCancelled(cancelled);
    DWORD read = 0;
    CheckWin32(ReadFile(handle, buffer.data(), static_cast<DWORD>(buffer.size()),
                       &read, nullptr), "读取文件失败");
    if (!read) break;
    if (BCryptHashData(resources.hash, buffer.data(), read, 0) < 0) {
      throw std::runtime_error("SHA-256 摘要计算失败");
    }
  }
  unsigned char digest[32]{};
  if (BCryptFinishHash(resources.hash, digest, sizeof(digest), 0) < 0) {
    throw std::runtime_error("SHA-256 摘要结束失败");
  }
  // BCryptDestroyHash 必须早于 object 工作缓冲区释放。
  BCryptDestroyHash(resources.hash);
  resources.hash = nullptr;
  return HexBytes(digest, sizeof(digest));
}

void VerifyRecord(const Snapshot& actual, const Map& expected,
                  const std::wstring& root, bool allow_hardlinks) {
  if (actual.directory() || actual.reparse()) {
    throw OperationError("skipped", "目标不是普通文件，或已变成重解析点");
  }
  if (!WithinRoot(actual.final_path, root)) {
    throw OperationError("skipped", "文件的真实位置已超出扫描根目录");
  }
  const std::string expected_id = StringField(expected, "file_id");
  const std::string expected_volume = StringField(expected, "volume_id");
  if (expected_id.empty() || expected_volume.empty() ||
      actual.file_id != expected_id || actual.volume_id != expected_volume) {
    throw OperationError("skipped", "文件身份与计划不一致，需要重新扫描");
  }
  if (actual.size != IntField(expected, "size") ||
      std::to_string(actual.mtime_ns) != StringField(expected, "mtime_ns")) {
    throw OperationError("skipped", "文件大小或最后修改时间已变化");
  }
  if (!EqualPath(actual.final_path, Wide(StringField(expected, "final_path")))) {
    throw OperationError("skipped", "文件的最终路径已变化");
  }
  if (actual.link_count > 1 && !allow_hardlinks) {
    throw OperationError("skipped", "当前文件存在硬链接，未开启硬链接清理");
  }
}

// 锁定根目录及每级父目录，拒绝连接点/符号链接，并限制重命名根目录或祖先目录。
// 对目录只禁止 DELETE 共享；正常读写目录下其他文件不受影响。
std::vector<Handle> LockParentChain(const std::wstring& file,
                                    const std::wstring& root) {
  const std::wstring absolute = AbsolutePath(file);
  if (!WithinRoot(absolute, root)) throw OperationError("skipped", "文件不在计划根目录内");
  std::vector<Handle> handles;
  std::wstring current = root;
  for (;;) {
    Handle directory = OpenFile(current, FILE_READ_ATTRIBUTES,
                                 FILE_SHARE_READ | FILE_SHARE_WRITE);
    const Snapshot state = ReadSnapshot(directory.get());
    if (!state.directory() || state.reparse()) {
      throw OperationError("skipped", "父目录包含重解析点或已不再是目录");
    }
    if (!EqualPath(state.final_path, current)) {
      throw OperationError("skipped", "父目录的实际位置与计划路径不一致");
    }
    handles.push_back(std::move(directory));
    const size_t start = current.back() == L'\\' ? current.size() : current.size() + 1;
    const size_t separator = absolute.find(L'\\', start);
    if (separator == std::wstring::npos) break;
    current = absolute.substr(0, separator);
  }
  return handles;
}

// 回收站操作回调必须同时检查“准备回收”和“实际回收”两个阶段；
// 如果 Shell 要把操作改为永久删除，在 PreDeleteItem 中立即拒绝。
class RecycleSink final : public IFileOperationProgressSink {
 public:
  RecycleSink(const Map& record, std::wstring root, bool allow_hardlinks,
              const std::atomic<bool>& cancelled,
              std::function<void()> verify_tree = {})
      : record_(record), root_(std::move(root)), allow_hardlinks_(allow_hardlinks),
        cancelled_(cancelled), verify_tree_(std::move(verify_tree)) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** object) override {
    if (!object) return E_POINTER;
    *object = nullptr;
    if (id == IID_IUnknown || id == IID_IFileOperationProgressSink) {
      *object = static_cast<IFileOperationProgressSink*>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = --references_;
    if (!count) delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE StartOperations() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE FinishOperations(HRESULT) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE PreRenameItem(DWORD, IShellItem*, LPCWSTR) override { return E_ABORT; }
  HRESULT STDMETHODCALLTYPE PostRenameItem(DWORD, IShellItem*, LPCWSTR, HRESULT, IShellItem*) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE PreMoveItem(DWORD, IShellItem*, IShellItem*, LPCWSTR) override { return E_ABORT; }
  HRESULT STDMETHODCALLTYPE PostMoveItem(DWORD, IShellItem*, IShellItem*, LPCWSTR, HRESULT, IShellItem*) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE PreCopyItem(DWORD, IShellItem*, IShellItem*, LPCWSTR) override { return E_ABORT; }
  HRESULT STDMETHODCALLTYPE PostCopyItem(DWORD, IShellItem*, IShellItem*, LPCWSTR, HRESULT, IShellItem*) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE PreNewItem(DWORD, IShellItem*, LPCWSTR) override { return E_ABORT; }
  HRESULT STDMETHODCALLTYPE PostNewItem(DWORD, IShellItem*, LPCWSTR, LPCWSTR, DWORD, HRESULT, IShellItem*) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE UpdateProgress(UINT, UINT) override {
    return cancelled_.load() ? E_ABORT : S_OK;
  }
  HRESULT STDMETHODCALLTYPE ResetTimer() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE PauseTimer() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE ResumeTimer() override { return S_OK; }

  HRESULT STDMETHODCALLTYPE PreDeleteItem(DWORD flags, IShellItem* item) override {
    if (cancelled_.load()) {
      reason = "清理已取消";
      return E_ABORT;
    }
    if (!(flags & TSF_DELETE_RECYCLE_IF_POSSIBLE)) {
      reason = "系统未使用回收站，已拒绝永久删除";
      return E_ABORT;
    }
    try {
      PWSTR shell_path = nullptr;
      CheckHr(item->GetDisplayName(SIGDN_FILESYSPATH, &shell_path), "获取回收目标失败");
      const std::wstring path(shell_path);
      CoTaskMemFree(shell_path);
      if (!EqualPath(AbsolutePath(path), AbsolutePath(Wide(StringField(record_, "path"))))) {
        throw OperationError("skipped", "Shell 回收目标与清理计划不一致");
      }
      if (verify_tree_) {
        // 整目录回收必须检查完整清单，不能沿用只比较单个文件元数据的逻辑。
        verify_tree_();
      } else {
        Handle file = OpenFile(path, FILE_READ_ATTRIBUTES,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
        VerifyRecord(ReadSnapshot(file.get()), record_, root_, allow_hardlinks_);
      }
      preflight_seen = true;
      return S_OK;
    } catch (const std::exception& error) {
      reason = error.what();
      return E_ABORT;
    }
  }

  HRESULT STDMETHODCALLTYPE PostDeleteItem(DWORD, IShellItem*, HRESULT result,
                                            IShellItem* recycled_item) override {
    postflight_seen = true;
    operation_result = result;
    recycled = SUCCEEDED(result) && recycled_item != nullptr;
    if (SUCCEEDED(result) && recycled_item == nullptr) {
      reason = "系统未返回回收站项目，无法确认回收结果；请检查文件与回收站";
    }
    return S_OK;
  }

  bool preflight_seen = false;
  bool postflight_seen = false;
  bool recycled = false;
  HRESULT operation_result = E_PENDING;
  std::string reason;

 private:
  ~RecycleSink() = default;
  std::atomic<ULONG> references_{1};
  const Map& record_;
  std::wstring root_;
  bool allow_hardlinks_;
  const std::atomic<bool>& cancelled_;
  std::function<void()> verify_tree_;
};

void RecycleFile(const Map& record, const std::wstring& root, bool allow_hardlinks,
                  HWND window, const std::atomic<bool>& cancelled,
                  std::function<void()> verify_tree = {},
                  bool* successful_operation = nullptr) {
  const std::wstring path = Wide(StringField(record, "path"));
  // 网络共享、可移动介质和不支持回收站的卷采用保守策略：直接跳过，
  // 不让 Shell 对“不支持回收”的情况自行采用永久删除回退。
  wchar_t volume_path[MAX_PATH]{};
  CheckWin32(GetVolumePathNameW(path.c_str(), volume_path, MAX_PATH), "获取磁盘路径失败");
  if (GetDriveTypeW(volume_path) != DRIVE_FIXED) {
    throw OperationError("skipped", "仅本地固定磁盘支持此程序的回收站清理");
  }
  SHQUERYRBINFO bin{};
  bin.cbSize = sizeof(bin);
  CheckHr(SHQueryRecycleBinW(volume_path, &bin), "当前磁盘回收站不可用");

  ComPtr<IFileOperation> operation;
  CheckHr(CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_INPROC_SERVER,
                            IID_PPV_ARGS(&operation)), "初始化回收站操作失败");
  CheckHr(operation->SetOwnerWindow(window), "设置回收站窗口失败");
  CheckHr(operation->SetOperationFlags(
              FOFX_RECYCLEONDELETE | FOFX_ADDUNDORECORD | FOFX_EARLYFAILURE |
              FOF_NOERRORUI | FOF_SILENT | FOF_NOCONFIRMATION |
              FOF_WANTNUKEWARNING | FOF_NO_CONNECTED_ELEMENTS),
          "配置回收站操作失败");
  ComPtr<IShellItem> item;
  CheckHr(SHCreateItemFromParsingName(path.c_str(), nullptr, IID_PPV_ARGS(&item)),
          "创建回收目标失败");
  ComPtr<RecycleSink> sink;
  sink.Attach(new RecycleSink(record, root, allow_hardlinks, cancelled,
                              std::move(verify_tree)));
  CheckHr(operation->DeleteItem(item.Get(), sink.Get()), "加入回收任务失败");
  CheckCancelled(cancelled);
  const HRESULT performed = operation->PerformOperations();
  // 整目录调用方需要区分“明确未执行”与“系统报告已执行但结果不完整”；
  // 后一种情况必须报告部分处理并重新扫描，不能误称所有文件均保持原状。
  if (successful_operation) {
    *successful_operation = sink->postflight_seen && SUCCEEDED(sink->operation_result);
  }
  BOOL aborted = FALSE;
  const HRESULT aborted_result = operation->GetAnyOperationsAborted(&aborted);
  if (sink->postflight_seen && sink->recycled) return;
  if (!sink->reason.empty()) throw OperationError("skipped", sink->reason);
  if (cancelled.load()) throw OperationError("cancelled", "操作已取消");
  CheckHr(performed, "移入回收站失败");
  CheckHr(aborted_result, "读取回收站结果失败");
  if (aborted || !sink->preflight_seen || !sink->postflight_seen) {
    throw OperationError("skipped", "回收站操作未完成，文件未确认移入回收站");
  }
  CheckHr(sink->operation_result, "移入回收站失败");
  throw std::runtime_error("无法确认回收站操作结果");
}

Map CleanFile(const Map& arguments, HWND window, const std::atomic<bool>& cancelled) {
  std::string path;
  int64_t size = 0;
  auto response = [&](const std::string& status, const std::string& reason) {
    return Map{{Value("status"), Value(status)}, {Value("path"), Value(path)},
               {Value("reason"), Value(reason)}, {Value("size"), Value(size)}};
  };
  try {
    const Map& keeper = MapField(arguments, "keep");
    const Map& candidate = MapField(arguments, "candidate");
    path = StringField(candidate, "path");
    size = IntField(candidate, "size");
    const std::wstring root = AbsolutePath(Wide(StringField(arguments, "root")));
    // 多目录模式中，保留文件与候选文件可能分别来自不同盘或不同根目录。
    // 兼容旧调用：未提供 keepRoot 时仍使用单一 root。
    const auto keep_root_field = arguments.find(Value("keepRoot"));
    const std::wstring keep_root = keep_root_field == arguments.end()
        ? root : AbsolutePath(Wide(StringField(arguments, "keepRoot")));
    const std::wstring keeper_path = AbsolutePath(Wide(StringField(keeper, "path")));
    const std::wstring candidate_path = AbsolutePath(Wide(path));
    const bool allow_hardlinks = BoolField(arguments, "allowHardlinks");
    const std::string mode = StringField(arguments, "mode");
    const std::string digest = StringField(arguments, "sha256");
    if (mode != "recycle" && mode != "permanent") throw std::runtime_error("未知清理方式");
    if (digest.size() != 64 || digest.find_first_not_of("0123456789abcdef") != std::string::npos) {
      throw std::runtime_error("计划中的 SHA-256 格式错误");
    }
    if (EqualPath(keeper_path, candidate_path)) {
      throw OperationError("skipped", "保留文件不能同时作为清理目标");
    }
    CheckCancelled(cancelled);

    auto keeper_parents = LockParentChain(keeper_path, keep_root);
    auto candidate_parents = LockParentChain(candidate_path, root);
    // keeper 禁止写入和删除共享，从完整校验起一直保护到本次清理操作结束。
    Handle keeper_handle = OpenFile(keeper_path, GENERIC_READ, FILE_SHARE_READ);
    Snapshot keeper_state = ReadSnapshot(keeper_handle.get());
    VerifyRecord(keeper_state, keeper, keep_root, allow_hardlinks);
    if (keeper_state.volume_id == StringField(candidate, "volume_id") &&
        keeper_state.file_id == StringField(candidate, "file_id")) {
      throw OperationError("skipped", "候选与保留项是同一文件的硬链接别名，未执行清理");
    }
    Handle candidate_handle = OpenFile(candidate_path,
        GENERIC_READ | (mode == "permanent" ? DELETE : 0),
        FILE_SHARE_READ | FILE_SHARE_DELETE);
    Snapshot candidate_state = ReadSnapshot(candidate_handle.get());
    VerifyRecord(candidate_state, candidate, root, allow_hardlinks);
    if (keeper_state.volume_id == candidate_state.volume_id &&
        keeper_state.file_id == candidate_state.file_id) {
      // 同一文件的多个硬链接不是额外的数据副本，保守保留，避免对 keeper 的锁产生歧义。
      throw OperationError("skipped", "候选与保留项指向同一个硬链接文件，未执行清理");
    }
    if (HashHandle(keeper_handle.get(), cancelled) != digest) {
      throw OperationError("skipped", "保留文件 SHA-256 已变化，该候选已跳过");
    }
    if (HashHandle(candidate_handle.get(), cancelled) != digest) {
      throw OperationError("skipped", "候选文件 SHA-256 已变化");
    }
    VerifyRecord(ReadSnapshot(keeper_handle.get()), keeper, keep_root, allow_hardlinks);
    VerifyRecord(ReadSnapshot(candidate_handle.get()), candidate, root, allow_hardlinks);
    CheckCancelled(cancelled);

    if (mode == "permanent") {
      // 通过已经校验的句柄设置删除状态，避免 unlink(path) 的路径替换窗口。
      FILE_DISPOSITION_INFO disposition{};
      disposition.DeleteFile = TRUE;
      CheckWin32(SetFileInformationByHandle(candidate_handle.get(), FileDispositionInfo,
                                             &disposition, sizeof(disposition)),
                 "永久删除失败");
      candidate_handle.Reset();
      return response("deleted", "已重新校验保留文件与候选文件，并按句柄永久删除");
    }

    // 回收时仍持有候选的只读句柄，允许 Shell 重命名/删除但禁止其他程序写入内容。
    // 父目录和 keeper 的锁也一直保持，PreDeleteItem 会再次核对身份；但 Windows
    // Shell 的路径操作无法与哈希校验组成原子事务，不承诺完全消除恶意并发替换。
    // 如果某个文件系统的 Shell 实现要求写访问，按错误保留文件，不解除保护重试。
    RecycleFile(candidate, root, allow_hardlinks, window, cancelled);
    return response("recycled", "已移入 Windows 回收站");
  } catch (const OperationError& error) {
    return response(error.status(), error.reason());
  } catch (const std::exception& error) {
    return response("error", error.what());
  }
}

// 整目录清理实现复用上述句柄、路径、摘要及回收站保护；单独组织便于审阅。
#include "folder_operations.inc"

Value PickPath(HWND window, bool directory, bool save, const std::string& name) {
  ComPtr<IFileDialog> dialog;
  if (save) {
    CheckHr(CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)), "创建保存对话框失败");
  } else {
    CheckHr(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&dialog)), "创建选择对话框失败");
  }
  FILEOPENDIALOGOPTIONS options{};
  CheckHr(dialog->GetOptions(&options), "读取对话框选项失败");
  options |= FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST;
  if (directory) options |= FOS_PICKFOLDERS;
  if (!save && !directory) options |= FOS_FILEMUSTEXIST;
  if (save) options |= FOS_OVERWRITEPROMPT;
  CheckHr(dialog->SetOptions(options), "设置对话框选项失败");
  if (!directory) {
    const COMDLG_FILTERSPEC filters[] = {{L"JSON 计划或日志", L"*.json"}};
    CheckHr(dialog->SetFileTypes(1, filters), "设置文件类型失败");
    CheckHr(dialog->SetDefaultExtension(L"json"), "设置默认扩展名失败");
  }
  if (!name.empty()) CheckHr(dialog->SetFileName(Wide(name).c_str()), "设置默认文件名失败");
  CheckHr(dialog->SetTitle(directory ? L"选择要扫描的目录" : save ? L"保存 JSON 文件" : L"导入清理计划"),
          "设置对话框标题失败");
  const HRESULT shown = dialog->Show(window);
  if (shown == HRESULT_FROM_WIN32(ERROR_CANCELLED)) return Value();
  CheckHr(shown, "选择路径失败");
  ComPtr<IShellItem> item;
  CheckHr(dialog->GetResult(&item), "获取所选路径失败");
  PWSTR raw = nullptr;
  CheckHr(item->GetDisplayName(SIGDN_FILESYSPATH, &raw), "获取文件系统路径失败");
  const std::string path = Utf8(raw);
  CoTaskMemFree(raw);
  return Value(path);
}

struct Reply {
  std::shared_ptr<Result> callback;
  Map value;
};
}  // namespace

WindowsBridge::WindowsBridge(flutter::BinaryMessenger* messenger, HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "dupe_file_cleaner/windows", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    OnMethodCall(call, std::move(result));
  });
}

WindowsBridge::~WindowsBridge() {
  cancelled_.store(true);
  if (worker_.joinable()) worker_.join();
  // 窗口销毁时清理尚未派发的结果，避免悬空回调引用 Flutter 引擎。
  MSG message{};
  while (PeekMessageW(&message, window_, kReplyMessage, kReplyMessage, PM_REMOVE)) {
    delete reinterpret_cast<Reply*>(message.lParam);
  }
  channel_->SetMethodCallHandler(nullptr);
}

bool WindowsBridge::HandleMessage(UINT message, WPARAM, LPARAM lparam) {
  if (message != kReplyMessage) return false;
  std::unique_ptr<Reply> reply(reinterpret_cast<Reply*>(lparam));
  if (worker_.joinable()) worker_.join();
  cleaning_.store(false);
  reply->callback->Success(Value(std::move(reply->value)));
  return true;
}

void WindowsBridge::OnMethodCall(const flutter::MethodCall<Value>& call,
                                 std::unique_ptr<Result> result) {
  try {
    const Map empty;
    // Dart 无参数调用在 StandardMethodCodec 中表示 monostate，而非空指针。
    // 将两种空值统一解释为空参数对象，使选择目录和取消命令可直接调用。
    const Map* arguments = (!call.arguments() ||
                            std::holds_alternative<std::monostate>(*call.arguments()))
                               ? &empty
                               : std::get_if<Map>(call.arguments());
    if (!arguments) throw std::runtime_error("平台调用参数必须是对象");
    const std::string& method = call.method_name();
    if (method == "inspect") {
      const std::wstring path = Wide(StringField(*arguments, "path"));
      Handle file = OpenFile(path, FILE_READ_ATTRIBUTES,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
      result->Success(Value(SnapshotMap(path, ReadSnapshot(file.get()))));
    } else if (method == "pickDirectory") {
      result->Success(PickPath(window_, true, false, ""));
    } else if (method == "pickDirectories") {
      result->Success(PickDirectories(window_));
    } else if (method == "chooseJsonFile") {
      std::string name;
      if (arguments->find(Value("suggestedName")) != arguments->end()) {
        name = StringField(*arguments, "suggestedName");
      }
      result->Success(PickPath(window_, false, BoolField(*arguments, "save"), name));
    } else if (method == "reveal") {
      const std::wstring path = AbsolutePath(Wide(StringField(*arguments, "path")));
      PIDLIST_ABSOLUTE item = ILCreateFromPathW(path.c_str());
      if (!item) throw std::runtime_error("文件已不存在，无法在资源管理器中定位");
      const HRESULT opened = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
      ILFree(item);
      CheckHr(opened, "打开资源管理器失败");
      result->Success();
    } else if (method == "setBusy") {
      busy_ = BoolField(*arguments, "busy");
      result->Success();
    } else if (method == "cancelNative") {
      cancelled_.store(true);
      result->Success();
    } else if (method == "resetCancellation") {
      if (cleaning_.load()) throw std::runtime_error("清理进行中，不能重置取消状态");
      cancelled_.store(false);
      result->Success();
    } else if (method == "cleanFile" || method == "cleanFolder") {
      if (cleaning_.exchange(true)) throw std::runtime_error("已有清理操作正在执行");
      if (worker_.joinable()) worker_.join();
      const Map work = *arguments;
      const bool folder = method == "cleanFolder";
      // 先保存回调的共享所有权：创建线程失败时仍能通知 Dart，避免任务永远等待。
      auto callback = std::shared_ptr<Result>(std::move(result));
      try {
        worker_ = std::thread([this, work, folder, callback]() mutable {
        const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        auto reply = std::make_unique<Reply>();
        reply->callback = callback;
        if (FAILED(initialized)) {
          reply->value = {{Value("status"), Value("error")},
                          {Value("path"), Value("")},
                          {Value("size"), Value(int64_t{0})},
                          {Value("reason"), Value("无法初始化清理工作线程的 COM 环境")}};
        } else {
          reply->value = folder ? CleanFolder(work, window_, cancelled_)
                                : CleanFile(work, window_, cancelled_);
          CoUninitialize();
        }
        if (PostMessageW(window_, kReplyMessage, 0, reinterpret_cast<LPARAM>(reply.get()))) {
          reply.release();
        } else {
          cleaning_.store(false);
        }
        });
      } catch (const std::exception& error) {
        cleaning_.store(false);
        callback->Error("windows_error", std::string("创建清理工作线程失败：") + error.what());
      }
    } else {
      result->NotImplemented();
    }
  } catch (const std::exception& error) {
    if (result) result->Error("windows_error", error.what());
  }
}
