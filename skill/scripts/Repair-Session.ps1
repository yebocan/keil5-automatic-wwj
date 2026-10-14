[CmdletBinding()]
param(
    [ValidateSet('start', 'attempt', 'status', 'diff', 'rollback', 'finish', 'list')]
    [string]$Action = 'status',

    # .uvprojx 工程文件（start / attempt 必需）
    [string]$Project,

    # 会话号（attempt / status / diff / rollback / finish 必需）
    [string]$SessionId,

    # 允许修改的文件范围，相对工程目录的通配符，例如 'USER\*.c','HARDWARE\*.h'。
    # 不传则默认取工程里登记的全部源文件。范围外的文件一旦被改动，本工具会报违规并建议停止。
    [string[]]$Scope,

    # 最大自动修复次数（任务书要求默认 3，且不允许无限重试）。
    [ValidateRange(1, 20)]
    [int]$MaxAttempts = 3,

    # 会话存放根目录，默认 %TEMP%\keil5-repair-sessions
    [string]$SessionRoot,

    # 本次尝试改了什么、为什么改（写进账本，便于事后复盘）
    [string]$Reason,

    # 回滚前把当前状态也备份一份（默认开启，保证回滚本身可撤销）
    [bool]$KeepCurrentOnRollback = $true,

    # 转发给 Build-Project.ps1 的 Keil 位置与超时。不传就由 Build-Project 自己
    # 走 KeilCommon 的解析链（参数 → 环境变量 → 配置文件 → 常见位置 → PATH），
    # 保证「各脚本共用同一个配置来源」。
    [string]$Uv4,

    [ValidateRange(10, 3600)]
    [int]$TimeoutSeconds = 600,

    [switch]$DryRun
)

# Repair-Session.ps1 —— 有限次自动修复的「账本 + 安全闸」。
#
# 这个脚本不替 AI 改代码（改代码由 AI 用编辑工具完成），它负责的是任务书里
# 「防止无限循环和盲目修改」那一半：
#   * start     —— 修改前给范围内每个文件做快照（原文件 + SHA256），建立会话账本
#   * attempt   —— 每次编译后登记一次尝试，并自动判定该不该继续
#   * status    —— 看当前第几次、还剩几次、该不该停
#   * diff      —— 看相对基线到底改了哪些行
#   * rollback  —— 一键恢复到修改前（回滚前会再备份一次当前状态，回滚也可撤销）
#   * finish    —— 收尾并给出结论
#   * list      —— 列出历史会话
#
# 自动判定「必须停止」的条件（对应任务书 10.3）：
#   1. 达到最大修复次数
#   2. 错误数比上一次增加
#   3. 本次没有任何文件被改动（空转）
#   4. 改了范围外的文件（超出授权）
#   5. 连续两次错误数完全不变（没有进展）
#
# 用法：
#   .\Repair-Session.ps1 -Action start -Project D:\proj\x.uvprojx -Scope 'USER\*.c'
#   .\Repair-Session.ps1 -Action attempt -SessionId rs_xxx -Reason '补上缺失的头文件'
#   .\Repair-Session.ps1 -Action status -SessionId rs_xxx
#   .\Repair-Session.ps1 -Action rollback -SessionId rs_xxx

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

if (-not $SessionRoot) {
    $SessionRoot = Join-Path ([IO.Path]::GetTempPath()) 'keil5-repair-sessions'
}

function Read-Session {
    param([string]$Id)
    if (-not $Id) { throw '缺少 -SessionId 参数。' }
    $dir = Join-Path $SessionRoot $Id
    $meta = Join-Path $dir 'session.json'
    if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) {
        throw "找不到会话 $Id（应位于 $meta）。用 -Action list 看现有会话。"
    }
    $data = (Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json)
    # 老会话（早期版本建的）没有 sessionDir 字段，这里补上，保证向后兼容。
    if (-not $data.PSObject.Properties['sessionDir'] -or -not $data.sessionDir) {
        $data | Add-Member -NotePropertyName sessionDir -NotePropertyValue $dir -Force
    }
    return [pscustomobject]@{
        dir  = $dir
        meta = $meta
        data = $data
    }
}

