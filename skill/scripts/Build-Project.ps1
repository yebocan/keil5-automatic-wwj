[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [ValidateSet('build', 'rebuild', 'clean', 'flash')]
    [string]$Action = 'build',
    [string]$LogFile,
    [string]$Uv4,
    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 600,
    # 指定要编译的 Target 名称（工程里有多个 Target 时必须指定）
    [string]$Target,
    # 关掉 HEX 校验（默认开启）
    [switch]$SkipHexCheck
)

# 用 Keil 官方命令行 UV4.exe 编译工程（编译层，不需要 UVSOCK，也不需要 uVision 保持打开）。
#
# UV4 的退出码（官方定义）：
#   0 = 无错误无警告   1 = 只有警告      2 = 有错误
#   3 = 致命错误      11 = 无法写入工程  12 = 设备未找到
#   13 = 写工程失败    15 = 导入 XML 失败 20 = 转换工程失败
#
# 编译结果判定不只看退出码，而是综合：
#   退出码 + 日志里是否出现 error + 日志里是否有结果行 + 本次是否真的产出了 .axf/.hex
# 任何一环拿不到证据，就报 '无法确定'（indeterminate），绝不默认成功。

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

# ---- 定位 UV4.exe（统一走 KeilCommon 的解析链）----
$resolved = Resolve-KeilUv4 -Uv4 $Uv4
$Uv4 = $resolved.path

# ---- 校验工程 ----
if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
    throw "Project file not found: $Project"
}
$Project = (Resolve-Path -LiteralPath $Project).Path

# ---- 解析工程（Target / 输出目录 / HEX 配置 / 源文件）----
$projInfo = $null
$projWarn = $null
try {
    $projInfo = Get-KeilProjectInfo -Project $Project
}
catch {
    $projWarn = "工程解析失败: $($_.Exception.Message)"
}

# 多 Target 处理
$targetName = $Target
if (-not $targetName -and $projInfo -and $projInfo.target) {
    $targetName = $projInfo.target.name
}
$targetAmbiguous = $false
if (-not $Target -and $projInfo -and $projInfo.targetCount -gt 1) {
    $targetAmbiguous = $true
}

# ---- 编译前记录输出文件状态（用于识别「旧文件冒充新产物」）----
$axfPath = $null
$hexPath = $null
if ($projInfo) { $axfPath = $projInfo.axfPath; $hexPath = $projInfo.hexPath }

function Get-FileStamp {
    param([string]$Path)
    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; size = 0; mtime = $null; sha256 = $null }
    }
    $f = Get-Item -LiteralPath $Path
    $hash = $null
    try { $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { }
    return [pscustomobject]@{ exists = $true; size = $f.Length; mtime = $f.LastWriteTime; sha256 = $hash }
}

$axfBefore = Get-FileStamp $axfPath
$hexBefore = Get-FileStamp $hexPath

