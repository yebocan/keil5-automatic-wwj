<#
.SYNOPSIS
    指定 Keil 的 UV4.exe 路径，写进本技能的配置文件。

.DESCRIPTION
    本技能的所有脚本（Build-Project.ps1 / Start-Uvision.ps1 / run-test.ps1 /
    Repair-Session.ps1）都通过 KeilCommon.ps1 的 Resolve-KeilUv4 找 Keil，
    查找优先级是：

        1) 命令行参数      -Uv4 "F:\Keil5\UV4\UV4.exe"
        2) 环境变量        KEIL5_UV4
        3) 配置文件        ← 本脚本写的就是这个
        4) 常见安装位置    F:\Keil5、C:\Keil_v5、D:\Keil_v5、E:\Keil_v5、C:\Keil、D:\Keil、E:\Keil
        5) 系统 PATH

    本脚本做的是第 3 项：把路径写进配置文件，这样以后所有脚本都不用再传 -Uv4。

    配置文件位置：%APPDATA%\keil5-automatic-wwj\config.json
    （可用环境变量 KEIL5_AUTOMATIC_WWJ_CONFIG 指向别处）

    本脚本只写这一个 JSON 文件，不改系统环境变量、不改注册表、不动 PATH。

.PARAMETER Uv4
    UV4.exe 的完整路径。省略则自动探测（按上面第 4 项的常见位置找）。

.PARAMETER Show
    只显示当前配置和实际解析结果，不做任何修改。

.PARAMETER Clear
    删除配置文件（回到「没有配置」状态，仍可自动探测）。

.EXAMPLE
    .\Set-KeilPath.ps1
    自动探测 Keil 并写入配置。

.EXAMPLE
    .\Set-KeilPath.ps1 -Uv4 "D:\Keil_v5\UV4\UV4.exe"
    手动指定。

.EXAMPLE
    .\Set-KeilPath.ps1 -Show
    看当前用的是哪个 Keil、从哪来的。
#>
[CmdletBinding()]
param(
    [string]$Uv4,
    [switch]$Show,
    [switch]$Clear
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

function Say([string]$Text) { Write-Host $Text }

Say ''
Say '=== Keil 路径配置 ==='

# ---------------- -Show：只读 ----------------
if ($Show) {
    $cfgPath = Get-KeilConfigPath
    Say ("配置文件: " + $cfgPath)
    $cfg = Get-KeilConfig
    if (-not $cfg.exists) {
        Say '当前状态: 配置文件不存在（没手动指定过，靠自动探测）'
    }
    elseif ($cfg.error) {
        Say ('当前状态: 配置文件存在但坏了 —— ' + $cfg.error)
    }
    else {
        Say ('配置内容: uv4 = ' + $cfg.uv4)
    }

    Say ''
    Say '实际解析结果（各脚本真正会用的那个）:'
    try {
        $r = Resolve-KeilUv4
        Say ('  路径: ' + $r.path)
        Say ('  来源: ' + $r.source)
        Say ('  文件存在: ' + (Test-Path -LiteralPath $r.path))
    }
    catch {
        Say ('  失败: ' + $_.Exception.Message)
    }
    Say ''
    return
}

# ---------------- -Clear：删除配置 ----------------
if ($Clear) {
    $cfgPath = Get-KeilConfigPath
    if (Test-Path -LiteralPath $cfgPath -PathType Leaf) {
        Remove-Item -LiteralPath $cfgPath -Force
        Say ('已删除配置文件: ' + $cfgPath)
        Say '之后仍会按常见安装位置自动探测。'
    }
    else {
        Say ('配置文件本来就不存在: ' + $cfgPath)
    }
    Say ''
    return
}

# ---------------- 指定或探测 ----------------
if (-not $Uv4) {
    Say '没有传 -Uv4，开始自动探测…'
    try {
        $found = Resolve-KeilUv4
        $Uv4 = $found.path
        Say ('探测到: ' + $Uv4 + '（来源: ' + $found.source + '）')
    }
    catch {
        Say ''
        Say '自动探测失败。请手动指定，例如：'
        Say '  .\Set-KeilPath.ps1 -Uv4 "F:\Keil5\UV4\UV4.exe"'
        Say ''
        Say $_.Exception.Message
        exit 1
    }
}

# 只接受确实存在的文件，且必须叫 UV4.exe
$resolved = $null
try {
    $resolved = (Resolve-Path -LiteralPath $Uv4 -ErrorAction Stop).Path
}
catch {
    Say ('路径不存在: ' + $Uv4)
    Say '请确认 Keil 装在哪，例如常见的 F:\Keil5\UV4\UV4.exe。'
    exit 1
}
if ([IO.Path]::GetFileName($resolved) -ne 'UV4.exe') {
    Say ('这个不是 UV4.exe: ' + $resolved)
    Say '本技能需要的是 uVision 的命令行程序 UV4.exe，通常位于 <Keil安装目录>\UV4\UV4.exe。'
    exit 1
}

Set-KeilConfig -Uv4 $resolved

$cfgPath = Get-KeilConfigPath
Say ''
Say '已写入配置:'
Say ('  文件: ' + $cfgPath)
Say ('  内容: { "uv4": "' + ($resolved -replace '\\', '\\') + '" }')

# 写完后立刻回读验证 —— 只写不验等于没配
$back = Get-KeilConfig
$verify = $back.exists -and ($back.uv4 -eq $resolved)
Say ''
if ($verify) {
    Say '回读验证: 通过'
}
else {
    Say '回读验证: 失败（写入的内容读回来不一致）'
    Say ('  读回: ' + $back.uv4)
    exit 1
}

$r = Resolve-KeilUv4
Say ('各脚本现在会用的路径: ' + $r.path)
Say ('来源: ' + $r.source)
Say ''
Say '完成。以后运行 Build-Project.ps1 / Start-Uvision.ps1 都不用再传 -Uv4。'
Say ''
