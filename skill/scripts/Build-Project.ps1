[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [ValidateSet('build', 'rebuild', 'clean', 'flash')]
    [string]$Action = 'build',
    [string]$LogFile,
    [string]$Uv4,
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 600
)

# 用 Keil 官方命令行 UV4.exe 编译工程（编译层，不需要 UVSOCK，也不需要 uVision 保持打开）。
#
# UV4 的退出码（官方定义）：
#   0 = 无错误无警告   1 = 只有警告      2 = 有错误
#   3 = 致命错误      11 = 无法写入工程  12 = 设备未找到
#   13 = 写工程失败    15 = 导入 XML 失败 20 = 转换工程失败
# 注意：编译结果以退出码 + 日志内容为准，进程正常退出不等于编译通过。

$ErrorActionPreference = 'Stop'

# ---- 定位 UV4.exe ----
if (-not $Uv4) {
    $candidates = @('F:\Keil5\UV4\UV4.exe', 'C:\Keil_v5\UV4\UV4.exe', 'D:\Keil_v5\UV4\UV4.exe')
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $found) {
        $cmd = Get-Command UV4.exe -ErrorAction SilentlyContinue
        if ($cmd) { $found = $cmd.Source }
    }
    if (-not $found) { throw 'UV4.exe not found. Pass -Uv4 with the full path.' }
    $Uv4 = $found
}
$Uv4 = (Resolve-Path -LiteralPath $Uv4).Path

if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
    throw "Project file not found: $Project"
}
$Project = (Resolve-Path -LiteralPath $Project).Path

if (-not $LogFile) {
    # 日志写到系统临时目录，绝不写进 skill 安装目录，也不污染用户工程目录。
    $logDir = Join-Path ([IO.Path]::GetTempPath()) 'keil5-automatic-wwj'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogFile = Join-Path $logDir ("uv4_{0}_{1}.log" -f $Action, (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$LogFile = [IO.Path]::GetFullPath($LogFile)
if (Test-Path -LiteralPath $LogFile) { Remove-Item -LiteralPath $LogFile -Force }

$switch = switch ($Action) {
    'build' { '-b' }
    'rebuild' { '-r' }
    'clean' { '-c' }
    'flash' { '-f' }
}

# 关键：UV4 的参数必须作为「一个字符串」传入并自带引号。
# 传数组（@('-b', $proj, '-o', $log)）时 UV4 不会写日志文件。
$argumentLine = "$switch `"$Project`" -o `"$LogFile`" -j0"
$proc = Start-Process -FilePath $Uv4 -ArgumentList $argumentLine -PassThru -WindowStyle Hidden
if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    $proc.Kill()
    throw "UV4 $Action exceeded $TimeoutSeconds seconds and was killed. Log: $LogFile"
}
$proc.Refresh()
$exitCode = $proc.ExitCode

$exitNames = @{
    0  = 'NO_ERRORS_NO_WARNINGS'
    1  = 'WARNINGS_ONLY'
    2  = 'ERRORS'
    3  = 'FATAL_ERROR'
    11 = 'CANNOT_WRITE_PROJECT'
    12 = 'DEVICE_NOT_FOUND'
    13 = 'WRITE_PROJECT_FAILED'
    15 = 'IMPORT_XML_FAILED'
    20 = 'CONVERT_PROJECT_FAILED'
}
$exitName = if ($exitNames.ContainsKey($exitCode)) { $exitNames[$exitCode] } else { "UNKNOWN_$exitCode" }

# ---- 解析日志 ----
$logText = if (Test-Path -LiteralPath $LogFile) { Get-Content -LiteralPath $LogFile -Raw -Encoding Default } else { '' }
$lines = if ($logText) { $logText -split "`r?`n" } else { @() }

# 编译诊断：形如 "main.c(24): error: #5: cannot open source input file ..."
$diagnostics = @()
foreach ($line in $lines) {
    if ($line -match '^\s*(.+?)\((\d+)\)\s*:\s*(error|warning|fatal error)\s*:?\s*(.*)$') {
        $diagnostics += [ordered]@{
            file    = $Matches[1].Trim()
            line    = [int]$Matches[2]
            kind    = $Matches[3].ToLower()
            message = $Matches[4].Trim()
        }
    }
}

# 体积统计："Program Size: Code=568 RO-data=336 RW-data=24 ZI-data=1024"
$programSize = $null
foreach ($line in $lines) {
    if ($line -match 'Program Size:\s*(.+)$') {
        $programSize = @{}
        foreach ($m in [regex]::Matches($Matches[1], '(\w[\w\-]*)=(\d+)')) {
            $programSize[$m.Groups[1].Value] = [int]$m.Groups[2].Value
        }
    }
}

# 结果行：'".\Objects\test.axf" - 0 Error(s), 0 Warning(s).'
$summaryLine = $null
foreach ($line in $lines) {
    if ($line -match '(\d+)\s+Error\(s\),\s*(\d+)\s+Warning\(s\)') { $summaryLine = $line.Trim() }
}

$errorCount = if ($summaryLine -and $summaryLine -match '(\d+)\s+Error\(s\)') { [int]$Matches[1] } else { ($diagnostics | Where-Object { $_.kind -ne 'warning' }).Count }
$warningCount = if ($summaryLine -and $summaryLine -match '(\d+)\s+Warning\(s\)') { [int]$Matches[1] } else { ($diagnostics | Where-Object { $_.kind -eq 'warning' }).Count }

$result = [ordered]@{
    skill         = 'keil5-automatic-wwj'
    action        = $Action
    project       = $Project
    uv4           = $Uv4
    exitCode      = $exitCode
    exitName      = $exitName
    success       = ($exitCode -in @(0, 1) -and $errorCount -eq 0)
    errorCount    = $errorCount
    warningCount  = $warningCount
    programSize   = $programSize
    diagnostics   = $diagnostics
    summaryLine   = $summaryLine
    logFile       = $LogFile
    tail          = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 15)
}
$result | ConvertTo-Json -Depth 6

if (-not $result.success) { exit 1 }
