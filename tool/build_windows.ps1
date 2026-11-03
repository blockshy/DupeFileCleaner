<#
.SYNOPSIS
构建 Windows x64 发布版，按运行文件白名单生成 ZIP 与 SHA-256 校验文件。
.PARAMETER FlutterSdk
Flutter SDK 根目录；未指定时使用 PATH 中的 flutter.bat。
.PARAMETER VersionTag
可选的版本标签（例如 v1.1.1）；提供时必须与 pubspec.yaml 完全一致。
.PARAMETER OutputDirectory
发布目录，默认 dist，必须位于本项目内。已有同名发布包不会被覆盖。
.NOTES
要求 PowerShell 7、Flutter SDK 和 Visual Studio C++ 桌面开发组件。
只打包程序运行文件、公开文档及许可证，不复制整个构建目录或调试符号。
#>
param(
    [string]$FlutterSdk = '',
    [string]$VersionTag = '',
    [string]$OutputDirectory = 'dist'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$versionLine = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?\s*$'
if (-not $versionLine) { throw 'pubspec.yaml 未包含有效的发布版本。' }
$packageVersion = $versionLine.Matches[0].Groups[1].Value
if ($VersionTag -and $VersionTag -cne "v$packageVersion") {
    throw '版本标签与 pubspec.yaml 不一致，拒绝构建。'
}
$VersionTag = "v$packageVersion"
$outputRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $OutputDirectory))
if (-not $outputRoot.StartsWith("$projectRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '输出目录必须位于本项目内，且不能等于项目根目录。'
}
$packageName = "DupeFileCleaner-$VersionTag-windows-x64"
$packageDirectory = Join-Path $outputRoot $packageName
$archivePath = "$packageDirectory.zip"
if ((Test-Path -LiteralPath $packageDirectory) -or (Test-Path -LiteralPath $archivePath) -or (Test-Path -LiteralPath "$archivePath.sha256")) {
    throw '同版本输出已经存在，请指定新的项目内输出目录；脚本不会覆盖既有产物。'
}
if ($FlutterSdk) {
    $flutterCommand = Join-Path $FlutterSdk 'bin\flutter.bat'
} else {
    $flutterCommand = (Get-Command flutter.bat -ErrorAction Stop).Source
}
if (-not (Test-Path -LiteralPath $flutterCommand -PathType Leaf)) {
    throw '未找到 Flutter。请通过 -FlutterSdk 指定 SDK 根目录。'
}

Push-Location -LiteralPath $projectRoot
try {
    # 发布版必须显式以主入口构建，避免上一次集成测试的入口混入发布产物。
    & $flutterCommand build windows --release --target lib/main.dart
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows Release 构建失败。' }

    $releaseDirectory = Join-Path $projectRoot 'build\windows\x64\runner\Release'
    $executable = Join-Path $releaseDirectory 'dupe_file_cleaner.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw '未找到 Windows x64 可执行文件，请检查构建输出。'
    }

    # 从已安装 Visual Studio 的可再分发目录查找 x64 CRT；不复制系统目录中的调试库。
    $vswherePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswherePath)) { throw '未找到 Visual Studio 安装查询工具。' }
    $visualStudioPath = & $vswherePath -latest -products '*' -requires Microsoft.VisualStudio.Workload.NativeDesktop -property installationPath
    $redistRoot = Join-Path $visualStudioPath 'VC\Redist\MSVC'
    # 新版 VS 还可能包含 v145 等别名目录，只对完整数字版本目录进行版本排序。
    $runtimeVersions = Get-ChildItem -LiteralPath $redistRoot -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+(\.\d+)?$' } |
        Sort-Object { [version]$_.Name } -Descending
    $crtDirectory = $null
    foreach ($versionDirectory in $runtimeVersions) {
        $x64Directory = Join-Path $versionDirectory.FullName 'x64'
        if (Test-Path -LiteralPath $x64Directory) {
            $crtDirectory = Get-ChildItem -LiteralPath $x64Directory -Directory -Filter 'Microsoft.VC*.CRT' | Select-Object -First 1
            if ($crtDirectory) { break }
        }
    }
    if (-not $crtDirectory) { throw '未找到可再分发的 x64 VC 运行库，不能生成完整发布包。' }

    New-Item -ItemType Directory -Path $packageDirectory -ErrorAction Stop | Out-Null
    # 主程序和运行时 DLL 需要一同分发；不将 PDB、构建缓存或测试入口带入发布包。
    Copy-Item -LiteralPath $executable -Destination $packageDirectory
    Get-ChildItem -LiteralPath $releaseDirectory -Filter '*.dll' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $packageDirectory
    }
    $runtimeData = Join-Path $releaseDirectory 'data'
    if (-not (Test-Path -LiteralPath (Join-Path $runtimeData 'flutter_assets'))) { throw '缺少 Flutter 运行资源。' }
    Copy-Item -LiteralPath $runtimeData -Destination $packageDirectory -Recurse
    $nativeAssets = Join-Path $releaseDirectory 'native_assets.json'
    if (Test-Path -LiteralPath $nativeAssets) { Copy-Item -LiteralPath $nativeAssets -Destination $packageDirectory }
    Get-ChildItem -LiteralPath $crtDirectory.FullName -Filter '*.dll' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $packageDirectory
    }

    # 仅携带面向使用者的公开说明以及完整许可文本；贡献流程留在源代码仓库。
    foreach ($document in @('README.md', 'README.en.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'CHANGELOG.md')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $document) -Destination $packageDirectory
    }
    $packageDocs = Join-Path $packageDirectory 'docs'
    New-Item -ItemType Directory -Path $packageDocs | Out-Null
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\usage.md') -Destination $packageDocs
    Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\licenses') -Destination $packageDocs -Recurse
    if (Test-Path -LiteralPath (Join-Path $projectRoot 'docs\images')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot 'docs\images') -Destination $packageDocs -Recurse
    }
    # 发布清单不记录构建机器用户名或绝对路径，仅写入包内相对路径与文件摘要。
    $files = Get-ChildItem -LiteralPath $packageDirectory -Recurse -File | Sort-Object FullName
    $manifest = foreach ($file in $files) {
        $relative = [System.IO.Path]::GetRelativePath($packageDirectory, $file.FullName).Replace('\', '/')
        if ($file.Extension -match '^\.(pdb|obj|ilk|log|py|pyc)$' -or $relative -match '(^|/)(test_artifacts|\.git|\.dart_tool)(/|$)') {
            throw "发布目录包含不允许分发的项目：$relative"
        }
        [ordered]@{ path = $relative; bytes = $file.Length; sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    [ordered]@{ version = $VersionTag; platform = 'windows-x64'; files = @($manifest) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $packageDirectory 'manifest.json') -Encoding utf8NoBOM
    Compress-Archive -LiteralPath $packageDirectory -DestinationPath $archivePath -CompressionLevel Optimal
    $checksum = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    "$($checksum.Hash.ToLowerInvariant())  $([System.IO.Path]::GetFileName($archivePath))" | Set-Content -LiteralPath "$archivePath.sha256" -Encoding utf8NoBOM
    Write-Output "发布目录：$packageDirectory"
    Write-Output "压缩文件：$archivePath"
    Write-Output "SHA-256：$($checksum.Hash)"
} finally {
    Pop-Location
}
