[CmdletBinding()]
param(
    [ValidateSet('all', 'build', 'debug')]
    [string]$Test = 'all',
    [string]$OutputDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'keil5-tests'),
    [string]$Uv4,
    [ValidateRange(1024, 65535)]
    [int]$Port = 41950,
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600,
    # 保留测试启动的 uVision（默认测试结束就关掉自己起的那个）
    [switch]$KeepUvision,
    # 允许清理「上一次自检被强杀后残留的」uVision。默认只报告不清理，
    # 因为结束进程必须有明确授权。加了这个开关也只清理登记表里属于本项目的进程。
    [switch]$CleanStaleUvision
)

# keil5-automatic-wwj 自检启动器。
#
# 两套例程：
#   build —— 编译层：用 UV4.exe -b 重建夹具工程，要求 0 错误，产物真的更新。
#   debug —— 调试层：PowerShell 启动 uVision（UVSOCK 端口），用 UvSockClient.exe
#            进仿真、下断点、单步、读变量/寄存器/内存。
#
# 进程安全（最重要）：
#   本脚本只结束「自己启动的那一个 uVision 进程」，通过 KeilCommon.ps1 的
#   Stop-OwnedUvision 完成（核对 PID + 进程名 + 启动时间，先优雅退出再考虑强杀）。
#   测试前如果用户已经开着别的 Keil，本脚本既不阻止也不关闭它，并且会在测试
#   结束后断言它仍然存活。
#
# uVision 启动成功、端口监听成功都不能单独算测试通过；本脚本逐项断言实际返回值。

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

$skillRoot = Split-Path -Parent $PSScriptRoot
$clientExe = Join-Path $skillRoot 'scripts\UvSockClient.exe'
$startScript = Join-Path $skillRoot 'scripts\Start-Uvision.ps1'
$buildScript = Join-Path $skillRoot 'scripts\Build-Project.ps1'
$fixtureProject = Join-Path $skillRoot 'assets\test-project\test.uvprojx'

foreach ($f in @($clientExe, $startScript, $buildScript, $fixtureProject)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing required file: $f" }
}

# ---- 结果目录：把夹具工程复制一份，绝不写进 skill 安装目录 ----
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null
$runToken = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$launchDir = Join-Path $outputRoot ('launch_' + $runToken)
New-Item -ItemType Directory -Path $launchDir | Out-Null
$workProject = Join-Path $launchDir 'test-project'
Copy-Item -LiteralPath (Split-Path -Parent $fixtureProject) -Destination $workProject -Recurse
$project = Join-Path $workProject 'test.uvprojx'

$checks = [Collections.Generic.List[object]]::new()
function Add-Check([string]$name, [bool]$passed, [string]$detail) {
    $script:checks.Add([ordered]@{ check = $name; passed = $passed; detail = $detail })
    Write-Output ("[{0}] {1} - {2}" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $name, $detail)
}

# ---- 总超时闸 ----
# -TimeoutSeconds 是本轮自检的总预算。以前这个参数被声明了却没用上，
# 结果一旦某个轮询卡住就会无限等下去。现在所有等待都必须先过这道闸
# （实现在 KeilCommon.ps1，单元测试覆盖同一份代码）。
$script:deadline = New-KeilDeadline -Seconds $TimeoutSeconds
function Get-RemainingSeconds { return (Get-KeilRemainingSeconds -Deadline $script:deadline) }
function Get-PollBudgetSeconds([int]$want, [int]$Minimum = 1) {
    return (Get-KeilBudget -Deadline $script:deadline -Want $want -Minimum $Minimum)
}
function Assert-Deadline([string]$stage) {
    return (Assert-KeilBudget -Deadline $script:deadline -Stage $stage)
}

$client = { param([string]$port, [string[]]$arguments)
    $all = @($port) + $arguments
    $raw = & $clientExe @all 2>&1 | Out-String
    $raw = $raw.Trim()
    try { return $raw | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; raw = $raw } }
}

