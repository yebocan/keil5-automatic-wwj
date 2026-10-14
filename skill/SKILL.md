---
name: keil5-automatic-wwj
description: 用本机 Keil MDK(uVision) 编译 STM32/ARM 工程、做源码级调试、在限定范围内改代码并有限次自动修复编译错误：后台编译并结构化解析错误、UVSOCK 远程控制仿真或硬件调试（断点/单步/读变量/寄存器/内存）、Intel HEX 独立校验。零 Python 依赖，附集成自检与多平台安装指令。
---

# Keil5 Automatic WWJ

把用户的嵌入式需求变成「真实编译 + 真实调试」的可验证结果：用 Keil 官方命令行编译，用 Keil 官方 UVSOCK 接口远程控制调试器，读回实际寄存器与内存作为证据。本 skill 指导流程与判断标准，执行由本目录内的脚本完成。

**零依赖**：不需要 Python，不需要 pip，不需要额外安装任何东西。客户端是 C# 源码，用系统自带的 .NET Framework 编译器（`csc.exe`）编译一次即可。

## 按用户请求选择入口

- **"编译一下 / 看看能不能过 / 检查工程"**：走编译层，用 [scripts/Build-Project.ps1](scripts/Build-Project.ps1)。不需要打开 uVision，不需要硬件。
- **"调试 / 单步 / 看变量 / 为什么卡住 / 跑不起来"**：走调试层，先 [scripts/Start-Uvision.ps1](scripts/Start-Uvision.ps1) 起 uVision，再用 [scripts/UvSockClient.exe](scripts/UvSockClient.exe) 下命令。没接硬件时用软件仿真。
- **"改一下代码 / 帮我修编译错误 / 自动改"**：走修改与修复层，用 [scripts/Repair-Session.ps1](scripts/Repair-Session.ps1)。它只负责「范围控制 + 备份 + 登记尝试」，改代码由你（AI）用编辑工具完成，**不要让它替你放开修改范围**。
- **"装在哪 / 怎么装到豆包 / 换个机器怎么用"**：读 [references/install.md](references/install.md)，按里面的实际路径装。**默认只装 DSH**。
- **"改一下 HEX / 看看生成的 HEX 对不对"**：Hex 相关结论见下方 HEX 独立验证一节。
- **"跑一下例子 / 测试 skill / 演示"**：用 [scripts/run-test.ps1](scripts/run-test.ps1) 跑两套自检例程，见下方表格。
- **"烧录到板子"**：需要真实调试探针（ULINK/ST-Link/J-Link）已连接，用 `flash` 命令。**探针未连接时不要尝试，先问用户。**

### 找不到 `UV4.exe` 怎么办

所有脚本共用同一套路径解析链（[scripts/KeilCommon.ps1](scripts/KeilCommon.ps1) 的 `Resolve-KeilUv4`）。优先级：`-Uv4` 参数 → `KEIL5_UV4` 环境变量 → 配置文件 → 常见安装位置（F:\Keil5、C:\Keil_v5、D:\Keil_v5、E:\Keil_v5、C:\Keil、D:\Keil、E:\Keil）→ PATH。**不读注册表、不扫全盘。**

推荐一次写配置，以后所有脚本都不用再传 `-Uv4`：

```powershell
& "<skill>\scripts\Set-KeilPath.ps1" -Uv4 "F:\Keil5\UV4\UV4.exe"
& "<skill>\scripts\Set-KeilPath.ps1" -Show
```

## 编译层

```powershell
& "<skill>\scripts\Build-Project.ps1" -Project "D:\path\to\your.uvprojx" -Action build
```

参数：`-Project`（必填）、`-Action`（`build`/`rebuild`/`clean`/`flash`，默认 `build`）、`-Target`（多 Target 工程必填）、`-Uv4`、`-LogFile`、`-TimeoutSeconds`（10-3600，默认 600）、`-SkipHexCheck`。

输出 JSON，关键字段分三组，**不要只看第一个**：

| 组 | 字段 | 说明 |
|---|---|---|
| 结论 | `success` / `buildStatus` / `determinate` / `reasons` | `buildStatus` ∈ `success`/`failed`/`indeterminate`；`determinate:false` 表示证据不足，**不能当成功用** |
| 编译证据 | `exitCode` / `exitName` / `timedOut` / `errorCount` / `warningCount` / `errorCountFromLog` / `fatalSeen` / `targetNotCreated` / `summaryLine` / `programSize` / `diagnostics` | `errorCountFromLog:false` 表示日志里没有结果行，此时 `errorCount` 是 `null`（不是 0） |
| 产物证据 | `axfPath` / `axfState` / `hexPath` / `hexState` / `hexStatus` / `hexFormatStatus` / `hexCheck` | `axfState` ∈ `created`/`changed`/`touched`/`unchanged`/`missing`；

