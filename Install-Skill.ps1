[CmdletBinding()]
param(
    [ValidateSet('all', 'dsh', 'codex', 'doubao', 'doubao-user', 'workbuddy')]
    [string[]]$Target = @('all'),

    # 技能源目录；默认取本脚本同级目录下的 skill\。
    [string]$Source,

    # 只显示会做什么，不实际复制。
    [switch]$DryRun
)

# keil5-automatic-wwj 多平台安装脚本。
#
# 把 skill\ 目录安装到本机各个 AI 客户端的技能目录。各平台路径如下（均已在本机核实）：
#
#   dsh         %USERPROFILE%\.dsh\skills                               DSH 原生技能目录
#   codex       %USERPROFILE%\.codex\skills                             Codex；DSH 也会扫描
#   doubao      %USERPROFILE%\Doubao\skills                             豆包工作电脑版（用户既有位置）
#   doubao-user ...\Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills
#                                                                       豆包官方用户技能目录
#   workbuddy   %USERPROFILE%\.workbuddy\skills                         WorkBuddy
#
# 注意：同一台机器上装多份时，改完源码要重新跑一次本脚本，各平台副本才会同步。

$ErrorActionPreference = 'Stop'

$skillName = 'keil5-automatic-wwj'

if (-not $Source) {
    $Source = Join-Path $PSScriptRoot 'skill'
}
$Source = [IO.Path]::GetFullPath($Source)

if (-not (Test-Path -LiteralPath $Source)) {
    throw "找不到技能源目录: $Source"
}
if (-not (Test-Path -LiteralPath (Join-Path $Source 'SKILL.md'))) {
    throw "技能源目录里没有 SKILL.md，可能不是技能目录: $Source"
}

function Get-TargetMap {
    $home_ = $env:USERPROFILE
    $doubaoUserSkills = Join-Path $env:LOCALAPPDATA 'Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills'

    $map = [ordered]@{
        'dsh'         = @{ Path = Join-Path $home_ '.dsh\skills';          Label = 'DSH（原生技能目录）' }
        'codex'       = @{ Path = Join-Path $home_ '.codex\skills';        Label = 'Codex（DSH 也会扫描）' }
        'doubao'      = @{ Path = Join-Path $home_ 'Doubao\skills';        Label = '豆包（用户既有位置）' }
        'doubao-user' = @{ Path = $doubaoUserSkills;                       Label = '豆包（官方用户技能目录）' }
        'workbuddy'   = @{ Path = Join-Path $home_ '.workbuddy\skills';    Label = 'WorkBuddy' }
    }
    return $map
}

$map = Get-TargetMap

# 展开 all
$keys = @()
foreach ($t in $Target) {
    if ($t -eq 'all') { $keys += $map.Keys } else { $keys += $t }
}
$keys = $keys | Select-Object -Unique

Write-Host ''
Write-Host "技能:     $skillName"
Write-Host "源目录:   $Source"
Write-Host "目标平台: $($keys -join ', ')"
Write-Host ''

$results = @()

foreach ($k in $keys) {
    $dest = Join-Path $map[$k].Path $skillName
    $parentExists = Test-Path -LiteralPath $map[$k].Path
    $alreadyThere = Test-Path -LiteralPath $dest

    if ($DryRun) {
        Write-Host ("  [试运行] {0,-12} -> {1}" -f $k, $dest)
        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            parentExisted = $parentExists; replaced = $alreadyThere; installed = $false
        }
        continue
    }

    try {
        New-Item -ItemType Directory -Path $map[$k].Path -Force | Out-Null
        if ($alreadyThere) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }
        Copy-Item -LiteralPath $Source -Destination $dest -Recurse -Force

        $fileCount = (Get-ChildItem -LiteralPath $dest -Recurse -File | Measure-Object).Count
        $ok = Test-Path -LiteralPath (Join-Path $dest 'SKILL.md')

        Write-Host ("  [完成] {0,-12} {1} 个文件 -> {2}" -f $k, $fileCount, $dest)

        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            parentExisted = $parentExists; replaced = $alreadyThere
            installed = $ok; files = $fileCount
        }
    }
    catch {
        Write-Host ("  [失败] {0,-12} {1}" -f $k, $_.Exception.Message)
        $results += [pscustomobject]@{
            target = $k; label = $map[$k].Label; destination = $dest
            parentExisted = $parentExists; replaced = $alreadyThere
            installed = $false; error = $_.Exception.Message
        }
    }
}

Write-Host ''
Write-Host '汇总：'
$results | ForEach-Object {
    $mark = if ($DryRun) { '·' } elseif ($_.installed) { '✓' } else { '✗' }
    Write-Host ("  {0} {1,-12} {2}" -f $mark, $_.target, $_.destination)
}

$okCount = ($results | Where-Object { $_.installed }).Count
if (-not $DryRun) {
    Write-Host ''
    Write-Host "成功 $okCount / $($results.Count) 个平台。"
    if ($okCount -lt $results.Count) {
        Write-Host '有平台安装失败，见上面的错误信息。'
        exit 1
    }
}

# 机器可读结果，方便脚本调用方解析。
$results | ConvertTo-Json -Depth 4 -Compress | Write-Output
