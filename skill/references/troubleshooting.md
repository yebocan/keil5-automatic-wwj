# 排错指南

按症状查。每条都写明「现象 → 原因 → 怎么办」。

## 编译层

### 编译报错但看不出是哪个文件

看 [Build-Project.ps1](Build-Project.ps1) 返回的 `diagnostics` 数组，每条都带 `file` / `line` / `kind` / `message`：

```json
{"file":"main.c","line":24,"kind":"error","message":"#5: cannot open source input file \"stm32_eval.h\": No such file or directory"}
```

`errorCount` 才是判断依据，**进程正常退出不代表编译通过**。

### 退出码 2，日志里是 `cannot open source input file`

工程缺头文件，或头文件的包含路径没配。这属于用户工程本身的问题，不是环境问题。在 uVision 里 Options for Target → C/C++ → Include Paths 里补路径。

### 退出码 11 / 13

`11` = 无法写工程文件，`13` = 写工程文件失败。通常是工程文件只读、被 uVision 占用（先关掉 uVision），或所在目录无写权限。

### 退出码 12

设备未找到。工程指定的器件在当前 Keil 安装里没有对应的 pack，需要装对应的 Device Family Pack。

### 中文路径 / 空格路径会不会有问题

不会。实测中文路径（`F:\杂物\电气B234袁浩2328052013\USER\yuan.uvprojx`）与含空格路径都能正常编译，不需要复制到纯英文目录。

### 日志文件是空的

用 `Start-Process` 时如果 `-ArgumentList` 传的是数组（`@('-b', $proj, '-o', $log)`），UV4 不会写日志。**必须传单个字符串**（含引号）：