`diagnostics` 每项 `{index,file,line,kind,code,message,raw}`；`kind` ∈ `error`/`warning`/`fatal error`，`code` 是 Keil 错误码（`#5`、`#177-D`），`raw` 是原始行。

判定规则（七个证据，任一缺证据就 `indeterminate` 而不是成功）：

1. 超时 → `failed`
2. 没有退出码 / 没有日志 / 日志里没有 `N Error(s), M Warning(s)` 结果行 → **`indeterminate`（不默认成功）**
3. `errorCount > 0` → `failed`
4. 退出码不在 `{0,1}` → `failed`
5. `build`/`rebuild` 但 `.axf` 状态是 `missing` 或 `unchanged` → `failed`（**防止拿上次的旧产物冒充新产物**）
6. 以上都不触发 → `success`，`reasons` 会写明依据

UV4 退出码：`0`=无错无警、`1`=仅警告、`2`=有错误、`3`=致命错误、`11`=无法写工程、`12`=设备未找到、`13`=写工程失败、`15`=导入 XML 失败、`20`=转换工程失败。**进程正常退出不等于编译通过。**

中文路径、空格路径都能用，不需要把工程复制到纯英文目录。

### 工程识别

`Get-KeilProjectInfo -Project <路径>`（在 KeilCommon.ps1 里）只读解析 `.uvprojx`/`.uvproj`，返回 `targets[]`（每个含 `name`/`device`/`outDir`/`outName`/`createHex`）、`sources[]`（每个含 `name`/`relative`/`fullPath`/`type`/`exists`）、`includes`、`outputDir`、`axfPath`、`hexPath`、`parseOk`。**源文件绝对路径用 `.fullPath`。** 多 Target 工程不用 `-Target` 指定就返回 `targetAmbiguous:true` 并拒绝编译，不替你猜。

### HEX 独立验证

编译层会独立校验 HEX，**不复用编译结论**。这四件事含义不同，别混着说：

1. **编译成功** —— `buildStatus=success`
2. **HEX 生成成功** —— `hexStatus=generated`
3. **HEX 格式验证成功** —— `hexFormatStatus=valid`
4. **程序功能正确** —— 本 skill **不验证**

`hexStatus` ∈ `generated`（本次新生成）/ `stale-from-previous-build`（**文件在但不是本次产物，上次成功的残留**）/ `not-generated` / `disabled-in-project` / `unknown`。判定依据是产物 SHA256 前后对比，**不靠修改时间**。已实测防住误判：先编译成功留下 HEX，再制造失败，结果 `buildStatus=failed`、`hexState=unchanged`、`hexStatus=stale-from-previous-build`、`success=false`。

单独校验任意 HEX：

```powershell
. "<skill>\scripts\KeilCommon.ps1"
Test-IntelHexFile -Path "D:\proj\Objects\app.hex" | Format-List
```

校验项：行首冒号、字节数声明与实际匹配、逐行校验和、EOF 记录、记录类型 00/01/02/03/04/05（类型 04 按 `高16位 << 16`，类型 02 按 `×16`）、0 字节判无效。返回 `{valid,records,dataRecords,dataBytes,eofSeen,checksumErrors,malformedLines,addressRange}`。

### 日志

日志默认写 `%TEMP%\keil5-automatic-wwj\uv4_<action>_<时间戳>.log`，**不写进技能安装目录**。用 `-LogFile` 指定别处。`Get-KeilBuildLogDiagnostics -Path <日志>`（KeilCommon.ps1）可单独解析：取不到结果行时 `errorCount` 是 `$null` 而非 0。

## 修改与自动修复层

**分工要说清楚**：`Repair-Session.ps1` 不替你改代码。它负责范围控制、备份、登记尝试、判断该不该继续；**改代码由你（AI）用编辑工具完成**。

```powershell
$r = "<skill>\scripts\Repair-Session.ps1"
& $r -Action start   -Project "D:\proj\app.uvprojx" -Scope 'USER\*.c','HARDWARE\*.h'
# → AI 用编辑工具改代码 →
& $r -Action attempt -SessionId rs_xxx -Reason '补上缺失的头文件'
& $r -Action status  -SessionId rs_xxx
& $r -Action diff    -SessionId rs_xxx
& $r -Action rollback -SessionId rs_xxx      # 需要时
& $r -Action finish   -SessionId rs_xxx
```