function Write-Session {
    param([string]$Dir, $Data)
    $Data | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Dir 'session.json') -Encoding UTF8
}

function Get-RelPath {
    param([string]$Root, [string]$Path)
    $r = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $p = [IO.Path]::GetFullPath($Path)
    if ($p.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { return $p.Substring($r.Length) }
    return $p
}

function Get-FileSha {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash } catch { return $null }
}

# 相对基线的改动清单（只比对范围里的文件）
function Compare-WithBaseline {
    param($Data)

    $root = $Data.projectDir
    $changed = New-Object System.Collections.ArrayList
    $added = New-Object System.Collections.ArrayList
    $removed = New-Object System.Collections.ArrayList
    $outside = New-Object System.Collections.ArrayList

    foreach ($f in $Data.files) {
        $cur = Join-Path $root $f.rel
        $sha = Get-FileSha $cur
        if (-not $sha) { $null = $removed.Add($f.rel); continue }
        if ($sha -ne $f.sha256) { $null = $changed.Add($f.rel) }
    }

    # 范围外是否被改动：只看工程目录里、会话开始之后被写过的源文件
    if ($Data.projectFiles) {
        $started = [datetime]$Data.createdAt
        foreach ($pf in $Data.projectFiles) {
            $inScope = $false
            foreach ($f in $Data.files) { if ($f.rel -eq $pf.rel) { $inScope = $true; break } }
            if ($inScope) { continue }
            $full = Join-Path $root $pf.rel
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
            $item = Get-Item -LiteralPath $full
            if ($item.LastWriteTime -gt $started) { $null = $outside.Add($pf.rel) }
        }
    }

    return [pscustomobject]@{
        changed = @($changed)
        added   = @($added)
        removed = @($removed)
        outside = @($outside)
    }
}

# 范围内所有文件的内容指纹（用于判断「这一轮到底改没改东西」）。
# 取所有文件「相对路径 + SHA256」拼起来再哈希；文件缺失记为 missing。
function Get-ScopeFingerprint {
    param($Data, [switch]$FromBaseline)

    $parts = @()
    foreach ($f in $Data.files) {
        if ($FromBaseline) {
            $sha = Get-FileSha (Join-Path (Join-Path $Data.sessionDir 'baseline') $f.rel)
            $parts += ($f.rel + '=' + $(if ($sha) { $sha } else { 'missing' }))
        }
        else {
            $sha = Get-FileSha (Join-Path $Data.projectDir $f.rel)
            $parts += ($f.rel + '=' + $(if ($sha) { $sha } else { 'missing' }))
        }
    }
    $joined = ($parts -join '|')
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($joined)
        return ([BitConverter]::ToString($sha256.ComputeHash($bytes)) -replace '-', '')
    }
    finally { $sha256.Dispose() }
}

# 极简行级差异：给出被删和被加的行，够用于人工核对。
function Get-LineDiff {
    param([string]$OldPath, [string]$NewPath)

    $old = @()
    $new = @()
    if (Test-Path -LiteralPath $OldPath -PathType Leaf) { $old = @(Get-Content -LiteralPath $OldPath -Encoding UTF8) }
    if (Test-Path -LiteralPath $NewPath -PathType Leaf) { $new = @(Get-Content -LiteralPath $NewPath -Encoding UTF8) }

    $cmp = Compare-Object -ReferenceObject $old -DifferenceObject $new -CaseSensitive
    $removedLines = @($cmp | Where-Object { $_.SideIndicator -eq '<=' } | ForEach-Object { $_.InputObject })
    $addedLines = @($cmp | Where-Object { $_.SideIndicator -eq '=>' } | ForEach-Object { $_.InputObject })

    return [pscustomobject]@{
        oldLineCount  = $old.Count
        newLineCount  = $new.Count
        removedCount  = $removedLines.Count
        addedCount    = $addedLines.Count
        removedSample = @($removedLines | Select-Object -First 40)
        addedSample   = @($addedLines | Select-Object -First 40)
    }
}

