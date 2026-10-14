# =====================================================================
# KeilCommon.ps1 — keil5-automatic-wwj 公共模块
#
# 被 Build-Project.ps1 / Start-Uvision.ps1 / run-test.ps1 点源引用，统一提供：
#   1. Keil (UV4.exe) 路径解析 —— 所有脚本共用同一份配置来源，不再各写各的
#   2. uVision 进程安全清理 —— 只结束本脚本自己启动的进程，绝不按名字批量杀
#   3. Intel HEX 格式校验 —— 按记录结构、校验和、结束记录逐项检查
#
# 兼容 Windows PowerShell 5.1 与 PowerShell 7+（不使用 ?: / ?? / 三元运算符）。
# =====================================================================

$ErrorActionPreference = 'Stop'

# =====================================================================
# 0. 超时预算
# =====================================================================
#
# 脚本里的轮询循环（等 uVision 起、等断点命中、等调试会话就绪）都必须先问
# 这里「还剩多少秒」。否则某个轮询卡住就会无限等下去。
#
# 用法：
#   $deadline = New-KeilDeadline -Seconds 600
#   $budget   = Get-KeilBudget -Deadline $deadline -Want 30 -Minimum 3
#   $budget   = Assert-KeilBudget -Deadline $deadline -Stage '等断点命中'
#
# 预算不足时抛错（而不是返回 0 或负数），让调用方立刻停下并如实报告，
# 不要拿一个「假装还能等」的值继续跑。

function New-KeilDeadline {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Seconds
    )
    if ($Seconds -le 0) { throw "超时预算必须是正数，收到 $Seconds" }
    return (Get-Date).AddSeconds($Seconds)
}

function Get-KeilRemainingSeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline
    )
    return [int][Math]::Floor(($Deadline - (Get-Date)).TotalSeconds)
}

# 返回本轮最多还能等多少秒。$Want 是调用方希望的时长，$Minimum 是该步骤
# 至少需要多久才能有意义（例如 uVision 启动至少要 3 秒）。
function Get-KeilBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline,
        [Parameter(Mandatory = $true)]
        [int]$Want,
        [int]$Minimum = 1
    )
    $left = Get-KeilRemainingSeconds -Deadline $Deadline
    if ($left -lt $Minimum) {
        throw "总超时预算即将用尽（剩余 $left 秒，此步骤至少需要 $Minimum 秒）。"
    }
    return [Math]::Min($Want, $left)
}

function Assert-KeilBudget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$Deadline,
        [Parameter(Mandatory = $true)]
        [string]$Stage
    )
    $left = Get-KeilRemainingSeconds -Deadline $Deadline
    if ($left -le 0) { throw "总超时预算已用完，停在：$Stage" }
    return $left
}

# =====================================================================
# 1. Keil 路径解析
# =====================================================================
#
# 配置来源优先级（从高到低）：
#   1) 调用方显式传入的 -Uv4
#   2) 环境变量 KEIL5_UV4
#   3) 配置文件（默认 %APPDATA%\keil5-automatic-wwj\config.json，
#      可用环境变量 KEIL5_AUTOMATIC_WWJ_CONFIG 覆盖路径）
#   4) 常见安装位置候选
#   5) 系统 PATH 中的 UV4.exe
#
# 找不到时抛错并逐条列出「试过哪些地方」，绝不静默失败、绝不扫描整个磁盘。

function Get-KeilConfigPath {
    if ($env:KEIL5_AUTOMATIC_WWJ_CONFIG) {
        return [IO.Path]::GetFullPath($env:KEIL5_AUTOMATIC_WWJ_CONFIG)
    }
    return (Join-Path $env:APPDATA 'keil5-automatic-wwj\config.json')
}

function Get-KeilConfig {
    <#
    .SYNOPSIS
        读取本技能的配置文件。
    .DESCRIPTION
        配置文件缺失 → 返回 exists=$false，属于正常情况（用户没配过）。
        配置文件存在但解析不了 → 这是「用户配错了」，必须让人看见：
          * 默认 Write-Warning 报警，并继续返回对象（error 字段非空），
            这样调用方（Resolve-KeilUv4）还能降级到候选路径继续干活；
          * 加 -Strict 则直接抛异常，供需要「配错就停」的调用方使用。
        绝不允许把损坏的配置静默当成「没有配置」——那会让用户以为自己的
        设置生效了，实际一直在用别的路径。
    #>
    [CmdletBinding()]
    param([switch]$Strict)

    $path = Get-KeilConfigPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ path = $path; exists = $false; uv4 = $null; error = $null }
    }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{ path = $path; exists = $true; uv4 = $json.uv4; error = $null }
    }
    catch {
        $msg = "配置文件 $path 无法解析：$($_.Exception.Message)"
        if ($Strict) { throw $msg }
        Write-Warning ($msg + ' 已忽略该文件，继续按候选路径查找 Keil。请修正或删除它。')
        return [pscustomobject]@{ path = $path; exists = $true; uv4 = $null; error = $msg }
    }
}

