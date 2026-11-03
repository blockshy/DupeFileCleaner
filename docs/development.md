# 开发与发布指南

[返回首页](../README.md)

## 环境

| 工具 | 要求 |
|---|---|
| 操作系统 | Windows x64；桌面功能测试需要 Windows 文件系统及桌面环境 |
| Flutter | 3.47.6 stable |
| Dart | 使用 Flutter 附带的 3.13.5 |
| Visual Studio | 安装“使用 C++ 的桌面开发”工作负载及 Windows SDK |
| Git | 用于获取源码与贡献更改 |
| PowerShell | 7 或更高版本，用于检查与发布脚本 |

Flutter 环境安装参考[官方 Windows 桌面配置](https://docs.flutter.dev/platform-integration/windows/setup)。使用 `flutter doctor -v` 检查工具链。Flutter 与依赖版本以仓库配置和 `pubspec.lock` 为准，升级应通过独立更改验证。

## 获取源码与运行

```powershell
# 克隆公开仓库，安装锁定的依赖并运行桌面入口。
git clone https://github.com/blockshy/DupeFileCleaner.git
Set-Location DupeFileCleaner
flutter pub get --enforce-lockfile
flutter run -d windows
```

应用无需外部服务配置或访问令牌。扫描、计划处理及清理均在本机执行。

## 代码结构

| 路径 | 职责 |
|---|---|
| `lib/core/` | 文件快照、计划解析与验证、分阶段文件判重和目录摘要 |
| `lib/application/` | 后台 isolate、进度与取消、保留选择、增量结果更新、日志与主题偏好 |
| `lib/platform/` | Dart 到 Windows 的类型化方法通道 |
| `lib/ui/` | 工业工作台、结果列表、主题、清单与清理确认 |
| `windows/runner/` | 文件身份、父目录保护、SHA-256、原生选择器、回收站及按句柄删除 |
| `test/` | 模型、算法、状态、主题和组件测试 |
| `integration_test/` | 真实 Windows 文件操作、完整工作流与界面截图测试 |
| `tool/` | 通用检查和发布打包脚本 |
| `.github/` | CI、Release 工作流及协作模板 |

后台扫描不直接删除文件。清理前将用户选择固化为执行计划，原生层随后重新验证保留对象与候选。修改路径验证、文件身份或清理算法时，必须同时评估文件与完整目录两种粒度。

文件夹摘要先按直接子项构造紧凑结构，再对可能重复的目录计算内容摘要；最终只有互不重叠的匹配树展开为完整清单。清理后的结果更新不刷新内容快照，而是移除已处理或不确定的成员，剩余项在下一次执行时重新复核。

## 检查与测试

在仓库根目录运行：

```powershell
# 格式、静态分析和无需真实删除的测试。
dart format --output=none --set-exit-if-changed lib test integration_test
flutter analyze
flutter test
```

Windows 集成测试会创建专用样本，执行真实回收或永久删除。测试限定在工程 `test_artifacts` 下的临时目录，并在清理前验证边界；不要将测试改为接收任意用户目录。

```powershell
# 顺序执行，共享 Windows runner 构建目录，不要并行启动这些命令。
flutter test integration_test/native_smoke_test.dart -d windows
flutter test integration_test/folder_native_test.dart -d windows
flutter test integration_test/workflow_test.dart -d windows
flutter test integration_test/multi_workflow_test.dart -d windows

# 使用合成数据生成截图，图片写入 test_artifacts。
flutter test integration_test/ui_capture_test.dart -d windows
```

涉及回收站的测试需要 Windows Shell 和可用的本地固定磁盘回收站；相关行为不能用普通的目录删除替代。测试不会清空系统回收站，少量专用样本可能保留在其中。CI 环境能力与测试选择由工作流明确配置，检查失败应定位原因，不应通过忽略失败放行发布。

也可以使用统一检查脚本，按顺序恢复锁定依赖、检查格式、运行分析与测试，并构建主入口发布版：

```powershell
# 使用 PowerShell 7，在项目根目录执行完整 Windows 检查。
.\tool\test_windows.ps1
```

## 构建与打包

```powershell
# 仅构建主程序，显式指定入口，避免与集成测试入口混淆。
flutter build windows --release --target lib/main.dart

# 生成版本化 ZIP 与 SHA-256；FlutterSdk 可省略以使用 PATH 中的 Flutter。
.\tool\build_windows.ps1 -VersionTag v1.1.1 -OutputDirectory dist
```

打包脚本从 Visual Studio 的可再分发目录查找 x64 VC 运行库，收集 EXE、必要 DLL、Flutter 资源、许可证及用户文档。发行包不包含调试符号、对象文件、测试材料、缓存或日志。所有运行资源必须与 EXE 一起分发。

输出路径必须位于项目内。脚本拒绝覆盖同名发布目录或压缩包；需要再次检查同一版本时，可使用新的输出子目录，例如 `-OutputDirectory dist/verify`。输出文件名固定为 `DupeFileCleaner-v<版本>-windows-x64.zip`，校验文件为相同名称加 `.sha256`。

## GitHub Actions

- **CI**：对主分支提交和 Pull Request 进行格式、静态分析、测试及 Windows 构建检查。
- **Release**：对版本标签进行版本一致性检查，通过检查后构建 Windows x64 包，上传 ZIP 与校验文件并发布 GitHub Release。
- 工作流固定 Flutter 版本和依赖，Action 引用固定到经过核对的提交；默认权限只读，发布任务按需获得仓库内容写权限。
- 发布认证使用工作流提供的 `GITHUB_TOKEN`，无需在仓库配置个人访问令牌。

具体触发条件、测试集合和步骤以 [CI 工作流](../.github/workflows/ci.yml) 和 [Release 工作流](../.github/workflows/release.yml) 为准。

## 发布一个版本

1. 修改 `pubspec.yaml` 中的版本号与构建号，并同步界面版本文字及 `CHANGELOG.md`。
2. 更新受影响文档，运行相应测试，提交 Pull Request 并合并到主分支。
3. 确认主分支 CI 通过，创建与项目版本一致的 `v<主版本>.<次版本>.<修订版本>` 标签并推送。
4. 等待 Release 工作流完成，检查 Release 附件、版本号、包内文件及 SHA-256。

```powershell
# 以下版本号仅为格式示例；仅为已审核通过的提交创建新标签。
git tag -a v1.1.2 -m "Release v1.1.2"
git push origin v1.1.2
```

不要移动已经发布的标签或用不同内容覆盖同一版本的发行包。需要修正已发布程序时，应创建新的修订版本；仅工作流临时失败时，可在确认目标标签未变化后重跑指定版本。