# ============================================================
# Action: list
# ============================================================
if ($Action -eq 'list') {
    $sessions = @()
    if (Test-Path -LiteralPath $SessionRoot) {
        foreach ($d in @(Get-ChildItem -LiteralPath $SessionRoot -Directory -ErrorAction SilentlyContinue)) {
            $meta = Join-Path $d.FullName 'session.json'
            if (-not (Test-Path -LiteralPath $meta -PathType Leaf)) { continue }
            try {
                $m = Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json
                $sessions += [ordered]@{
                    sessionId  = $m.sessionId
                    project    = $m.projectName
                    createdAt  = $m.createdAt
                    attempts   = @($m.attempts).Count
                    maxAttempts = $m.maxAttempts
                    state      = $m.state
                    conclusion = $m.conclusion
                }
            }
            catch { }
        }
    }
    Write-Host ''
    if ($sessions.Count -eq 0) {
        Write-Host "  没有历史会话（根目录: $SessionRoot）"
    }
    else {
        foreach ($s in $sessions) {
            Write-Host ("  {0}  {1,-28} 尝试 {2}/{3}  {4}" -f $s.sessionId, $s.project, $s.attempts, $s.maxAttempts, $s.state)
        }
    }
    Write-Host ''
    [ordered]@{ action = 'list'; sessionRoot = $SessionRoot; count = $sessions.Count; sessions = $sessions } | ConvertTo-Json -Depth 6
    return
}

