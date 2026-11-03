<#
.SYNOPSIS
校验已存在的稳定版本标签、提交、项目版本与变更说明，输出发布元数据。
.PARAMETER Tag
现有 Git 标签，格式为 v主版本.次版本.修订版本。
.PARAMETER ExpectedCommit
可选的预期提交；构建和发布阶段传入该值以发现检查之后发生的标签移动。
.PARAMETER NotesFile
从标签指向的 CHANGELOG.md 提取的版本说明保存位置。
.NOTES
所有版本信息直接从同一个 Git 提交读取，不依赖工作目录中可能被修改的文件。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,
    [string]$ExpectedCommit = '',
    [string]$NotesFile = 'build/release-notes.md'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Read-GitOutput {
    param([string[]]$Arguments)
    $result = & git @Arguments
    if ($LASTEXITCODE -ne 0) { throw "无法读取 Git 元数据：$($Arguments -join ' ')" }
    return ($result -join "`n")
}

if ($Tag -cnotmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw '标签必须是 vX.Y.Z 格式的稳定版本，且不能包含前导零。'
}
Push-Location -LiteralPath $projectRoot
try {
    $commit = (Read-GitOutput @('rev-parse', '--verify', "refs/tags/$Tag^{commit}")).Trim()
    if ($commit -cnotmatch '^[0-9a-f]{40}$') { throw '标签未解析到合法的提交。' }
    if ($ExpectedCommit -and $commit -cne $ExpectedCommit) { throw '标签指向的提交已变化，拒绝发布。' }
    $version = $Tag.Substring(1)
    $pubspec = Read-GitOutput @('show', "${commit}:pubspec.yaml")
    $versionLines = [regex]::Matches($pubspec, '(?m)^version:\s*(\d+\.\d+\.\d+)(?:\+\d+)?\s*$')
    if ($versionLines.Count -ne 1 -or $versionLines[0].Groups[1].Value -cne $version) {
        throw '标签版本与 pubspec.yaml 版本不一致。'
    }

    # 只使用该版本的产品变更说明，不将提交列表或其他版本说明自动混入 Release。
    $changelog = Read-GitOutput @('show', "${commit}:CHANGELOG.md")
    $heading = '(?m)^##\s+\[?' + [regex]::Escape($version) + '\]?(?:\s+-\s+[^\r\n]+)?\s*$'
    $sections = [regex]::Matches($changelog, $heading)
    if ($sections.Count -ne 1) { throw "CHANGELOG.md 必须恰好包含一个 $version 版本节。" }
    $section = $sections[0]
    $tail = $changelog.Substring($section.Index + $section.Length)
    $nextHeading = [regex]::Match($tail, '(?m)^##\s+')
    $notes = $(if ($nextHeading.Success) { $tail.Substring(0, $nextHeading.Index) } else { $tail }).Trim()
    if ([string]::IsNullOrWhiteSpace($notes)) { throw '当前版本的发布说明不能为空。' }
    $notesPath = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $NotesFile))
    $null = New-Item -ItemType Directory -Path ([System.IO.Path]::GetDirectoryName($notesPath)) -Force
    [System.IO.File]::WriteAllText($notesPath, "$notes`n", [System.Text.UTF8Encoding]::new($false))

    if ($env:GITHUB_OUTPUT) {
        @("tag=$Tag", "version=$version", "commit=$commit") | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8
    }
    Write-Output "已校验版本 $Tag，提交 $commit。"
} finally {
    Pop-Location
}