function Set-KeilConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uv4
    )
    if (-not (Test-Path -LiteralPath $Uv4 -PathType Leaf)) {
        throw "不是有效的文件路径: $Uv4"
    }
    $resolved = (Resolve-Path -LiteralPath $Uv4).Path
    $path = Get-KeilConfigPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $obj = [ordered]@{
        uv4      = $resolved
        saved_at = (Get-Date).ToString('s')
    }
    ($obj | ConvertTo-Json) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Resolve-KeilUv4 {
    [CmdletBinding()]
    param(
        [string]$Uv4
    )

    $attempts = New-Object System.Collections.ArrayList

    # ---- 1) 显式参数 ----
    if ($Uv4) {
        if (Test-Path -LiteralPath $Uv4 -PathType Leaf) {
            $p = (Resolve-Path -LiteralPath $Uv4).Path
            return [pscustomobject]@{ path = $p; source = 'parameter'; attempts = @($attempts) }
        }
        $null = $attempts.Add("1) -Uv4 参数: $Uv4 （文件不存在）")
    }

    # ---- 2) 环境变量 ----
    if ($env:KEIL5_UV4) {
        if (Test-Path -LiteralPath $env:KEIL5_UV4 -PathType Leaf) {
            $p = (Resolve-Path -LiteralPath $env:KEIL5_UV4).Path
            return [pscustomobject]@{ path = $p; source = 'env:KEIL5_UV4'; attempts = @($attempts) }
        }
        $null = $attempts.Add("2) 环境变量 KEIL5_UV4=$env:KEIL5_UV4 （文件不存在）")
    }
    else {
        $null = $attempts.Add('2) 环境变量 KEIL5_UV4 未设置')
    }

    # ---- 3) 配置文件 ----
    $cfg = Get-KeilConfig
    if ($cfg.error) {
        $null = $attempts.Add("3) 配置文件 $($cfg.path) 解析失败: $($cfg.error)")
    }
    elseif ($cfg.uv4) {
        if (Test-Path -LiteralPath $cfg.uv4 -PathType Leaf) {
            $p = (Resolve-Path -LiteralPath $cfg.uv4).Path
            return [pscustomobject]@{ path = $p; source = "config:$($cfg.path)"; attempts = @($attempts) }
        }
        $null = $attempts.Add("3) 配置文件 $($cfg.path) 指向 $($cfg.uv4) （文件不存在）")
    }
    else {
        $null = $attempts.Add("3) 配置文件 $($cfg.path) 不存在或没有 uv4 字段")
    }

    # ---- 4) 常见安装位置 ----
    # 可用环境变量 KEIL5_UV4_CANDIDATES 覆盖（分号分隔）——换机器/换盘符时不用改脚本。
    $candidates = @(
        'F:\Keil5\UV4\UV4.exe',
        'C:\Keil_v5\UV4\UV4.exe',
        'D:\Keil_v5\UV4\UV4.exe',
        'E:\Keil_v5\UV4\UV4.exe',
        'C:\Keil\UV4\UV4.exe',
        'D:\Keil\UV4\UV4.exe',
        'E:\Keil\UV4\UV4.exe'
    )
    if ($env:KEIL5_UV4_CANDIDATES) {
        $candidates = @($env:KEIL5_UV4_CANDIDATES -split ';' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    }
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            $p = (Resolve-Path -LiteralPath $c).Path
            return [pscustomobject]@{ path = $p; source = "candidate:$c"; attempts = @($attempts) }
        }
    }
    $null = $attempts.Add("4) 常见安装位置: 检查了 $($candidates.Count) 个路径，均不存在")

    # ---- 5) PATH ----
    $cmd = Get-Command UV4.exe -ErrorAction SilentlyContinue
    if ($cmd -and (Test-Path -LiteralPath $cmd.Source -PathType Leaf)) {
        return [pscustomobject]@{ path = $cmd.Source; source = 'PATH'; attempts = @($attempts) }
    }
    $null = $attempts.Add('5) 系统 PATH 中未找到 UV4.exe')

    $detail = ($attempts | ForEach-Object { "    $_" }) -join "`r`n"
    $cfgPath = Get-KeilConfigPath
    $msg = "找不到 Keil 的 UV4.exe。已按优先级试过以下来源，全部失败：`r`n$detail`r`n`r`n请任选一种方式指定 Keil 路径：`r`n    1) 命令行参数   -Uv4 ""F:\Keil5\UV4\UV4.exe""`r`n    2) 环境变量     setx KEIL5_UV4 ""F:\Keil5\UV4\UV4.exe""`r`n    3) 配置文件     $cfgPath`r`n                    内容: { ""uv4"": ""F:\\\\Keil5\\\\UV4\\\\UV4.exe"" }`r`n    4) 运行一次     .\Set-KeilPath.ps1 -Uv4 ""F:\Keil5\UV4\UV4.exe""`r`n"
    throw $msg
}