# ============================================================
# Action: start
# ============================================================
if ($Action -eq 'start') {
    if (-not $Project) { throw '缺少 -Project 参数（.uvprojx 路径）。' }
    if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) { throw "工程文件不存在: $Project" }
    $Project = (Resolve-Path -LiteralPath $Project).Path
    $projectDir = Split-Path -Parent $Project
    $projectName = [IO.Path]::GetFileNameWithoutExtension($Project)

    # 工程里登记的全部源文件（用于判定「范围外是否被改动」）
    $projInfo = $null
    try { $projInfo = Get-KeilProjectInfo -Project $Project } catch { }
    $projectFiles = @()
    if ($projInfo -and $projInfo.sources) {
        foreach ($s in $projInfo.sources) {
            if (-not $s.fullPath) { continue }
            $rel = Get-RelPath -Root $projectDir -Path $s.fullPath
            $projectFiles += [ordered]@{ rel = $rel; exists = [bool]$s.exists }
        }
    }

    # 本次允许改的范围
    $scopedRels = @()
    if ($Scope -and $Scope.Count -gt 0) {
        foreach ($s in $projectFiles) {
            foreach ($pat in $Scope) {
                if ($s.rel -like $pat -or ([IO.Path]::GetFileName($s.rel)) -like $pat) { $scopedRels += $s.rel; break }
            }
        }
        if ($scopedRels.Count -eq 0) {
            throw "按 -Scope（$($Scope -join ', ')）在工程里没匹配到任何文件。工程登记的源文件有：$($projectFiles.rel -join ', ')"
        }
    }
    else {
        $scopedRels = @($projectFiles | ForEach-Object { $_.rel })
    }

    $sessionId = 'rs_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $dir = Join-Path $SessionRoot $sessionId
    $baseDir = Join-Path $dir 'baseline'

    Write-Host ''
    Write-Host "会话号:   $sessionId"
    Write-Host "工程:     $Project"
    Write-Host "工程目录: $projectDir"
    Write-Host "修改范围: $($scopedRels.Count) 个文件"
    foreach ($r in $scopedRels) { Write-Host "          $r" }
    Write-Host "最大次数: $MaxAttempts"

    if ($DryRun) {
        Write-Host ''
        Write-Host '（试运行，未创建任何文件）'
        [ordered]@{ action = 'start'; dryRun = $true; sessionId = $sessionId; projectDir = $projectDir; scope = $scopedRels; maxAttempts = $MaxAttempts } | ConvertTo-Json -Depth 6
        return
    }

    New-Item -ItemType Directory -Path $baseDir -Force | Out-Null

    $files = @()
    foreach ($rel in $scopedRels) {
        $src = Join-Path $projectDir $rel
        $sha = Get-FileSha $src
        $size = 0
        if (Test-Path -LiteralPath $src -PathType Leaf) { $size = (Get-Item -LiteralPath $src).Length }

        # 快照：保留相对目录结构
        if ($sha) {
            $dst = Join-Path $baseDir $rel
            $dstParent = Split-Path -Parent $dst
            if ($dstParent -and -not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
        $files += [ordered]@{ rel = $rel; sha256 = $sha; size = $size; existedAtStart = [bool]$sha }
    }

    $data = [ordered]@{
        sessionId    = $sessionId
        sessionDir   = $dir
        createdAt    = (Get-Date).ToString('o')
        project      = $Project
        projectName  = $projectName
        projectDir   = $projectDir
        scope        = @($Scope)
        maxAttempts  = $MaxAttempts
        state        = 'open'
        conclusion   = $null
        files        = $files
        projectFiles = $projectFiles
        attempts     = @()
    }
    Write-Session -Dir $dir -Data $data

    $backedUp = @($files | Where-Object { $_.existedAtStart }).Count
    Write-Host ''
    Write-Host "  [完成] 已建立会话，快照 $backedUp 个文件 -> $baseDir"
    Write-Host '  下一步：用编辑工具改代码，然后 -Action attempt 登记一次编译。'
    Write-Host ''
    [ordered]@{
        action = 'start'; sessionId = $sessionId; sessionDir = $dir
        projectDir = $projectDir; scope = $scopedRels; maxAttempts = $MaxAttempts
        snapshotFiles = $backedUp
    } | ConvertTo-Json -Depth 6
    return
}

# ============================================================
# Action: attempt
# ============================================================
if ($Action -eq 'attempt') {
    $s = Read-Session -Id $SessionId
    $data = $s.data
    $dir = $s.dir

    if ($data.state -ne 'open') {
        throw "会话 $SessionId 状态是 $($data.state)，已结束，不能再登记尝试。"
    }

    $attempts = @($data.attempts)
    $nextIndex = $attempts.Count + 1
    if ($nextIndex -gt [int]$data.maxAttempts) {
        Write-Host ''
        Write-Host "  [拒绝] 已达最大修复次数 $($data.maxAttempts)，不再接受新的尝试。"
        Write-Host '  请用 -Action rollback 恢复，或 -Action finish 收尾。'
        Write-Host ''
        [ordered]@{ action = 'attempt'; sessionId = $SessionId; accepted = $false; reason = 'max-attempts-reached'; attempts = $attempts.Count; maxAttempts = $data.maxAttempts } | ConvertTo-Json -Depth 6
        exit 1
    }

    $delta = Compare-WithBaseline -Data $data

    # 当前范围内所有文件的内容指纹。
    # 注意：不能用「改了哪些文件」来判断空转 —— 同一个文件被改了两次，
    # 文件清单一模一样，但内容已经不同，那是真的又改了一轮。
    $scopeFingerprint = Get-ScopeFingerprint -Data $data

    # 空转检测：与上一次尝试的内容指纹完全相同 → 这一轮什么都没改
    $noChange = $false
    if ($attempts.Count -gt 0) {
        if ($attempts[-1].scopeFingerprint -eq $scopeFingerprint) { $noChange = $true }
    }
    else {
        # 第一次尝试：与基线相比也没动过，同样是空转
        $baseFingerprint = Get-ScopeFingerprint -Data $data -FromBaseline
        if ($baseFingerprint -eq $scopeFingerprint) { $noChange = $true }
    }

    # 跑编译
    $buildScript = Join-Path $PSScriptRoot 'Build-Project.ps1'
    $logFile = Join-Path $dir ("attempt-{0}.log" -f $nextIndex)
    Write-Host ''
    Write-Host "  第 $nextIndex / $($data.maxAttempts) 次尝试，正在编译……"

    $buildJson = $null
    $buildRaw = $null
    $buildError = $null
    try {
        # 把 Keil 位置与超时转发下去；未指定时由 Build-Project 走统一的解析链。
        $buildArgs = @{ Project = $data.project; LogFile = $logFile; TimeoutSeconds = $TimeoutSeconds }
        if ($Uv4) { $buildArgs['Uv4'] = $Uv4 }
        $buildRaw = & $buildScript @buildArgs 2>&1 | Out-String

        # 先按「整体是一个 JSON」解析（最稳），失败再退回到「取最后一行以 { 开头的」。
        try { $buildJson = $buildRaw | ConvertFrom-Json } catch { }
        if (-not $buildJson) {
            $jsonLine = @($buildRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
            if ($jsonLine.Count -gt 0) {
                try { $buildJson = $jsonLine[0] | ConvertFrom-Json } catch { }
            }
        }
        if (-not $buildJson) { $buildError = '编译脚本的输出不是可解析的 JSON' }
    }
    catch {
        $buildError = $_.Exception.Message
        Write-Host "  [警告] 编译脚本抛出异常: $buildError"
    }

    $errorCount = $null
    $warningCount = $null
    $buildStatus = 'indeterminate'
    $hexStatus = 'unknown'
    if ($buildJson) {
        $errorCount = $buildJson.errorCount
        $warningCount = $buildJson.warningCount
        $buildStatus = $buildJson.buildStatus
        $hexStatus = $buildJson.hexStatus
    }

    # ---- 停止条件判定 ----
    $stop = $false
    $stopReasons = New-Object System.Collections.ArrayList

    if ($buildStatus -eq 'success') {
        $stop = $true
        $null = $stopReasons.Add('编译成功')
    }
    if ($nextIndex -ge [int]$data.maxAttempts) {
        $stop = $true
        $null = $stopReasons.Add("达到最大修复次数 $($data.maxAttempts)")
    }
    if ($delta.outside.Count -gt 0) {
        $stop = $true
        $null = $stopReasons.Add("改动了范围外的文件（超出授权）: $($delta.outside -join ', ')")
    }
    if ($noChange) {
        $stop = $true
        $null = $stopReasons.Add('本次没有任何文件被改动（空转），继续重试没有意义')
    }
    if ($attempts.Count -gt 0 -and $null -ne $errorCount) {
        $prevErr = $attempts[-1].errorCount
        if ($null -ne $prevErr) {
            if ($errorCount -gt $prevErr) {
                $stop = $true
                $null = $stopReasons.Add("错误数从 $prevErr 增加到 $errorCount，修改让情况变糟")
            }
            elseif ($errorCount -eq $prevErr -and -not $noChange) {
                $null = $stopReasons.Add("错误数仍为 $errorCount，与上次相同")
                # 连续两次不变 → 没进展
                if ($attempts.Count -ge 2) {
                    $prevPrev = $attempts[-2].errorCount
                    if ($null -ne $prevPrev -and $prevPrev -eq $errorCount) {
                        $stop = $true
                        $null = $stopReasons.Add("连续三次错误数都是 $errorCount，没有进展")
                    }
                }
            }
        }
    }

    $record = [ordered]@{
        index        = $nextIndex
        at           = (Get-Date).ToString('o')
        reason       = $Reason
        changedFiles = @($delta.changed)
        removedFiles = @($delta.removed)
        outsideFiles = @($delta.outside)
        noChange     = $noChange
        scopeFingerprint = $scopeFingerprint
        buildStatus  = $buildStatus
        errorCount   = $errorCount
        warningCount = $warningCount
        hexStatus    = $hexStatus
        logFile      = $logFile
        buildError   = $buildError
        stop         = $stop
        stopReasons  = @($stopReasons)
    }
    $data.attempts = @($attempts) + @($record)

    if ($stop) {
        if ($buildStatus -eq 'success') {
            $data.state = 'succeeded'
            $data.conclusion = '编译成功'
        }
        else {
            $data.state = 'stopped'
            $data.conclusion = ($stopReasons -join '；')
        }
    }
    Write-Session -Dir $dir -Data $data

    Write-Host ''
    Write-Host ("  编译状态: {0}   错误 {1}   警告 {2}   HEX {3}" -f $buildStatus, $errorCount, $warningCount, $hexStatus)
    Write-Host ("  改动文件: {0}" -f $(if ($delta.changed.Count) { $delta.changed -join ', ' } else { '（无）' }))
    if ($delta.outside.Count -gt 0) { Write-Host ("  [警告] 范围外文件被改动: " + ($delta.outside -join ', ')) }
    Write-Host ''
    if ($stop) {
        Write-Host "  [停止] 应当停止自动修复。原因："
        foreach ($r in $stopReasons) { Write-Host "         · $r" }
    }
    else {
        Write-Host "  [继续] 还剩 $([int]$data.maxAttempts - $nextIndex) 次尝试机会。"
    }
    Write-Host ''
    $record | ConvertTo-Json -Depth 6
    if ($stop -and $buildStatus -ne 'success') { exit 1 }
    return
}

# ============================================================
# Action: status
# ============================================================
if ($Action -eq 'status') {
    $s = Read-Session -Id $SessionId
    $data = $s.data
    $delta = Compare-WithBaseline -Data $data
    $attempts = @($data.attempts)
    $remaining = [int]$data.maxAttempts - $attempts.Count
    if ($remaining -lt 0) { $remaining = 0 }

    Write-Host ''
    Write-Host "会话:     $($data.sessionId)"
    Write-Host "工程:     $($data.projectName)  ($($data.projectDir))"
    Write-Host "建立于:   $($data.createdAt)"
    Write-Host "状态:     $($data.state)"
    Write-Host "尝试:     $($attempts.Count) / $($data.maxAttempts)  剩余 $remaining"
    Write-Host "范围:     $($data.files.Count) 个文件"
    Write-Host ''
    if ($attempts.Count -gt 0) {
        Write-Host '历次尝试：'
        foreach ($a in $attempts) {
            Write-Host ("  #{0}  {1,-14} 错误 {2,-5} 警告 {3,-5} {4}" -f $a.index, $a.buildStatus, $a.errorCount, $a.warningCount, $a.reason)
        }
        Write-Host ''
    }
    Write-Host '相对基线当前改动：'
    Write-Host ("  已改: {0}" -f $(if ($delta.changed.Count) { $delta.changed -join ', ' } else { '（无）' }))
    if ($delta.removed.Count -gt 0) { Write-Host ("  已删: " + ($delta.removed -join ', ')) }
    if ($delta.outside.Count -gt 0) { Write-Host ("  范围外: " + ($delta.outside -join ', ')) }
    Write-Host ''
    [ordered]@{
        action = 'status'; sessionId = $data.sessionId; state = $data.state
        attempts = $attempts.Count; maxAttempts = $data.maxAttempts; remaining = $remaining
        changed = @($delta.changed); removed = @($delta.removed); outside = @($delta.outside)
        conclusion = $data.conclusion
    } | ConvertTo-Json -Depth 6
    return
}

# ============================================================
# Action: diff
# ============================================================
if ($Action -eq 'diff') {
    $s = Read-Session -Id $SessionId
    $data = $s.data
    $root = $data.projectDir
    $baseDir = Join-Path $s.dir 'baseline'
    $delta = Compare-WithBaseline -Data $data

    $diffs = @()
    Write-Host ''
    if ($delta.changed.Count -eq 0 -and $delta.removed.Count -eq 0) {
        Write-Host '  相对基线没有任何改动。'
    }
    foreach ($rel in $delta.changed) {
        $d = Get-LineDiff -OldPath (Join-Path $baseDir $rel) -NewPath (Join-Path $root $rel)
        Write-Host ("  === {0}  (-{1} / +{2} 行)" -f $rel, $d.removedCount, $d.addedCount)
        foreach ($l in $d.removedSample) { Write-Host ("    - " + $l) }
        foreach ($l in $d.addedSample) { Write-Host ("    + " + $l) }
        Write-Host ''
        $diffs += [ordered]@{ file = $rel; removedCount = $d.removedCount; addedCount = $d.addedCount; removed = $d.removedSample; added = $d.addedSample }
    }
    foreach ($rel in $delta.removed) {
        Write-Host ("  === {0}  （文件已被删除）" -f $rel)
        $diffs += [ordered]@{ file = $rel; deleted = $true }
    }
    [ordered]@{ action = 'diff'; sessionId = $data.sessionId; changed = @($delta.changed); deleted = @($delta.removed); outside = @($delta.outside); diffs = $diffs } | ConvertTo-Json -Depth 8
    return
}

# ============================================================
# Action: rollback
# ============================================================
if ($Action -eq 'rollback') {
    $s = Read-Session -Id $SessionId
    $data = $s.data
    $root = $data.projectDir
    $baseDir = Join-Path $s.dir 'baseline'
    $delta = Compare-WithBaseline -Data $data

    Write-Host ''
    Write-Host "  会话 $($data.sessionId)  将恢复到 $($data.createdAt) 的状态"
    Write-Host "  涉及 $($delta.changed.Count) 个已改文件、$($delta.removed.Count) 个已删文件"

    if ($delta.changed.Count -eq 0 -and $delta.removed.Count -eq 0) {
        Write-Host '  没有需要恢复的内容。'
        [ordered]@{ action = 'rollback'; sessionId = $data.sessionId; restored = @(); note = 'no changes to restore' } | ConvertTo-Json -Depth 6
        return
    }

    if ($DryRun) {
        Write-Host '  （试运行，未改动任何文件）'
        [ordered]@{ action = 'rollback'; dryRun = $true; sessionId = $data.sessionId; wouldRestore = @($delta.changed) + @($delta.removed) } | ConvertTo-Json -Depth 6
        return
    }

    # 回滚前先把「当前状态」也存一份，这样回滚本身也能撤销。
    $preDir = $null
    if ($KeepCurrentOnRollback) {
        $preDir = Join-Path $s.dir ('pre-rollback_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
        foreach ($rel in @($delta.changed) + @($delta.removed)) {
            $cur = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $cur -PathType Leaf)) { continue }
            $dst = Join-Path $preDir $rel
            $dstParent = Split-Path -Parent $dst
            if ($dstParent -and -not (Test-Path -LiteralPath $dstParent)) { New-Item -ItemType Directory -Path $dstParent -Force | Out-Null }
            Copy-Item -LiteralPath $cur -Destination $dst -Force
        }
        Write-Host "  当前状态已另存: $preDir"
    }

    $restored = @()
    foreach ($rel in @($delta.changed) + @($delta.removed)) {
        $src = Join-Path $baseDir $rel
        $dst = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) {
            Write-Host "  [跳过] $rel 基线里没有这个文件，无法恢复"
            continue
        }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $shaNow = Get-FileSha $dst
        $ok = $false
        foreach ($f in $data.files) { if ($f.rel -eq $rel -and $f.sha256 -eq $shaNow) { $ok = $true; break } }
        Write-Host ("  [{0}] {1}" -f $(if ($ok) { '完成' } else { '校验失败' }), $rel)
        $restored += [ordered]@{ file = $rel; restored = $ok; sha256 = $shaNow }
    }

    $data.state = 'rolled-back'
    $data.conclusion = '已回滚到修改前状态'
    Write-Session -Dir $s.dir -Data $data

    Write-Host ''
    [ordered]@{
        action = 'rollback'; sessionId = $data.sessionId
        restored = $restored; preRollbackBackup = $preDir
        verifyCommand = "再跑一次编译确认工程已回到原状"
    } | ConvertTo-Json -Depth 6
    return
}

