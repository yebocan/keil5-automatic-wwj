[CmdletBinding()]
param(
    [ValidateSet('all', 'build', 'debug')]
    [string]$Test = 'all',
    [string]$OutputDirectory = (Join-Path (Get-Location).Path 'keil5-skill-tests'),
    [string]$Uv4,
    [ValidateRange(1024, 65535)]
    [int]$Port = 41950,
    [ValidateRange(30, 3600)]
    [int]$TimeoutSeconds = 600,
    [switch]$KeepUvision
)

# keil5-automatic-wwj 自检启动器。
#
# 两套例程：
#   build —— 编译层：用 UV4.exe -b 重建夹具工程，要求 0 错误 0 警告。
#   debug —— 调试层：PowerShell 启动 uVision（UVSOCK 端口），用 UvSockClient.exe
#            进仿真、下断点、单步、读变量/寄存器/内存。
#
# 注意：uVision 启动成功、端口监听成功都不能单独算测试通过；本脚本逐项断言
# 实际返回值，并把每一项的结果写进 result.json。

$ErrorActionPreference = 'Stop'

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

$client = { param([string]$port, [string[]]$arguments)
    $all = @($port) + $arguments
    $raw = & $clientExe @all 2>&1 | Out-String
    $raw = $raw.Trim()
    try { return $raw | ConvertFrom-Json } catch { return [pscustomobject]@{ ok = $false; raw = $raw } }
}

# ================= 例程 1：编译层 =================
if ($Test -in @('all', 'build')) {
    Write-Output '=== build: UV4.exe 命令行编译 ==='
    $buildLog = Join-Path $launchDir 'build.log'
    $buildRaw = & $buildScript -Project $project -Action rebuild -LogFile $buildLog -Uv4 $Uv4 2>&1 | Out-String
    $build = $null
    try { $build = $buildRaw | ConvertFrom-Json } catch { }
    if (-not $build) {
        Add-Check 'build.ran' $false ("Build script produced no parsable JSON: " + $buildRaw.Trim())
    } else {
        Add-Check 'build.exitCode' ($build.exitCode -eq 0) ("exitCode=" + $build.exitCode + " (" + $build.exitName + ")")
        Add-Check 'build.noErrors' ($build.errorCount -eq 0) ("errors=" + $build.errorCount + " warnings=" + $build.warningCount)
        Add-Check 'build.artifact' (Test-Path -LiteralPath (Join-Path $workProject 'Objects\test.axf')) 'Objects\test.axf exists'
        Add-Check 'build.hex' (Test-Path -LiteralPath (Join-Path $workProject 'Objects\test.hex')) 'Objects\test.hex exists'
        $size = $build.programSize
        Add-Check 'build.programSize' ($null -ne $size) ("Code=" + $size.Code + " RO=" + $size.'RO-data' + " RW=" + $size.'RW-data' + " ZI=" + $size.'ZI-data')
    }
}