# =====================================================================
# 2. uVision 进程安全清理
# =====================================================================
#
# 安全约束（按优先级）：
#   1. 绝不按名字批量结束 UV4 —— 用户可能同时开着别的 Keil 工程，强杀会丢未保存的修改。
#   2. 只接受调用方显式传入的 PID，不猜、不扫、不按名字匹配。
#   3. 结束前核对进程名与启动时间，防止 PID 被系统复用后误杀无关进程。
#   4. 先优雅退出（UVSOCK exit → 关闭主窗口），都失败才强杀，且只杀这一个 PID。

function Get-ProcessIdentity {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $started = $null
    try { $started = $p.StartTime } catch { }
    $path = $null
    try { $path = $p.Path } catch { }
    return [pscustomobject]@{
        pid       = $p.Id
        name      = $p.ProcessName
        startedAt = $started
        path      = $path
    }
}

function Get-UvisionProcesses {
    # 只用于「记录」已有实例，绝不用于结束。
    $list = @()
    foreach ($p in @(Get-Process -Name UV4 -ErrorAction SilentlyContinue)) {
        $started = $null
        try { $started = $p.StartTime } catch { }
        $list += [pscustomobject]@{ pid = $p.Id; startedAt = $started }
    }
    return $list
}

function Stop-OwnedUvision {
    [CmdletBinding()]
    param(
        [int]$ProcessId,
        # 用 object 而不是 datetime：拿不到启动时间时必须「拒绝清理」，
        # 不能因为 $null 转不成 DateTime 就抛异常（那会让调用方的 finally 崩掉）。
        [object]$StartedAt,
        [int]$Port,
        [string]$ClientExe,
        [int]$GracefulWaitSeconds = 8
    )

    $out = [ordered]@{
        pid       = $ProcessId
        attempted = $false
        refused   = $false
        method    = $null
        killed    = $false
        message   = $null
    }

    if (-not $ProcessId -or $ProcessId -le 0) {
        $out.message = '没有记录到本脚本启动的 PID，不做任何清理。'
        return [pscustomobject]$out
    }

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $proc) {
        $out.message = "PID $ProcessId 已经退出，无需清理。"
        return [pscustomobject]$out
    }

    if ($proc.ProcessName -ne 'UV4') {
        $out.refused = $true
        $out.message = "PID $ProcessId 现在的进程名是 '$($proc.ProcessName)'，不是 UV4，拒绝结束。"
        return [pscustomobject]$out
    }

    if ($StartedAt -and $StartedAt -ne [datetime]::MinValue) {
        # $StartedAt 声明成 object 是为了容忍 null / 字符串（来自 JSON 的登记表）。
        # 能转成 DateTime 就比对；转不了就当作「没有可信启动时间」——
        # 此时进程名已经是 UV4，仍然放行，但把情况写进 message 以便排查。
        $asDate = $null
        try { $asDate = [datetime]$StartedAt } catch { $asDate = $null }
        if ($null -ne $asDate -and $asDate -ne [datetime]::MinValue) {
            try {
                $delta = [Math]::Abs(($proc.StartTime - $asDate).TotalSeconds)
                if ($delta -gt 2) {
                    $out.refused = $true
                    $out.message = "PID $ProcessId 的启动时间与记录相差 $([Math]::Round($delta, 1)) 秒，疑似 PID 被复用，拒绝结束。"
                    return [pscustomobject]$out
                }
            }
            catch { }
        }
    }

    $out.attempted = $true

    # ---- 第一优先：让 uVision 自己退出 ----
    if ($Port -and $ClientExe -and (Test-Path -LiteralPath $ClientExe)) {
        try { & $ClientExe $Port 'exit' 2>&1 | Out-Null } catch { }
        $deadline = (Get-Date).AddSeconds($GracefulWaitSeconds)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 400
            if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
                $out.method = 'uvsock-exit'
                $out.message = "PID $ProcessId 已通过 UVSOCK exit 正常退出。"
                # 进程没了就把登记表里的这条也撤掉，否则登记表只增不减，
                # 跑几十次之后积一堆死 PID，真残留反而被淹没。
                $out.registryEntryRemoved = Remove-KeilOwnedRegistryEntry -ProcessId $ProcessId
                return [pscustomobject]$out
            }
        }
    }

    # ---- 第二优先：要求主窗口正常关闭 ----
    try {
        $proc.Refresh()
        if ($proc.MainWindowHandle -ne 0) {
            $null = $proc.CloseMainWindow()
            $deadline = (Get-Date).AddSeconds($GracefulWaitSeconds)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Milliseconds 400
                if (-not (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) {
                    $out.method = 'close-main-window'
                    $out.message = "PID $ProcessId 已通过关闭主窗口正常退出。"
                    $out.registryEntryRemoved = Remove-KeilOwnedRegistryEntry -ProcessId $ProcessId
                    return [pscustomobject]$out
                }
            }
        }
    }
    catch { }

    # ---- 最后手段：只强杀这一个 PID ----
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
        $out.method = 'force-kill'
        $out.killed = $true
        $out.message = "PID $ProcessId 未响应正常退出，已强制结束（仅此一个进程）。"
        $out.registryEntryRemoved = Remove-KeilOwnedRegistryEntry -ProcessId $ProcessId
    }
    catch {
        $out.method = 'failed'
        $out.message = "PID $ProcessId 强制结束失败: $($_.Exception.Message)"
    }
    return [pscustomobject]$out
}