# ============================================================
# Action: finish
# ============================================================
if ($Action -eq 'finish') {
    $s = Read-Session -Id $SessionId
    $data = $s.data
    $attempts = @($data.attempts)
    $last = $null
    if ($attempts.Count -gt 0) { $last = $attempts[-1] }

    if ($data.state -eq 'open') {
        $data.state = 'abandoned'
        $data.conclusion = '主动结束，未达成编译成功'
        if ($Reason) { $data.conclusion = $Reason }
    }
    Write-Session -Dir $s.dir -Data $data

    Write-Host ''
    Write-Host "会话 $($data.sessionId) 结束，状态 $($data.state)"
    Write-Host "  共尝试 $($attempts.Count) 次（上限 $($data.maxAttempts)）"
    if ($last) { Write-Host "  最后一次: $($last.buildStatus)，错误 $($last.errorCount)，警告 $($last.warningCount)" }
    Write-Host "  结论: $($data.conclusion)"
    Write-Host "  基线快照仍保留在: $(Join-Path $s.dir 'baseline')（需要时可再 rollback）"
    Write-Host ''
    [ordered]@{
        action = 'finish'; sessionId = $data.sessionId; state = $data.state
        attempts = $attempts.Count; maxAttempts = $data.maxAttempts
        conclusion = $data.conclusion; baselineDir = (Join-Path $s.dir 'baseline')
    } | ConvertTo-Json -Depth 6
    return
}