参数：`-Action`（`start`/`attempt`/`status`/`diff`/`rollback`/`finish`/`list`）、`-Project`、`-SessionId`、`-Scope`（相对工程目录的通配符，不传默认取工程登记的全部源文件）、`-MaxAttempts`（1-20，**默认 3**）、`-Reason`、`-KeepCurrentOnRollback`（默认 `true`）、`-Uv4`、`-TimeoutSeconds`、`-DryRun`。

会话目录 `%TEMP%\keil5-repair-sessions\<会话号>\` 含 `session.json`（账本：范围、每个文件原始 SHA256/大小、每次尝试记录、结论）与 `baseline\`（基线快照，回滚从这还原）。

**五个必须停止的条件**（`attempt` 自动判定并写进 `conclusion`）：

1. 达到最大修复次数（默认 3）
2. 错误数比上一次增加
3. 本次没有任何文件被改动（空转，继续重试没意义）
4. **改了范围外的文件**（超出授权）
5. 连续两次错误数完全不变（没有进展）

**禁止用销毁行为伪造成功**：不得通过关闭检查、删除关键代码、屏蔽警告、改编译选项来让编译变绿。

**回滚可撤销**：`rollback` 默认先把当前改动也备份一份（`-KeepCurrentOnRollback $true`），所以回滚本身也能再回滚。

## 调试层

两步，顺序不能颠倒：

```powershell
# 1. 启动 uVision（必须用 PowerShell/cmd 启动，见下方"已知缺陷"）
& "<skill>\scripts\Start-Uvision.ps1" -Project "D:\path\to\your.uvprojx" -Port 41950