# ---------------------------------------------------------------------
# 3.0 启动登记表：异常中断后也能认出「这是我自己起的 uVision」
# ---------------------------------------------------------------------
#
# 背景（实测踩到的坑）：run-test.ps1 用 try/finally 清理自己启动的 uVision，
# 但如果整个 PowerShell 进程被强杀（Ctrl+C、任务管理器、作业被终止），
# finally 不会执行，测试起的 uVision 就残留下来。用户任务书要求
# 「测试后原有 Keil 仍在运行」「只清理自己创建的进程」，残留同样算缺陷。
#
# 做法：Start-Uvision.ps1 启动成功后立刻把 {pid, started_at, port, project, script}
# 写进登记表（默认 %TEMP%\keil5-automatic-wwj\owned-uvision.json）。下次运行任何
# 脚本时都能读出来，判断哪些是「本项目起过的」。清理前仍要逐项复核
# PID 存活、进程名是 UV4、启动时间吻合——登记表只是线索，不是杀进程的授权。

function Get-KeilOwnedRegistryPath {
    $root = Join-Path ([IO.Path]::GetTempPath()) 'keil5-automatic-wwj'
    return (Join-Path $root 'owned-uvision.json')
}

function Register-OwnedUvision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [datetime]$StartedAt,
        [int]$Port,
        [string]$Project
    )

    $path = Get-KeilOwnedRegistryPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $entries = @()
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $existing = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($existing) { $entries = @($existing) }
        }
        catch { $entries = @() }   # 登记表损坏就当空的，不因此让启动失败
    }

    # 同一 PID 只留一条（重跑覆盖旧记录）
    $entries = @($entries | Where-Object { $_.pid -ne $ProcessId })

    $entries += [pscustomobject]@{
        pid        = $ProcessId
        started_at = $(if ($StartedAt) { $StartedAt.ToString('o') } else { $null })
        port       = $Port
        project    = $Project
        recorded_at = (Get-Date).ToString('o')
    }

    $entries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

