# Keil5 Automatic WWJ

让 AI 智能体真正操作本机 **Keil MDK (uVision)** 的 DSH 技能：编译 STM32/ARM 工程、远程控制调试器做源码级调试（断点、单步、读变量/寄存器/内存），并用读回的真实数据作为证据。

**零 Python 依赖**，不需要 pip，不需要安装任何第三方库。

---

## 它解决什么问题

AI 帮你写嵌入式代码时，最常见的困境是「代码写出来了，但没法验证」——编译过不过、变量实际是多少、程序卡在哪一行，全都靠人肉去 uVision 里点。这个技能把这两件事变成命令行可调用、结果可解析的接口：

- **编译**：后台调 `UV4.exe` 编译，把编译器输出解析成结构化的「文件 + 行号 + 错误信息」。
- **调试**：通过 Keil 官方的 UVSOCK 接口远程控制 uVision，下断点、单步、读变量和寄存器，拿回**真实数值**。

## 两条能力链路

### 编译层（零依赖，立刻可用）

```powershell
& ".\skill\scripts\Build-Project.ps1" -Project "D:\your\project.uvprojx" -Action build
```

返回 JSON，含 `errorCount`、`warningCount`、`programSize`、`diagnostics`（每条错误带文件与行号）、`exitCode`、`logFile`。

中文路径、空格路径都支持。不需要打开 uVision，不需要硬件。

### 调试层（走 UVSOCK，支持纯软件仿真）

```powershell
# 1. 启动 uVision（必须用 PowerShell 启动，原因见下）
& ".\skill\scripts\Start-Uvision.ps1" -Project "D:\your\project.uvprojx" -Port 41950

# 2. 接入并下命令
& ".\skill\scripts\UvSockClient.exe" 41950 set-debugtarget simulator
& ".\skill\scripts\UvSockClient.exe" 41950 dbg-enter
& ".\skill\scripts\UvSockClient.exe" 41950 bp-create main
& ".\skill\scripts\UvSockClient.exe" 41950 run
& ".\skill\scripts\UvSockClient.exe" 41950 eval global_counter
& ".\skill\scripts\UvSockClient.exe" 41950 regs
```

共 60+ 条命令，覆盖会话控制、执行控制、断点、求值、内存、寄存器、符号、工程信息、构建、串口等。完整清单见 [skill/references/commands.md](skill/references/commands.md)。

**没接调试探针也能用**——切到软件仿真（`SARMCM3.DLL`）即可做断点、单步、变量观测。

## 自检例程

```powershell
& ".\skill\scripts\run-test.ps1" -Test all -OutputDirectory "D:\some\writable\dir"
```

`-Test` 可取 `all`（默认）、`build`、`debug`。单独跑 `-Test debug` 时脚本会先补一次编译（调试会话需要可加载的 `.axf`）。

两套例程共 20 项检查，全部通过才打印 `RESULT: PASS`：

| 例程 | 检查内容 |
|---|---|
| `build` | UV4 退出码 0、0 错误 0 警告、生成 `.axf` 与 `.hex`、输出程序体积 |
| `debug` | uVision 启动、切仿真、进调试、断点精确停在 `main`、读到全局变量初值、单步后数组被改写为 300、读到 37 个寄存器与中断向量表、退出后 uVision 仍存活 |

脚本会把夹具工程复制到输出目录再操作，**不会写进技能安装目录**。加 `-KeepUvision` 可保留窗口自己看。

**读实际 `result.json` 判断通过。uVision 启动了、端口监听了、进程没崩，都不能单独算测试通过。**

## 安装

一键装到本机所有 AI 客户端：

```powershell
cd "D:\deepseek harness gongzuoqu\keil5-automatic-wwj"
pwsh -File .\Install-Skill.ps1 -DryRun   # 先看会装到哪
pwsh -File .\Install-Skill.ps1           # 实际安装
```

