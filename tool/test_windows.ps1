<#
.SYNOPSIS
在 Windows 上执行公开源码的完整检查，并验证 Release 主入口可以构建。
.NOTES
集成测试仅操作项目 test_artifacts 中自行创建的样本。任一命令失败立即停止，
包括真实回收站验证；不把环境异常或测试失败当作通过。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Invoke-CheckedCommand {
    param([string]$Executable, [string[]]$Arguments)
    & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable $($Arguments -join ' ') 执行失败，退出码 $LASTEXITCODE。"
    }
}

Push-Location -LiteralPath $projectRoot
try {
    Invoke-CheckedCommand 'flutter' @('config', '--enable-windows-desktop')
    Invoke-CheckedCommand 'flutter' @('pub', 'get', '--enforce-lockfile')
    Invoke-CheckedCommand 'dart' @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test', 'integration_test')
    Invoke-CheckedCommand 'flutter' @('analyze')
    Invoke-CheckedCommand 'flutter' @('test', '--reporter', 'expanded')

    # 分别启动原生测试，避免多个 runner 同时争用窗口、原生服务和构建目录。
    $integrationSuites = @(
        'integration_test/native_smoke_test.dart',
        'integration_test/workflow_test.dart',
        'integration_test/folder_native_test.dart',
        'integration_test/multi_workflow_test.dart'
    )
    foreach ($suite in $integrationSuites) {
        Invoke-CheckedCommand 'flutter' @('test', $suite, '-d', 'windows', '--reporter', 'expanded')
    }
    # 显式指定程序入口，不能把最后一次集成测试的入口带入发布构建。
    Invoke-CheckedCommand 'flutter' @('build', 'windows', '--release', '--target', 'lib/main.dart')
} finally {
    Pop-Location
}