# 读出登记表里仍然存活的条目（只读，不结束任何进程）。
# 返回每项 {pid, alive, processName, startedAt, startedAtMatches, port, project, owned}
function Get-RegisteredOwnedUvision {
    [CmdletBinding()]
    param()

    $path = Get-KeilOwnedRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }

    $entries = @()
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($raw) { $entries = @($raw | ConvertFrom-Json) }
    }
    catch { return @() }

    $result = @()
    foreach ($e in $entries) {
        if (-not $e.pid) { continue }
        $proc = Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue
        $recorded = $null
        if ($e.started_at) { try { $recorded = [datetime]::Parse($e.started_at) } catch { } }

        $item = [pscustomobject]@{
            pid                = [int]$e.pid
            alive              = ($null -ne $proc)
            processName        = $(if ($proc) { $proc.ProcessName } else { $null })
            startedAt          = $(if ($proc) { try { $proc.StartTime } catch { $null } } else { $null })
            startedAtMatches   = $false
            port               = $e.port
            project            = $e.project
            owned              = $false
        }
        if ($proc -and $proc.ProcessName -eq 'UV4') {
            $item.owned = $true
            if ($recorded -and $item.startedAt) {
                $delta = [Math]::Abs(($item.startedAt - $recorded).TotalSeconds)
                $item.startedAtMatches = ($delta -le 2)
                # 启动时间对不上说明 PID 已被别的进程复用，撤销 owned 判定
                if (-not $item.startedAtMatches) { $item.owned = $false }
            }
        }
        $result += $item
    }
    return $result
}

# 清掉登记表里「已经确定不再属于本项目的」条目：进程已退出、进程名不再是 UV4、
# 或启动时间与记录对不上（PID 被复用）。只删登记表里的记录，绝不结束任何进程。
#
# 为什么需要它：登记表只增不减的话，跑几十次测试后会积一大堆死 PID，
# 每次运行都把它们当成「残留」报出来，真正的残留反而被淹没。
function Remove-KeilDeadRegistryEntries {
    [CmdletBinding()]
    param()

    $path = Get-KeilOwnedRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ path = $path; existed = $false; before = 0; removed = 0; kept = 0 }
    }

    $entries = @()
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if ($raw) { $entries = @($raw | ConvertFrom-Json) }
    }
    catch { return [pscustomobject]@{ path = $path; existed = $true; before = 0; removed = 0; kept = 0; parseError = $true } }

    $before = $entries.Count
    $kept = @()
    foreach ($e in $entries) {
        if (-not $e.pid) { continue }                      # 没有 PID 的记录没有意义
        $proc = Get-Process -Id ([int]$e.pid) -ErrorAction SilentlyContinue
        if (-not $proc) { continue }                       # 已退出
        if ($proc.ProcessName -ne 'UV4') { continue }      # PID 被别的程序复用了
        if ($e.started_at) {
            $recorded = $null
            try { $recorded = [datetime]::Parse($e.started_at) } catch { }
            if ($recorded) {
                $st = $null
                try { $st = $proc.StartTime } catch { }
                if ($st -and ([Math]::Abs(($st - $recorded).TotalSeconds) -gt 2)) { continue }
            }
        }
        $kept += $e
    }

    if ($kept.Count -eq 0) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    else {
        $kept | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    }

    return [pscustomobject]@{
        path    = $path
        existed = $true
        before  = $before
        removed = ($before - $kept.Count)
        kept    = $kept.Count
    }
}

# 清掉登记表里已经不存活的条目；可选把「疑似残留」一起报出来。
function Remove-KeilOwnedRegistryEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId
    )
    $path = Get-KeilOwnedRegistryPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        $entries = @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
        $kept = @($entries | Where-Object { $_.pid -ne $ProcessId })
        if ($kept.Count -eq 0) {
            Remove-Item -LiteralPath $path -Force
        }
        else {
            $kept | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
        }
        return ($kept.Count -ne $entries.Count)
    }
    catch { return $false }
}

# =====================================================================
# 3. Intel HEX 格式校验
# =====================================================================
#
# 逐行检查记录结构（:LLAAAATT...CC）、字节数声明、校验和、结束记录，
# 并统计数据记录数与地址范围。只按内容判断，不靠扩展名。

