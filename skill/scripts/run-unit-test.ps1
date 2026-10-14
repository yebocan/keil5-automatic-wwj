[CmdletBinding()]
param(
    [string]$WorkDirectory = (Join-Path ([IO.Path]::GetTempPath()) 'keil5-unit-tests')
)

# keil5-automatic-wwj 单元测试 —— 全部使用临时目录里的合成数据，不碰真实 Keil 工程，
# 不启动 uVision，不结束任何进程。
#
# 覆盖：Keil 路径解析优先级 / 工程解析 / 编译日志解析 / Intel HEX 校验 /
#       进程清理的拒绝条件 / 安装目录判定。
#
# 与 run-test.ps1 的区别：run-test.ps1 是集成测试（真的启动 uVision 编译+调试）；
# 本脚本是单元测试，秒级完成，可以在任何机器上跑（不需要装 Keil）。

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

$scriptRoot = $PSScriptRoot
$work = [IO.Path]::GetFullPath($WorkDirectory)
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null

$results = [Collections.Generic.List[object]]::new()
function Check([string]$name, [bool]$passed, [string]$detail) {
    $script:results.Add([ordered]@{ test = $name; passed = $passed; detail = $detail })
    Write-Output ("[{0}] {1} - {2}" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), $name, $detail)
}
function Section([string]$title) { Write-Output ''; Write-Output ("--- " + $title + " ---") }

# =====================================================================
Section '1. Keil 路径解析（优先级与失败提示）'
# =====================================================================

# 1.1 显式参数优先，且必须真的存在
$fakeUv4 = Join-Path $work 'fake-UV4.exe'
Set-Content -LiteralPath $fakeUv4 -Value 'stub' -Encoding ASCII
$r = Resolve-KeilUv4 -Uv4 $fakeUv4
Check 'path.parameterWins' ($r.source -eq 'parameter' -and $r.path -eq $fakeUv4) ("source=" + $r.source)

# 1.2 参数不存在时不能静默回退，必须记录尝试过
$missing = Join-Path $work 'nope\UV4.exe'
try {
    $r2 = Resolve-KeilUv4 -Uv4 $missing
    # 本机装了 Keil，所以会回退到候选路径 —— 关键是 attempts 里必须记录了这次失败
    $recorded = (@($r2.attempts) -join '|') -match 'nope'
    Check 'path.missingParameterRecorded' $recorded ("fallback=" + $r2.source + " recorded=" + $recorded)
}
catch {
    $ok = $_.Exception.Message -match 'nope'
    Check 'path.missingParameterRecorded' $ok ("throw contains path: " + $ok)
}

# 1.3 完全找不到时，报错必须列出「试过哪些地方」
#     用 KEIL5_UV4_CANDIDATES 把候选目录换成空目录，才能真的走到「找不到」分支。
$savedEnv = $env:KEIL5_UV4
$savedCfg = $env:KEIL5_AUTOMATIC_WWJ_CONFIG
$savedCand = $env:KEIL5_UV4_CANDIDATES
try {
    $env:KEIL5_UV4 = $null
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = Join-Path $work 'cfg-does-not-exist.json'
    $env:KEIL5_UV4_CANDIDATES = $work   # 这个目录里没有 UV4.exe
    $oldPath = $env:PATH
    $env:PATH = $work
    try {
        $null = Resolve-KeilUv4
        Check 'path.notFoundListsAttempts' $false '本应找不到 UV4，却返回了结果'
    }
    catch {
        $msg = $_.Exception.Message
        $hasList = ($msg -match 'KEIL5_UV4') -and ($msg -match '配置文件') -and ($msg -match '常见安装位置') -and ($msg -match 'PATH')
        Check 'path.notFoundListsAttempts' $hasList ('error lists every attempted source: ' + $hasList)
    }
    $env:PATH = $oldPath
}
finally {
    $env:KEIL5_UV4 = $savedEnv
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $savedCfg
    $env:KEIL5_UV4_CANDIDATES = $savedCand
}

# 1.4 配置文件读写（source 形如 "config:<路径>"）
try {
    $cfgPath = Join-Path $work 'config.json'
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $cfgPath
    $null = Set-KeilConfig -Uv4 $fakeUv4
    $cfg = Get-KeilConfig
    $r3 = Resolve-KeilUv4
    Check 'path.configFileRoundTrip' ($cfg.exists -and $r3.source -like 'config:*' -and $r3.path -eq $fakeUv4) ("source=" + $r3.source + " cfg=" + $cfg.uv4)
}
finally { $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $savedCfg }

# 1.5 配置文件损坏 → 必须报错而不是崩溃
try {
    $badCfg = Join-Path $work 'bad-config.json'
    Set-Content -LiteralPath $badCfg -Value '{ this is not json' -Encoding UTF8
    $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $badCfg
    $cfgBad = Get-KeilConfig
    Check 'path.corruptConfigHandled' ($cfgBad.exists -and $cfgBad.error) ('error reported: ' + [bool]$cfgBad.error)
}
finally { $env:KEIL5_AUTOMATIC_WWJ_CONFIG = $savedCfg }

# =====================================================================
Section '2. 工程解析（.uvprojx）'
# =====================================================================

# 2.1 路径带空格 + 中文
$cnDir = Join-Path $work '中文 目录 带空格'
New-Item -ItemType Directory -Path $cnDir -Force | Out-Null
$projXml = @'
<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<Project xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <SchemaVersion>2.1</SchemaVersion>
  <Targets>
    <Target>
      <TargetName>Target 1</TargetName>
      <ToolsetNumber>0x4</ToolsetNumber>
      <TargetOption>
        <TargetCommonOption>
          <Device>STM32F103RC</Device>
          <OutputDirectory>..\OBJ\</OutputDirectory>
          <OutputName>demo</OutputName>
          <CreateHexFile>1</CreateHexFile>
        </TargetCommonOption>
        <TargetArmAds>
          <Cads>
            <IncludePath>..\INC;.\sub dir</IncludePath>
          </Cads>
        </TargetArmAds>
      </TargetOption>
    </Target>
    <Target>
      <TargetName>Target 2</TargetName>
      <TargetOption>
        <TargetCommonOption>
          <Device>STM32F407VG</Device>
          <OutputDirectory>.\out2\</OutputDirectory>
          <OutputName>demo2</OutputName>
          <CreateHexFile>0</CreateHexFile>
        </TargetCommonOption>
      </TargetOption>
    </Target>
  </Targets>
