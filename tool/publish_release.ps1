<#
.SYNOPSIS
使用 GitHub CLI 发布已经验证的版本归档，保护现有正式版本不被覆盖。
.NOTES
仅供拥有 contents:write 的发布任务调用；使用环境变量 GH_TOKEN 提供工作流令牌。
先创建草稿、上传、下载复核，最后公开发布。正式版本的重复运行只核验已有产物，
不替换其二进制内容；草稿同名资产内容不一致时停止，要求维护者检查。
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][string]$Repository,
    [Parameter(Mandatory)][string]$ArtifactDirectory,
    [Parameter(Mandatory)][string]$NotesFile
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Tag -cnotmatch '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$' -or
    $Commit -cnotmatch '^[0-9a-f]{40}$' -or
    $Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw '发布参数格式不正确。' }

function Invoke-Gh {
    param([string[]]$Arguments)
    $result = & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI 操作失败：$($Arguments -join ' ')" }
    return ($result -join "`n")
}

function Read-Release {
    # 列表 API 正常返回空数组；网络或权限错误会抛出，不能误当作“版本不存在”。
    $pages = (Invoke-Gh -Arguments @('api', "repos/$Repository/releases?per_page=100", '--paginate', '--slurp')) | ConvertFrom-Json
    $matchedReleases = @(foreach ($page in $pages) { foreach ($release in $page) { if ($release.tag_name -ceq $Tag) { $release } } })
    if ($matchedReleases.Count -gt 1) { throw '远端出现多个同标签版本，拒绝继续。' }
    if ($matchedReleases.Count -eq 0) { return $null }
    return $matchedReleases[0]
}

function Assert-RemoteTagCommit {
    # 必须读取远端当前引用；不能仅凭检出时缓存的本地标签判断标签没有被移动。
    # 同时支持轻量标签和附注标签，逐层解析附注对象后比较最终提交。
    $reference = (Invoke-Gh -Arguments @('api', "repos/$Repository/git/ref/tags/$Tag")) | ConvertFrom-Json
    $targetObject = $reference.object
    for ($depth = 0; $targetObject.type -ceq 'tag'; $depth++) {
        if ($depth -ge 8 -or $targetObject.sha -cnotmatch '^[0-9a-f]{40}$') {
            throw '远端附注标签层级或对象标识不正确。'
        }
        $annotation = (Invoke-Gh -Arguments @('api', "repos/$Repository/git/tags/$($targetObject.sha)")) | ConvertFrom-Json
        $targetObject = $annotation.object
    }
    if ($targetObject.type -cne 'commit' -or $targetObject.sha -cne $Commit) {
        throw '远端标签指向的提交已变化，拒绝发布或修改 Release。'
    }
}

$archiveName = "DupeFileCleaner-$Tag-windows-x64.zip"
$assetNames = @($archiveName, "$archiveName.sha256")
& (Join-Path $PSScriptRoot 'verify_release_package.ps1') -Tag $Tag -ArtifactDirectory $ArtifactDirectory
Assert-RemoteTagCommit
$release = Read-Release
if ($null -ne $release -and $release.target_commitish -cne $Commit) {
    throw '现有 Release 的目标提交与本次标签提交不一致，拒绝覆盖。'
}
$temporaryRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$downloadDirectory = Join-Path $temporaryRoot ('release-verification-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $downloadDirectory

if ($null -ne $release -and -not $release.draft) {
    # 同一提交的再次构建可能带有不同归档时间，因此不强迫新 ZIP 覆盖已发布内容。
    # 只核验远端正式产物自身的完整性；已有内容保持不变。
    foreach ($name in $assetNames) {
        if (@($release.assets | Where-Object { $_.name -ceq $name }).Count -ne 1) { throw "正式 Release 缺少唯一资产：$name" }
        $null = Invoke-Gh -Arguments @('release', 'download', $Tag, '--repo', $Repository, '--pattern', $name, '--dir', $downloadDirectory)
    }
    & (Join-Path $PSScriptRoot 'verify_release_package.ps1') -Tag $Tag -ArtifactDirectory $downloadDirectory
    Write-Output "版本 $Tag 已正式发布，远端产物校验通过，保持现有内容。"
    exit 0
}

if ($null -eq $release) {
    Assert-RemoteTagCommit
    $null = Invoke-Gh -Arguments @('release', 'create', $Tag, '--repo', $Repository, '--verify-tag', '--target', $Commit, '--title', "DupeFile Cleaner $Tag", '--notes-file', $NotesFile, '--draft')
    $release = Read-Release
}
if ($null -eq $release -or -not $release.draft) { throw '未获得可安全填充的 Release 草稿。' }
foreach ($asset in $release.assets) {
    if ($asset.name -cnotin $assetNames) { throw 'Release 草稿包含未知资产，拒绝修改。' }
}
foreach ($name in $assetNames) {
    $localPath = Join-Path $ArtifactDirectory $name
    $existing = @($release.assets | Where-Object { $_.name -ceq $name })
    if ($existing.Count -gt 0) {
        if ($existing.Count -ne 1) { throw "Release 草稿包含重复资产：$name" }
        $null = Invoke-Gh -Arguments @('release', 'download', $Tag, '--repo', $Repository, '--pattern', $name, '--dir', $downloadDirectory)
        if ((Get-FileHash -LiteralPath (Join-Path $downloadDirectory $name) -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $localPath -Algorithm SHA256).Hash) {
            throw "草稿已有同名不同内容资产 $name，拒绝覆盖；请检查该草稿后再重试。"
        }
    } else {
        # 不传 --clobber，避免任何同名资产在并发或手动操作中被覆盖。
        $null = Invoke-Gh -Arguments @('release', 'upload', $Tag, $localPath, '--repo', $Repository)
        $null = Invoke-Gh -Arguments @('release', 'download', $Tag, '--repo', $Repository, '--pattern', $name, '--dir', $downloadDirectory)
    }
}
& (Join-Path $PSScriptRoot 'verify_release_package.ps1') -Tag $Tag -ArtifactDirectory $downloadDirectory
$release = Read-Release
if (-not $release.draft -or $release.target_commitish -cne $Commit -or @($release.assets).Count -ne 2) {
    throw '发布草稿在上传期间发生变化，拒绝切换公开状态。'
}
Assert-RemoteTagCommit
$null = Invoke-Gh -Arguments @('release', 'edit', $Tag, '--repo', $Repository, '--draft=false', '--notes-file', $NotesFile)
$published = Read-Release
if ($null -eq $published -or $published.draft -or $published.target_commitish -cne $Commit) {
    throw 'GitHub 未确认版本已经按预期提交公开发布。'
}
Write-Output "版本 $Tag 已发布：https://github.com/$Repository/releases/tag/$Tag"