# ================= 例程 2：调试层 =================
if ($Test -in @('all', 'debug')) {
    Write-Output '=== debug: UVSOCK 仿真调试 ==='
    $uvisionProc = $null
    try {
        # 调试会话必须有可加载的程序映像。单独跑 -Test debug 时编译层被跳过，
        # 夹具里就没有 .axf，uVision 进调试后会立刻掉出来，表现为
        # dbg-status 短暂 true 然后所有命令报 6 NOT_DEBUGGING。
        # 所以这里先补一次编译。
        $axfPath = Join-Path $workProject 'Objects\test.axf'
        if (-not (Test-Path -LiteralPath $axfPath)) {
            Write-Output '  (no .axf yet - building fixture first)'
            $preRaw = & $buildScript -Project $project -Action build -LogFile (Join-Path $launchDir 'prebuild.log') -Uv4 $Uv4 2>&1 | Out-String
            $pre = $null
            try { $pre = $preRaw | ConvertFrom-Json } catch { }
            if (-not $pre -or $pre.errorCount -ne 0 -or -not (Test-Path -LiteralPath $axfPath)) {
                Add-Check 'debug.prebuild' $false ("fixture build failed: " + $preRaw.Trim())
                throw 'fixture build failed'
            }
            Add-Check 'debug.prebuild' $true ("exitCode=" + $pre.exitCode + " errors=" + $pre.errorCount)
        }

        $existing = Get-Process -Name UV4 -ErrorAction SilentlyContinue
        if ($existing) {
            Add-Check 'debug.noStaleUvision' $false ("uVision already running (PID " + ($existing.Id -join ',') + "); close it and rerun")
            throw 'uVision already running'
        }

        $startRaw = & $startScript -Project $project -Port $Port -Uv4 $Uv4 2>&1 | Out-String
        $started = $null
        try { $started = $startRaw | ConvertFrom-Json } catch { }
        if (-not $started -or -not $started.listening) {
            Add-Check 'debug.uvisionUp' $false ("Launcher failed: " + $startRaw.Trim())
            throw 'uVision did not start'
        }
        $uvisionProc = Get-Process -Id $started.pid -ErrorAction SilentlyContinue
        Add-Check 'debug.uvisionUp' $true ("PID=" + $started.pid + " port=" + $Port)

        # 1) info
        $info = & $client $Port @('info')
        Add-Check 'debug.info' ($info.ok -and $info.result.uvsockVersion -gt 0) ("uvsockVersion=" + $info.result.uvsockVersion + " " + $info.result.uvision)

        # 2) 切到仿真器并进入调试
        #    注意：dbg-enter 是异步的。它返回 SUCCESS 只表示请求被接受，
        #    此时 dbg-status 往往还报 6 NOT_DEBUGGING。必须轮询到调试会话真的
        #    建立（debugging=true）才能做复位/断点/运行。
        $sim = & $client $Port @('set-debugtarget', 'simulator')
        Add-Check 'debug.setSimulator' ($sim.ok -and $sim.result.status -eq 0) ("status=" + $sim.result.status + " " + $sim.result.statusName)
        $enter = & $client $Port @('dbg-enter')
        Add-Check 'debug.enter' ($enter.ok -and $enter.result.status -eq 0) ("status=" + $enter.result.status + " " + $enter.result.statusName)

        $st = $null
        $readyDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $readyDeadline) {
            Start-Sleep -Milliseconds 750
            $st = & $client $Port @('dbg-status')
            if ($st.result.debugging -eq $true) { break }
        }
        # dbg-status 短暂报 true 也可能是"正在掉线"。再等一轮复确认，
        # 并验证符号表真的加载了（main 能求值出非零地址），否则后面的
        # bp-create 会报 6 NOT_DEBUGGING。
        $stReady = $false; $mainProbe = 0
        if ($st.result.debugging -eq $true) {
            Start-Sleep -Seconds 2
            $st2 = & $client $Port @('dbg-status')
            if ($st2.result.debugging -eq $true) {
                $probe = & $client $Port @('eval', 'main')
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
        $null = & $client $Port @('stop')
        Start-Sleep -Seconds 1
        $null = & $client $Port @('reset')
        Start-Sleep -Seconds 2
        $bp = & $client $Port @('bp-create', 'main')
        Add-Check 'debug.breakpoint' ($bp.ok -and $bp.result.status -eq 0) ("bp-create main status=" + $bp.result.status)

        # 断点地址必须在 run 之前读：目标运行中时 uVision 无法求值，
        # eval 会返回 vType=0 的垃圾（读成 0x00000000）。
        $mainAddr = & $client $Port @('eval', 'main')
        $mainValue = 0
        if ($mainAddr.ok -and $null -ne $mainAddr.result.value) { $mainValue = [int64]$mainAddr.result.value }

        $run = & $client $Port @('run')
        Add-Check 'debug.run' ($run.ok -and $run.result.status -eq 0) ("run status=" + $run.result.status)

        $hitMain = $false; $pcValue = 0; $running = $null
        $hitDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $hitDeadline) {
            Start-Sleep -Milliseconds 700
            $st2 = & $client $Port @('dbg-status')
            $running = $st2.result.running
            if ($running -eq $false) {
                $pc = & $client $Port @('eval', 'PC')
                if ($pc.ok -and $null -ne $pc.result.value) {
                    $pcValue = [int64]$pc.result.value
                    if ($pcValue -eq $mainValue) { $hitMain = $true; break }
                }
            }
        }
        Add-Check 'debug.stoppedAtMain' $hitMain ("running=" + $running + " PC=0x" + $pcValue.ToString('X8') + " main=0x" + $mainValue.ToString('X8'))

        # 4) 变量读取：夹具里 global_array 初值 {11,22,33,44}，断点停在 main 入口时未被改写
        $a0 = & $client $Port @('eval', 'global_array[0]')
        $a3 = & $client $Port @('eval', 'global_array[3]')
        $v0 = if ($a0.ok) { $a0.result.value } else { $null }
        $v3 = if ($a3.ok) { $a3.result.value } else { $null }
        Add-Check 'debug.readGlobals' ($v0 -eq 11 -and $v3 -eq 44) ("global_array[0]=" + $v0 + " global_array[3]=" + $v3)

        # 5) 单步：main 开头的 for 循环会把 global_array 改写成 {0,100,200,300}。
        #    执行足够多的单步后检查末元素，证明单步确实在推进真实代码。
        $null = & $client $Port @('step-n', '20')
        Start-Sleep -Milliseconds 1500
        $s3 = & $client $Port @('eval', 'global_array[3]')
        $st3 = & $client $Port @('dbg-status')
        $s3v = if ($s3.ok) { $s3.result.value } else { $null }
        Add-Check 'debug.stepping' ($s3v -eq 300) ("global_array[3] 44 -> " + $s3v + " (running=" + $st3.result.running + ")")

        # 6) 寄存器与内存
        $regs = & $client $Port @('regs')
        $pcReg = @($regs.result.registers | Where-Object { $_.isPC })
        $pcRegVal = if ($pcReg.Count -gt 0) { $pcReg[0].value } else { '<none>' }
        Add-Check 'debug.registers' ($regs.result.count -ge 16 -and $pcReg.Count -eq 1) ("count=" + $regs.result.count + " PC=" + $pcRegVal)
        $mem = & $client $Port @('mem-read', '0x08000000', '16')
        Add-Check 'debug.memory' ($mem.ok -and $mem.result.errCount -eq 0 -and $mem.result.bytes.Length -ge 32) ("vector@0x08000000=" + $mem.result.bytes.Substring(0, 16))

        # 7) 断点枚举
        $bps = & $client $Port @('bp-enum')
        Add-Check 'debug.bpEnum' ($bps.result.count -ge 1) ("breakpoints=" + $bps.result.count)

        # 8) 退出调试（目标必须已停止；运行中退出会返回 11 TARGET_EXECUTING）
        $stop = & $client $Port @('stop')
        Start-Sleep -Seconds 1
        $exit = & $client $Port @('dbg-exit')
        Add-Check 'debug.exit' ($exit.ok -and $exit.result.status -eq 0) ("stop status=" + $stop.result.status + " dbg-exit status=" + $exit.result.status)

        # 9) uVision 仍然存活（整轮操作没把它搞崩）
        if ($uvisionProc) {
            $uvisionProc.Refresh()
            Add-Check 'debug.uvisionAlive' (-not $uvisionProc.HasExited) ("PID " + $uvisionProc.Id + " still running")
        }
    }
    catch {
        Add-Check 'debug.aborted' $false $_.Exception.Message
    }
    finally {
        if (-not $KeepUvision) {
            Get-Process -Name UV4 -ErrorAction SilentlyContinue | Stop-Process -Force
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
    uvisionKept    = [bool]$KeepUvision
    checks         = $checks
}
$resultPath = Join-Path $launchDir 'result.json'
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8

Write-Output ''
Write-Output ("RESULT: {0}  ({1}/{2} checks passed)" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), ($checks.Count - $failed.Count), $checks.Count)
Write-Output ("result.json: " + $resultPath)
if (-not $passed) { exit 1 }
