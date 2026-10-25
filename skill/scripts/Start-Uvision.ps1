[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,
    [int]$Port = 41800,
    [string]$Uv4,
    [ValidateRange(3, 120)]
    [int]$WaitSeconds = 30,
    [switch]$NoProject,
    [switch]$Reuse
)

# 启动 Keil uVision 并打开 UVSOCK 端口。
#
# 为什么必须用这个脚本启动，而不是用 C# 的 Process.Start：
#   uVision 5.35 由 C# 进程 Process.Start 启动时会在约 2 秒内以 0xC0000005
#   （访问冲突，错误模块 UV4.exe）自行崩溃；由 PowerShell 或 cmd 启动则正常。
#   因此 UvSockClient.exe 只负责“接入”，启动一律走本脚本。
#
# 进程安全：
#   本脚本启动前会记录「启动之前就已经存在的 UV4 进程」，启动后只认自己新起的
#   那个 PID。所有进程操作都通过 KeilCommon.ps1 的 Stop-OwnedUvision 完成，
#   绝不按进程名批量结束 UV4。
#
# uVision 启动成功不等于测试通过，必须再跑客户端命令验证。

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'KeilCommon.ps1')

# ---- 定位 UV4.exe（统一走 KeilCommon 的解析链）----
$resolved = Resolve-KeilUv4 -Uv4 $Uv4
$Uv4 = $resolved.path

# ---- 记录启动前已有的 uVision 实例（只记录，绝不结束）----
# 用户可能同时开着别的工程，所以这里既不阻止也不清理，只如实记录并写进输出，
# 供调用方（run-test.ps1）在测试结束后核对「原有实例是否仍然存活」。
$preExisting = @(Get-UvisionProcesses)
$preExistingPids = @($preExisting | ForEach-Object { $_.pid })
if ($preExisting.Count -gt 0) {
    Write-Verbose ("检测到启动前已有 {0} 个 uVision 实例（PID {1}）；本脚本不会结束它们。" -f $preExisting.Count, ($preExistingPids -join ', '))
}

if ($Project) {
    if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
        throw "Project file not found: $Project"
    }
    $Project = (Resolve-Path -LiteralPath $Project).Path
    if ([IO.Path]::GetExtension($Project) -notin @('.uvprojx', '.uvproj')) {
        throw 'Project must be a .uvprojx (or legacy .uvproj) file.'
    }
}

# ---- 检查端口占用；被占用时自动向后找一个空闲端口 ----
# 用户可能已经用 -s 41800 之类的方式开着别的 uVision，此时不能抢端口，
# 也不能报错退出——自动换一个空闲端口即可，并在输出里说明换了。
$requestedPort = $Port
$portTries = 0
while ($portTries -lt 50) {
    $inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if (-not $inUse) { break }
    $Port++
    $portTries++
}
if ($portTries -ge 50) {
    throw "从 $requestedPort 起连续 50 个端口都被占用，无法为 uVision 找到可用的 UVSOCK 端口。"
}
$portChanged = ($Port -ne $requestedPort)

# ---- 启动 ----
if ($NoProject) {
    $argumentLine = "-s $Port"
}
else {
    $argumentLine = "`"$Project`" -s $Port"
}
$proc = Start-Process -FilePath $Uv4 -ArgumentList $argumentLine -PassThru
$ownedPid = $proc.Id
$ownedStart = $null
try { $ownedStart = $proc.StartTime } catch { }
Write-Verbose ("UV4 launched. PID={0} port={1}" -f $ownedPid, $Port)

# ---- 立刻登记自己启动的进程 ----
# 必须放在「等端口」之前：等待期间调用方就可能被强杀，那时 finally 不会执行。
# 登记表让下一次运行能认出「这是本项目起的」，从而安全收尾。
# 登记失败不影响启动流程，只记进 $registryError 由调用方判断。
#
# owner_pid 记的是 $PID（当前 PowerShell 进程）。Stop-OwnedUvision 会用
# Get-ProcessParentId 核对 uVision 的父进程是否正是这个 owner_pid——对不上就
# 拒绝结束。这样即使外部脚本猜到 PID 和启动时间，也关不掉我们的 uVision，
# 我们也不会误关别人启动的 uVision。
$ownerPid = $PID
$registryPath = $null
$registryError = $null
try {
    $registryPath = Register-OwnedUvision -ProcessId $ownedPid -OwnerPid $ownerPid -StartedAt $ownedStart -Port $Port -Project $(if ($NoProject) { $null } else { $Project })
}
catch {
    $registryError = $_.Exception.Message
}

# ---- 等待端口开始监听 ----
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$listening = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) {
        # 自己起的进程已经死了，登记表里这条要撤掉，免得以后误判成残留
        Remove-KeilOwnedRegistryEntry -ProcessId $ownedPid
        throw ("uVision exited during startup with code {0}. Launch it from an interactive PowerShell/cmd session and check whether a modal dialog appeared." -f $proc.ExitCode)
    }
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        $listening = $true
        break
    }
}
if (-not $listening) {
    # 启动失败时只清理自己刚起的那个进程。
    $cleanup = Stop-OwnedUvision -ProcessId $ownedPid -OwnerPid $ownerPid -StartedAt $ownedStart -Port $Port -ClientExe (Join-Path $PSScriptRoot 'UvSockClient.exe')
    if (-not (Get-Process -Id $ownedPid -ErrorAction SilentlyContinue)) {
        Remove-KeilOwnedRegistryEntry -ProcessId $ownedPid
    }
    throw "UVSOCK port $Port did not start listening within $WaitSeconds seconds (uVision PID $ownedPid). 清理结果: $($cleanup.message)"
}

# 端口就绪后 uVision 还需要一点时间完成工程加载。
Start-Sleep -Seconds 2

$info = [ordered]@{
    skill            = 'keil5-automatic-wwj'
    uv4              = $Uv4
    uv4_source       = $resolved.source
    project          = $(if ($NoProject) { $null } else { $Project })
    port             = $Port
    port_requested   = $requestedPort
    port_changed     = $portChanged
    pid              = $ownedPid
    owner_pid        = $ownerPid
    started_at       = $(if ($ownedStart) { $ownedStart.ToString('s') } else { (Get-Date).ToString('s') })
    listening        = $true
    preexisting_pids = $preExistingPids
    reused           = [bool]$Reuse
    registry         = $registryPath
    registry_error   = $registryError
    note             = 'uVision is up and the UVSOCK port is listening. This is NOT a passed test: run UvSockClient.exe commands to verify.'
}
# 单行 JSON，方便调用方按行解析（详见 Build-Project.ps1 的同名说明）。
$info | ConvertTo-Json -Compress