# ---- 日志文件 ----
if (-not $LogFile) {
    # 日志写到系统临时目录，绝不写进 skill 安装目录，也不污染用户工程目录。
    $logDir = Join-Path ([IO.Path]::GetTempPath()) 'keil5-automatic-wwj'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $LogFile = Join-Path $logDir ("uv4_{0}_{1}.log" -f $Action, (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$LogFile = [IO.Path]::GetFullPath($LogFile)
$logDirParent = Split-Path -Parent $LogFile
if ($logDirParent -and -not (Test-Path -LiteralPath $logDirParent)) {
    New-Item -ItemType Directory -Path $logDirParent -Force | Out-Null
}
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

$timedOut = $false
$exited = $proc.WaitForExit($TimeoutSeconds * 1000)
if (-not $exited) {
    $timedOut = $true
    # 只结束本脚本自己启动的这一个编译进程。
    try { $proc.Kill() } catch { }
    Start-Sleep -Milliseconds 500
}
$proc.Refresh()
$exitCode = $null
if ($exited -and $proc.HasExited) { $exitCode = $proc.ExitCode }

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
$exitName = if ($null -eq $exitCode) { 'NO_EXIT_CODE' }
elseif ($exitNames.ContainsKey($exitCode)) { $exitNames[$exitCode] }
else { "UNKNOWN_$exitCode" }

# ---- 解析日志（统一走 KeilCommon 的解析器，单元测试覆盖同一份实现）----
$logAvailable = $false
if (Test-Path -LiteralPath $LogFile) {
    $logAvailable = ((Get-Item -LiteralPath $LogFile).Length -gt 0)
}

$parsed = Get-KeilBuildLogDiagnostics -Path $LogFile
$lines = $parsed.lines
$diagnostics = $parsed.diagnostics
$programSize = $parsed.programSize
$summaryLine = $parsed.summaryLine
$errorCount = $parsed.errorCount
$warningCount = $parsed.warningCount
$errorCountFromLog = $parsed.errorCountFromLog
$fatalSeen = $parsed.fatalSeen
$targetNotCreated = $parsed.targetNotCreated
$parseError = $parsed.parseError

# 日志解析不出结果行时，回退到诊断条目计数，但标记为不确定。
if (-not $errorCountFromLog) {
    $errorCount = @($diagnostics | Where-Object { $_.kind -ne 'warning' }).Count
    $warningCount = @($diagnostics | Where-Object { $_.kind -eq 'warning' }).Count
}

# ---- 产物状态 ----
$axfAfter = Get-FileStamp $axfPath
$hexAfter = Get-FileStamp $hexPath

function Compare-Stamp {
    param($Before, $After)
    if (-not $After -or -not $After.exists) { return 'missing' }
    if (-not $Before -or -not $Before.exists) { return 'created' }
    if ($Before.sha256 -and $After.sha256 -and $Before.sha256 -ne $After.sha256) { return 'changed' }
    if ($Before.size -ne $After.size) { return 'changed' }
    if ($Before.mtime -ne $After.mtime) { return 'touched' }
    return 'unchanged'
}

$axfState = Compare-Stamp $axfBefore $axfAfter
$hexState = Compare-Stamp $hexBefore $hexAfter

# ---- HEX 格式校验（仅当本次真的产出了 HEX）----
$hexCheck = $null
if (-not $SkipHexCheck -and $hexPath -and $hexAfter.exists -and $hexState -in @('created', 'changed')) {
    $hexCheck = Test-IntelHexFile -Path $hexPath
}

# ---- 综合判定 ----
# success 只代表「本次编译成功产出」；HEX 校验是独立结论，不混为一谈。
$reasons = New-Object System.Collections.ArrayList

$success = $false
$determinate = $true

if ($timedOut) {
    $determinate = $true
    $success = $false
    $null = $reasons.Add("编译超时（超过 $TimeoutSeconds 秒）")
}
elseif ($null -eq $exitCode) {
    $determinate = $false
    $null = $reasons.Add('没有拿到 UV4 的退出码，无法判定')
}
elseif (-not $logAvailable) {
    $determinate = $false
    $null = $reasons.Add('UV4 没有写出日志文件，无法判定')
}
elseif ($parseError) {
    # 日志在手上，但解析过程出错 → 不允许默认成功
    $determinate = $false
    $null = $reasons.Add("编译日志解析失败，无法确定结果: $parseError")
}
elseif (-not $errorCountFromLog) {
    # 日志里没有 "N Error(s), M Warning(s)" 结果行 → 无法确定
    $determinate = $false
    $null = $reasons.Add('日志里没有 "N Error(s), M Warning(s)" 结果行，无法确定编译结果')
}
else {
    if ($errorCount -gt 0) {
        $success = $false
        $null = $reasons.Add("本次编译有 $errorCount 个错误")
    }
    elseif ($exitCode -notin @(0, 1)) {
        $success = $false
        $null = $reasons.Add("退出码 $exitCode ($exitName) 表示编译未正常完成")
    }
    elseif ($Action -in @('build', 'rebuild')) {
        if (-not $axfPath) {
            $determinate = $false
            $null = $reasons.Add('工程里没解析出输出目录/输出名，无法确认是否产出 .axf')
        }
        elseif ($axfState -eq 'missing') {
            $success = $false
            $null = $reasons.Add("日志显示 0 错误，但预期产物不存在: $axfPath")
        }
        elseif ($axfState -eq 'unchanged') {
            $success = $false
            $null = $reasons.Add("预期产物与编译前完全相同（未被本次编译更新）: $axfPath")
        }
        else {
            $success = $true
            $null = $reasons.Add("退出码 $exitCode，0 错误，产物已更新（$axfState）")
        }
    }
    else {
        # clean / flash：只看退出码与日志
        $success = ($exitCode -in @(0, 1))
        $null = $reasons.Add("动作 $Action 完成，退出码 $exitCode")
    }
}

$buildStatus = 'failed'
if ($timedOut) { $buildStatus = 'failed' }
elseif (-not $determinate) { $buildStatus = 'indeterminate' }
elseif ($success) { $buildStatus = 'success' }

# HEX 独立结论
$hexStatus = 'not-applicable'
if ($Action -in @('build', 'rebuild')) {
    if (-not $projInfo -or -not $hexPath) {
        $hexStatus = 'unknown'
    }
    elseif (-not $projInfo.target.createHex) {
        $hexStatus = 'disabled-in-project'
    }
    elseif (-not $hexAfter.exists) {
        $hexStatus = 'not-generated'
    }
    elseif ($hexState -eq 'unchanged') {
        $hexStatus = 'stale-from-previous-build'
    }
    else {
        $hexStatus = 'generated'
    }
}

$hexFormatStatus = 'not-run'
if ($hexCheck) {
    $hexFormatStatus = $(if ($hexCheck.valid) { 'valid' } else { 'invalid' })
}

$result = [ordered]@{
    skill          = 'keil5-automatic-wwj'
    action         = $Action
    project        = $Project
    projectName    = $(if ($projInfo) { [IO.Path]::GetFileNameWithoutExtension($projInfo.project) } else { [IO.Path]::GetFileNameWithoutExtension($Project) })
    target         = $targetName
    targetCount    = $(if ($projInfo) { $projInfo.targetCount } else { $null })
    targetAmbiguous = $targetAmbiguous
    device         = $(if ($projInfo -and $projInfo.target) { $projInfo.target.device } else { $null })
    uv4            = $Uv4
    uv4Source      = $resolved.source
    exitCode       = $exitCode
    exitName       = $exitName
    timedOut       = $timedOut
    success        = $success
    buildStatus    = $buildStatus
    determinate    = $determinate
    reasons        = @($reasons)
    errorCount     = $errorCount
    warningCount   = $warningCount
    errorCountFromLog = $errorCountFromLog
    fatalSeen      = $fatalSeen
    targetNotCreated = $targetNotCreated
    programSize    = $programSize
    diagnostics    = $diagnostics
    summaryLine    = $summaryLine
    axfPath        = $axfPath
    axfState       = $axfState
    hexPath        = $hexPath
    hexState       = $hexState
    hexStatus      = $hexStatus
    hexFormatStatus = $hexFormatStatus
    hexCheck       = $hexCheck
    projectWarning = $projWarn
    parseError     = $parseError
    logFile        = $LogFile
    logAvailable   = $logAvailable
    tail           = @($lines | Where-Object { $_.Trim() } | Select-Object -Last 15)
}
# 输出单行 JSON：调用方（run-test.ps1 / Repair-Session.ps1）会按行取结果，
# 多行 JSON 会让它们只拿到第一行 "{" 而解析失败。
$result | ConvertTo-Json -Depth 8 -Compress

if (-not $success) { exit 1 }