function Test-IntelHexFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$MaxBytes = 16777216
    )

    $res = [ordered]@{
        path           = $Path
        exists         = $false
        size           = 0
        format         = 'unknown'
        valid          = $false
        records        = 0
        dataRecords    = 0
        dataBytes      = 0
        eofSeen        = $false
        checksumErrors = 0
        malformedLines = 0
        firstErrorLine = $null
        firstErrorText = $null
        addressRange   = $null
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $res.firstErrorText = '文件不存在'
        return [pscustomobject]$res
    }
    $res.exists = $true

    $fi = Get-Item -LiteralPath $Path
    $res.size = $fi.Length
    if ($fi.Length -eq 0) {
        $res.firstErrorText = '文件为空（0 字节）'
        return [pscustomobject]$res
    }
    if ($fi.Length -gt $MaxBytes) {
        $res.firstErrorText = "文件过大（$($fi.Length) 字节），跳过格式校验"
        return [pscustomobject]$res
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding ASCII)
    $baseAddr = 0
    $minAddr = $null
    $maxAddr = $null
    $lineNo = 0
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $hexStyle = [Globalization.NumberStyles]::HexNumber

    foreach ($raw in $lines) {
        $lineNo++
        $line = $raw.Trim()
        if ($line -eq '') { continue }
        $res.records++

        if (-not $line.StartsWith(':')) {
            $res.malformedLines++
            if (-not $res.firstErrorLine) { $res.firstErrorLine = $lineNo; $res.firstErrorText = '行首不是冒号' }
            continue
        }

        $hex = $line.Substring(1)
        if (($hex.Length % 2) -ne 0 -or $hex.Length -lt 10) {
            $res.malformedLines++
            if (-not $res.firstErrorLine) { $res.firstErrorLine = $lineNo; $res.firstErrorText = '十六进制长度非法' }
            continue
        }

        $byteCount = $hex.Length / 2
        $bytes = New-Object byte[] $byteCount
        $bad = $false
        for ($i = 0; $i -lt $byteCount; $i++) {
            $b = [byte]0
            if (-not [byte]::TryParse($hex.Substring($i * 2, 2), $hexStyle, $inv, [ref]$b)) {
                $bad = $true
                break
            }
            $bytes[$i] = $b
        }
        if ($bad) {
            $res.malformedLines++
            if (-not $res.firstErrorLine) { $res.firstErrorLine = $lineNo; $res.firstErrorText = '含非十六进制字符' }
            continue
        }

        $len = [int]$bytes[0]
        if ($bytes.Length -ne ($len + 5)) {
            $res.malformedLines++
            if (-not $res.firstErrorLine) {
                $res.firstErrorLine = $lineNo
                $res.firstErrorText = "字节数声明 $len 与实际 $($bytes.Length - 5) 不符"
            }
            continue
        }

        $sum = 0
        for ($i = 0; $i -lt ($bytes.Length - 1); $i++) {
            $sum = ($sum + [int]$bytes[$i]) -band 0xFF
        }
        $expect = (0x100 - $sum) -band 0xFF
        if ([int]$bytes[$bytes.Length - 1] -ne $expect) {
            $res.checksumErrors++
            if (-not $res.firstErrorLine) { $res.firstErrorLine = $lineNo; $res.firstErrorText = '校验和不匹配' }
            continue
        }

        $type = [int]$bytes[3]
        $addr = $baseAddr + ([int]$bytes[1] * 256) + [int]$bytes[2]

        if ($type -eq 0) {
            $res.dataRecords++
            $res.dataBytes += $len
            if ($null -eq $minAddr -or $addr -lt $minAddr) { $minAddr = $addr }
            $end = $addr + $len - 1
            if ($null -eq $maxAddr -or $end -gt $maxAddr) { $maxAddr = $end }
        }
        elseif ($type -eq 1) {
            $res.eofSeen = $true
        }
        elseif ($type -eq 4) {
            if ($len -eq 2) { $baseAddr = (([int]$bytes[4] * 256) + [int]$bytes[5]) * 65536 }
        }
        elseif ($type -eq 2) {
            if ($len -eq 2) { $baseAddr = (([int]$bytes[4] * 256) + [int]$bytes[5]) * 16 }
        }
        elseif ($type -eq 3 -or $type -eq 5) {
            # 起始地址记录，内容合法即可
        }
        else {
            $res.malformedLines++
            if (-not $res.firstErrorLine) { $res.firstErrorLine = $lineNo; $res.firstErrorText = "未知记录类型 $type" }
            continue
        }
    }

    if ($null -ne $minAddr) {
        $res.addressRange = ('0x{0:X8}-0x{1:X8}' -f $minAddr, $maxAddr)
    }
    $res.format = 'intel-hex'
    $res.valid = ($res.malformedLines -eq 0 -and $res.checksumErrors -eq 0 -and $res.eofSeen -and $res.dataRecords -gt 0)

    return [pscustomobject]$res
}

# =====================================================================
# 4. 工程文件（.uvprojx / .uvproj）读取
# =====================================================================
#
# 从 Keil 工程 XML 里读出 Target 名称、器件、输出目录、输出名、是否生成 HEX、
# 源文件列表、头文件包含目录。只做只读解析，不修改工程文件。

