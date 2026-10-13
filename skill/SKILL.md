---
name: keil5-automatic-wwj
description: 用本机 Keil MDK(uVision) 编译 STM32/ARM 工程并做源码级调试：后台编译解析编译错误、UVSOCK 远程控制仿真或硬件调试（断点、单步、读变量/寄存器/内存）。零 Python 依赖，附可见窗口自检例程。
---

# Keil5 Automatic WWJ

把用户的嵌入式需求变成「真实编译 + 真实调试」的可验证结果：用 Keil 官方命令行编译，用 Keil 官方 UVSOCK 接口远程控制调试器，读回实际寄存器与内存作为证据。本 skill 指导流程与判断标准，执行由本目录内的脚本完成。

**零依赖**：不需要 Python，不需要 pip，不需要额外安装任何东西。客户端是 C# 源码，用系统自带的 .NET Framework 编译器（`csc.exe`）编译一次即可。

## 按用户请求选择入口

- **"编译一下 / 看看能不能过 / 检查工程"**：走编译层，用 [scripts/Build-Project.ps1](scripts/Build-Project.ps1)。不需要打开 uVision，不需要硬件。
- **"调试 / 单步 / 看变量 / 为什么卡住 / 跑不起来"**：走调试层，先 [scripts/Start-Uvision.ps1](scripts/Start-Uvision.ps1) 起 uVision，再用 [scripts/UvSockClient.exe](scripts/UvSockClient.exe) 下命令。没接硬件时用软件仿真。
- **"跑一下例子 / 测试 skill / 演示"**：用 [scripts/run-test.ps1](scripts/run-test.ps1) 跑两套自检例程，见下方表格。
- **"烧录到板子"**：需要真实调试探针（ULINK/ST-Link/J-Link）已连接，用 `flash` 命令。**探针未连接时不要尝试，先问用户。**

## 编译层

```powershell
& "<skill>\scripts\Build-Project.ps1" -Project "D:\path\to\your.uvprojx" -Action build
```

输出 JSON，关键字段：`success`、`exitCode`、`exitName`、`errorCount`、`warningCount`、`programSize`、`diagnostics`（每个错误带 `file`/`line`/`kind`/`message`）、`logFile`。

UV4 退出码：`0`=无错无警、`1`=仅警告、`2`=有错误、`3`=致命错误、`11`=无法写工程、`12`=设备未找到、`13`=写工程失败、`15`=导入 XML 失败、`20`=转换工程失败。**进程正常退出不等于编译通过**：必须同时看 `errorCount`。

中文路径、空格路径都能用，不需要把工程复制到纯英文目录。

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

## 两套自检例程

| 用户想看什么 | 例程 | 验收重点 |
|---|---|---|
| 工程能不能编译通过 | `run-test.ps1 -Test build` | UV4 退出码 0，0 错误 0 警告，生成 `.axf` 与 `.hex`，输出程序体积 |
| 断点、单步、看变量能不能用 | `run-test.ps1 -Test debug` | 断点精确停在 `main`，读到 `global_array` 初值，单步后数组被改写为 300，读到 37 个寄存器与中断向量表，uVision 全程存活 |

```powershell
& "<skill>\scripts\run-test.ps1" -Test all -OutputDirectory "D:\some\writable\dir"
```

`-Test` 可取 `all`（默认）、`build`、`debug`。单独跑 `-Test debug` 时脚本会先补一次编译——调试会话必须有可加载的 `.axf`，否则 uVision 进调试后会立刻掉出来。

加 `-KeepUvision` 保留调试窗口供用户自己看。脚本把夹具工程复制到输出目录再操作，**不会写进 skill 安装目录**。结束时打印 `RESULT: PASS/FAIL` 并把逐项结果写进 `result.json`。

**读实际 `result.json` 判断通过；uVision 启动了、端口监听了、进程没崩，都不能单独算测试通过。**

## 给用户工程做调试的常规流程

1. 先编译（`Build-Project.ps1`）。编译不过就先修编译错误，不要急着调试。
2. 确认用户是否接了硬件探针。没接就 `set-debugtarget simulator`；接了则保持 `hardware`。
3. `Start-Uvision.ps1` 起窗口，让用户能看见过程。
4. 进调试 → 轮询就绪 → 下断点 → `run` → 轮询命中 → 读变量/寄存器/内存。
5. 交付时给出**实际读回的值**（地址、变量值、寄存器），不要只说"已调试成功"。
6. 需要长期保留调试会话时不要 `exit`；用完主动收尾，别留一堆 uVision 进程。

## 参考文档

- [references/install.md](references/install.md) —— 各平台安装路径与验证方法（DSH / Codex / 豆包 / WorkBuddy）
- [references/protocol.md](references/protocol.md) —— UVSOCK 协议要点、报文格式、状态码、结构体布局（要扩展客户端时读）
- [references/troubleshooting.md](references/troubleshooting.md) —— 按症状查：编译失败、连不上、卡住、命令报错
- [references/commands.md](references/commands.md) —— 全部命令的参数与返回示例

## 跨智能体使用

本 skill 的执行层是「PowerShell 脚本 + 一个 C# 命令行程序」，不依赖 DSH 专有接口，任何能执行命令行的智能体都能调用。

用户问「怎么装到 DSH / 豆包 / WorkBuddy / Codex」时，读 [references/install.md](references/install.md)，按里面的实际路径安装，不要凭印象编路径。装完必须跑 `run-test.ps1` 验证——**技能出现在列表里、Keil 窗口弹出来，都不能算装好**。

移植到其他机器时注意：

- 路径要按目标机器实际安装位置传（`-Uv4` 参数），不要照抄本文档里的 `F:\Keil5`。
- 技能目录里带用户名（如 `C:\Users\yebocan\...`），换机器后要按实际用户名替换。
- `UvSockClient.exe` 已随 skill 提供；若目标机器上不可用，用 `csc.exe /out:UvSockClient.exe UvSockClient.cs` 重新编译（源码在 [scripts/UvSockClient.cs](scripts/UvSockClient.cs)）。
- 不同 uVision 版本的 UVSOCK 版本号可能不同（本机实测 229 / V2.29），协议报文格式一致。
