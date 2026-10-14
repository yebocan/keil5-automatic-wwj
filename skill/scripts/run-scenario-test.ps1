[CmdletBinding()]
param(
    # 输出目录，默认 %TEMP%\keil5-scenarios
    [string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'keil5-scenarios'),

    # 只跑某一组：all / path / project / build / hex / process / install / repair
    [ValidateSet('all', 'path', 'project', 'build', 'hex', 'process', 'install', 'repair')]
    [string]$Group = 'all',

    # 允许真的启动 Keil 跑编译（默认开启；关掉后只跑离线用例）
    [bool]$AllowRealKeil = $true,

    # 单个真实编译用例的超时上限
    [ValidateRange(10, 3600)]
    [int]$BuildTimeoutSeconds = 300
)

# keil5-automatic-wwj 场景测试 —— 对应任务书第 10 节的 22 个场景。
#
# 与另外两个测试脚本的分工：
#   run-unit-test.ps1     单元测试：单个函数的行为（秒级，不需要 Keil）
#   run-scenario-test.ps1 场景测试：一个完整场景端到端走通（本文件）
#   run-test.ps1          集成测试：真的启动 uVision 编译+调试（需要 Keil）
#
# 每项结果都带 mode 字段，明确区分：
#   mock    —— 用伪造的 UV4 / 合成日志跑，验证的是脚本自己的判定逻辑
#   real    —— 真的调用了 Keil，验证的是端到端链路
#   offline —— 纯离线判定，不涉及外部程序
# 没真跑 Keil 的用例绝不会被写成「真实编译测试通过」。

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

$scriptRoot = $PSScriptRoot
$skillRoot = Split-Path -Parent $scriptRoot
$repoRoot = Split-Path -Parent $skillRoot
$buildScript = Join-Path $scriptRoot 'Build-Project.ps1'
$startScript = Join-Path $scriptRoot 'Start-Uvision.ps1'
$repairScript = Join-Path $scriptRoot 'Repair-Session.ps1'
$installScript = Join-Path $repoRoot 'Install-Skill.ps1'
$clientExe = Join-Path $scriptRoot 'UvSockClient.exe'

