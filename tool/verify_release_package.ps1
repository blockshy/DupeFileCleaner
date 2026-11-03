<#
.SYNOPSIS
校验发布 ZIP、校验文件和包内逐文件清单，不向磁盘解压任何归档内容。
.NOTES
用于发布前、上传后及重复运行时的同一验证路径。拒绝路径跳转、大小写别名、
清单外文件及调试/测试材料；文件摘要直接从 ZIP 数据流计算。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$ArtifactDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Tag -cnotmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw '发布标签格式不正确。' }
$packageName = "DupeFileCleaner-$Tag-windows-x64"
$archiveName = "$packageName.zip"
$archivePath = Join-Path $ArtifactDirectory $archiveName
$checksumPath = "$archivePath.sha256"
$checksum = (Get-Content -LiteralPath $checksumPath -Raw).Trim()
$checksumMatch = [regex]::Match($checksum, '^([0-9a-fA-F]{64})  ' + [regex]::Escape($archiveName) + '$')
if (-not $checksumMatch.Success) { throw 'SHA-256 文件格式或归档文件名不正确。' }
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -ine $checksumMatch.Groups[1].Value) {
    throw '发布 ZIP 的 SHA-256 不匹配。'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead([System.IO.Path]::GetFullPath($archivePath))
try {
    $entries = [System.Collections.Generic.Dictionary[string, System.IO.Compression.ZipArchiveEntry]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $prefix = "$packageName/"
    foreach ($entry in $archive.Entries) {
        $name = $entry.FullName.Replace('\', '/')
        if (-not $name.StartsWith($prefix, [System.StringComparison]::Ordinal) -or
            $name -match '(^|/)\.\.?(/|$)' -or $name.Contains(':')) {
            throw "发布 ZIP 包含不合法的路径：$name"
        }
        if ($name.EndsWith('/')) { continue }
        $relative = $name.Substring($prefix.Length)
        if ([string]::IsNullOrWhiteSpace($relative) -or -not $entries.TryAdd($relative, $entry)) {
            throw '发布 ZIP 包含空路径或重复路径。'
        }
        if ($relative -match '\.(pdb|obj|ilk|log|py|pyc)$' -or
            $relative -match '(^|/)(test_artifacts|\.git|\.dart_tool|\.idea)(/|$)') {
            throw "发布 ZIP 包含不允许分发的项目：$relative"
        }
    }
    foreach ($required in @('dupe_file_cleaner.exe', 'flutter_windows.dll', 'msvcp140.dll', 'vcruntime140.dll', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'manifest.json')) {
        if (-not $entries.ContainsKey($required)) { throw "发布 ZIP 缺少必需文件：$required" }
    }
    $reader = [System.IO.StreamReader]::new($entries['manifest.json'].Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($manifest.version -cne $Tag -or $manifest.platform -cne 'windows-x64' -or @($manifest.files).Count -eq 0) {
        throw '包内清单的版本、平台或文件列表不正确。'
    }
    $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($file in $manifest.files) {
        $path = [string]$file.path
        if ($path -eq 'manifest.json' -or -not $listed.Add($path) -or -not $entries.ContainsKey($path)) {
            throw "包内清单包含重复或不存在的文件：$path"
        }
        if ([string]$file.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $entries[$path].Length -ne $file.bytes) {
            throw "文件摘要格式或长度不正确：$path"
        }
        $stream = $entries[$path].Open()
        try { $digest = (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash } finally { $stream.Dispose() }
        if ($digest -ine $file.sha256) { throw "包内文件 SHA-256 不匹配：$path" }
    }
    if ($entries.Count -ne $listed.Count + 1) { throw '发布 ZIP 含有未列入 manifest.json 的文件。' }
    Write-Output "已校验 $Tag 发布包，共 $($listed.Count) 个清单文件。"
} finally {
    $archive.Dispose()
}