# ---- 测试前：记录用户已有的 uVision 实例（只记录，绝不结束）----
$preExistingPids = @(Get-UvisionProcesses | ForEach-Object { $_.pid })

# ================= 例程 1：编译层 =================
if ($Test -in @('all', 'build')) {
    Write-Output '=== build: UV4.exe 命令行编译 ==='
    $buildLog = Join-Path $launchDir 'build.log'
    # 编译也要吃总超时预算：UV4 卡住时不能让整轮自检无限等
    $buildBudget = Get-PollBudgetSeconds ($TimeoutSeconds - 10) -Minimum 10
    $buildRaw = & $buildScript -Project $project -Action rebuild -LogFile $buildLog -Uv4 $Uv4 -TimeoutSeconds $buildBudget 2>&1 | Out-String
    $build = $null
    try { $build = $buildRaw | ConvertFrom-Json } catch { }
    if (-not $build) {
        Add-Check 'build.ran' $false ("Build script produced no parsable JSON: " + $buildRaw.Trim())
    } else {
        Add-Check 'build.determinate' ([bool]$build.determinate) ("determinate=" + $build.determinate + " buildStatus=" + $build.buildStatus)
        Add-Check 'build.exitCode' ($build.exitCode -eq 0) ("exitCode=" + $build.exitCode + " (" + $build.exitName + ")")
        Add-Check 'build.noErrors' ($build.errorCount -eq 0) ("errors=" + $build.errorCount + " warnings=" + $build.warningCount)
        Add-Check 'build.success' ([bool]$build.success) ("success=" + $build.success + " reasons=" + (@($build.reasons) -join ' | '))
        Add-Check 'build.artifactFresh' ($build.axfState -in @('created', 'changed')) ("axfState=" + $build.axfState)
        Add-Check 'build.artifact' (Test-Path -LiteralPath (Join-Path $workProject 'Objects\test.axf')) 'Objects\test.axf exists'
        Add-Check 'build.hex' (Test-Path -LiteralPath (Join-Path $workProject 'Objects\test.hex')) 'Objects\test.hex exists'
        Add-Check 'build.hexGenerated' ($build.hexStatus -eq 'generated') ("hexStatus=" + $build.hexStatus + " hexState=" + $build.hexState)
        Add-Check 'build.hexFormat' ($build.hexFormatStatus -eq 'valid') ("hexFormatStatus=" + $build.hexFormatStatus + " records=" + $build.hexCheck.records + " dataBytes=" + $build.hexCheck.dataBytes + " range=" + $build.hexCheck.addressRange)
        $size = $build.programSize
        Add-Check 'build.programSize' ($null -ne $size) ("Code=" + $size.Code + " RO=" + $size.'RO-data' + " RW=" + $size.'RW-data' + " ZI=" + $size.'ZI-data')
    }
}