$work = [IO.Path]::GetFullPath($WorkDirectory)
# 上一轮如果留下还开着的 uVision，它可能正锁着工作目录里的工程文件。
# 这种情况下不能直接失败：换一个带时间戳的新目录继续跑（旧目录留给用户自己清）。
if (Test-Path -LiteralPath $work) {
    try {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction Stop
    }
    catch {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $work = [IO.Path]::GetFullPath($work.TrimEnd('\') + '_' + $stamp)
        Write-Output ("[提示] 旧工作目录被占用（可能有还开着的 uVision 锁着它），改用新目录: " + $work)
    }
}
New-Item -ItemType Directory -Path $work -Force | Out-Null

$results = [Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$passed, [string]$mode, [string]$detail) {
    $script:results.Add([ordered]@{ test = $name; passed = $passed; mode = $mode; detail = $detail })
    Write-Output ("[{0}] {1} ({2}) - {3}" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $name, $mode, $detail)
}
function Section([string]$title) { Write-Output ''; Write-Output ("--- " + $title + " ---") }
function Want([string]$g) { return ($Group -eq 'all' -or $Group -eq $g) }

# 所有真实 Keil 用例共用的「本次允许真跑」判定
$realOk = $AllowRealKeil
$uv4Path = $null
if ($realOk) {
    try { $uv4Path = (Resolve-KeilUv4).path } catch { $realOk = $false }
}

# 记录测试开始前用户自己的 uVision，最后要核对它们还活着
$preExisting = @(Get-UvisionProcesses | Select-Object -ExpandProperty pid)

# 夹具工程副本：多个分组共用，永远复制到临时目录，绝不写进技能安装目录。
$fixtureSrc = Join-Path $skillRoot 'assets\test-project'
$projDir = Join-Path $work 'test-project'
Copy-Item -LiteralPath $fixtureSrc -Destination $projDir -Recurse -Force
$fixtureProj = Join-Path $projDir 'test.uvprojx'

# =====================================================================
if (Want 'path') {
Section '场景 1-2：Keil 路径不存在 / 路径正确'
# =====================================================================

# 场景 1：把候选表指向空目录，必须报「找不到」并列出试过的地方，而不是静默成功
$savedCand = $env:KEIL5_UV4_CANDIDATES
$savedUv4 = $env:KEIL5_UV4
$savedCfg = $env:KEIL5_AUTOMATIC_WWJ_CONFIG
try {
    $emptyRoot = Join-Path $work 'no-keil-here'
    New-Item -ItemType Directory -Path $emptyRoot -Force | Out-Null
    $env:KEIL5_UV4 = $null
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = Join-Path $work 'no-such-config.json'
    $env:KEIL5_UV4_CANDIDATES = $emptyRoot
    $threw = $false
    $msg = ''
    try { $null = Resolve-KeilUv4 } catch { $threw = $true; $msg = $_.Exception.Message }
    $listsSources = ($msg -match '试过') -or ($msg -match 'attempts') -or ($msg -match 'KEIL5_UV4')
    Check 'scenario.keilPathMissing' ($threw -and $msg.Length -gt 0) 'mock' `
        ("threw=" + $threw + " 提示含来源说明=" + $listsSources)
    # 报错不能只说「找不到」，必须告诉用户怎么指定
    Check 'scenario.keilPathMissingGuidesUser' (($msg -match '-Uv4') -and ($msg -match 'KEIL5_UV4')) 'mock' `
        '错误信息列出了 4 种指定方式'
}
finally {
    $env:KEIL5_UV4_CANDIDATES = $savedCand
    $env:KEIL5_UV4 = $savedUv4
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $savedCfg
}

# 场景 2：路径正确时必须解析出真实存在的文件
try {
    $r = Resolve-KeilUv4
    Check 'scenario.keilPathCorrect' ((Test-Path -LiteralPath $r.path) -and $r.path -match 'UV4\.exe$') 'real' `
        ("path=" + $r.path + " source=" + $r.source)
}
catch {
    Check 'scenario.keilPathCorrect' $false 'real' ("本机未找到 Keil: " + $_.Exception.Message)
}
}

# =====================================================================
if (Want 'project') {
Section '场景 3-6：工程不存在 / 配置不完整 / 路径含空格 / 路径含中文'
# =====================================================================

# 场景 3：工程不存在 → 必须明确报错，不能返回一个空对象让后面继续跑
$threw = $false
$msg = ''
try { $null = Get-KeilProjectInfo -Project (Join-Path $work 'no-such.uvprojx') } catch { $threw = $true; $msg = $_.Exception.Message }
Check 'scenario.projectMissing' $threw 'offline' ("threw=" + $threw + " msg=" + $msg.Substring(0, [Math]::Min(50, $msg.Length)))

# 场景 4：工程配置不完整（没有 Targets / 没有 TargetName）→ 要能报出来而不是崩掉
$badDir = Join-Path $work 'bad-project'
New-Item -ItemType Directory -Path $badDir -Force | Out-Null
$badProj = Join-Path $badDir 'bad.uvprojx'
@'
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<Project xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <SchemaVersion>2.1</SchemaVersion>
  <Targets></Targets>
</Project>
'@ | Set-Content -LiteralPath $badProj -Encoding UTF8
$threw = $false
$msg = ''
$info = $null
try { $info = Get-KeilProjectInfo -Project $badProj } catch { $threw = $true; $msg = $_.Exception.Message }
if ($threw) {
    Check 'scenario.projectIncomplete' $true 'offline' ("明确报错: " + $msg.Substring(0, [Math]::Min(50, $msg.Length)))
}
else {
    # 解析成功但没有 Target —— 也必须是可判定的状态，不能假装正常
    Check 'scenario.projectIncomplete' ($info.targetCount -eq 0 -and $info.parseOk) 'offline' `
        ("targetCount=" + $info.targetCount + " parseOk=" + $info.parseOk + "（已解析但无 Target，调用方据此拒绝编译）")
}

# 场景 5+6：路径含空格 + 含中文 —— 一次覆盖（目录名同时含两者）
$cnDir = Join-Path $work '中文 目录 带空格'
New-Item -ItemType Directory -Path $cnDir -Force | Out-Null
$cnProj = Join-Path $cnDir 'demo 工程.uvprojx'
@'
<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<Project xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <SchemaVersion>2.1</SchemaVersion>
  <Targets>
    <Target>
      <TargetName>Target 1</TargetName>
      <ToolsetNumber>0x4</ToolsetNumber>
      <TargetOption>
        <TargetCommonOption>
          <Device>STM32F103RC</Device>
          <OutputDirectory>.\OBJ\</OutputDirectory>
          <OutputName>demo</OutputName>
          <CreateHexFile>1</CreateHexFile>
        </TargetCommonOption>
      </TargetOption>
      <Groups>
        <Group><GroupName>SRC</GroupName><Files>
          <File><FileName>main.c</FileName><FileType>1</FileType><FilePath>.\main.c</FilePath></File>
        </Files></Group>
      </Groups>
    </Target>
  </Targets>
</Project>
'@ | Set-Content -LiteralPath $cnProj -Encoding UTF8
Set-Content -LiteralPath (Join-Path $cnDir 'main.c') -Value 'int main(void){return 0;}' -Encoding ASCII

$threw = $false
$info = $null
try { $info = Get-KeilProjectInfo -Project $cnProj } catch { $threw = $true }
if ($threw) {
    Check 'scenario.pathWithSpacesAndChinese' $false 'offline' ('解析抛异常: ' + $_.Exception.Message)
}
else {
    $okDir = ($info.projectDir.TrimEnd('\') -eq $cnDir.TrimEnd('\'))
    $okSrc = ($info.sources.Count -eq 1) -and $info.sources[0].exists
    Check 'scenario.pathWithSpacesAndChinese' ($okDir -and $okSrc -and $info.targetCount -eq 1) 'offline' `
        ("dir 解析正确=" + $okDir + " 源文件存在=" + $okSrc + " target=" + $info.targetCount)
}
}

# =====================================================================
if (Want 'build') {
Section '场景 7-9、16-17：编译成功 / 失败 / 含警告 / 超时 / 异常'
# =====================================================================

# 伪造一个 UV4：用来在不碰真 Keil 的前提下测超时与异常分支
$fakeSlow = Join-Path $work 'fake-slow-uv4.cmd'
@'
@echo off
ping -n 60 127.0.0.1 > nul
'@ | Set-Content -LiteralPath $fakeSlow -Encoding ASCII

$fakeWeird = Join-Path $work 'fake-weird-uv4.cmd'
@'
@echo off
exit /b 99
'@ | Set-Content -LiteralPath $fakeWeird -Encoding ASCII

# 场景 16：编译超时 —— 必须标记 timedOut，且只结束自己启动的进程
$toLog = Join-Path $work 'timeout.log'
$toRaw = & $buildScript -Project $cnProj -Uv4 $fakeSlow -LogFile $toLog -TimeoutSeconds 10 2>&1 | Out-String
$toJson = $null
try { $toJson = $toRaw | ConvertFrom-Json } catch { }
if (-not $toJson) {
    $line = @($toRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($line.Count) { try { $toJson = $line[0] | ConvertFrom-Json } catch { } }
}
Check 'scenario.buildTimeout' ($toJson -and $toJson.timedOut -eq $true -and $toJson.buildStatus -eq 'failed') 'mock' `
    $(if ($toJson) { "timedOut=" + $toJson.timedOut + " buildStatus=" + $toJson.buildStatus } else { '输出不是 JSON' })

# 场景 17：编译进程异常退出（退出码不在官方表里、且没写日志）→ 必须 indeterminate，不能猜成功
$weirdLog = Join-Path $work 'weird.log'
$weirdRaw = & $buildScript -Project $cnProj -Uv4 $fakeWeird -LogFile $weirdLog -TimeoutSeconds 30 2>&1 | Out-String
$weirdJson = $null
try { $weirdJson = $weirdRaw | ConvertFrom-Json } catch { }
if (-not $weirdJson) {
    $line = @($weirdRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($line.Count) { try { $weirdJson = $line[0] | ConvertFrom-Json } catch { } }
}
Check 'scenario.buildAbnormalExit' ($weirdJson -and $weirdJson.buildStatus -eq 'indeterminate' -and $weirdJson.success -eq $false) 'mock' `
    $(if ($weirdJson) { "exitCode=" + $weirdJson.exitCode + " buildStatus=" + $weirdJson.buildStatus + " determinate=" + $weirdJson.determinate } else { '输出不是 JSON' })

# 场景 7：真实编译成功 —— 用夹具工程（上面已复制到临时目录，绝不写进技能安装目录）
if ($realOk -and (Test-Path -LiteralPath $fixtureProj)) {
    $okLog = Join-Path $work 'build-ok.log'
    $okRaw = & $buildScript -Project $fixtureProj -Action rebuild -LogFile $okLog -Uv4 $uv4Path -TimeoutSeconds $BuildTimeoutSeconds 2>&1 | Out-String
    $okJson = $null
    try { $okJson = $okRaw | ConvertFrom-Json } catch { }
    if (-not $okJson) {
        $line = @($okRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count) { try { $okJson = $line[0] | ConvertFrom-Json } catch { } }
    }
    Check 'scenario.buildSuccess' ($okJson -and $okJson.buildStatus -eq 'success' -and $okJson.errorCount -eq 0) 'real' `
        $(if ($okJson) { "exitCode=" + $okJson.exitCode + " errors=" + $okJson.errorCount + " axfState=" + $okJson.axfState } else { '输出不是 JSON' })

    # 场景 8：真实编译失败 —— 往副本里注入一个语法错误
    # 注意：注入的内容必须真的是语法错误。`int broken(void) { return ; }` 是合法 C
    # （int 函数里 return; 只是警告），编译会成功，场景就白测了。
    #
    # 关键（真实踩过的坑）：UV4 的增量编译按**秒级** mtime 判断源文件是否过期。
    # 如果上一轮编译生成的 .o 和本行 Set-Content 落在同一秒，UV4 会认为 main.c
    # 没过期而跳过编译 —— 日志里连 `compiling main.c...` 都没有，
    # 场景 8 就变成「注入了错误却报告编译成功」，白测。
    # 所以注入前必须先清掉 Objects 里的中间产物与最终产物。
    $brokenMain = Join-Path $projDir 'main.c'
    $objDir = Join-Path $projDir 'Objects'
    if (Test-Path -LiteralPath $objDir) {
        Get-ChildItem -LiteralPath $objDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.axf', '.hex' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    # 顺便清掉中间产物（.o / .d / .crf），保证 UV4 一定重新编译 main.c。
    # 这是删除临时目录里的副本，与用户工程无关。
    if (Test-Path -LiteralPath $objDir) {
        Get-ChildItem -LiteralPath $objDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.o', '.d', '.crf', '.lst', '.dep' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $origMain = Get-Content -LiteralPath $brokenMain -Raw
    Set-Content -LiteralPath $brokenMain -Value ($origMain + "`r`nint broken(void) { this is not C at all @@ ; }`r`n") -Encoding UTF8
    $badLog = Join-Path $work 'build-bad.log'
    $badRaw = & $buildScript -Project $fixtureProj -Action build -LogFile $badLog -Uv4 $uv4Path -TimeoutSeconds $BuildTimeoutSeconds 2>&1 | Out-String
    $badJson = $null
    try { $badJson = $badRaw | ConvertFrom-Json } catch { }
    if (-not $badJson) {
        $line = @($badRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count) { try { $badJson = $line[0] | ConvertFrom-Json } catch { } }
    }
    # 编译失败必须同时满足三个条件，缺一个都算判定不合格：
    #   ① buildStatus = failed        —— 结论正确
    #   ② errorCount >= 1            —— 真的数出了错误（不是「没结果行就默认 0」）
    #   ③ 有结构化诊断               —— 能告诉调用方错在哪个文件哪一行
    $badOk = ($badJson -and $badJson.buildStatus -eq 'failed' -and $badJson.errorCount -ge 1)
    $hasDiag = $badJson -and @($badJson.diagnostics).Count -ge 1
    Check 'scenario.buildFailure' $badOk 'real' `
        $(if ($badJson) {
            "exitCode=" + $badJson.exitCode + " buildStatus=" + $badJson.buildStatus +
                " errors=" + $badJson.errorCount + " 诊断条数=" + @($badJson.diagnostics).Count +
                " axfState=" + $badJson.axfState
        } else { '输出不是 JSON' })
    # 诊断必须结构化：有文件、有行号、有描述
    $diagOk = $false
    if ($hasDiag) {
        $d0 = @($badJson.diagnostics)[0]
        $diagOk = ($d0.file -match 'main\.c') -and ($d0.line -gt 0) -and ($d0.message.Length -gt 0)
    }
    Check 'scenario.buildFailureDiagnostics' $diagOk 'real' `
        $(if ($hasDiag) { $f = @($badJson.diagnostics)[0]; "file=" + $f.file + " line=" + $f.line + " kind=" + $f.kind } else { '没有诊断条目' })
    # 场景 8 附带：编译失败时绝不能因为旧产物还在就报告好东西
    $axfState = if ($badJson) { [string]$badJson.axfState } else { '' }
    $hexState = if ($badJson) { [string]$badJson.hexState } else { '' }
    Check 'scenario.buildFailureNoStaleArtifact' `
        ($badOk -and $axfState -eq 'missing' -and $hexState -eq 'missing') 'real' `
        ("axfState=" + $axfState + " hexState=" + $hexState + "（失败后不得残留旧产物）")

    # 场景 9：日志含警告 —— 用合成日志验证「警告不等于失败」
    $warnLog = Join-Path $work 'warn.log'
    @'
Build target 'Target 1'
compiling main.c...
main.c(12): warning:  #177-D: variable "x" was declared but never referenced
".\Objects\test.axf" - 0 Error(s), 1 Warning(s).
'@ | Set-Content -LiteralPath $warnLog -Encoding Default
    $wp = Get-KeilBuildLogDiagnostics -Path $warnLog
    $wd = @($wp.diagnostics)
    Check 'scenario.logWithWarning' ($wp.errorCount -eq 0 -and $wp.warningCount -eq 1 -and $wd.Count -eq 1 -and $wd[0].kind -eq 'warning') 'mock' `
        ("errors=" + $wp.errorCount + " warnings=" + $wp.warningCount + " kind=" + $(if ($wd.Count) { $wd[0].kind } else { 'n/a' }))
}
else {
    $why = if (-not $AllowRealKeil) { '已用 -AllowRealKeil:$false 关闭真实 Keil' } else { '本机没有可用 Keil' }
    Check 'scenario.buildSuccess' $false 'real' ('未执行（' + $why + '）')
    Check 'scenario.buildFailure' $false 'real' ('未执行（' + $why + '）')
    Check 'scenario.buildFailureDiagnostics' $false 'real' ('未执行（' + $why + '）')
    Check 'scenario.buildFailureNoStaleArtifact' $false 'real' ('未执行（' + $why + '）')
    Check 'scenario.logWithWarning' $false 'mock' ('未执行（' + $why + '）')
}
}

# =====================================================================
if (Want 'hex') {
Section '场景 10-13：HEX 未生成 / 为空 / 格式错误 / 上次遗留'
# =====================================================================

# 场景 10：HEX 未生成 —— 把 CreateHexFile 关掉再解析，必须报 disabled-in-project
$noHexDir = Join-Path $work 'no-hex-project'
Copy-Item -LiteralPath (Join-Path $skillRoot 'assets\test-project') -Destination $noHexDir -Recurse -Force
$noHexProj = Join-Path $noHexDir 'test.uvprojx'
(Get-Content -LiteralPath $noHexProj -Raw) -replace '<CreateHexFile>1</CreateHexFile>', '<CreateHexFile>0</CreateHexFile>' |
    Set-Content -LiteralPath $noHexProj -Encoding UTF8
$nh = Get-KeilProjectInfo -Project $noHexProj
Check 'scenario.hexDisabledInProject' ($nh.target.createHex -eq $false) 'offline' ("createHex=" + $nh.target.createHex)

# 场景 11：HEX 为空文件
$emptyHex = Join-Path $work 'empty.hex'
[IO.File]::WriteAllText($emptyHex, '')
$eh = Test-IntelHexFile -Path $emptyHex
Check 'scenario.hexEmpty' ($eh.exists -and $eh.valid -eq $false -and $eh.size -eq 0) 'offline' ("valid=" + $eh.valid + " size=" + $eh.size)

# 场景 12：HEX 格式错误（校验和被改坏）
# 校验和必须是错的：:10 0000 00 00..0F 的正确校验和是 78，这里故意写 FF。
$badHex = Join-Path $work 'bad.hex'
@'
:10000000000102030405060708090A0B0C0D0E0FFF
:00000001FF
'@ | Set-Content -LiteralPath $badHex -Encoding ASCII
$bh = Test-IntelHexFile -Path $badHex
Check 'scenario.hexBadChecksum' ($bh.valid -eq $false -and $bh.checksumErrors -ge 1) 'offline' ("checksumErrors=" + $bh.checksumErrors + " valid=" + $bh.valid)

# 反向对照：同一行把校验和写对（78）必须判为合法 —— 防止「一律判失败」的假阳性
$goodHex = Join-Path $work 'good.hex'
@'
:10000000000102030405060708090A0B0C0D0E0F78
:00000001FF
'@ | Set-Content -LiteralPath $goodHex -Encoding ASCII
$gh = Test-IntelHexFile -Path $goodHex
Check 'scenario.hexGoodChecksumAccepted' ($gh.valid -eq $true -and $gh.checksumErrors -eq 0) 'offline' ("valid=" + $gh.valid + " checksumErrors=" + $gh.checksumErrors)

# 场景 13：上次遗留的 HEX —— 这是最危险的一类误判，单独测
#   手法：放一个「上次编译留下的」HEX，再让编译失败，检查脚本不会因为文件还在就报成功。
$staleDir = Join-Path $work 'stale-project'
Copy-Item -LiteralPath (Join-Path $skillRoot 'assets\test-project') -Destination $staleDir -Recurse -Force
$staleProj = Join-Path $staleDir 'test.uvprojx'
$staleObj = Join-Path $staleDir 'Objects'
New-Item -ItemType Directory -Path $staleObj -Force | Out-Null
$staleHex = Join-Path $staleObj 'test.hex'
@'
:10000000000102030405060708090A0B0C0D0E0F78
:00000001FF
'@ | Set-Content -LiteralPath $staleHex -Encoding ASCII
$staleAxf = Join-Path $staleObj 'test.axf'
Set-Content -LiteralPath $staleAxf -Value 'stale' -Encoding ASCII
# 把时间往前拨，模拟「上一次」留下的产物
(Get-Item -LiteralPath $staleHex).LastWriteTime = (Get-Date).AddHours(-5)
(Get-Item -LiteralPath $staleAxf).LastWriteTime = (Get-Date).AddHours(-5)
# 注入语法错误让本次编译必然失败
$staleMain = Join-Path $staleDir 'main.c'
Set-Content -LiteralPath $staleMain -Value ((Get-Content -LiteralPath $staleMain -Raw) + "`r`nint broken2(void) { return ; }`r`n") -Encoding UTF8

if ($realOk) {
    $staleLog = Join-Path $work 'stale.log'
    $staleRaw = & $buildScript -Project $staleProj -Action build -LogFile $staleLog -Uv4 $uv4Path -TimeoutSeconds $BuildTimeoutSeconds 2>&1 | Out-String
    $staleJson = $null
    try { $staleJson = $staleRaw | ConvertFrom-Json } catch { }
    if (-not $staleJson) {
        $line = @($staleRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count) { try { $staleJson = $line[0] | ConvertFrom-Json } catch { } }
    }
    # 核心断言：编译失败时，绝不能因为旧 HEX 还在而报 hexStatus=generated
    $notFooled = $staleJson -and $staleJson.buildStatus -eq 'failed' -and $staleJson.hexStatus -ne 'generated'
    Check 'scenario.staleHexNotMistaken' $notFooled 'real' `
        $(if ($staleJson) { "buildStatus=" + $staleJson.buildStatus + " hexState=" + $staleJson.hexState + " hexStatus=" + $staleJson.hexStatus } else { '输出不是 JSON' })
    Check 'scenario.staleHexSuccessFalse' ($staleJson -and $staleJson.success -eq $false) 'real' `
        $(if ($staleJson) { "success=" + $staleJson.success } else { 'n/a' })
}
else {
    Check 'scenario.staleHexNotMistaken' $false 'real' '未执行（没有可用 Keil）'
    Check 'scenario.staleHexSuccessFalse' $false 'real' '未执行（没有可用 Keil）'
}

# 离线补一条：Compare-Stamp 的判定本身（不依赖 Keil）
# 用 Build-Project 内部的同一套规则做等价验证：内容相同 + 时间变了 → touched（不是 changed）
$t1 = Join-Path $work 'stamp-a.bin'
$t2 = Join-Path $work 'stamp-b.bin'
Set-Content -LiteralPath $t1 -Value 'same' -Encoding ASCII
Set-Content -LiteralPath $t2 -Value 'same' -Encoding ASCII
$h1 = (Get-FileHash -LiteralPath $t1 -Algorithm SHA256).Hash
$h2 = (Get-FileHash -LiteralPath $t2 -Algorithm SHA256).Hash
Check 'scenario.stampSameContentSameHash' ($h1 -eq $h2) 'offline' '内容相同则哈希相同（Compare-Stamp 判 touched 的依据）'
Set-Content -LiteralPath $t2 -Value 'diff' -Encoding ASCII
$h3 = (Get-FileHash -LiteralPath $t2 -Algorithm SHA256).Hash
Check 'scenario.stampDiffContentDiffHash' ($h1 -ne $h3) 'offline' '内容不同则哈希不同（Compare-Stamp 判 changed 的依据）'
}

# =====================================================================
if (Want 'process') {
Section '场景 14-15：用户已开 Keil / 用户开了多个 Keil'
# =====================================================================

# 场景 14+15：这个必须用真实 uVision 才有意义。
# 做法：由测试脚本自己启动 1 个（模拟「用户开着」），再启动第 2 个（模拟「用户开着多个」），
#       然后跑一次完整自检，最后核对这两个实例是否都还活着。
if ($realOk) {
    # 模拟用户的实例用「另一份工程副本」，免得和自检自己那个实例抢同一个工程文件
    # （uVision 打开同一个 .uvprojx 会互相干扰）。
    $userDir = Join-Path $work 'simulated-user'
    Copy-Item -LiteralPath $fixtureSrc -Destination $userDir -Recurse -Force
    $userProj = Join-Path $userDir 'test.uvprojx'

    $userSim = @()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $p = 43000 + $i * 2
            $raw = & $startScript -Project $userProj -Uv4 $uv4Path -Port $p -WaitSeconds 60 2>&1 | Out-String
            $j = $null
            try { $j = $raw | ConvertFrom-Json } catch { }
            if (-not $j) {
                $line = @($raw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
                if ($line.Count) { try { $j = $line[0] | ConvertFrom-Json } catch { } }
            }
            if ($j -and $j.pid) { $userSim += [int]$j.pid }
        }
        Check 'scenario.userHasOneUvision' ($userSim.Count -ge 1) 'real' ("模拟用户实例: " + ($userSim -join ','))

        if ($userSim.Count -ge 2) {
            # 再跑一次自检（它自己会再起一个），核对用户的 2 个实例没被碰
            $safety = & (Join-Path $scriptRoot 'run-test.ps1') -Test build -OutputDirectory (Join-Path $work 'safety-run') -Uv4 $uv4Path -Port 43100 2>&1 | Out-String
            $alive = @($userSim | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            Check 'scenario.multipleUvisionNotKilled' ($alive.Count -eq $userSim.Count) 'real' `
                ("测试前 " + $userSim.Count + " 个，测试后存活 " + $alive.Count + " 个")
            $safetyPass = $safety -match 'RESULT: PASS'
            Check 'scenario.selfTestPassesWithUserKeil' $safetyPass 'real' `
                $(if ($safetyPass) { '自检在用户开着 Keil 的情况下仍然通过' } else { '自检未通过（详见 safety-run）' })
        }
        else {
            Check 'scenario.multipleUvisionNotKilled' $false 'real' '未能启动两个模拟实例'
            Check 'scenario.selfTestPassesWithUserKeil' $false 'real' '未能启动两个模拟实例'
        }
    }
    finally {
        # 只清理本段自己启动的实例（有明确 PID），逐个走 Stop-OwnedUvision
        foreach ($pp in $userSim) {
            if (Get-Process -Id $pp -ErrorAction SilentlyContinue) {
                $ident = Get-ProcessIdentity -ProcessId $pp
                $null = Stop-OwnedUvision -ProcessId $pp -StartedAt $ident.startedAt -ClientExe $clientExe -GracefulWaitSeconds 5
            }
        }
    }
}
else {
    Check 'scenario.userHasOneUvision' $false 'real' '未执行（没有可用 Keil）'
    Check 'scenario.multipleUvisionNotKilled' $false 'real' '未执行（没有可用 Keil）'
    Check 'scenario.selfTestPassesWithUserKeil' $false 'real' '未执行（没有可用 Keil）'
}

# 离线：清理函数在「没有 PID」时绝不能动手（这是 P0 的核心保证）
$c = Stop-OwnedUvision
Check 'scenario.cleanupRefusesNoPid' ($c.attempted -eq $false -and $c.killed -eq $false) 'offline' ("message=" + $c.message)

# 离线：清理函数对「不是 UV4 的进程」必须拒绝（拿自己当靶子）
$c2 = Stop-OwnedUvision -ProcessId $PID -StartedAt (Get-Date)
$meAlive = [bool](Get-Process -Id $PID -ErrorAction SilentlyContinue)
Check 'scenario.cleanupRefusesNonUv4' ($c2.refused -eq $true -and $meAlive) 'offline' `
    ("refused=" + $c2.refused + " 本进程存活=" + $meAlive)
}

# =====================================================================
if (Want 'install') {
Section '场景 18-19、21：安装目录已存在 / 更新出错 / DSH 未加载 Skill'
# =====================================================================

# 场景 18：目标目录已存在同名技能 —— 必须能识别「是本项目的」还是「别人的」
# 这一段真的把 Install-Skill.ps1 跑起来（用假的 USERPROFILE 隔离），
# 不靠 grep 源码，而是看它实际做了什么。
$fakeHome = Join-Path $work 'fake-home'
$fakeDsh = Join-Path $fakeHome '.dsh\skills'
$occupied = Join-Path $fakeDsh 'keil5-automatic-wwj'
New-Item -ItemType Directory -Path $occupied -Force | Out-Null
# 先放一个「别人的同名技能」：name 一样但内容不是本项目的
@'
---
name: keil5-automatic-wwj
description: 别人的技能，名字碰巧一样
---
这不是本项目的内容。
'@ | Set-Content -LiteralPath (Join-Path $occupied 'SKILL.md') -Encoding UTF8
Set-Content -LiteralPath (Join-Path $occupied 'someone-else.txt') -Value 'not ours' -Encoding ASCII

$savedHome = $env:USERPROFILE
try {
    $env:USERPROFILE = $fakeHome
    $dryRaw = & $installScript -Action install -Target dsh -Source (Join-Path $skillRoot '') -DryRun 2>&1 | Out-String
    # 注意：本项目的 SKILL.md 与「别人的」同名，Test-IsOurSkill 只看 name，
    # 所以这里会判为「属于本项目」。真正要验证的是：脚本不会静默删掉对方的内容。
    # 用一个 name 不同的技能来验证拒绝分支。
    @'
---
name: some-other-skill
description: 完全无关的技能
---
无关内容
'@ | Set-Content -LiteralPath (Join-Path $occupied 'SKILL.md') -Encoding UTF8
    $refRaw = & $installScript -Action install -Target dsh -Source (Join-Path $skillRoot '') 2>&1 | Out-String
    $refused = ($refRaw -match 'occupied by a different skill') -or ($refRaw -match '为免覆盖别人的技能')
    $untouched = Test-Path -LiteralPath (Join-Path $occupied 'someone-else.txt')
    Check 'scenario.installRefusesForeignSkill' ($refused -and $untouched) 'real' `
        ("拒绝=" + $refused + " 对方文件未被删=" + $untouched)

    # 场景 18b：是本项目的旧版本 → 必须备份后再覆盖
    # 造一个「本项目的旧版本」：正确的 name + 一个多余文件
    @'
---
name: keil5-automatic-wwj
description: 本项目旧版本
---
旧内容
'@ | Set-Content -LiteralPath (Join-Path $occupied 'SKILL.md') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $occupied 'old-extra.txt') -Value 'old' -Encoding ASCII
    $updRaw = & $installScript -Action install -Target dsh -Source (Join-Path $skillRoot '') -BackupDirectory (Join-Path $work 'install-backup') 2>&1 | Out-String
    # 备份目录结构是 <BackupDirectory>\<平台>_<时间戳>\<技能名>\...（多一层技能名）
    # 所以必须递归找，不能只看一层。
    $backupDirs = @(Get-ChildItem -LiteralPath (Join-Path $work 'install-backup') -Directory -ErrorAction SilentlyContinue)
    $backupHasOld = @(Get-ChildItem -LiteralPath (Join-Path $work 'install-backup') -Recurse -File -Filter 'old-extra.txt' -ErrorAction SilentlyContinue).Count -ge 1
    Check 'scenario.installBacksUpOldVersion' ($backupDirs.Count -ge 1 -and $backupHasOld) 'real' `
        ("备份目录数=" + $backupDirs.Count + " 含旧文件=" + $backupHasOld)
    # 覆盖后必须是新版本（旧的多余文件不该还在）
    $newInstalled = Test-Path -LiteralPath (Join-Path $occupied 'scripts\KeilCommon.ps1')
    $oldGone = -not (Test-Path -LiteralPath (Join-Path $occupied 'old-extra.txt'))
    Check 'scenario.installReplacedOldVersion' ($newInstalled -and $oldGone) 'real' `
        ("新文件到位=" + $newInstalled + " 旧文件已清=" + $oldGone)
    # 安装后必须通过 SKILL.md 校验
    $verified = (Get-Content -LiteralPath (Join-Path $occupied 'SKILL.md') -Raw) -match 'name:\s*keil5-automatic-wwj'
    Check 'scenario.installVerifiedAfterCopy' $verified 'real' '安装后 name 校验通过'

    # 场景 18c：卸载只删本技能目录，父目录里其他技能必须留着
    $otherSkill = Join-Path $fakeDsh 'another-skill'
    New-Item -ItemType Directory -Path $otherSkill -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $otherSkill 'SKILL.md') -Value "---`nname: another-skill`n---`n" -Encoding UTF8
    $unRaw = & $installScript -Action uninstall -Target dsh -Source (Join-Path $skillRoot '') 2>&1 | Out-String
    $oursGone = -not (Test-Path -LiteralPath $occupied)
    $otherKept = Test-Path -LiteralPath (Join-Path $otherSkill 'SKILL.md')
    Check 'scenario.uninstallKeepsOtherSkills' ($oursGone -and $otherKept) 'real' `
        ("本技能已删=" + $oursGone + " 其他技能保留=" + $otherKept)

    # 场景 18d：status 动作必须如实反映「没装」
    $stRaw = & $installScript -Action status -Target dsh -Source (Join-Path $skillRoot '') 2>&1 | Out-String
    $stSaysMissing = ($stRaw -match 'not-installed') -or ($stRaw -match '未安装')
    Check 'scenario.installStatusReportsMissing' $stSaysMissing 'real' 'status 如实报告未安装'
}
finally {
    $env:USERPROFILE = $savedHome
}

# 场景 19：更新出错 —— 目标父目录不可写时必须报错，而不是假装成功
#   手法：让父目录路径上有一个「同名文件」占位，New-Item 建目录必然失败。
$blockParent = Join-Path $work 'blocked-parent'
New-Item -ItemType Directory -Path $blockParent -Force | Out-Null
Set-Content -LiteralPath (Join-Path $blockParent '.dsh') -Value 'i am a file' -Encoding ASCII
$savedHome = $env:USERPROFILE
try {
    $env:USERPROFILE = $blockParent
    $errRaw = & $installScript -Action install -Target dsh -Source (Join-Path $skillRoot '') 2>&1 | Out-String
    $reported = ($errRaw -match '失败') -or ($errRaw -match 'error')
    $exitCode = $LASTEXITCODE
    Check 'scenario.updateErrorSurfaces' $reported 'real' `
        ("脚本报出了失败=" + $reported + " exitCode=" + $exitCode)
    # 失败时不能把「未安装」写成成功
    $notClaimed = -not ($errRaw -match '\[完成\].*dsh')
    Check 'scenario.updateErrorNotClaimedAsSuccess' $notClaimed 'real' '失败时没有打印 [完成]'
}
finally {
    $env:USERPROFILE = $savedHome
}

# 场景 21：DSH 未加载 Skill —— 判定标准是「安装目录里 SKILL.md 的 name 对不对」
$installCheck = Join-Path $work 'check-skill'
New-Item -ItemType Directory -Path $installCheck -Force | Out-Null
# 21a：完全没装
$notLoaded = -not (Test-Path -LiteralPath (Join-Path $installCheck 'SKILL.md'))
Check 'scenario.skillNotLoadedDetected' $notLoaded 'offline' 'SKILL.md 不存在 → 判定为未安装'
# 21b：装了但 frontmatter 的 name 不对 → 也要判为「不是本技能」
Set-Content -LiteralPath (Join-Path $installCheck 'SKILL.md') -Value "---`nname: something-else`n---`n" -Encoding UTF8
$wrongName = -not ((Get-Content -LiteralPath (Join-Path $installCheck 'SKILL.md') -Raw) -match 'name:\s*keil5-automatic-wwj')
Check 'scenario.skillWrongNameDetected' $wrongName 'offline' 'name 不匹配 → 判定为装错'
# 21c：真正的技能目录必须能通过判定
$realSkillMd = Join-Path $skillRoot 'SKILL.md'
$realNameOk = (Get-Content -LiteralPath $realSkillMd -Raw) -match 'name:\s*keil5-automatic-wwj'
Check 'scenario.realSkillNameMatches' $realNameOk 'offline' '本仓库 skill\SKILL.md 的 name 正确'
# 21d：DSH 实际安装位置必须真的能加载（有 SKILL.md + 脚本齐全）
$dshSkill = Join-Path $env:USERPROFILE '.dsh\skills\keil5-automatic-wwj'
if (Test-Path -LiteralPath $dshSkill) {
    $need = @('SKILL.md', 'scripts\KeilCommon.ps1', 'scripts\Build-Project.ps1', 'scripts\run-test.ps1', 'scripts\UvSockClient.exe')
    $missing = @($need | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dshSkill $_)) })
    Check 'scenario.dshInstallComplete' ($missing.Count -eq 0) 'real' `
        $(if ($missing.Count) { '缺: ' + ($missing -join ', ') } else { 'DSH 安装目录关键文件齐全' })
}
else {
    Check 'scenario.dshInstallComplete' $false 'real' ('DSH 未安装: ' + $dshSkill)
}
}

# =====================================================================
if (Want 'repair') {
Section '场景 20、22：自动修复达上限 / 配置缺失损坏'
# =====================================================================

$rsRoot = Join-Path $work 'repair-scenarios'

# 场景 20：自动修复达上限 —— 用一个永远编译不过的工程连做 3 次
$repairProjDir = Join-Path $work 'never-compiles'
New-Item -ItemType Directory -Path $repairProjDir -Force | Out-Null
$repairProj = Join-Path $repairProjDir 'never.uvprojx'
Copy-Item -LiteralPath (Join-Path $skillRoot 'assets\test-project\test.uvprojx') -Destination $repairProj -Force
foreach ($f in 'main.c', 'core_cm3.c', 'core_cm3.h', 'stm32f10x.h', 'system_stm32f10x.c', 'system_stm32f10x.h', 'startup_stm32f10x_hd.s', 'EventRecorderStub.scvd') {
    Copy-Item -LiteralPath (Join-Path $skillRoot ("assets\test-project\" + $f)) -Destination (Join-Path $repairProjDir $f) -Force
}
Copy-Item -LiteralPath (Join-Path $skillRoot 'assets\test-project\DebugConfig') -Destination (Join-Path $repairProjDir 'DebugConfig') -Recurse -Force

$startRaw = & $repairScript -Action start -Project $repairProj -Scope '*.c' -SessionRoot $rsRoot -MaxAttempts 3 2>&1 | Out-String
$startJson = $null
try { $startJson = $startRaw | ConvertFrom-Json } catch { }
if (-not $startJson) {
    $line = @($startRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if ($line.Count) { try { $startJson = $line[0] | ConvertFrom-Json } catch { } }
}
Check 'scenario.repairSessionStarts' ($startJson -and $startJson.sessionId) 'offline' `
    $(if ($startJson) { "session=" + $startJson.sessionId + " 范围=" + @($startJson.scope).Count + " 文件" } else { '未返回会话号' })

if ($startJson -and $startJson.sessionId -and $realOk) {
    $sid = $startJson.sessionId
    # 第一次尝试：什么都不改 → 应判定「空转」并停止
    $a1 = & $repairScript -Action attempt -SessionId $sid -SessionRoot $rsRoot -Reason '未改动，测试空转判定' -Uv4 $uv4Path -TimeoutSeconds $BuildTimeoutSeconds 2>&1 | Out-String
    $a1Json = $null
    try { $a1Json = $a1 | ConvertFrom-Json } catch { }
    if (-not $a1Json) {
        $line = @($a1 -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count) { try { $a1Json = $line[0] | ConvertFrom-Json } catch { } }
    }
    $noChangeStop = $a1Json -and ($a1Json.stop -eq $true) -and (@($a1Json.stopReasons) -join '|') -match '空转'
    Check 'scenario.repairStopsOnNoChange' $noChangeStop 'real' `
        $(if ($a1Json) { "stop=" + $a1Json.stop + " 原因=" + (@($a1Json.stopReasons) -join '；') } else { '输出不是 JSON' })

    # 上限本身：直接读会话账本确认 maxAttempts=3
    $st = & $repairScript -Action status -SessionId $sid -SessionRoot $rsRoot 2>&1 | Out-String
    $stJson = $null
    try { $stJson = $st | ConvertFrom-Json } catch { }
    if (-not $stJson) {
        $line = @($st -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count) { try { $stJson = $line[0] | ConvertFrom-Json } catch { } }
    }
    $maxOk = $stJson -and [int]$stJson.maxAttempts -eq 3
    Check 'scenario.repairMaxAttemptsIs3' $maxOk 'offline' `
        $(if ($stJson) { "maxAttempts=" + $stJson.maxAttempts + " 已尝试=" + @($stJson.attempts).Count } else { '未取到会话状态' })

    # 回滚：能恢复原文件，且回滚前会备份当前状态（回滚可撤销）
    # 基线哈希要在「注入改动之前」取，否则断言没有意义。
    $mainC = Join-Path $repairProjDir 'main.c'
    $baselineHash = (Get-FileHash -LiteralPath $mainC -Algorithm SHA256).Hash
    Add-Content -LiteralPath $mainC -Value '// scenario injected change' -Encoding ASCII
    $injectedHash = (Get-FileHash -LiteralPath $mainC -Algorithm SHA256).Hash
    $rbRaw = & $repairScript -Action rollback -SessionId $sid -SessionRoot $rsRoot 2>&1 | Out-String
    $afterHash = (Get-FileHash -LiteralPath $mainC -Algorithm SHA256).Hash
    $rbJson = $null
    try { $rbJson = $rbRaw | ConvertFrom-Json } catch { }
    if (-not $rbJson) {
        $line = @($rbRaw -split "`r?`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
        if ($line.Count) { try { $rbJson = $line[0] | ConvertFrom-Json } catch { } }
    }
    # 注入的改动确实改变了文件（否则这个场景没测到东西）
    Check 'scenario.repairInjectChangedFile' ($injectedHash -ne $baselineHash) 'real' `
        ("注入后哈希变化=" + ($injectedHash -ne $baselineHash))
    # 回滚后必须回到基线内容：哈希等于基线，且注入的那行不见了
    $contentNow = Get-Content -LiteralPath $mainC -Raw
    $injectedGone = $contentNow -notmatch 'scenario injected change'
    Check 'scenario.repairRollbackRestores' (($afterHash -eq $baselineHash) -and $injectedGone) 'real' `
        ("回到基线哈希=" + ($afterHash -eq $baselineHash) + " 注入行已消失=" + $injectedGone)
    # 回滚本身可撤销：必须留了一份 pre-rollback 备份
    $preDirs = @(Get-ChildItem -LiteralPath (Join-Path $rsRoot $sid) -Directory -Filter 'pre-rollback_*' -ErrorAction SilentlyContinue)
    $preHasMain = $false
    foreach ($pd in $preDirs) {
        if (@(Get-ChildItem -LiteralPath $pd.FullName -Recurse -File -Filter 'main.c' -ErrorAction SilentlyContinue).Count -ge 1) { $preHasMain = $true }
    }
    Check 'scenario.repairRollbackIsUndoable' ($preDirs.Count -ge 1 -and $preHasMain) 'real' `
        ("pre-rollback 备份数=" + $preDirs.Count + " 含 main.c=" + $preHasMain)
}
else {
    $why = if (-not $realOk) { '没有可用 Keil' } else { '会话未建立' }
    Check 'scenario.repairStopsOnNoChange' $false 'real' ('未执行（' + $why + '）')
    Check 'scenario.repairMaxAttemptsIs3' $false 'offline' ('未执行（' + $why + '）')
    Check 'scenario.repairRollbackRestores' $false 'real' ('未执行（' + $why + '）')
}

# 场景 22：配置文件缺失 / 损坏 —— 必须能降级，不能崩
$savedCfg = $env:KEIL5_AUTOMATIC_WWJ_CONFIG
try {
    $cfgPath = Join-Path $work 'cfg-missing.json'
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $cfgPath
    # 22a：缺失 → 返回空配置而不是抛异常
    $threw = $false
    $cfg = $null
    try { $cfg = Get-KeilConfig } catch { $threw = $true }
    Check 'scenario.configMissingTolerated' (-not $threw) 'offline' ("threw=" + $threw + " cfg=" + $(if ($null -eq $cfg) { 'null' } else { 'object' }))

    # 22b：损坏（不是合法 JSON）→ 必须让人看见，而不是静默当成空配置
    # 设计约定：默认报警（Write-Warning + error 字段非空）并继续降级；
    #           加 -Strict 才抛异常。两种都必须能被检出。
    Set-Content -LiteralPath $cfgPath -Value '{ "uv4": ' -Encoding UTF8
    $warned = $false
    $cfgErr = $null
    $threwStrict = $false
    try {
        $cfg2 = Get-KeilConfig -WarningAction SilentlyContinue -WarningVariable wv -ErrorAction Stop
        $cfgErr = $cfg2.error
        if (@($wv).Count -ge 1) { $warned = $true }
    }
    catch { $warned = $true; $cfgErr = $_.Exception.Message }
    try { $null = Get-KeilConfig -Strict } catch { $threwStrict = $true }
    $reported = ($null -ne $cfgErr -and "$cfgErr" -ne '') -or $warned
    Check 'scenario.configCorruptReported' $reported 'offline' `
        ("报了错=" + $reported + " 警告=" + $warned + " error字段=" + $(if ($cfgErr) { '有' } else { '无' }))
    Check 'scenario.configCorruptStrictThrows' $threwStrict 'offline' ("-Strict 抛异常=" + $threwStrict)

    # 22c：损坏的配置不能挡住路径解析 —— 还要能回退到候选路径
    $threw = $false
    $resolved = $null
    try { $resolved = Resolve-KeilUv4 } catch { $threw = $true }
    Check 'scenario.configCorruptStillResolves' ((-not $threw) -and $resolved -and $resolved.path) 'real' `
        $(if ($resolved) { "source=" + $resolved.source + " path=" + $resolved.path } else { '解析失败: ' + $threw })
}
finally {
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $savedCfg
}
}

# =====================================================================
Section '收尾安全核对'
# =====================================================================
if ($preExisting.Count -gt 0) {
    $survivors = @($preExisting | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    Check 'safety.preexistingAlive' ($survivors.Count -eq $preExisting.Count) 'real' `
        ("测试前 " + $preExisting.Count + " 个，存活 " + $survivors.Count + " 个")
}
else {
    Check 'safety.preexistingAlive' $true 'real' '测试前没有已运行的 uVision（无进程可误杀）'
}

# 技能安装目录不能被测试写脏
$dirty = @(Get-ChildItem -LiteralPath $scriptRoot -File | Where-Object { $_.Extension -in '.log', '.hex', '.axf', '.map', '.o' })
Check 'safety.skillDirNotPolluted' ($dirty.Count -eq 0) 'offline' `
    $(if ($dirty.Count) { '残留: ' + (@($dirty.Name) -join ', ') } else { 'skill\scripts 无编译产物残留' })

# =====================================================================
# 汇总
# =====================================================================
$failed = @($results | Where-Object { -not $_.passed })
$passed = ($failed.Count -eq 0)
$byMode = @{}
foreach ($r in $results) {
    if (-not $byMode.ContainsKey($r.mode)) { $byMode[$r.mode] = @{ total = 0; failed = 0 } }
    $byMode[$r.mode].total++
    if (-not $r.passed) { $byMode[$r.mode].failed++ }
}

$summary = [ordered]@{
    skill       = 'keil5-automatic-wwj'
    suite       = 'scenario'
    group       = $Group
    allowRealKeil = $AllowRealKeil
    keilPath    = $uv4Path
    passed      = $passed
    testCount   = $results.Count
    failedCount = $failed.Count
    byMode      = $byMode
    workDir     = $work
    tests       = $results
}
$summaryPath = Join-Path $work 'scenario-result.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Output ''
Write-Output ("  按类型统计: " + (@($byMode.Keys | ForEach-Object { "$_=$($byMode[$_].total - $byMode[$_].failed)/$($byMode[$_].total)" }) -join '  '))
Write-Output ("SCENARIO RESULT: {0}  ({1}/{2} scenarios passed)" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), ($results.Count - $failed.Count), $results.Count)
Write-Output ("result.json: " + $summaryPath)
if (-not $passed) { exit 1 }