function Get-KeilProjectInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Project
    )

    if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
        throw "工程文件不存在: $Project"
    }
    $full = (Resolve-Path -LiteralPath $Project).Path
    $ext = [IO.Path]::GetExtension($full).ToLowerInvariant()
    if ($ext -ne '.uvprojx' -and $ext -ne '.uvproj') {
        throw "不是 Keil 工程文件（需要 .uvprojx 或 .uvproj）: $full"
    }

    $projDir = Split-Path -Parent $full

    try {
        [xml]$xml = Get-Content -LiteralPath $full -Raw -Encoding UTF8
    }
    catch {
        throw "工程文件无法解析为 XML: $full`r`n$($_.Exception.Message)"
    }

    # 收集所有 Target
    $targets = @()
    $targetNodes = @($xml.SelectNodes('//Target'))
    foreach ($t in $targetNodes) {
        $nameNode = $t.SelectSingleNode('TargetName')
        $targetName = $null
        if ($nameNode) { $targetName = $nameNode.InnerText }

        $device = $null
        $d = $t.SelectSingleNode('.//Device')
        if ($d) { $device = $d.InnerText }

        $outDir = $null
        $o = $t.SelectSingleNode('.//OutputDirectory')
        if ($o) { $outDir = $o.InnerText }

        $outName = $null
        $n = $t.SelectSingleNode('.//OutputName')
        if ($n) { $outName = $n.InnerText }

        $createHex = $null
        $h = $t.SelectSingleNode('.//CreateHexFile')
        if ($h) { $createHex = ($h.InnerText -eq '1') }

        $createAxm = $null
        $a = $t.SelectSingleNode('.//CreateExecutable')
        if ($a) { $createAxm = ($a.InnerText -eq '1') }

        $targets += [pscustomobject]@{
            name      = $targetName
            device    = $device
            outDir    = $outDir
            outName   = $outName
            createHex = $createHex
        }
    }

    # 源文件
    $sources = @()
    foreach ($f in @($xml.SelectNodes('//File'))) {
        $fp = $f.SelectSingleNode('FilePath')
        $fn = $f.SelectSingleNode('FileName')
        $ft = $f.SelectSingleNode('FileType')
        if ($fp) {
            $rel = $fp.InnerText
            $abs = $rel
            if (-not [IO.Path]::IsPathRooted($rel)) {
                $abs = [IO.Path]::GetFullPath((Join-Path $projDir $rel))
            }
            $sources += [pscustomobject]@{
                name     = $(if ($fn) { $fn.InnerText } else { [IO.Path]::GetFileName($rel) })
                relative = $rel
                fullPath = $abs
                type     = $(if ($ft) { [int]$ft.InnerText } else { 0 })
                exists   = (Test-Path -LiteralPath $abs -PathType Leaf)
            }
        }
    }

    # 头文件包含目录
    $includes = @()
    foreach ($i in @($xml.SelectNodes('//IncludePath'))) {
        foreach ($part in ($i.InnerText -split ';')) {
            $p = $part.Trim()
            if ($p) { $includes += $p }
        }
    }

    $firstTarget = $null
    if ($targets.Count -gt 0) { $firstTarget = $targets[0] }

    $outDirAbs = $null
    if ($firstTarget -and $firstTarget.outDir) {
        $od = $firstTarget.outDir
        if ([IO.Path]::IsPathRooted($od)) { $outDirAbs = [IO.Path]::GetFullPath($od) }
        else { $outDirAbs = [IO.Path]::GetFullPath((Join-Path $projDir $od)) }
    }

    $axfPath = $null
    $hexPath = $null
    if ($outDirAbs -and $firstTarget -and $firstTarget.outName) {
        $axfPath = Join-Path $outDirAbs ($firstTarget.outName + '.axf')
        $hexPath = Join-Path $outDirAbs ($firstTarget.outName + '.hex')
    }

    return [pscustomobject]@{
        project       = $full
        projectDir    = $projDir
        targets       = $targets
        targetCount   = $targets.Count
        target        = $firstTarget
        sources       = $sources
        sourceCount   = $sources.Count
        includes      = $includes
        outputDir     = $outDirAbs
        axfPath       = $axfPath
        hexPath       = $hexPath
        parseOk       = $true
    }
}