</Project>
'@
$projPath = Join-Path $cnDir 'demo 工程.uvprojx'
Set-Content -LiteralPath $projPath -Value $projXml -Encoding UTF8
# 造两个源文件，验证存在性检测
Set-Content -LiteralPath (Join-Path $cnDir 'main.c') -Value 'int main(void){return 0;}' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $cnDir 'gone.c') -Value 'x' -Encoding ASCII
$projXml2 = $projXml.Replace('</Targets>', @'
  <Groups>
    <Group>
      <GroupName>App</GroupName>
      <Files>
        <File><FileName>main.c</FileName><FileType>1</FileType><FilePath>.\main.c</FilePath></File>
        <File><FileName>gone.c</FileName><FileType>1</FileType><FilePath>.\gone.c</FilePath></File>
      </Files>
    </Group>
  </Groups>
</Targets>
'@)
Set-Content -LiteralPath $projPath -Value $projXml2 -Encoding UTF8
Remove-Item -LiteralPath (Join-Path $cnDir 'gone.c') -Force

$pi = Get-KeilProjectInfo -Project $projPath
Check 'project.parsesChineseSpacePath' ($pi.parseOk -and $pi.project -eq $projPath) ("path=" + $pi.project)
Check 'project.targetCount' ($pi.targetCount -eq 2) ("targetCount=" + $pi.targetCount)
Check 'project.firstTarget' ($pi.target.name -eq 'Target 1' -and $pi.target.device -eq 'STM32F103RC') ("target=" + $pi.target.name + " device=" + $pi.target.device)
$expectOut = [IO.Path]::GetFullPath((Join-Path $cnDir '..\OBJ')).TrimEnd('\', '/')
Check 'project.outputDirResolved' ($pi.outputDir.TrimEnd('\', '/') -eq $expectOut) ("outputDir=" + $pi.outputDir + " expected=" + $expectOut)
Check 'project.axfPath' ($pi.axfPath -eq (Join-Path $pi.outputDir 'demo.axf')) ("axf=" + $pi.axfPath)
Check 'project.hexEnabled' ($pi.target.createHex -eq $true) ("createHex=" + $pi.target.createHex)
Check 'project.secondTargetHexOff' ($pi.targets[1].createHex -eq $false) ("target2 createHex=" + $pi.targets[1].createHex)
Check 'project.includesParsed' ($pi.includes.Count -eq 2) ("includes=" + ($pi.includes -join ' ; '))
Check 'project.sourceCount' ($pi.sourceCount -eq 2) ("sources=" + $pi.sourceCount)
$mainSrc = $pi.sources | Where-Object { $_.name -eq 'main.c' }
$goneSrc = $pi.sources | Where-Object { $_.name -eq 'gone.c' }
Check 'project.sourceExistsFlag' ($mainSrc.exists -eq $true -and $goneSrc.exists -eq $false) ("main.c exists=" + $mainSrc.exists + " gone.c exists=" + $goneSrc.exists)

# 2.2 非工程文件必须拒绝
try {
    $null = Get-KeilProjectInfo -Project (Join-Path $cnDir 'main.c')
    Check 'project.rejectsNonProject' $false '没有拒绝 .c 文件'
}
catch {
    Check 'project.rejectsNonProject' ($_.Exception.Message -match 'uvprojx') ('rejected: ' + $_.Exception.Message.Substring(0, [Math]::Min(50, $_.Exception.Message.Length)))
}

# 2.3 工程文件不存在 → 明确报错
try {
    $null = Get-KeilProjectInfo -Project (Join-Path $cnDir 'nope.uvprojx')
    Check 'project.rejectsMissing' $false '没有拒绝不存在的工程'
}
catch {
    Check 'project.rejectsMissing' ($_.Exception.Message -match '不存在') ('rejected: ' + $_.Exception.Message.Substring(0, [Math]::Min(40, $_.Exception.Message.Length)))
}

# =====================================================================
Section '3. Intel HEX 校验'
# =====================================================================

function New-HexLine([int]$len, [int]$addr, [int]$type, [int[]]$data) {
    $hi = [int](($addr -shr 8) -band 0xFF)
    $lo = [int]($addr -band 0xFF)
    $bytes = @($len) + @($hi) + @($lo) + @($type) + @($data)
    $sum = 0
    foreach ($b in $bytes) { $sum = ($sum + $b) -band 0xFF }
    $ck = (0x100 - $sum) -band 0xFF
    $all = $bytes + @($ck)
    return ':' + (($all | ForEach-Object { '{0:X2}' -f $_ }) -join '')
}

# 3.1 合法文件
$goodHex = Join-Path $work 'good.hex'
$lines = @(
    New-HexLine 16 0 0 @(0x20, 0x04, 0x00, 0x20, 0x49, 0x01, 0x00, 0x08, 0x51, 0x01, 0x00, 0x08, 0x53, 0x01, 0x00, 0x08)
    New-HexLine 4 16 0 @(0x55, 0x01, 0x00, 0x08)
    New-HexLine 0 0 1 @()
)
Set-Content -LiteralPath $goodHex -Value ($lines -join "`r`n") -Encoding ASCII
$h = Test-IntelHexFile -Path $goodHex
Check 'hex.validFile' ($h.valid -and $h.eofSeen -and $h.dataRecords -eq 2) ("valid=" + $h.valid + " dataRecords=" + $h.dataRecords + " range=" + $h.addressRange)

# 3.2 校验和错误（把最后一字节改成 FF，注意要换掉整个字节，不能只换一个字符）
$badSum = Join-Path $work 'badsum.hex'
$corrupted = $lines[0].Substring(0, $lines[0].Length - 2) + 'FF'
Set-Content -LiteralPath $badSum -Value ($corrupted + "`r`n" + $lines[2]) -Encoding ASCII
$h2 = Test-IntelHexFile -Path $badSum
Check 'hex.checksumError' ((-not $h2.valid) -and $h2.checksumErrors -ge 1) ("valid=" + $h2.valid + " checksumErrors=" + $h2.checksumErrors)

# 3.3 空文件（真的 0 字节，不能用 Set-Content ''，那会写入 CRLF）
$emptyHex = Join-Path $work 'empty.hex'
[IO.File]::WriteAllText($emptyHex, '')
$h3 = Test-IntelHexFile -Path $emptyHex
Check 'hex.emptyFile' ((-not $h3.valid) -and $h3.size -eq 0) ("valid=" + $h3.valid + " size=" + $h3.size + " msg=" + $h3.firstErrorText)

# 3.4 缺少结束记录
$noEof = Join-Path $work 'noeof.hex'
Set-Content -LiteralPath $noEof -Value $lines[0] -Encoding ASCII
$h4 = Test-IntelHexFile -Path $noEof
Check 'hex.missingEof' ((-not $h4.valid) -and (-not $h4.eofSeen)) ("valid=" + $h4.valid + " eofSeen=" + $h4.eofSeen)

# 3.5 行首不是冒号
$noColon = Join-Path $work 'nocolon.hex'
Set-Content -LiteralPath $noColon -Value ('X' + $lines[0].Substring(1)) -Encoding ASCII
$h5 = Test-IntelHexFile -Path $noColon
Check 'hex.malformedLine' ((-not $h5.valid) -and $h5.malformedLines -ge 1) ("valid=" + $h5.valid + " malformed=" + $h5.malformedLines + " msg=" + $h5.firstErrorText)

# 3.6 扩展线性地址记录（类型 04）必须被识别
#     类型 04 的 2 字节数据是「高 16 位」，0x0800 << 16 = 0x08000000（STM32 Flash 基址）
$extHex = Join-Path $work 'ext.hex'
$extLines = @(
    New-HexLine 2 0 4 @(0x08, 0x00)
    New-HexLine 4 0 0 @(0x11, 0x22, 0x33, 0x44)
    New-HexLine 0 0 1 @()
)
Set-Content -LiteralPath $extHex -Value ($extLines -join "`r`n") -Encoding ASCII
$h6 = Test-IntelHexFile -Path $extHex
Check 'hex.extendedAddress' ($h6.valid -and $h6.addressRange -eq '0x08000000-0x08000003') ("valid=" + $h6.valid + " range=" + $h6.addressRange)

# 3.7 不存在的文件
$h7 = Test-IntelHexFile -Path (Join-Path $work 'nope.hex')
Check 'hex.missingFile' ((-not $h7.valid) -and (-not $h7.exists)) ("valid=" + $h7.valid + " exists=" + $h7.exists)

# =====================================================================
Section '4. 进程清理：拒绝条件（绝不误杀）'
# =====================================================================

# 4.1 没有 PID → 什么都不做
$c1 = Stop-OwnedUvision -ProcessId 0
Check 'proc.noPidNoAction' ((-not $c1.attempted) -and (-not $c1.killed)) ("message=" + $c1.message)

# 4.2 PID 不存在 → 什么都不做
$c2 = Stop-OwnedUvision -ProcessId 999999
Check 'proc.deadPidNoAction' ((-not $c2.killed)) ("message=" + $c2.message)

# 4.3 PID 存在但不是 UV4（用当前 PowerShell 进程试）→ 必须拒绝
$me = $PID
$c3 = Stop-OwnedUvision -ProcessId $me
$alive = [bool](Get-Process -Id $me -ErrorAction SilentlyContinue)
Check 'proc.refusesNonUv4' ($c3.refused -and (-not $c3.killed) -and $alive) ("refused=" + $c3.refused + " alive=" + $alive + " message=" + $c3.message)

# 4.4 PID 是 UV4 但启动时间对不上 → 必须拒绝（防 PID 复用）
$c4 = Stop-OwnedUvision -ProcessId $me -StartedAt (Get-Date).AddHours(-5)
Check 'proc.refusesWrongStartTime' ($c4.refused -and (-not $c4.killed) -and $alive) ("refused=" + $c4.refused + " message=" + $c4.message)

# 4.5 记录已有实例的函数只读、不结束
$before = @(Get-UvisionProcesses).Count
$null = Get-UvisionProcesses
$after = @(Get-UvisionProcesses).Count
Check 'proc.enumIsReadOnly' ($before -eq $after) ("uv4 count before=" + $before + " after=" + $after)

# 4.6 启动登记表：异常中断后能认出「这是本项目起的 uVision」
# 这一段只测登记表自身的读写与判定，不启动任何 uVision。
$regPath = Get-KeilOwnedRegistryPath
$regBackup = $null
if (Test-Path -LiteralPath $regPath) { $regBackup = Get-Content -LiteralPath $regPath -Raw }
try {
    Remove-Item -LiteralPath $regPath -Force -ErrorAction SilentlyContinue

    # 空登记表要能安全读回（不能抛异常）
    $threw = $false
    try { $null = Get-RegisteredOwnedUvision } catch { $threw = $true }
    Check 'registry.emptyReadsClean' (-not $threw) ('threw=' + $threw)

    # 登记一个不存在的 PID：能写进去，但读回时必须判为 not alive / 不 owned
    $null = Register-OwnedUvision -ProcessId 999999 -StartedAt (Get-Date) -Port 1234 -Project 'x.uvprojx'
    $items = @(Get-RegisteredOwnedUvision)
    Check 'registry.writesEntry' ($items.Count -eq 1 -and $items[0].pid -eq 999999) ("count=" + $items.Count)
    Check 'registry.deadPidNotOwned' ($items.Count -eq 1 -and -not $items[0].alive -and -not $items[0].owned) `
        ("alive=" + $(if ($items.Count) { $items[0].alive } else { 'n/a' }) + " owned=" + $(if ($items.Count) { $items[0].owned } else { 'n/a' }))

    # 登记当前进程（存在，但不是 UV4）→ 必须判为不 owned（绝不能误判成可清理的 Keil）
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 1234 -Project 'x.uvprojx'
    $items = @(Get-RegisteredOwnedUvision | Where-Object { $_.pid -eq $PID })
    Check 'registry.nonUv4NotOwned' ($items.Count -eq 1 -and -not $items[0].owned) `
        ("processName=" + $(if ($items.Count) { $items[0].processName } else { 'n/a' }) + " owned=" + $(if ($items.Count) { $items[0].owned } else { 'n/a' }))

    # PID 被复用（启动时间对不上）→ 必须判为不 owned
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date).AddHours(-5) -Port 1234 -Project 'x.uvprojx'
    $items = @(Get-RegisteredOwnedUvision | Where-Object { $_.pid -eq $PID })
    Check 'registry.startTimeMismatchNotOwned' ($items.Count -eq 1 -and -not $items[0].owned -and -not $items[0].startedAtMatches) `
        ("matches=" + $(if ($items.Count) { $items[0].startedAtMatches } else { 'n/a' }))

    # 移除条目
    $null = Register-OwnedUvision -ProcessId 999999 -StartedAt (Get-Date) -Port 1 -Project 'a'
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 1 -Project 'b'
    Remove-KeilOwnedRegistryEntry -ProcessId 999999
    $left = @(Get-RegisteredOwnedUvision)
    Check 'registry.removeEntry' ($left.Count -eq 1 -and $left[0].pid -eq $PID) ("left=" + $left.Count)
    Remove-KeilOwnedRegistryEntry -ProcessId $PID
    Check 'registry.removeLastDeletesFile' (-not (Test-Path -LiteralPath $regPath)) 'file removed when last entry goes'

    # 同一 PID 重复登记只留一条
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 1 -Project 'a'
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 2 -Project 'b'
    $items = @(Get-RegisteredOwnedUvision)
    Check 'registry.noDuplicatePid' ($items.Count -eq 1 -and $items[0].port -eq 2) ("count=" + $items.Count)

    # 登记表损坏时要当空的处理，不能让启动流程失败
    Set-Content -LiteralPath $regPath -Value '{ this is not json' -Encoding UTF8
    $threw = $false
    try { $null = Get-RegisteredOwnedUvision } catch { $threw = $true }
    Check 'registry.corruptFileReadsClean' (-not $threw) ('threw=' + $threw)
    $threw = $false
    try { $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 3 -Project 'c' } catch { $threw = $true }
    Check 'registry.corruptFileWritesClean' (-not $threw) ('threw=' + $threw)

    # run-test.ps1 必须真的用了登记表（否则清理逻辑是摆设）
    $rtTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'run-test.ps1') -Raw
    Check 'registry.runTestUsesIt' ($rtTxt -match 'Get-RegisteredOwnedUvision') 'run-test.ps1 reads the registry'
    Check 'registry.startUvisionRegisters' ((Get-Content -LiteralPath (Join-Path $scriptRoot 'Start-Uvision.ps1') -Raw) -match 'Register-OwnedUvision') 'Start-Uvision.ps1 registers its pid'
    Check 'registry.registerBeforeWait' `
        ((Get-Content -LiteralPath (Join-Path $scriptRoot 'Start-Uvision.ps1') -Raw) -match '(?s)Register-OwnedUvision.*等待端口') `
        'registration happens before waiting for the port'

    # ---- 死条目清理：登记表只增不减的话，跑几十次后会积一堆死 PID，
    #      每次都被当成「残留」报出来，真正的残留反而被淹没（真实发生过的缺陷：
    #      实测积累到 8 条死记录，全是已退出的 PID）。----
    Remove-Item -LiteralPath $regPath -Force -ErrorAction SilentlyContinue
    $null = Register-OwnedUvision -ProcessId 999998 -StartedAt (Get-Date).AddHours(-1) -Port 11 -Project 'dead-1'
    $null = Register-OwnedUvision -ProcessId 999997 -StartedAt (Get-Date).AddHours(-1) -Port 12 -Project 'dead-2'
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 13 -Project 'alive-non-uv4'
    $purged = Remove-KeilDeadRegistryEntries
    # 3 条都该被清：两个 PID 根本不存在，第三个是当前 pwsh 进程（不是 UV4）
    Check 'registry.purgeRemovesDead' ($purged.before -eq 3 -and $purged.removed -eq 3) `
        ("before=" + $purged.before + " removed=" + $purged.removed)
    # 清完没有存活条目，文件应消失
    Check 'registry.purgeRemovesNonUv4' ($purged.kept -eq 0 -and -not (Test-Path -LiteralPath $regPath)) `
        ("kept=" + $purged.kept + " fileGone=" + (-not (Test-Path -LiteralPath $regPath)))

    # 空登记表 / 不存在的登记表都不能抛异常
    $threw = $false
    try { $null = Remove-KeilDeadRegistryEntries } catch { $threw = $true }
    Check 'registry.purgeMissingFileClean' (-not $threw) ('threw=' + $threw)

    # 损坏的登记表也不能抛异常（不能让清理把整个脚本带崩）
    Set-Content -LiteralPath $regPath -Value '[{ broken' -Encoding UTF8
    $threw = $false
    try { $null = Remove-KeilDeadRegistryEntries } catch { $threw = $true }
    Check 'registry.purgeCorruptClean' (-not $threw) ('threw=' + $threw)

    # ---- owner 授权链（m04193 用户要求：只关自己打开的，绝不动别人的窗口）----
    # 旧版登记表条目没有 owner_pid：读回时必须判为不 owned，
    # 并且 Remove-KeilDeadRegistryEntries 要把它当无效条目清掉
    Remove-Item -LiteralPath $regPath -Force -ErrorAction SilentlyContinue
    '{"pid":' + $PID + ',"started_at":"' + (Get-Date).AddSeconds(-1).ToString('o') + '","port":4242,"project":"legacy"}' |
        Set-Content -LiteralPath $regPath -Encoding UTF8
    $legacy = @(Get-RegisteredOwnedUvision | Where-Object { $_.pid -eq $PID })
    Check 'registry.legacyEntryNoOwner' ($legacy.Count -eq 1 -and -not $legacy[0].owned -and -not $legacy[0].owner_pid) `
        ("owned=" + $(if ($legacy.Count) { $legacy[0].owned } else { 'n/a' }) + " owner_pid=" + $(if ($legacy.Count) { $legacy[0].owner_pid } else { 'n/a' }))
    $purged2 = Remove-KeilDeadRegistryEntries
    Check 'registry.purgeDropsOwnerless' ($purged2.removed -ge 1 -and -not (Test-Path -LiteralPath $regPath)) `
        ("removed=" + $purged2.removed + " kept=" + $purged2.kept)

    # 登记必须写入 owner_pid（默认取当前进程）
    Remove-Item -LiteralPath $regPath -Force -ErrorAction SilentlyContinue
    $null = Register-OwnedUvision -ProcessId $PID -StartedAt (Get-Date) -Port 4321 -Project 'owner-test'
    $ownedItem = @(Get-RegisteredOwnedUvision | Where-Object { $_.pid -eq $PID })
    Check 'registry.recordsOwnerPid' ($ownedItem.Count -eq 1 -and $ownedItem[0].owner_pid -eq $PID) `
        ("owner_pid=" + $(if ($ownedItem.Count) { $ownedItem[0].owner_pid } else { 'n/a' }))
    $null = Register-OwnedUvision -ProcessId $PID -OwnerPid 987654 -StartedAt (Get-Date) -Port 4322 -Project 'owner-test'
    $ownedItem = @(Get-RegisteredOwnedUvision | Where-Object { $_.pid -eq $PID })
    Check 'registry.ownerPidOverridable' ($ownedItem.Count -eq 1 -and $ownedItem[0].owner_pid -eq 987654) `
        ("owner_pid=" + $(if ($ownedItem.Count) { $ownedItem[0].owner_pid } else { 'n/a' }))

    # Stop-OwnedUvision：owner 对不上必须拒绝（拿自己当靶子，owner 传一个不相干的 PID）
    $me = $PID
    $c5 = Stop-OwnedUvision -ProcessId $me -OwnerPid 987654 -StartedAt (Get-Date)
    $alive2 = [bool](Get-Process -Id $me -ErrorAction SilentlyContinue)
    Check 'proc.refusesForeignOwner' ($c5.refused -and (-not $c5.attempted) -and $alive2) `
        ("refused=" + $c5.refused + " alive=" + $alive2 + " ownerCheck=" + $c5.ownerCheck + " message=" + $c5.message)

    # owner 进程不存在时必须拒绝（PID 被复用的高危场景）
    $deadOwner = 4195000
    while (Get-Process -Id $deadOwner -ErrorAction SilentlyContinue) { $deadOwner++ }
    $c6 = Stop-OwnedUvision -ProcessId $me -OwnerPid $deadOwner -StartedAt (Get-Date)
    Check 'proc.refusesDeadOwner' ($c6.refused -and (-not $c6.attempted) -and $alive2) `
        ("refused=" + $c6.refused + " ownerCheck=" + $c6.ownerCheck)

    # 默认 OwnerPid 就是当前进程：登记值不是当前进程时必须带着 caller-not-owner 拒绝
    $c7 = Stop-OwnedUvision -ProcessId $me -StartedAt (Get-Date)
    Check 'proc.defaultOwnerIsSelf' ($c7.refused -and $c7.ownerCheck -like ('caller-not-owner:*caller=' + $me)) `
        ("ownerCheck=" + $c7.ownerCheck)

    # 把登记值换回当前进程后，owner 闸应放行（随后仍因进程名不是 UV4 被拒）——
    # 这条证明授权链不会把「自己登记的自己」挡在门外。
    $null = Register-OwnedUvision -ProcessId $me -OwnerPid $me -OwnerStartedAt (Get-Process -Id $me).StartTime -StartedAt (Get-Date) -Port 4321 -Project 'owner-test'
    $c7b = Stop-OwnedUvision -ProcessId $me -StartedAt (Get-Date)
    Check 'proc.defaultOwnerMatchesRegistry' ($c7b.ownerCheck -like 'ok:owner=*') `
        ("ownerCheck=" + $c7b.ownerCheck + " refused=" + $c7b.refused + " message=" + $c7b.message)
    Remove-KeilOwnedRegistryEntry -ProcessId $me

    # 源码层面：Start-Uvision 必须把 owner_pid 传进登记与清理
    $suTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'Start-Uvision.ps1') -Raw
    Check 'registry.startUvisionPassesOwner' ($suTxt -match 'Register-OwnedUvision\s+-ProcessId\s+\$ownedPid\s+-OwnerPid' -and $suTxt -match 'Stop-OwnedUvision\s+-ProcessId\s+\$ownedPid\s+-OwnerPid') `
        'Start-Uvision.ps1 passes -OwnerPid to both register and stop'
    # 登记表必须是授权的唯一依据：Stop-OwnedUvision 必须先查登记条目
    $kcTxt2 = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'KeilCommon.ps1') -Raw
    Check 'registry.stopChecksRegistryEntry' ($kcTxt2 -match 'Get-RegistryEntry\s+-ProcessId\s+\$ProcessId' -and $kcTxt2 -match 'no-registry-entry') 'Stop-OwnedUvision requires a registry entry'
    # 登记表里没有 owner_pid 的旧条目必须被拒绝（授权链不完整）
    Check 'registry.stopRejectsOwnerlessEntry' ($kcTxt2 -match 'entry-missing-owner') 'ownerless entries are refused'
    # 登记的 owner 启动时间必须写入，用于防 owner PID 被复用
    Check 'registry.recordsOwnerStart' ($kcTxt2 -match 'owner_started_at' -and $kcTxt2 -match 'owner-pid-reused') 'owner start time is recorded and verified'
    # -CleanStaleUvision 分支必须按 owner 判断，不能无脑清
    $rtTxt2 = Get-Content -LiteralPath (Join-Path $scriptRoot 'run-test.ps1') -Raw
    Check 'registry.staleCleanupChecksOwner' ($rtTxt2 -match 'owner_pid' -and $rtTxt2 -match 'ownerStillAlive' -and $rtTxt2 -match 'OwnerPid \(\[int\]\$s\.owner_pid\)') 'run-test.ps1 stale cleanup respects owner'

    # 全仓库不允许出现按名字批量结束 UV4 的写法
    $scan = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $scriptRoot -Filter '*.ps1' -File)) {
        $t = Get-Content -LiteralPath $f.FullName -Raw
        if ($t -match 'Stop-Process\s+-Name\s+UV4' -or $t -match 'Get-Process\s+-Name\s+UV4[^\r\n]*\|\s*Stop-Process') { $scan += $f.Name }
    }
    Check 'proc.noNameBasedKill' ($scan.Count -eq 0) ('files=' + $(if ($scan.Count) { $scan -join ',' } else { 'none' }))

    # Stop-OwnedUvision 结束后必须顺手撤掉登记条目（否则登记表只增不减）
    $kcTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'KeilCommon.ps1') -Raw
    $stopBlock = [regex]::Match($kcTxt, '(?s)function Stop-OwnedUvision \{.*?\n\}')
    Check 'registry.stopRemovesEntry' `
        ($stopBlock.Success -and $stopBlock.Value -match 'Remove-KeilOwnedRegistryEntry') `
        'Stop-OwnedUvision clears its registry entry'

    # run-test.ps1 每次运行都要清一次死条目
    Check 'registry.runTestPurges' ($rtTxt -match 'Remove-KeilDeadRegistryEntries') 'run-test.ps1 purges dead entries'
}
finally {
    # 还原登记表，别把用户/其它脚本的既有记录搞丢
    if ($null -ne $regBackup) { Set-Content -LiteralPath $regPath -Value $regBackup -Encoding UTF8 }
    else { Remove-Item -LiteralPath $regPath -Force -ErrorAction SilentlyContinue }
}

