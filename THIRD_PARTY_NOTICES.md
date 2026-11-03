# 第三方声明 / Third-party notices

DupeFile Cleaner 的原创代码使用 [MIT 许可证](LICENSE)。第三方代码、字体、运行库及工具保留其各自的版权与许可；项目 MIT 许可证不替代这些条款。

## 主要组件

| 组件 | 用途 | 许可与声明 |
|---|---|---|
| [Flutter](https://github.com/flutter/flutter) | 桌面框架、Windows runner 基础代码与运行引擎 | BSD-3-Clause；[完整文本](docs/licenses/FLUTTER-LICENSE.txt) |
| [Dart](https://github.com/dart-lang/sdk) | 语言与运行时 | BSD-3-Clause；[完整文本](docs/licenses/DART-LICENSE.txt) |
| [crypto](https://pub.dev/packages/crypto) | SHA-256 摘要 | BSD-3-Clause；[完整文本](docs/licenses/CRYPTO-LICENSE.txt) |
| [path](https://pub.dev/packages/path) | 路径处理 | BSD-3-Clause；[完整文本](docs/licenses/PATH-LICENSE.txt) |
| Flutter SDK 附带的 Material Icons 字体 | 界面图标 | 本发行所用 SDK 附带 CC-BY-4.0 文本；[完整文本](docs/licenses/MATERIAL-ICONS-LICENSE.txt) |
| Flutter SDK 附带的 Roboto 字体资源 | 框架字体资源 | Apache-2.0；[完整文本](docs/licenses/ROBOTO-LICENSE.txt) |
| Microsoft Visual C++ 运行库 | Windows 程序运行支持 | Microsoft 许可条款，见下文 |

Flutter 与其引擎还包含其他第三方组件。Flutter 构建生成的 `data/flutter_assets/NOTICES.Z` 随运行资源一起保留，包含构建所收集的依赖声明；直接与间接 Dart 包的精确版本记录在 `pubspec.lock`。本表是主要组件索引，不是对所有依赖统一重新授权。

## 字体归属

Material Icons 为 Google 提供的图标字体；相关资源随 Flutter SDK 提供。项目使用其图标并由 Flutter 构建工具按需处理字体。具体许可适用随该 SDK 资源附带的文本，不应将其他版本资源的许可直接套用于此发行。

Roboto 字体资源由 Google 提供并按随附 Apache-2.0 文本使用。应用优先使用 Windows 提供的 Microsoft YaHei UI；系统字体不由本项目单独重新分发。

## Microsoft Visual C++ 运行库

Windows 发行包可包含 Visual Studio 可再分发目录提供的 x64 VC 运行库。其版权归 Microsoft，使用及再分发受 Microsoft 相应许可条款约束，不适用项目的 MIT 许可证。相关说明：

- [Redistributing Visual C++ files](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files)
- [Microsoft Visual C++ Redistributable](https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist)

重新打包时应使用获准再分发的运行库文件，并遵守适用的许可。不要用操作系统目录中的调试库替代可再分发运行库。

## 再分发

请保留本文件、`LICENSE`、`docs/licenses/` 中的完整许可文本，以及 Flutter 生成的依赖声明。新增或升级依赖、字体或其他资源时，应重新检查附带的版权、NOTICE 和许可证，并相应更新发行包。