| 平台 | 技能目录 |
|---|---|
| DSH | `%USERPROFILE%\.dsh\skills\keil5-automatic-wwj\` |
| Codex | `%USERPROFILE%\.codex\skills\keil5-automatic-wwj\` |
| 豆包（工作电脑版） | `%USERPROFILE%\Doubao\skills\keil5-automatic-wwj\` |
| 豆包（官方用户技能目录） | `%LOCALAPPDATA%\Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills\keil5-automatic-wwj\` |
| WorkBuddy | `%USERPROFILE%\.workbuddy\skills\keil5-automatic-wwj\` |

只装某一个用 `-Target dsh` / `-Target doubao` / `-Target workbuddy`（可多选）。也可以手工把 `skill/` 目录整个复制过去。

各平台的加载机制、注意事项与验证方法见 [skill/references/install.md](skill/references/install.md)。

### 装完必须验证

```powershell
& "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\run-test.ps1" -Test all -OutputDirectory "$env:TEMP\keil5-tests"
```

看到 `RESULT: PASS (20/20 checks passed)` 才算装好。**技能出现在列表里、Keil 窗口弹出来了，都不能算装好。**

### 前置条件

| 项 | 要求 |
|---|---|
| 操作系统 | Windows（PowerShell + .NET Framework） |
| Keil MDK | 已安装（本项目在 V5.35 上验证） |
| .NET Framework | 4.x（Windows 10/11 自带） |
| Python | **不需要** |
| 调试探针 | 可选。没有就用软件仿真 |

若 `UV4.exe` 不在常见位置，用 `-Uv4` 参数指定，或设 `KEIL_UV4` 环境变量。

## 已知限制（重要）

这些是实测确认的边界，不是配置问题：

1. **uVision 5.35 由 C# 进程启动会自崩**（约 2 秒内 `0xC0000005`，错误模块是 UV4.exe 自身）。由 PowerShell 或 cmd 启动则完全正常。这是 Keil 自身的缺陷，因此本项目**一律用 `Start-Uvision.ps1` 启动**，`UvSockClient.exe` 只负责接入。

2. **软件仿真不模拟时钟树**。Keil 的 `SARMCM3.DLL` 不模拟 HSE 晶振与 PLL，官方 `system_stm32f10x.c` 里等待 `RCC_CR_PLLRDY` 的循环永远不退出，目标会卡死在 `SystemInit()`。仿真调试时要用跳过时钟配置的夹具（见 `assets/test-project`），或用 `run-to <main地址>` 跳过初始化，或改用真实硬件。

3. **`adr2line`（地址反查源码行）在本机 Keil 5.35 上不可用**，始终返回 `32 NO_ADRMAP`。要反查就读 `.map` 或 `.lst` 文件。

4. **`watch` 返回 `28 NOT_SUPPORTED`**，用 `eval` 代替。

5. **`dbg-enter` 返回 SUCCESS 不等于调试会话已建立**。必须轮询 `dbg-status` 到 `debugging:true`。工程若配的是硬件调试器而探针未连接，会先返回 SUCCESS 然后所有命令报 `6 NOT_DEBUGGING`。

更多症状见 [skill/references/troubleshooting.md](skill/references/troubleshooting.md)。

## 目录结构

```
keil5-automatic-wwj/
├── README.md                      本文件
├── 使用教程.md                     中文使用教程（给使用者看，含速查表与避坑指南）
├── Install-Skill.ps1               一键安装到各平台技能目录
├── Publish-ToGitHub.ps1            一键发布到 GitHub
├── skill/                         技能本体（可整体复制到技能目录）
│   ├── SKILL.md                   技能说明与工作流程
│   ├── agents/openai.yaml         跨智能体接口描述
│   ├── scripts/
│   │   ├── Build-Project.ps1      编译层入口
│   │   ├── Start-Uvision.ps1      启动 uVision 并等端口就绪
│   │   ├── UvSockClient.cs        UVSOCK 客户端源码（C#，零依赖）
│   │   ├── UvSockClient.exe       已编译的客户端
│   │   └── run-test.ps1           两套自检例程
│   ├── references/
│   │   ├── install.md             各平台安装路径与验证方法
│   │   ├── protocol.md            UVSOCK 协议要点（要扩展客户端时读）
│   │   ├── commands.md            全部命令的参数与返回示例
│   │   └── troubleshooting.md     按症状查的排错指南
│   └── assets/test-project/       STM32F103 自检夹具工程
└── keil5-automatic-wwj-skill.zip  打包好的技能（可直接分发）
```

## 技术原理

- **编译层**用 Keil 官方命令行：`UV4.exe -b <工程> -o <日志>`。退出码含义：`0`=无错无警、`1`=仅警告、`2`=有错误、`3`=致命错误、`11`=无法写工程、`12`=设备未找到、`13`=写工程失败、`15`=导入 XML 失败、`20`=转换工程失败。
- **调试层**用 Keil 官方 UVSOCK（TCP/IP）协议。uVision 带 `-s <端口>` 启动后在该端口开服务端，客户端发二进制命令、收二进制响应。协议无握手、无认证。报文头 32 字节（`#pragma pack(1)`），响应分同步（`0x3000`）与异步（`0x4000`）两类。

  完整协议细节（含结构体布局、状态码、异步流）见 [skill/references/protocol.md](skill/references/protocol.md)。

- **客户端**是单个 C# 文件，用系统自带的 `csc.exe` 编译：

  ```powershell
  & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize /out:"UvSockClient.exe" "UvSockClient.cs"
  ```

  不需要 .NET SDK、不需要 NuGet 包。

## 跨智能体使用

执行层是「PowerShell 脚本 + 一个 C# 命令行程序」，不依赖 DSH 专有接口，任何能执行命令行的智能体都能调用。移植时把 `-Uv4` 指向目标机器的实际安装位置即可。

## 许可

MIT
