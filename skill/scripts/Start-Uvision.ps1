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
# 本脚本同时承担另一件事：把结果目录、日志、PID 记录下来，供后续脚本和
# 调试层客户端读取。uVision 启动成功不等于测试通过，必须再跑客户端命令。

$ErrorActionPreference = 'Stop'

# ---- 定位 UV4.exe ----
if (-not $Uv4) {
    $candidates = @(
        'F:\Keil5\UV4\UV4.exe',
        'C:\Keil_v5\UV4\UV4.exe',
        'D:\Keil_v5\UV4\UV4.exe'
    )
    $found = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $found) {
        $cmd = Get-Command UV4.exe -ErrorAction SilentlyContinue
        if ($cmd) { $found = $cmd.Source }
    }
    if (-not $found) {
        throw 'UV4.exe not found. Pass -Uv4 with the full path, e.g. -Uv4 "F:\Keil5\UV4\UV4.exe".'
    }
    $Uv4 = $found
}
$Uv4 = (Resolve-Path -LiteralPath $Uv4).Path

# ---- 处理已有实例 ----
$existing = Get-Process -Name UV4 -ErrorAction SilentlyContinue
if ($existing -and -not $Reuse) {
    throw ("uVision is already running (PID {0}). Close it first, or pass -Reuse to attach to the running instance's port." -f ($existing.Id -join ', '))
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

# ---- 检查端口占用 ----
$inUse = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($inUse) {
    throw "TCP port $Port is already listening (PID $($inUse.OwningProcess -join ', ')). Pick another -Port."
}

# ---- 启动 ----
if ($NoProject) {
    $argumentLine = "-s $Port"
} else {
    $argumentLine = "`"$Project`" -s $Port"
}
$proc = Start-Process -FilePath $Uv4 -ArgumentList $argumentLine -PassThru
Write-Verbose ("UV4 launched. PID={0} port={1}" -f $proc.Id, $Port)

# ---- 等待端口开始监听 ----
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$listening = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $proc.Refresh()
    if ($proc.HasExited) {
        throw ("uVision exited during startup with code {0}. Launch it from an interactive PowerShell/cmd session and check whether a modal dialog appeared." -f $proc.ExitCode)
    }
    if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
        $listening = $true
        break
    }
}
if (-not $listening) {
    throw "UVSOCK port $Port did not start listening within $WaitSeconds seconds (uVision PID $($proc.Id) is still running)."
}

# 端口就绪后 uVision 还需要一点时间完成工程加载。
Start-Sleep -Seconds 2

$info = [ordered]@{
    skill           = 'keil5-automatic-wwj'
    uv4             = $Uv4
    project         = $(if ($NoProject) { $null } else { $Project })
    port            = $Port
    pid             = $proc.Id
    listening       = $true
    started_at      = (Get-Date).ToString('s')
    note            = 'uVision is up and the UVSOCK port is listening. This is NOT a passed test: run UvSockClient.exe commands to verify.'
}
$info | ConvertTo-Json