# =====================================================================
# 5. Keil 编译日志解析
# =====================================================================
#
# 把 UV4 写出的编译日志解析成结构化结果。被 Build-Project.ps1 与单元测试共用。
#
# 返回：
#   diagnostics  —— 每条 { index, file, line, kind, code, message, raw }
#   errorCount / warningCount —— 来自 "N Error(s), M Warning(s)" 结果行；
#                                解析不到结果行时为 $null（调用方必须据此判「无法确定」，
#                                绝不能默认 0 错误）
#   programSize  —— "Program Size: Code=.. RO-data=.. " 解析出的键值对
#   summaryLine  —— 结果行原文
#   fatalSeen / targetNotCreated —— 关键字命中情况
#   lines        —— 原始行数组
#
# 注意（真实踩过的坑）：PowerShell 的 $Matches 是全局的，内层再跑一次 -match
# 会把它整个覆盖掉。所以每层匹配都必须先把结果取到局部变量里再继续。
function Get-KeilBuildLogDiagnostics {
    [CmdletBinding()]
    param(
        # 日志文件路径。用 -Text 直接传文本时可以不传。
        [string]$Path,
        # 直接传日志文本（给测试用，可省去建文件）
        [string]$Text
    )

    $lines = @()
    if ($PSBoundParameters.ContainsKey('Text')) {
        if ($Text) { $lines = @($Text -split "`r?`n") }
    }
    elseif ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding Default
        if ($raw) { $lines = @($raw -split "`r?`n") }
    }

    $diagnostics = @()
    $diagIndex = 0
    $parseError = $null

    try {
        foreach ($line in $lines) {
            if ($line -notmatch '^\s*(.+?)\((\d+)\)\s*:\s*(fatal error|error|warning)\s*:?\s*(.*)$') { continue }

            $diagIndex++
            $dFile = $Matches[1].Trim()
            $dLine = [int]$Matches[2]
            $dKind = $(if ($Matches[3] -eq 'warning') { 'warning' } else { 'error' })
            $dMsg = $Matches[4].Trim()
            $dCode = $null

            # 抽出编译器错误码。ARMCC 的写法有好几种：
            #   #5 / #29        普通错误
            #   #177-D          带后缀的警告（后缀也是码的一部分，不能只取到 #177）
            #   #1-D / #47-D
            #   C4065E          某些工具链风格
            if ($dMsg -match '^(#[0-9]+[A-Za-z]*(?:-[A-Za-z]+)?|[A-Z][0-9]{3,4}[A-Z]?)\s*:?\s*(.*)$') {
                $dCode = $Matches[1]
                $dMsg = $Matches[2].Trim()
            }

            $diagnostics += [pscustomobject]@{
                index   = $diagIndex
                file    = $dFile
                line    = $dLine
                kind    = $dKind
                code    = $dCode
                message = $dMsg
                raw     = $line.Trim()
            }
        }
    }
    catch {
        $parseError = $_.Exception.Message
    }

    # 结果行：'".\Objects\test.axf" - 0 Error(s), 0 Warning(s).'
    $summaryLine = $null
    $errorCount = $null
    $warningCount = $null
    foreach ($line in $lines) {
        if ($line -notmatch '(\d+)\s+Error\(s\),\s*(\d+)\s+Warning\(s\)') { continue }
        $summaryLine = $line.Trim()
        $errorCount = [int]$Matches[1]
        $warningCount = [int]$Matches[2]
    }

    # 体积统计："Program Size: Code=568 RO-data=336 RW-data=24 ZI-data=1024"
    $programSize = $null
    foreach ($line in $lines) {
        if ($line -notmatch 'Program Size:\s*(.+)$') { continue }
        $sizeText = $Matches[1]
        $programSize = [ordered]@{}
        foreach ($m in [regex]::Matches($sizeText, '([A-Za-z][A-Za-z\-]*)=(\d+)')) {
            $programSize[$m.Groups[1].Value] = [int]$m.Groups[2].Value
        }
    }

    $fatalSeen = (@($lines | Where-Object { $_ -match '(?i)fatal error|Target not created|Build Time Elapsed' }).Count -gt 0)
    $targetNotCreated = (@($lines | Where-Object { $_ -match '(?i)Target not created' }).Count -gt 0)

    return [pscustomobject]@{
        lines            = $lines
        diagnostics      = $diagnostics
        diagnosticCount  = $diagnostics.Count
        summaryLine      = $summaryLine
        errorCount       = $errorCount
        warningCount     = $warningCount
        errorCountFromLog = ($null -ne $errorCount)
        programSize      = $programSize
        fatalSeen        = $fatalSeen
        targetNotCreated = $targetNotCreated
        parseError       = $parseError
    }
}