# =====================================================================
Section '5. 安装目录判定（Install-Skill 的目标路径）'
# =====================================================================

# Install-Skill.ps1 在仓库根目录，不在技能目录里 —— 安装版只有 skill\ 一份。
# 所以这里不能写死 ../../Install-Skill.ps1，要分「源码仓库」和「安装副本」两种情况：
#   源码仓库：skill\scripts\..\..\Install-Skill.ps1 存在，检查实际文件。
#   安装副本：上级是技能根目录，再上一级是技能目录本身；改装时自带的正是这份副本，
#             用「源目录的 GitHub 副本不存在」当作跳过理由会误报缺陷，
#             因此从已安装的技能副本里读同一份 Install-Skill.ps1，检查到的内容是等价的。
$installScriptCandidates = @(
    (Join-Path $scriptRoot '..\..\Install-Skill.ps1')
    (Join-Path $scriptRoot '..\..\skill\Install-Skill.ps1')
) | ForEach-Object { [IO.Path]::GetFullPath($_) }
$installScript = @($installScriptCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
$installScriptFrom = if ($installScript) { 'repo' } else { 'installed-copy' }
if (-not $installScript) {
    # 安装副本兜底：技能目录里的同名副本（Install-Skill.ps1 随技能一起分发）。
    $installScript = Join-Path (Split-Path (Split-Path $scriptRoot -Parent) -Parent) 'Install-Skill.ps1'
    $installScript = [IO.Path]::GetFullPath($installScript)
}
if (Test-Path -LiteralPath $installScript) {
    $txt = Get-Content -LiteralPath $installScript -Raw
    # 默认目标必须只含 DSH（用户要求：默认只装 DSH，不默认铺到所有工具）
    $defaultTarget = $null
    if ($txt -match "\[string\[\]\]\`$Target\s*=\s*@\(([^)]*)\)") { $defaultTarget = $Matches[1] }
    Check 'install.defaultIsDshOnly' ($defaultTarget -match "'dsh'" -and $defaultTarget -notmatch "'all'") ("default Target=" + $defaultTarget)
    # 覆盖前必须备份
    Check 'install.hasBackupStep' ($txt -match 'backup' -or $txt -match '备份') ('mentions backup: ' + [bool](($txt -match 'backup') -or ($txt -match '备份')))
    # 文件计数不能写成 @(... | Measure-Object).Count —— 那个值恒为 1，会误报「更新 1 个文件」
    # （真实发生过的缺陷：装了 25 个文件，却打印「更新 1 个文件」）
    # 检查时先去掉注释行，否则「警示注释里引用了这个错误写法」会被误判成缺陷。
    $codeOnly = (@($txt -split "`r?`n" | Where-Object { $_.TrimStart() -notmatch '^#' }) -join "`n")
    $badCount = $codeOnly -match '@\([^)]*Measure-Object[^)]*\)\.Count'
    Check 'install.noMeasureObjectCountBug' (-not $badCount) `
        $(if ($badCount) { '仍有 @(... | Measure-Object).Count（恒等于 1）' } else { '文件计数写法正确' })
    # 计数必须真的数数组元素：@(Get-ChildItem ...).Count
    $goodCount = $codeOnly -match '@\(Get-ChildItem[^)]*\)\.Count'
    Check 'install.countsRecursively' $goodCount '安装后统计文件数用的是数组 .Count'
}
else {
    Check 'install.scriptFound' $false ("未找到 Install-Skill.ps1（两处候选都没找到: " + ($installScriptCandidates -join ' ; ') + "）")
}

# =====================================================================
Section '6. 编译日志解析（离线，不启动 Keil）'
# =====================================================================
# 这一段防的是「解析器本身写错」：$Matches 被内层正则覆盖、行号取错、
# 诊断整条丢失，都是真实发生过的缺陷。

$logDir = Join-Path $work 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

# 6.1 带错误码的诊断行必须解析出正确的文件、行号、错误码
$log1 = Join-Path $logDir 'with-code.log'
@'
Build target 'Target 1'
compiling main.c...
main.c(44): error:  #29: expected an expression
  int undefined_symbol_xyz = ;
main.c: 0 warnings, 1 error
".\Objects\test.axf" - 1 Error(s), 0 Warning(s).
Target not created.
'@ | Set-Content -LiteralPath $log1 -Encoding Default
$r1 = Get-KeilBuildLogDiagnostics -Path $log1
$d1 = @($r1.diagnostics)
Check 'log.parsesErrorCode' ($d1.Count -eq 1 -and $d1[0].line -eq 44 -and $d1[0].code -eq '#29') `
    ("count=" + $d1.Count + " line=" + $(if ($d1.Count) { $d1[0].line } else { 'n/a' }) + " code=" + $(if ($d1.Count) { $d1[0].code } else { 'n/a' }))
Check 'log.messageNotSwallowed' ($d1.Count -eq 1 -and $d1[0].message -eq 'expected an expression') `
    ("message=" + $(if ($d1.Count) { $d1[0].message } else { 'n/a' }))
Check 'log.errorCountFromSummary' ($r1.errorCount -eq 1 -and $r1.warningCount -eq 0) `
    ("errors=" + $r1.errorCount + " warnings=" + $r1.warningCount)

# 6.2 警告不能被当成错误
$log2 = Join-Path $logDir 'warn.log'
@'
compiling util.c...
util.c(12): warning:  #177-D: variable "x" was declared but never referenced
".\Objects\app.axf" - 0 Error(s), 1 Warning(s).
'@ | Set-Content -LiteralPath $log2 -Encoding Default
$r2 = Get-KeilBuildLogDiagnostics -Path $log2
$d2 = @($r2.diagnostics)
Check 'log.warningKind' ($d2.Count -eq 1 -and $d2[0].kind -eq 'warning') `
    ("kind=" + $(if ($d2.Count) { $d2[0].kind } else { 'n/a' }))
Check 'log.warningNotCountedAsError' ($r2.errorCount -eq 0 -and $r2.warningCount -eq 1) `
    ("errors=" + $r2.errorCount + " warnings=" + $r2.warningCount)

# 6.3 fatal error 也要识别
$log3 = Join-Path $logDir 'fatal.log'
@'
compiling main.c...
main.c(3): fatal error:  #5: cannot open source input file "missing.h": No such file or directory
".\Objects\app.axf" - 1 Error(s), 0 Warning(s).
'@ | Set-Content -LiteralPath $log3 -Encoding Default
$r3 = Get-KeilBuildLogDiagnostics -Path $log3
$d3 = @($r3.diagnostics)
Check 'log.fatalRecognized' ($d3.Count -eq 1 -and $d3[0].kind -eq 'error') `
    ("kind=" + $(if ($d3.Count) { $d3[0].kind } else { 'n/a' }))

# 6.4 没有结果行的日志 → 必须判为「无法确定」，不能默认成功
$log4 = Join-Path $logDir 'no-summary.log'
"something odd happened`r`nno summary line here" | Set-Content -LiteralPath $log4 -Encoding Default
$r4 = Get-KeilBuildLogDiagnostics -Path $log4
Check 'log.noSummaryIsIndeterminate' ($null -eq $r4.errorCount) ("errorCount=" + $(if ($null -eq $r4.errorCount) { 'null' } else { $r4.errorCount }))

# 6.5 空日志 / 不存在的日志不能抛异常
$log5 = Join-Path $logDir 'empty.log'
Set-Content -LiteralPath $log5 -Value '' -Encoding Default
$threw = $false
try { $null = Get-KeilBuildLogDiagnostics -Path $log5 } catch { $threw = $true }
Check 'log.emptyDoesNotThrow' (-not $threw) ('threw=' + $threw)
$threw = $false
try { $null = Get-KeilBuildLogDiagnostics -Path (Join-Path $logDir 'nope.log') } catch { $threw = $true }
Check 'log.missingDoesNotThrow' (-not $threw) ('threw=' + $threw)

# 6.6 体积统计
$log6 = Join-Path $logDir 'size.log'
@'
Program Size: Code=256 RO-data=336 RW-data=28 ZI-data=1028
".\Objects\test.axf" - 0 Error(s), 0 Warning(s).
'@ | Set-Content -LiteralPath $log6 -Encoding Default
$r6 = Get-KeilBuildLogDiagnostics -Path $log6
$sz = $r6.programSize
Check 'log.programSize' ($sz -and $sz['Code'] -eq 256 -and $sz['ZI-data'] -eq 1028) `
    ("size=" + $(if ($sz) { ($sz.Keys | ForEach-Object { $_ + '=' + $sz[$_] }) -join ' ' } else { 'null' }))

# =====================================================================
Section '7. 超时预算（离线）'
# =====================================================================
# 任务书要求「编译超时、测试超时都要能安全停下」，所以超时闸本身必须被测到。

$dl = New-KeilDeadline -Seconds 10
Check 'budget.freshDeadline' ((Get-KeilRemainingSeconds -Deadline $dl) -ge 8) `
    ("remaining=" + (Get-KeilRemainingSeconds -Deadline $dl))

# Want 超过剩余量时，取剩余量（不能返回一个比实际时间还长的值）
Check 'budget.cappedByRemaining' ((Get-KeilBudget -Deadline $dl -Want 300) -le 10) `
    ("budget=" + (Get-KeilBudget -Deadline $dl -Want 300))

# Want 小于剩余量时，原样返回 Want
Check 'budget.honoursWant' ((Get-KeilBudget -Deadline $dl -Want 3) -eq 3) `
    ("budget=" + (Get-KeilBudget -Deadline $dl -Want 3))

# 已过期的 deadline：必须抛错，不能返回 0/负数让调用方继续跑
$expired = (Get-Date).AddSeconds(-5)
$threw = $false
try { $null = Get-KeilBudget -Deadline $expired -Want 30 -Minimum 3 } catch { $threw = $true }
Check 'budget.expiredThrows' $threw ("threw=" + $threw)

# 剩余量不够 Minimum：也要抛错（否则会把非法值传给有下限校验的参数）
$threw = $false
try { $null = Get-KeilBudget -Deadline $dl -Want 30 -Minimum 600 } catch { $threw = $true }
Check 'budget.belowMinimumThrows' $threw ("threw=" + $threw)

# Assert 在过期时必须抛错，正常时返回剩余秒数
$threw = $false
try { $null = Assert-KeilBudget -Deadline $expired -Stage '等断点命中' } catch { $threw = $true }
Check 'budget.assertExpiredThrows' $threw ("threw=" + $threw)
Check 'budget.assertReturnsRemaining' ((Assert-KeilBudget -Deadline $dl -Stage 'x') -ge 8) 'returns remaining seconds'

# 非法预算必须在建立时就拒绝
$threw = $false
try { $null = New-KeilDeadline -Seconds 0 } catch { $threw = $true }
Check 'budget.rejectsZero' $threw ("threw=" + $threw)

# 自检脚本必须真的使用这道闸（防止以后有人把参数又改成没人用）
$rtTxt = Get-Content -LiteralPath (Join-Path $scriptRoot 'run-test.ps1') -Raw
Check 'budget.runTestUsesGate' ($rtTxt -match 'Get-KeilBudget') 'run-test.ps1 calls Get-KeilBudget'
Check 'budget.runTestNoRawDeadline' ($rtTxt -notmatch 'AddSeconds\(\s*30\s*\)') 'no hard-coded 30s deadline left'

# =====================================================================
Section '8. 修复会话：账本与安全闸（离线，不启动 Keil）'
# =====================================================================
# 这一段只测「判定逻辑」，不跑真实编译 —— 真实编译链路由 run-test.ps1 覆盖。

$repairScript = Join-Path $scriptRoot 'Repair-Session.ps1'
if (Test-Path -LiteralPath $repairScript) {
    $rsTxt = Get-Content -LiteralPath $repairScript -Raw

    # 7.1 默认修复次数必须是 3（任务书 10.1）
    # 注意：单引号字符串里反引号不是转义符，要匹配字面量 $ 得直接写 \$
    $maxDefault = $null
    if ($rsTxt -match '\[int\]\$MaxAttempts\s*=\s*(\d+)') { $maxDefault = [int]$Matches[1] }
    Check 'repair.defaultMaxAttempts3' ($maxDefault -eq 3) ("default MaxAttempts=" + $maxDefault)

    # 7.2 上限必须被 ValidateRange 限制，不能无限重试
    Check 'repair.maxAttemptsBounded' ($rsTxt -match 'ValidateRange\(1,\s*\d+\)') 'ValidateRange present'

    # 7.3 六种停止条件都要在代码里出现
    foreach ($cond in @('max-attempts', '错误数从', '空转', '范围外', '连续三次', '编译成功')) {
        Check ('repair.stopCondition.' + ($cond -replace '[^\w]', '')) ($rsTxt -match [regex]::Escape($cond)) ("contains: " + $cond)
    }

    # 7.4 回滚前必须另存当前状态（回滚本身可撤销）
    Check 'repair.rollbackIsUndoable' ($rsTxt -match 'pre-rollback') 'pre-rollback backup present'

    # 7.5 会话账本要能跨进程读回（用真实建一次会话验证）
    $fixProj = Join-Path $work '中文 目录 带空格\demo 工程.uvprojx'   # 第 2 节已建
    if (Test-Path -LiteralPath $fixProj) {
        $rsRoot = Join-Path $work 'rs-test'
        $startRaw = & $repairScript -Action start -Project $fixProj -Scope '*.c' -SessionRoot $rsRoot -MaxAttempts 2 -DryRun 2>&1 | Out-String
        $startOk = ($startRaw -match '"dryRun":\s*true')
        Check 'repair.startDryRun' $startOk 'dry-run start produced JSON'
    }
    else {
        Check 'repair.startDryRun' $false 'fixture project missing'
    }

    # 7.6 会话不存在时必须报错，不能静默返回空
    $threw = $false
    $msg = ''
    try { & $repairScript -Action status -SessionId 'rs_does_not_exist' -SessionRoot (Join-Path $work 'rs-none') 2>&1 | Out-Null }
    catch { $threw = $true; $msg = $_.Exception.Message }
    Check 'repair.unknownSessionFails' $threw ("threw=" + $threw + " msg=" + $msg.Substring(0, [Math]::Min(40, $msg.Length)))
}
else {
    Check 'repair.scriptFound' $false ("未找到 Repair-Session.ps1: " + $repairScript)
}

# =====================================================================
# 汇总
# =====================================================================
$failed = @($results | Where-Object { -not $_.passed })
$passed = ($failed.Count -eq 0)
$summary = [ordered]@{
    skill      = 'keil5-automatic-wwj'
    suite      = 'unit'
    passed     = $passed
    testCount  = $results.Count
    failedCount = $failed.Count
    workDir    = $work
    tests      = $results
}
$summaryPath = Join-Path $work 'unit-result.json'
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $summaryPath -Encoding utf8

Write-Output ''
Write-Output ("UNIT RESULT: {0}  ({1}/{2} tests passed)" -f $(if ($passed) { 'PASS' } else { 'FAIL' }), ($results.Count - $failed.Count), $results.Count)
Write-Output ("result.json: " + $summaryPath)
if (-not $passed) { exit 1 }