# 2. 接入并发命令
& "<skill>\scripts\UvSockClient.exe" 41950 <命令> [参数...]
```

客户端每条命令输出一行 JSON：`{"ok":true,"command":"...","result":{...},"messages":[...]}`。失败时 `ok:false` 并带 `error`，退出码 1。

### 无硬件时的软件仿真

```
set-debugtarget simulator   # 切到软件仿真（SARMCM3.DLL）
dbg-enter                   # 进入调试（异步，返回 SUCCESS 不代表已就绪）
```

`dbg-enter` 之后**必须轮询** `dbg-status` 直到 `debugging:true`，通常需要 1-3 秒。直接接着发 `reset`/`run` 会失败或行为错乱。

### 调试命令一览

| 类别 | 命令 |
|---|---|
| 会话 | `dbg-enter` `dbg-exit` `dbg-status` `set-debugtarget <simulator\|hardware>` `debugtarget` |
| 执行 | `reset` `run` `stop` `run-to <地址>` `step` `step-n <N>` `step-into` `step-into-n <N>` `step-asm` `step-asm-n <N>` `step-out` |
| 断点 | `bp-create <表达式> [类型] [计数]` `bp-enum` `bp-del <索引>` |
| 求值 | `eval <表达式>` `eval-str <表达式>` `watch <表达式>` `watch-del <索引>` |
| 数据 | `mem-read <地址> <字节数>` `mem-write <地址> <十六进制>` `regs` `reg-set <名> <值>` `reg-groups` `dsm <地址> <长度>` |
| 符号 | `line2adr <绝对路径> <行号>` `adr2line <地址>` `stack` `vars` `tasks` |
| 工程 | `targets` `curtarget` `settarget <名>` `groups` `files <组名>` `activefiles` `outputname` |
| 构建 | `build` `rebuild` `clean` `cancel` `flash` `flash-erase` |
| 其他 | `info` `license` `time` `serial-get` `serial-put` `exec <uVision命令>` `menus` `ui-lock` `ui-unlock` `show` `hide` `exit` `load <工程>` `close` |

### 调试层的时序规则（踩过的坑，务必遵守）

1. **`dbg-enter` 是异步的**：返回 `SUCCESS` 只表示请求被接受。要轮询 `dbg-status` 到 `debugging:true` 才算就绪。
2. **`reset` 之后要等约 2 秒**再 `run`，否则仿真器还没复位完，断点会被跳过。
3. **`run` 之后不要固定 sleep 就断言**：轮询 `dbg-status`，等 `running` 变回 `false`（断点命中）或超时。
4. **目标运行中不能求值**：`eval` 会返回 `vType=0` 的空结果。客户端已把这种情况转成明确的 `TARGET_NOT_STOPPED` 错误，不要把它当数字用。**断点地址要在 `run` 之前读。**
5. **`dbg-exit` 前先 `stop`**：目标运行中退出返回 `11 TARGET_EXECUTING`。
6. **`line2adr` 必须传绝对路径**：`main.c` 或 `.\main.c` 会返回 `32 NO_ADRMAP`。
7. `adr2line`（地址反查源码行）在本机 Keil 5.35 上始终返回 `NO_ADRMAP`，**该命令不可用**，不要依赖它。
8. `watch` 返回 `28 NOT_SUPPORTED`，用 `eval` 代替。

## 已知缺陷与硬性约束

**uVision 5.35 由 C# 进程启动会自崩。** 用 C# `Process.Start` 启动 `UV4.exe`，它会在约 2 秒内以 `0xC0000005`（访问冲突，错误模块 UV4.exe 自身）退出；由 PowerShell 或 cmd 启动则完全正常。这是 Keil 自身的缺陷，与 UVSOCK 协议无关。因此：

- **启动一律用 [scripts/Start-Uvision.ps1](scripts/Start-Uvision.ps1)**（内部走 `Start-Process`），不要写 C# 启动器。
- `UvSockClient.exe` 只负责**接入**已在运行的 uVision，不负责启动。
- 若 uVision 异常退出，先检查是不是被别的 C# 程序启动的。

**软件仿真不模拟时钟树。** Keil 的 `SARMCM3.DLL` 不模拟 HSE 晶振和 PLL：官方 `system_stm32f10x.c` 里等待 `RCC_CR_PLLRDY` 的循环永远不退出，目标会卡死在 `SystemInit()`，表现为 PC 停在 `0x080002xx` 不前进、断点命中不到 `main`。**这不是脚本问题。** 仿真调试时要么用 [assets/test-project](assets/test-project) 里那种跳过时钟配置的夹具，要么用 `run-to <main地址>` 直接跳过初始化，要么改用真实硬件调试。

**`UV_PRJ_ENUM_TARGETS` 等枚举命令在调试模式下不可用**（返回 `10 DEBUGGING`）。需要工程结构信息时先 `dbg-exit`。

**目标工程若配的是硬件调试器而探针未连接**，`dbg-enter` 会返回 `SUCCESS` 但随后所有调试命令报 `6 NOT_DEBUGGING`。**`dbg-enter` 返回 SUCCESS 不等于调试会话真的建立了** —— 必须用 `dbg-status` 确认。没有硬件时先 `set-debugtarget simulator`。

## 三套测试套件

| 用户想看什么 | 例程 | 验收重点 |
|---|---|---|
| 工程能不能编译通过 | `run-test.ps1 -Test build` | 退出码 0，0 错误 0 警告，`.axf` 与 `.hex` 均为本次生成，HEX 格式合法，输出程序体积 |
| 断点、单步、看变量能不能用 | `run-test.ps1 -Test debug` | 断点精确停在 `main`，读到 `global_array` 初值，单步后数组被改写为 300，读到 37 个寄存器与中断向量表，uVision 全程存活 |
| 逻辑对不对（完全不动 Keil） | `run-unit-test.ps1` | 路径解析、工程解析、HEX 校验、进程清理拒绝条件、安装判定、日志解析、超时预算、修复账本 |

```powershell
& "<skill>\scripts\run-test.ps1" -Test all -OutputDirectory "D:\some\writable\dir"
& "<skill>\scripts\run-unit-test.ps1"                 # 秒级，不需要装 Keil
& "<skill>\scripts\run-scenario-test.ps1"             # 50 个场景，含真调 Keil 的用例
```

`-Test` 可取 `all`（默认）、`build`、`debug`。单独跑 `-Test debug` 时脚本会先补一次编译——调试会话必须有可加载的 `.axf`，否则 uVision 进调试后会立刻掉出来。

加 `-KeepUvision` 保留调试窗口供用户自己看。脚本把夹具工程复制到输出目录再操作，**不会写进 skill 安装目录**。结束时打印 `RESULT: PASS/FAIL` 并把逐项结果写进 `result.json`。

**三套测试的判定标准**

- **单元测试**：`UNIT RESULT: PASS (n/m tests passed)`，结果写 `%TEMP%\keil5-unit-tests\unit-result.json`。全离线、秒级。
- **场景测试**：`SCENARIO RESULT: PASS (n/m scenarios passed)`。**每条结果都带 `mode` 字段**（`real` 真调 Keil / `mock` 伪造 UV4 或合成日志 / `offline` 纯离线），**没真跑 Keil 的用例不会被写成「真实编译测试通过」**。
- **集成自检**：`RESULT: PASS (n/m checks passed)`；`result.json` 顶层字段是 `skill`/`test`/`passed`/`checkCount`/`failedCount`/`launchDir`/`checks[]`（**没有 `allPassed`/`total` 字段**，别猜）。

**读实际 JSON 判断通过；uVision 启动了、端口监听了、进程没崩，都不能单独算测试通过。**

## 进程安全（最高优先级）

本 skill **绝不按名字批量结束进程**。清理 uVision 的唯一入口是 `Stop-OwnedUvision`，三个条件全部满足才动手：

| 校验 | 不满足时 |
|---|---|
| PID 必须是用 `Register-OwnedUvision` 登记过的 | 没有登记 PID 就什么都不做 |
| 进程名必须正好是 `UV4` | `refused`（防 PID 复用后误杀别的程序） |
| 启动时间与登记时相差不超过 2 秒 | `refused` |

清理顺序：UVSOCK `exit` → `CloseMainWindow()` → `Stop-Process -Id <单个PID> -Force`。**全仓库没有一句 `Get-Process -Name UV4 | Stop-Process`。**

其他保证：

- `Get-UvisionProcesses()`（枚举）是**只读**的，只记录不结束。
- `Start-Uvision.ps1` 检测到已有 uVision 实例时**不阻止、不清理**，只在输出里记 `preexisting_pids`；端口被占用会自动向后找空闲端口（输出 `port_requested`/`port_changed`）。
- 集成自检有一条断言 `safety.preexistingUvisionAlive`：跑前记下所有已存在的 uVision PID，跑完逐个核对仍存活。**实测用户开着 1 个 / 2 个 Keil 时跑自检，用户实例全程存活。**
- 启动 uVision 之前先写登记表（`%TEMP%\keil5-automatic-wwj\owned-uvision.json`），所以测试进程被强杀（Ctrl+C / 作业终止，`finally` 不执行）时，也能靠 `-CleanStaleUvision` 在下次收尾。

## 给用户工程做调试的常规流程

1. 先编译（`Build-Project.ps1`）。编译不过就先修编译错误，不要急着调试。
2. 确认用户是否接了硬件探针。没接就 `set-debugtarget simulator`；接了则保持 `hardware`。
3. `Start-Uvision.ps1` 起窗口，让用户能看见过程。
4. 进调试 → 轮询就绪 → 下断点 → `run` → 轮询命中 → 读变量/寄存器/内存。
5. 交付时给出**实际读回的值**（地址、变量值、寄存器），不要只说"已调试成功"。
6. 需要长期保留调试会话时不要 `exit`；用完主动收尾，别留一堆 uVision 进程。

## 参考文档

- [references/install.md](references/install.md) —— 各平台安装路径、一键安装、升级校验与验证方法（DSH / Codex / 豆包 / WorkBuddy）
- [references/protocol.md](references/protocol.md) —— UVSOCK 协议要点、报文格式、状态码、结构体布局（要扩展客户端时读）
- [references/troubleshooting.md](references/troubleshooting.md) —— 按症状查：编译失败、连不上、卡住、命令报错、进程安全问题
- [references/commands.md](references/commands.md) —— 全部命令的参数与返回示例

## 跨智能体使用

本 skill 的执行层是「PowerShell 脚本 + 一个 C# 命令行程序」，不依赖 DSH 专有接口，任何能执行命令行的智能体都能调用。

用户问「怎么装到 DSH / 豆包 / WorkBuddy / Codex」时，读 [references/install.md](references/install.md)，按里面的实际路径安装，不要凭印象编路径。装完必须跑 `run-test.ps1` 验证——**技能出现在列表里、Keil 窗口弹出来，都不能算装好**。

移植到其他机器时注意：

- 路径要按目标机器实际安装位置传（`-Uv4` 参数），不要照抄本文档里的 `F:\Keil5`。
- 技能目录里带用户名（如 `C:\Users\yebocan\...`），换机器后要按实际用户名替换。
- `UvSockClient.exe` 已随 skill 提供；若目标机器上不可用，用 `csc.exe /out:UvSockClient.exe UvSockClient.cs` 重新编译（源码在 [scripts/UvSockClient.cs](scripts/UvSockClient.cs)）。
- 不同 uVision 版本的 UVSOCK 版本号可能不同（本机实测 229 / V2.29），协议报文格式一致。