# ================= 例程 2：调试层 =================
if ($Test -in @('all', 'debug')) {
    Write-Output '=== debug: UVSOCK 仿真调试 ==='
    $uvisionProc = $null
    $ownedPid = $null
    $ownedStart = $null
    $actualPort = $Port
    try {
        # 调试会话必须有可加载的程序映像。单独跑 -Test debug 时编译层被跳过，
        # 夹具里就没有 .axf，uVision 进调试后会立刻掉出来，表现为
        # dbg-status 短暂 true 然后所有命令报 6 NOT_DEBUGGING。
        # 所以这里先补一次编译。
        $axfPath = Join-Path $workProject 'Objects\test.axf'
        if (-not (Test-Path -LiteralPath $axfPath)) {
            Write-Output '  (no .axf yet - building fixture first)'
            $preRaw = & $buildScript -Project $project -Action build -LogFile (Join-Path $launchDir 'prebuild.log') -Uv4 $Uv4 -TimeoutSeconds (Get-PollBudgetSeconds 300 -Minimum 10) 2>&1 | Out-String
            $pre = $null
            try { $pre = $preRaw | ConvertFrom-Json } catch { }
            if (-not $pre -or $pre.errorCount -ne 0 -or -not (Test-Path -LiteralPath $axfPath)) {
                Add-Check 'debug.prebuild' $false ("fixture build failed: " + $preRaw.Trim())
                throw 'fixture build failed'
            }
            Add-Check 'debug.prebuild' $true ("exitCode=" + $pre.exitCode + " errors=" + $pre.errorCount)
        }

        # 不再阻止「用户已经开着 Keil」——Start-Uvision.ps1 会自动让开被占用的端口，
        # 并且只记录已有实例、不碰它们。
        $startRaw = & $startScript -Project $project -Port $Port -Uv4 $Uv4 -WaitSeconds (Get-PollBudgetSeconds 60 -Minimum 3) 2>&1 | Out-String
        $started = $null
        try { $started = $startRaw | ConvertFrom-Json } catch { }
        if (-not $started -or -not $started.listening) {
            Add-Check 'debug.uvisionUp' $false ("Launcher failed: " + $startRaw.Trim())
            throw 'uVision did not start'
        }
        $ownedPid = [int]$started.pid
        $actualPort = [int]$started.port
        $uvisionProc = Get-Process -Id $ownedPid -ErrorAction SilentlyContinue
        if ($uvisionProc) { try { $ownedStart = $uvisionProc.StartTime } catch { } }
        Add-Check 'debug.uvisionUp' $true ("PID=" + $ownedPid + " port=" + $actualPort + $(if ($started.port_changed) { " (requested " + $started.port_requested + ", port was busy)" } else { '' }))

        # 1) info
        $info = & $client $actualPort @('info')
        Add-Check 'debug.info' ($info.ok -and $info.result.uvsockVersion -gt 0) ("uvsockVersion=" + $info.result.uvsockVersion + " " + $info.result.uvision)

        # 2) 切到仿真器并进入调试
        #    注意：dbg-enter 是异步的。它返回 SUCCESS 只表示请求被接受，
        #    此时 dbg-status 往往还报 6 NOT_DEBUGGING。必须轮询到调试会话真的
        #    建立（debugging=true）才能做复位/断点/运行。
        $sim = & $client $actualPort @('set-debugtarget', 'simulator')
        Add-Check 'debug.setSimulator' ($sim.ok -and $sim.result.status -eq 0) ("status=" + $sim.result.status + " " + $sim.result.statusName)
        $enter = & $client $actualPort @('dbg-enter')
        Add-Check 'debug.enter' ($enter.ok -and $enter.result.status -eq 0) ("status=" + $enter.result.status + " " + $enter.result.statusName)

        $st = $null
        $readyDeadline = (Get-Date).AddSeconds((Get-PollBudgetSeconds 30))
        while ((Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 750
            $st = & $client $actualPort @('dbg-status')
            if ($st.result.debugging -eq $true) { break }
        }
        # dbg-status 短暂报 true 也可能是"正在掉线"。再等一轮复确认，
        # 并验证符号表真的加载了（main 能求值出非零地址），否则后面的
        # bp-create 会报 6 NOT_DEBUGGING。
        $stReady = $false; $mainProbe = 0
        if ($st.result.debugging -eq $true) {
            Start-Sleep -Seconds 2
            $st2 = & $client $actualPort @('dbg-status')
            if ($st2.result.debugging -eq $true) {
                $probe = & $client $actualPort @('eval', 'main')
                if ($probe.ok -and $null -ne $probe.result.value) { $mainProbe = [int64]$probe.result.value }
                if ($mainProbe -ne 0) { $stReady = $true }
            }
        }
        Add-Check 'debug.status' $stReady ("debugging=" + $st.result.debugging + " running=" + $st.result.running + " main=0x" + $mainProbe.ToString('X8'))
        if (-not $stReady) { throw ('debug session did not become ready (main symbol unresolved: 0x' + $mainProbe.ToString('X8') + ')') }

        # 3) 复位 + 断点停在 main
        #    时序很重要，这里踩过三个坑：
        #      a) reset 之前目标必须已停止，否则 reset 与运行状态竞争；
        #      b) reset 之后仿真器还要约 1-2 秒才真正复位完成，立刻 run 会跳过断点；
        #      c) run 之后不能固定 sleep 就断言，必须轮询到 running 变回 false
        #         （断点命中）或超时，否则会把"还在跑"误判成"没命中"。
        $null = & $client $actualPort @('stop')
        Start-Sleep -Seconds 1
        $null = & $client $actualPort @('reset')
        Start-Sleep -Seconds 2
        $bp = & $client $actualPort @('bp-create', 'main')
        Add-Check 'debug.breakpoint' ($bp.ok -and $bp.result.status -eq 0) ("bp-create main status=" + $bp.result.status)

        # 断点地址必须在 run 之前读：目标运行中时 uVision 无法求值，
        # eval 会返回 vType=0 的垃圾（读成 0x00000000）。
        $mainAddr = & $client $actualPort @('eval', 'main')
        $mainValue = 0
        if ($mainAddr.ok -and $null -ne $mainAddr.result.value) { $mainValue = [int64]$mainAddr.result.value }

        $run = & $client $actualPort @('run')
        Add-Check 'debug.run' ($run.ok -and $run.result.status -eq 0) ("run status=" + $run.result.status)

        $hitMain = $false; $pcValue = 0; $running = $null
        $hitDeadline = (Get-Date).AddSeconds((Get-PollBudgetSeconds 30))
        while ((Get-Date) -lt $hitDeadline) {
            Start-Sleep -Milliseconds 700
            $st2 = & $client $actualPort @('dbg-status')
            $running = $st2.result.running
            if ($running -eq $false) {
                $pc = & $client $actualPort @('eval', 'PC')
                if ($pc.ok -and $null -ne $pc.result.value) {
                    $pcValue = [int64]$pc.result.value
                    if ($pcValue -eq $mainValue) { $hitMain = $true; break }
                }
            }
        }
        Add-Check 'debug.stoppedAtMain' $hitMain ("running=" + $running + " PC=0x" + $pcValue.ToString('X8') + " main=0x" + $mainValue.ToString('X8'))

        # 4) 变量读取：夹具里 global_array 初值 {11,22,33,44}，断点停在 main 入口时未被改写
        $a0 = & $client $actualPort @('eval', 'global_array[0]')
        $a3 = & $client $actualPort @('eval', 'global_array[3]')
        $v0 = if ($a0.ok) { $a0.result.value } else { $null }
        $v3 = if ($a3.ok) { $a3.result.value } else { $null }
        Add-Check 'debug.readGlobals' ($v0 -eq 11 -and $v3 -eq 44) ("global_array[0]=" + $v0 + " global_array[3]=" + $v3)

        # 5) 单步：main 开头的 for 循环会把 global_array 改写成 {0,100,200,300}。
        #    执行足够多的单步后检查末元素，证明单步确实在推进真实代码。
        $null = & $client $actualPort @('step-n', '20')
        Start-Sleep -Milliseconds 1500
        $s3 = & $client $actualPort @('eval', 'global_array[3]')
        $st3 = & $client $actualPort @('dbg-status')
        $s3v = if ($s3.ok) { $s3.result.value } else { $null }
        Add-Check 'debug.stepping' ($s3v -eq 300) ("global_array[3] 44 -> " + $s3v + " (running=" + $st3.result.running + ")")

        # 6) 寄存器与内存
        $regs = & $client $actualPort @('regs')
        $pcReg = @($regs.result.registers | Where-Object { $_.isPC })
        $pcRegVal = if ($pcReg.Count -gt 0) { $pcReg[0].value } else { '<none>' }
        Add-Check 'debug.registers' ($regs.result.count -ge 16 -and $pcReg.Count -eq 1) ("count=" + $regs.result.count + " PC=" + $pcRegVal)
        $mem = & $client $actualPort @('mem-read', '0x08000000', '16')
        Add-Check 'debug.memory' ($mem.ok -and $mem.result.errCount -eq 0 -and $mem.result.bytes.Length -ge 32) ("vector@0x08000000=" + $mem.result.bytes.Substring(0, 16))

        # 7) 断点枚举
        $bps = & $client $actualPort @('bp-enum')
        Add-Check 'debug.bpEnum' ($bps.result.count -ge 1) ("breakpoints=" + $bps.result.count)

        # 8) 退出调试（目标必须已停止；运行中退出会返回 11 TARGET_EXECUTING）
        $stop = & $client $actualPort @('stop')
        Start-Sleep -Seconds 1
        $exit = & $client $actualPort @('dbg-exit')
        Add-Check 'debug.exit' ($exit.ok -and $exit.result.status -eq 0) ("stop status=" + $stop.result.status + " dbg-exit status=" + $exit.result.status)

        # 9) 本脚本启动的 uVision 仍然存活（整轮操作没把它搞崩）
        if ($uvisionProc) {
            $uvisionProc.Refresh()
            Add-Check 'debug.uvisionAlive' (-not $uvisionProc.HasExited) ("PID " + $uvisionProc.Id + " still running")
        }
    }
    catch {
        Add-Check 'debug.aborted' $false $_.Exception.Message
    }
    finally {
        # 只清理本脚本启动的那一个进程：核对 PID + 进程名 UV4 + 启动时间，
        # 先让它自己退出（UVSOCK exit → 关主窗口），都失败才强杀这一个 PID。
        if ($ownedPid -and -not $KeepUvision) {
            $cleanup = Stop-OwnedUvision -ProcessId $ownedPid -OwnerPid $PID -StartedAt $ownedStart -Port $actualPort -ClientExe $clientExe
            Write-Output ("[INFO] cleanup - " + $cleanup.message + " (owner 校验: " + $cleanup.ownerCheck + ")")
            if ($cleanup.attempted -and -not (Get-Process -Id $ownedPid -ErrorAction SilentlyContinue)) {
                Remove-KeilOwnedRegistryEntry -ProcessId $ownedPid
            }
        }
        elseif ($ownedPid -and $KeepUvision) {
            Write-Output ("[INFO] cleanup - -KeepUvision 指定保留，未结束 PID " + $ownedPid)
            # 用户明确要留着它，就把登记表里这条撤掉：所有权交给用户，
            # 免得下一次自检把它当成本项目的残留去处理。
            Remove-KeilOwnedRegistryEntry -ProcessId $ownedPid
        }

        # 用户原有的 uVision 必须仍然存活 —— 这是 P0 安全断言。
        if ($preExistingPids.Count -gt 0) {
            $survivors = @()
            foreach ($pp in $preExistingPids) {
                if (Get-Process -Id $pp -ErrorAction SilentlyContinue) { $survivors += $pp }
            }
            Add-Check 'safety.preexistingUvisionAlive' ($survivors.Count -eq $preExistingPids.Count) `
                ("before=" + ($preExistingPids -join ',') + " alive_after=" + ($survivors -join ','))
        }
        else {
            Add-Check 'safety.preexistingUvisionAlive' $true '测试前没有已运行的 uVision 实例（无进程可误杀）'
        }

        # 残留检测：登记表里还活着、且不是本轮启动的那个 uVision，只可能是
        # 「上一次自检被强杀」留下的（finally 没跑到）。登记表本身就是归属凭证——
        # 只有 Start-Uvision.ps1 会往里写，所以命中即代表是本项目起的进程。
        # 注意不能拿 $preExistingPids 排除：上次残留的实例在本次运行看来也是
        # 「运行前就存在的」，那样反而永远查不出来。
        #
        # 先清掉登记表里「已退出 / PID 被复用」的死条目：登记表只增不减的话，
        # 跑几十次之后会积一大堆死 PID，每次都被当成残留报出来，真残留反而被淹没。
        # 这一步只删登记表里的记录，不结束任何进程。
        $purged = Remove-KeilDeadRegistryEntries
        if ($purged.existed -and $purged.removed -gt 0) {
            Write-Output ("[INFO] 登记表清理：移除 " + $purged.removed + " 条已失效记录（进程已退出或 PID 被复用），保留 " + $purged.kept + " 条。")
        }

        $stale = @()
        foreach ($item in @(Get-RegisteredOwnedUvision)) {
            if (-not $item.owned) { continue }                              # 进程没了或 PID 被复用
            if ($ownedPid -and $item.pid -eq $ownedPid -and -not $KeepUvision) { continue }  # 本轮的，已清理
            $stale += $item
        }
        if ($stale.Count -gt 0) {
            $staleIds = (@($stale | ForEach-Object { $_.pid }) -join ',')
            if ($CleanStaleUvision) {
                foreach ($s in $stale) {
                    # 只清 owner 进程已经不在的残留：上一轮被强杀就等于 owner 已死，
                    # 此时由本轮进程接管收尾权。owner 还活着的一律不动，交给它自己收尾。
                    if ($s.owner_pid) {
                        $ownerStillAlive = Get-Process -Id ([int]$s.owner_pid) -ErrorAction SilentlyContinue
                        if ($ownerStillAlive -and $ownerStillAlive.Id -ne $PID) {
                            Write-Output ("[跳过] 残留 uVision PID " + $s.pid + " 的启动进程 " + $s.owner_pid + " 仍在运行，交由它自己收尾，本轮不动。")
                            continue
                        }
                        $c = Stop-OwnedUvision -ProcessId $s.pid -OwnerPid ([int]$s.owner_pid) -StartedAt $s.startedAt -Port $s.port -ClientExe $clientExe
                    }
                    else {
                        # 老版本登记表没有 owner_pid，没有授权依据就不结束，只报告。
                        Write-Output ("[跳过] 残留 uVision PID " + $s.pid + " 的登记条目没有 owner_pid（旧版本登记表），不确定归属，不结束。")
                        continue
                    }
                    Write-Output ("[INFO] 清理上次残留的 uVision PID " + $s.pid + " - " + $c.message)
                    if (-not (Get-Process -Id $s.pid -ErrorAction SilentlyContinue)) {
                        Remove-KeilOwnedRegistryEntry -ProcessId $s.pid
                    }
                }
                $left = @(Get-RegisteredOwnedUvision | Where-Object { $_.owned })
                Add-Check 'safety.staleUvisionCleaned' ($left.Count -eq 0) `
                    ("清理了 PID " + $staleIds + "；登记表剩余存活条目 " + $left.Count)
            }
            else {
                # 默认只报告不清理：结束进程必须有明确授权。这里也不判失败——
                # 这是「上一轮」的历史遗留，不该让本轮代码的结论变红。
                Write-Output ("[INFO] 检测到上次自检残留的 uVision（PID " + $staleIds + "）。它们不是本轮的产物；加 -CleanStaleUvision 可安全收尾（只清登记表里属于本项目的进程，不碰你自己的 Keil）。")
            }
        }
    }
}

# ================= 汇总 =================
$failed = @($checks | Where-Object { -not $_.passed })
$passed = ($failed.Count -eq 0)
$result = [ordered]@{
    skill          = 'keil5-automatic-wwj'
    test           = $Test
    passed         = $passed
    checkCount     = $checks.Count
    failedCount    = $failed.Count
    launchDir      = $launchDir
    project        = $project
    preexistingPids = $preExistingPids
    uvisionKept    = [bool]$KeepUvision
    checks         = $checks
}
$resultPath = Join-Path $launchDir 'result.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8

Write-Output ''
Write-Output ("RESULT: {0}  ({1}/{2} checks passed)" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), ($checks.Count - $failed.Count), $checks.Count)
Write-Output ("result.json: " + $resultPath)
if (-not $passed) { exit 1 }