```powershell
Start-Process -FilePath $uv4 -ArgumentList "-b `"$proj`" -o `"$log`"" -PassThru -Wait
```

`Build-Project.ps1` 已经处理好了。

## 调试层

### uVision 一启动就没了 / 端口连不上

**先查是不是被 C# 程序启动的。** uVision 5.35 由 C# `Process.Start` 启动会在约 2 秒内以 `0xC0000005`（访问冲突，错误模块是 UV4.exe 自身）崩溃；由 PowerShell 或 cmd 启动完全正常。这是 Keil 自身的缺陷。

诊断：Windows 事件查看器 → Windows 日志 → 应用程序，找来源 `.NET Runtime` 或 `Application Error`、事件 ID 1000 的记录，`错误模块名称: UV4.exe`、`异常代码: 0xc0000005` 即可确认。

**一律用 [Start-Uvision.ps1](Start-Uvision.ps1) 启动**，它内部走 `Start-Process`。

### 端口连不上（`Start-Uvision.ps1` 报超时）

- 检查 `-s` 后面的端口有没有被别的进程占用：`Get-NetTCPConnection -LocalPort <端口>`。
- 检查是不是已经有 uVision 在跑：`Get-Process UV4`。多个实例会抢端口。
- 换一个端口重试（`-Port 41960`）。
- uVision 加载大工程可能超过 30 秒，加大 `-WaitSeconds`。

### `dbg-enter` 返回 SUCCESS，但接着所有调试命令报 `6 NOT_DEBUGGING`

**这是最常遇到的坑。** `dbg-enter` 返回 SUCCESS 只表示请求被接受了，不代表调试会话真的建立。

按顺序排查：

1. **有没有可加载的程序映像。** 调试会话必须有 `.axf`。工程没编译过（或 `Objects` 目录被清掉）时，uVision 进调试后会立刻掉出来，表现为 `dbg-status` 短暂 `true` 然后所有命令报 `6`。先编译一次。`run-test.ps1` 的 `-Test debug` 已自动补编译。
2. **调试器驱动对不对。** 先 `debugtarget` 看返回。如果是 `{"target":0,"debugTarget":"hardware"}` 而机器上没接探针，进调试会失败。执行 `set-debugtarget simulator` 切到软件仿真。
3. **进调试后要等。** `dbg-enter` 之后轮询 `dbg-status` 到 `debugging:true`，通常 1-3 秒。不要紧接着就发 `reset`。判断"真的就绪"的可靠标准是 `eval main` 能返回非零地址（符号表已加载）。
4. **看 uVision 窗口的 Build Output。** 里面如果有 `Error: Flash Download failed - Target DLL has been cancelled`，说明工程配的是硬件调试器（如 ULINK2）而探针没接。窗口右下角状态栏会显示当前驱动名（如 `ULINK2/ME Cortex Debugger`）。
5. **看 Options for Target → Debug。** 确认选的是 `Use Simulator` 还是右侧的探针。选 `Use Simulator` 后保存，工程目录下会生成 `.uvoptx`，之后 UVSOCK 切 `simulator` 也能生效。

### 程序卡在 `SystemInit` / `main` 之前的地址不前进

**软件仿真不模拟时钟树。** Keil 的 `SARMCM3.DLL` 不模拟 HSE 晶振与 PLL，官方 `system_stm32f10x.c` 里这个循环永远不退出：

```c
do {
  RCC->CR |= ((uint32_t)RCC_CR_HSEON);
  HSEStatus = RCC->CR & RCC_CR_HSERDY;
  StartUpCounter++;
} while((HSEStatus == 0) && (StartUpCounter != HSE_STARTUP_TIMEOUT));
```

现象：`run` 之后 PC 停在 `0x080002xx`（`SystemInit` 范围内）不动，设在 `main` 或业务函数上的断点命中不到，`dbg-status` 的 `nVal` 恒为 0。

三种解法：

1. **用夹具工程**：`assets/test-project` 里的 `system_stm32f10x.c` 已改成跳过时钟配置的版本，可以直接跑。
2. **`run-to <main地址>`** 直接跳过初始化。地址从 `.map` 文件的 `Image Entry point` / `main` 段查。
3. **用真实硬件调试**：接上探针，`set-debugtarget hardware`。

### 断点命中了但变量是初始值

断点停在 `main` 入口时，全局变量的初始化还没执行完（`__main` 里的 scatterload 段拷贝尚未完成）。要看初始化后的值，断点设在 `main` 之后几行，或先 `step` 几次。

### `eval` 返回空 / `TARGET_NOT_STOPPED`

目标正在运行时不能求值。先 `stop`，或等断点命中（`dbg-status` 的 `running` 变回 `false`）再读。

客户端会把这种情况转成明确的错误，**不要把它当数字 0 用**：

```json
{"ok":false,"error":"TARGET_NOT_STOPPED"}
```

### `line2adr` 返回 `32 NO_ADRMAP`

两个原因：

1. **路径不是绝对路径。** 必须传完整路径（`D:\proj\main.c`），`main.c` 或 `.\main.c` 都会失败。
2. **调试会话没建立。** 先确认 `dbg-status` 是 `debugging:true`。

### `adr2line` 返回 `32 NO_ADRMAP`

本机 Keil 5.35 上这个命令**始终不可用**，不是配置问题。要地址反查源码行，读 `Listings\<工程名>.map` 或 `.lst` 文件。

### `watch` 返回 `28 NOT_SUPPORTED`

本机 Keil 5.35 上不支持。**用 `eval` 代替**。

### `targets` / `groups` / `files` 返回空数组或 `10 DEBUGGING`

- 返回空数组：这些命令走「同步响应 + 异步流」，必须一直读到 `END` 消息。客户端已经处理；若自己写客户端要注意。
- 返回 `10 DEBUGGING`：调试模式下工程类枚举不可用。先 `dbg-exit`。

### 命令全部超时、uVision 界面卡死（`Responding=False`）

进调试失败（如探针未连接）后，uVision 主线程可能卡住。`Get-Process UV4 | Select Responding` 会显示 `False`。

处置：`Stop-Process -Name UV4 -Force`，然后用 `Start-Uvision.ps1` 重启。**不要反复发命令**，只会让它卡得更死。

### `dbg-exit` 返回 `11 TARGET_EXECUTING`

目标正在运行，先 `stop` 再 `dbg-exit`。

### 调试模式下 `build` 返回 `10 DEBUGGING`

调试会话进行中不能构建。先 `dbg-exit`，或用 [Build-Project.ps1](Build-Project.ps1)（它走 UV4 命令行，与调试会话独立）。

## 环境

### 没有 Python 能不能用

能。本 skill 零 Python 依赖：编译层是 PowerShell 调 `UV4.exe`，调试层是 C# 编译出的单个 exe。C# 编译器用系统自带的 `csc.exe`（`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`），不需要装 .NET SDK。

### `UvSockClient.exe` 找不到了

用 `csc.exe` 重新编译：

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize /out:"UvSockClient.exe" "UvSockClient.cs"
```

源码在 [UvSockClient.cs](UvSockClient.cs)。不需要任何 NuGet 包或额外引用。

### 提示找不到 `UV4.exe`

用 `-Uv4` 参数显式指定，或用 `KEIL_UV4` 环境变量：

```powershell
$env:KEIL_UV4 = "D:\Keil\UV4\UV4.exe"
```

脚本的查找顺序是：`-Uv4` 参数 → `KEIL_UV4` 环境变量 → 注册表 → 常见安装路径。

### 换了台机器要改什么

- `-Uv4` 指向目标机器的 `UV4.exe`（不同机器安装位置不同，本机是 `F:\Keil5\UV4\UV4.exe`）。
- 不同 uVision 版本 UVSOCK 版本号可能不同（本机 229 / V2.29），协议报文格式一致。
- 若目标机器没有 .NET Framework 4.x，需要先装（Windows 10/11 自带）。

## 端口占用速查

```powershell
Get-NetTCPConnection -LocalPort 41950 -ErrorAction SilentlyContinue
Get-Process UV4 -ErrorAction SilentlyContinue | Select-Object Id, Responding, MainWindowTitle
Stop-Process -Name UV4 -Force      # 清理全部 uVision 实例
```
