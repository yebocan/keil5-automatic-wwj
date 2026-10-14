# Keil5 Automatic WWJ

让 AI 智能体真正操作本机 **Keil MDK (uVision)** 的技能：编译 STM32/ARM 工程、远程控制调试器做源码级调试（断点、单步、读变量/寄存器/内存）、在限定范围内自动改代码并有限次修复编译错误，全部用读回的真实数据作为证据。

**零 Python 依赖**，不需要 pip，不需要安装任何第三方库。

> 本 README 对应仓库当前代码。文中每条能力都标注了「已实测 / 未实测」，未实现的功能写在[计划功能](#计划功能未实现)一节，不会混在现有能力里。

---

## 1. 项目用途

AI 帮你写嵌入式代码时，最常见的困境是「代码写出来了，但没法验证」——编译过不过、变量实际是多少、程序卡在哪一行，全都靠人肉去 uVision 里点。本技能把这件事变成命令行可调用、结果可解析的接口：

| 环节 | 做法 | 证据 |
|---|---|---|
| 编译 | 后台调 `UV4.exe` 编译，把编译器输出解析成结构化诊断 | 退出码 + 日志结果行 + 产物 SHA256 变化 |
| 调试 | 通过 Keil 官方 UVSOCK 接口远程控制 uVision | 断点命中地址、变量读回值、寄存器快照 |
| 改代码 | 在用户限定的文件范围内修改，改前自动快照 | 会话账本记录每个文件的原始 SHA256 |
| 修复 | 每次编译登记一次尝试，自动判断该不该继续 | 错误数变化趋势 + 是否改了范围外文件 |
| 验证 | 独立校验 Intel HEX 的结构、校验和与生成时间 | 逐行解析结果，不靠修改时间 |

## 2. 支持的环境

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | Windows 10 / 11 | 依赖 PowerShell 与 .NET Framework |
| PowerShell | Windows PowerShell 5.1 **或** PowerShell 7+ | 两个都测过；脚本不用 7 才有的语法 |
| Keil MDK | uVision 5（本项目在 **V5.35** 上验证） | 需要 `UV4.exe`；调试层需要 `UVSOCK64.dll`/`UVSC64.dll`（随 uVision 安装） |
| .NET Framework | 4.x | Windows 10/11 自带，用于编译 C# 客户端 |
| Python | **不需要** | 整个项目零 Python |
| 调试探针 | 可选 | 没有探针就用软件仿真（`SARMCM3.DLL`） |

实测环境：Windows 10 + PowerShell 7.6.6 + Keil MDK V5.35（`F:\Keil5`）+ 无调试探针。

## 3. 安装要求

- 磁盘：技能本体约 1.2 MB（含夹具工程与已编译客户端）。
- 权限：普通用户即可。安装脚本只往当前用户的技能目录写文件，**不改系统环境变量、不改注册表、不动 PATH**。
- 网络：不需要。安装与运行全程离线。
- 管理员权限：不需要。

## 4. 如何安装 Skill

```powershell
cd "D:\deepseek harness gongzuoqu\keil5-automatic-wwj"
pwsh -File .\Install-Skill.ps1 -DryRun      # 先看会装到哪，不写任何文件
pwsh -File .\Install-Skill.ps1              # 实际安装（默认只装 DSH）
```

**默认只装 DSH**。要装到别处必须显式指定 `-Target`：

```powershell
pwsh -File .\Install-Skill.ps1 -Target dsh,doubao,workbuddy
```

| `-Target` | 技能目录 |
|---|---|
| `dsh`（默认） | `%USERPROFILE%\.dsh\skills\keil5-automatic-wwj\` |
| `codex` | `%USERPROFILE%\.codex\skills\keil5-automatic-wwj\` |
| `doubao` | `%USERPROFILE%\Doubao\skills\keil5-automatic-wwj\` |
| `doubao-user` | `%LOCALAPPDATA%\Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills\keil5-automatic-wwj\` |
| `workbuddy` | `%USERPROFILE%\.workbuddy\skills\keil5-automatic-wwj\` |

安装脚本的安全行为（都已实测）：

- 目标目录已有**同名但不是本技能**的目录时 → **拒绝覆盖**，并提示「为免覆盖别人的技能，本脚本不动它」。判定依据是 `SKILL.md` frontmatter 里的 `name:` 字段。
- 覆盖本技能的旧版本前，先把整个旧目录备份到 `%TEMP%\keil5-automatic-wwj-backup\<时间戳>\<平台>_<时间戳>\`，并打印旧版本的描述，让你知道覆盖掉的是什么。
- 安装后回读校验 `SKILL.md` 的 `name:`，校验不过会打印 `[警告]`。

其它动作：

```powershell
pwsh -File .\Install-Skill.ps1 -Action status      # 看各平台装没装
pwsh -File .\Install-Skill.ps1 -Action update      # 同 install，语义更明确
pwsh -File .\Install-Skill.ps1 -Action uninstall -Target dsh   # 只删本技能目录
```

`-Action uninstall` 只删技能目录本身，父目录里别人的技能一律不碰；目标不是本技能时拒绝删除。

各平台的加载机制与注意事项见 [skill/references/install.md](skill/references/install.md)。

### 装完必须验证

```powershell
& "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\run-test.ps1" -Test all -OutputDirectory "$env:TEMP\keil5-tests"
```

看到 `RESULT: PASS (26/26 checks passed)` 才算装好。**技能出现在列表里、Keil 窗口弹出来了，都不能算装好。**

## 5. 如何配置 Keil 路径

所有脚本共用同一套解析链（实现在 `skill/scripts/KeilCommon.ps1` 的 `Resolve-KeilUv4`），优先级从高到低：

| 优先级 | 来源 | 写法 |
|---|---|---|
| 1 | 命令行参数 | `-Uv4 "D:\Keil_v5\UV4\UV4.exe"` |
| 2 | 环境变量 | `$env:KEIL5_UV4 = "D:\Keil_v5\UV4\UV4.exe"` |
| 3 | **配置文件** | 用下面的 `Set-KeilPath.ps1` 写 |
| 4 | 常见安装位置 | `F:\Keil5`、`C:\Keil_v5`、`D:\Keil_v5`、`E:\Keil_v5`、`C:\Keil`、`D:\Keil`、`E:\Keil` 下的 `UV4\UV4.exe` |
| 5 | 系统 PATH | PATH 里的 `UV4.exe` |

**只做定点探测，不扫全盘。** 全部找不到时抛错并逐条列出试过哪些来源。

推荐用配置脚本一次写好，以后所有脚本都不用再传 `-Uv4`：

```powershell
$s = "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\Set-KeilPath.ps1"
& $s                                    # 自动探测并写入
& $s -Uv4 "D:\Keil_v5\UV4\UV4.exe"      # 手动指定
& $s -Show                              # 看当前用的是哪个、从哪来的
& $s -Clear                             # 删掉配置，回到自动探测
```

配置文件位置 `%APPDATA%\keil5-automatic-wwj\config.json`（可用环境变量 `KEIL5_AUTOMATIC_WWJ_CONFIG` 指向别处）。内容形如：

```json
{ "uv4": "F:\\Keil5\\UV4\\UV4.exe", "saved_at": "2026-10-14T13:21:29" }
```

`Set-KeilPath.ps1` 会校验目标确实是名为 `UV4.exe` 的已存在文件，写完后立刻回读比对，写入失败会 `exit 1`。

配置坏掉时（JSON 语法错）不会静默忽略：`Get-KeilConfig` 会打印警告说「已忽略该文件，继续按候选路径查找」，让你知道自己的设置没生效。

## 6. 如何识别工程

`KeilCommon.ps1` 的 `Get-KeilProjectInfo -Project <路径>` 只读解析 `.uvprojx` / `.uvproj`（XML），返回：

| 字段 | 含义 |
|---|---|
| `project` / `projectDir` | 工程文件绝对路径 / 所在目录 |
| `targets[]` | 每个 Target：`{name, device, outDir, outName, createHex}` |
| `targetCount` / `target` | Target 数量 / 第一个 Target 名 |
| `sources[]` | 每个源文件：`{name, relative, fullPath, type, exists}` |
| `sourceCount` / `includes` | 源文件数 / 头文件搜索路径 |
| `outputDir` / `axfPath` / `hexPath` | 输出目录与预期产物路径 |
| `parseOk` | 是否解析成功 |

要点：

- **路径含空格、中文都支持**（已实测：`C:\...\中文 目录 带空格\demo 工程.uvprojx`）。
- `sources[]` 里取绝对路径要用 **`.fullPath`**（没有 `.path` 字段）。
- **多 Target 工程必须用 `-Target` 指定**，否则 `Build-Project.ps1` 返回 `targetAmbiguous=true` 并拒绝编译——不会替你猜。
- 解析成功但没有 Target（`targetCount=0`）时调用方应拒绝编译，这属于「工程配置不完整」。
- 不是 `.uvprojx`/`.uvproj` 或文件不存在时直接抛错，不会返回半成品结果。

```powershell
. "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\KeilCommon.ps1"
Get-KeilProjectInfo -Project "D:\proj\app.uvprojx" | Format-List
```

## 7. 如何调用编译功能

```powershell
& "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\Build-Project.ps1" `
    -Project "D:\your\project.uvprojx" -Action build
```

参数：`-Project`（必填）、`-Action`（`build`/`rebuild`/`clean`/`flash`，默认 `build`）、`-Target`（多 Target 时必填）、`-Uv4`、`-LogFile`、`-TimeoutSeconds`（10–3600，默认 600）、`-SkipHexCheck`。

### 编译结论怎么来的（不只看退出码）

`Build-Project.ps1` 综合七个证据给出结论，任一环节缺证据就报「无法确定」而不是成功：

| 证据 | 字段 |
|---|---|
| UV4 进程是否正常结束 | `timedOut` |
| 退出码 | `exitCode` / `exitName` |
| 日志里有没有结果行 `N Error(s), M Warning(s)` | `errorCountFromLog`（`false` 时 `errorCount` 为 `null`） |
| 日志里的错误/警告 | `errorCount` / `warningCount` / `diagnostics[]` |
| 产物 `.axf` 是否本次真的更新 | `axfState`：`created`/`changed`/`touched`/`unchanged`/`missing` |
| HEX 是否生成 | `hexState` / `hexStatus` |
| HEX 格式是否合法 | `hexFormatStatus` / `hexCheck` |

输出里三个结论字段是分开的，别混着看：

- `success`（布尔）：仅表示「本次编译本身是否成功」。
- `buildStatus`：`success` / `failed` / `indeterminate`。
- `determinate`（布尔）：`false` 表示证据不足、结论不可信。

判定规则（实测有效）：

- 超时 → `failed`。
- 没有退出码 / 没有日志 / 日志里没有结果行 → `indeterminate`（**不再默认成功**）。
- `errorCount > 0` → `failed`。
- 退出码不在 `{0,1}` → `failed`。
- `build`/`rebuild` 但 `.axf` 状态是 `missing` 或 `unchanged` → `failed`（防止拿上次的旧产物冒充成功）。
- 以上都不触发 → `success`，`reasons` 里会写明依据。

UV4 退出码：`0`=无错无警、`1`=仅警告、`2`=有错误、`3`=致命错误、`11`=无法写工程、`12`=设备未找到、`13`=写工程失败、`15`=导入 XML 失败、`20`=转换工程失败。

### 输出字段（实测）

```
skill, action, project, projectName, target, targetCount, targetAmbiguous, device,
uv4, uv4Source, exitCode, exitName, timedOut, success, buildStatus, determinate,
reasons, errorCount, warningCount, errorCountFromLog, fatalSeen, targetNotCreated,
programSize{Code,RO-data,RW-data,ZI-data}, diagnostics[{index,file,line,kind,code,message,raw}],
summaryLine, axfPath, axfState, hexPath, hexState, hexStatus, hexFormatStatus,
hexCheck{...}, projectWarning, parseError, logFile, logAvailable, tail
```

真实样例（夹具工程 `-Action rebuild`）：

```json
{
  "exitCode": 0, "exitName": "NO_ERRORS_NO_WARNINGS", "success": true,
  "buildStatus": "success", "determinate": true,
  "programSize": { "Code": 256, "RO-data": 336, "RW-data": 28, "ZI-data": 1028 },
  "axfState": "created", "hexState": "created", "hexStatus": "generated",
  "hexFormatStatus": "valid",
  "summaryLine": "\".\\Objects\\test.axf\" - 0 Error(s), 0 Warning(s)."
}
```

编译失败时 `diagnostics[]` 每条形如：

```json
{ "index": 0, "file": "main.c", "line": 24, "kind": "error",
  "code": "#5", "message": "cannot open source input file \"stm32_eval.h\": No such file or directory" }
```

`kind` 取 `error` / `warning` / `fatal error`；`code` 是 Keil 错误码（`#5`、`#177-D`、`C4065E` 等）；`raw` 保留原始行，解析不出来时靠它兜底。

## 8. 如何验证 HEX

编译时如果工程勾了「Create HEX File」，脚本会独立校验 HEX，**不复用编译的结论**：

```json
"hexStatus": "generated",
"hexFormatStatus": "valid",
"hexCheck": {
  "path": "...\\Objects\\test.hex", "exists": true, "size": 1798,
  "format": "intel-hex", "valid": true,
  "records": 42, "dataRecords": 39, "dataBytes": 620,
  "eofSeen": true, "checksumErrors": 0, "malformedLines": 0,
  "addressRange": "0x08000000-0x0800026B"
}
```

`hexStatus` 的取值与含义：

| 值 | 含义 |
|---|---|
| `generated` | 本次编译新生成，且文件状态为 `created`/`changed` |
| `stale-from-previous-build` | **文件还在，但不是本次生成的**——上一次成功的残留 |
| `not-generated` | 工程要求生成，但文件不存在 |
| `disabled-in-project` | 工程的 `CreateHexFile` 没开 |
| `unknown` | 没编译成功，无从判断 |

`hexFormatStatus` 由 `Test-IntelHexFile` 给出：`not-run` / `valid` / `invalid`。校验项：

- 每行以 `:` 开头，长度为偶数且合法十六进制。
- 记录头声明字节数 `LL` 与实际数据长度一致。
- 每行校验和正确（含 `0xFF` 补码求和）。
- 存在 EOF 记录（类型 `01`）。
- 支持记录类型 `00`/`01`/`02`/`03`/`04`/`05`；类型 `04`（扩展线性地址）按 `高16位 << 16` 计算，类型 `02`（扩展段地址）按 `×16` 计算。
- 文件为空（0 字节）判为无效。

**旧 HEX 误判已实测防住**：先编译成功留下 HEX，再制造编译失败，结果为 `buildStatus=failed`、`hexState=unchanged`、`hexStatus=stale-from-previous-build`、`success=false`——**没有因为旧文件还在就报成功**。判定依据是产物 SHA256 与大小的前后对比，不是修改时间。

单独校验任意 HEX：

```powershell
. "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\KeilCommon.ps1"
Test-IntelHexFile -Path "D:\proj\Objects\app.hex" | Format-List
```

### 四件事要分开说

这四句话的含义完全不同，本技能不会把它们混为一谈：

1. **编译成功** —— `buildStatus=success`。
2. **HEX 生成成功** —— `hexStatus=generated`。
3. **HEX 格式验证成功** —— `hexFormatStatus=valid`。
4. **程序功能正确** —— **本技能不验证**。它只保证产物结构合法，功能对不对要靠仿真调试或真实硬件。

## 9. 如何进行自动修复

`Repair-Session.ps1` 是「账本 + 安全闸」，它**不替你改代码**（改代码由 AI 用编辑工具完成），负责的是防止无限循环和盲目修改那一半。

```powershell
$r = "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\scripts\Repair-Session.ps1"

# 1) 改代码前：给范围内每个文件做快照，建立会话
& $r -Action start -Project "D:\proj\app.uvprojx" -Scope 'USER\*.c','HARDWARE\*.h'

# 2) AI 用编辑工具改代码 …

# 3) 改完登记一次尝试（会真的调编译）
& $r -Action attempt -SessionId rs_xxx -Reason '补上缺失的头文件'

# 4) 随时看状态 / 看改了什么
& $r -Action status -SessionId rs_xxx
& $r -Action diff   -SessionId rs_xxx

# 5) 不行就回滚，或收尾
& $r -Action rollback -SessionId rs_xxx
& $r -Action finish   -SessionId rs_xxx
```

参数：`-Action`（`start`/`attempt`/`status`/`diff`/`rollback`/`finish`/`list`）、`-Project`、`-SessionId`、`-Scope`（相对工程目录的通配符，不传则默认取工程里登记的全部源文件）、`-MaxAttempts`（1–20，**默认 3**）、`-SessionRoot`（默认 `%TEMP%\keil5-repair-sessions`）、`-Reason`、`-KeepCurrentOnRollback`（默认 `true`）、`-Uv4`、`-TimeoutSeconds`、`-DryRun`。

`status` 输出：`action, sessionId, state, attempts, maxAttempts, remaining, changed, removed, outside, conclusion`。
`start` 输出：`action, sessionId, sessionDir, projectDir, scope, maxAttempts, snapshotFiles`。
`diff` 输出：`action, sessionId, changed, deleted, outside, diffs`。

会话目录布局（实测）：

```
%TEMP%\keil5-repair-sessions\rs_20261014_133452_b98bea\
├── session.json          账本：范围、每个文件的原始 SHA256/大小、每次尝试记录、结论
└── baseline\             基线快照（原文件整份复制，回滚就是从这里还原）
    └── main.c
```

**必须停止的五个条件**（`attempt` 会自动判定并写进 `conclusion`）：

1. 达到最大修复次数（默认 3，可配但不会无限）。
2. 错误数比上一次增加。
3. 本次没有任何文件被改动（空转，继续重试没意义）。
4. 改了范围外的文件（超出授权）。
5. 连续两次错误数完全不变（没有进展）。

**回滚是可撤销的**：`-Action rollback` 默认先把你当前的改动也备份一份（`-KeepCurrentOnRollback $true`），所以回滚本身也能再回滚。

`start` 时会同时记录工程登记的全部源文件是否存在，所以「改了范围外的文件」和「新增/删除了工程文件」都能被发现。

## 10. 如何查看日志

编译日志默认写到系统临时目录，**不写进技能安装目录**：

```
%TEMP%\keil5-automatic-wwj\uv4_<action>_<时间戳>.log
```

用 `-LogFile` 指定别处：

```powershell
& "...\Build-Project.ps1" -Project "D:\proj\app.uvprojx" -LogFile "D:\logs\build.log"
```

输出里的 `logFile` 是本次日志的绝对路径，`logAvailable` 表示日志非空，`tail` 是日志末尾若干行（方便直接看报错），`summaryLine` 是结果行原文。

日志解析由 `KeilCommon.ps1` 的 `Get-KeilBuildLogDiagnostics` 完成，单独用也行：

```powershell
. "...\KeilCommon.ps1"
$p = Get-KeilBuildLogDiagnostics -Path "D:\logs\build.log"
$p.errorCount        # 解析不到结果行时是 $null，不是 0
$p.diagnostics       # 结构化诊断数组
```

`Get-KeilBuildLogDiagnostics` 也可以直接喂文本（`-Text $string`），两个参数都不是必填。

自检与场景测试的结果 JSON：

- 集成自检：`<OutputDirectory>\launch_<时间戳>\result.json`，顶层字段 `skill`/`test`/`passed`/`checkCount`/`failedCount`/`launchDir`/`project`/`uvisionKept`/`checks[]`。
- 单元测试：`%TEMP%\keil5-unit-tests\unit-result.json`。
- 场景测试：`<WorkDirectory>\scenario-result.json`。

## 11. 常见错误如何处理

完整清单见 [skill/references/troubleshooting.md](skill/references/troubleshooting.md)（按症状查）。最高频的几条：

| 症状 | 原因 | 处理 |
|---|---|---|
| 所有调试命令报 `6 NOT_DEBUGGING` | ①工程配的是硬件调试器（如 `UL2CM3.DLL`）但探针没插；②没有可加载的 `.axf` | ①`set-debugtarget simulator` 切仿真；②先编译 |
| `dbg-enter` 返回 SUCCESS 但马上报 6 | 同上。SUCCESS 只表示命令被接受 | 轮询 `dbg-status` 到 `debugging:true` 再下别的命令 |
| 目标卡在 `SystemInit()` 不动 | 软件仿真不模拟 HSE/PLL，等 `RCC_CR_PLLRDY` 的循环永不退出 | 用 `run-to <main地址>` 跳过初始化，或换仿真友好的 `system_stm32f10x.c` |
| `adr2line` 报 `32 NO_ADRMAP` | Keil 5.35 本机限制 | 读 `.map` 或 `.lst` 文件 |
| `watch` 报 `28 NOT_SUPPORTED` | 本机限制 | 用 `eval` |
| 找不到 `UV4.exe` | 不在常见位置 | 跑 `Set-KeilPath.ps1 -Uv4 "..."` |
| 提示「配置文件无法解析」 | `config.json` 语法坏了 | 修正或删除它，或重跑 `Set-KeilPath.ps1` |
| 编译报 `cannot open source input file` | 工程自身缺头文件/路径不对 | 这是工程问题，不是技能问题；改工程的 Include 路径 |
| 目标目录已有同名技能被拒绝 | 那是别人的技能 | 换目录，或先确认后手工处理 |
| uVision 启动后约 2 秒崩溃（`0xC0000005`） | 由 C# 进程启动导致（Keil 自身缺陷） | 一律用 `Start-Uvision.ps1` 启动 |

## 12. 如何备份和恢复

**代码修改的回滚**（自动修复场景）：

```powershell
& $r -Action rollback -SessionId rs_xxx     # 从 baseline 还原，且回滚前再备份当前状态
& $r -Action diff     -SessionId rs_xxx     # 先看清改了什么
```

基线快照位置：`%TEMP%\keil5-repair-sessions\<会话号>\baseline\`。`finish` 之后基线仍保留，需要时可再回滚。

**技能文件的回滚**（安装/更新场景）：

覆盖安装前，`Install-Skill.ps1` 会自动把旧版本整目录备份到：

```
%TEMP%\keil5-automatic-wwj-backup\<时间戳>\<平台>_<时间戳>\
```

要恢复旧版本，把备份目录里的内容复制回技能目录即可：

```powershell
Copy-Item "$env:TEMP\keil5-automatic-wwj-backup\<时间戳>\dsh_<时间戳>\*" `
          "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj\" -Recurse -Force
```

**仓库本身的回滚**：本项目是 git 仓库，用常规 git 操作即可：

```powershell
git log --oneline          # 看历史
git stash                  # 暂存当前改动（可 git stash pop 取回）
git revert <提交>          # 生成一个反向提交，不改写历史
git checkout -- <文件>     # 丢弃某个文件的未提交改动
```

> **不建议用 `git reset --hard` 或 `git clean -fd`**：前者会丢弃未提交的修改，后者会删除未跟踪文件，两者都可能让你丢掉正在做的工作。要撤销就用 `git revert`（保留历史）或先 `git stash`。

**部分成功部分失败怎么办**：如果一轮修复里有的文件改对了、有的改错了，`rollback` 会整体还原到基线（因为基线是「修改前」的完整状态）。要保留部分成果，先手工把想留的文件复制出去，再回滚。

## 13. 当前已知限制

这些是实测确认的边界，不是配置问题：

1. **uVision 5.35 由 C# 进程启动会自崩**（约 2 秒内 `0xC0000005`，错误模块是 UV4.exe 自身）。由 PowerShell 或 cmd 启动则完全正常。这是 Keil 自身的缺陷，因此本项目**一律用 `Start-Uvision.ps1` 启动**，`UvSockClient.exe` 只负责接入 TCP，绝不负责启动。

2. **软件仿真不模拟时钟树**。Keil 的 `SARMCM3.DLL` 不模拟 HSE 晶振与 PLL，官方 `system_stm32f10x.c` 里等待 `RCC_CR_PLLRDY` 的循环永远不退出，目标会卡死在 `SystemInit()`。仿真调试时要用跳过时钟配置的夹具（见 `assets/test-project`），或用 `run-to <main地址>` 跳过初始化，或改用真实硬件。

3. **`adr2line`（地址反查源码行）在本机 Keil 5.35 上不可用**，始终返回 `32 NO_ADRMAP`。要反查就读 `.map` 或 `.lst` 文件。`line2adr` 必须传绝对路径，相对路径同样返回 `NO_ADRMAP`。

4. **`watch` 返回 `28 NOT_SUPPORTED`**，用 `eval` 代替。`vars`（无参数）返回 `9 NOT_FOUND`；`stack` 在停在 `main` 入口时返回空 `frames`（没有调用栈）。

5. **`dbg-enter` 返回 SUCCESS 不等于调试会话已建立**。必须轮询 `dbg-status` 到 `debugging:true`。工程若配的是硬件调试器而探针未连接，会先返回 SUCCESS 然后所有命令报 `6 NOT_DEBUGGING`。

6. **硬件调试、烧录未实测**。本机没有调试探针，`flash` / `flash-erase` 与硬件断点只实现了接口，**没有在真实硬件上验证过**。

7. **`exec`（执行 uVision 内置命令）返回空输出**。`exec "BS main.c 56"` 返回 `status=0` 但 `output` 为空数组，实际效果未验证。

8. **`dsm` 返回的是源码行文本**（如 `"    34: { \n"`），不是反汇编指令。

9. **功能正确性不在覆盖范围内**。本技能验证「编译通过、HEX 结构合法、变量读回值符合预期」，不证明程序逻辑正确。

## 计划功能（未实现）

以下功能**尚未实现**，写在这里以免被误认为现有能力：

- 真实硬件烧录的端到端验证（缺探针）。
- 断点命中后的自动变量快照对比（目前靠手工 `eval`）。
- 编译错误的自动定位修复（目前是「AI 读诊断 → 人工/AI 改代码 → 登记 attempt」的流程，没有内置的自动改写器）。
- 多工程批量编译。

## 安全说明

本技能会执行本机命令、读写文件、开 TCP 端口，使用前请了解边界：

- **进程**：只结束自己启动的 uVision。判定依据是**启动时登记的 PID + owner 进程**（登记表外的 PID 一律不碰），并对进程名做 `UV4` 校验、启动时间差 2 秒内才认。**不会按进程名批量结束**；用户手动打开的 uVision 根本不会进登记表，所以从一开始就不在清理范围内（已实测：用户开着 2 个 Keil 时跑 `run-test.ps1 -Test all`，`PASS (26/26)`，用户实例全程存活）。**授权只认登记表、不认父进程**——从桌面双击打开的 uVision 父进程是 `explorer`，靠父进程判定会被冒充，该漏洞实测存在并已修复。
- **文件写入范围**：编译产物写在工程自己的输出目录；日志写在 `%TEMP%`；修复会话写在 `%TEMP%\keil5-repair-sessions`；安装只写用户级技能目录。**不改系统配置、不改环境变量、不动注册表。**
- **不覆盖无关文件**：安装脚本遇到非本技能的同名目录会拒绝；修复会话只改 `-Scope` 指定范围内的文件，改了范围外会报违规并建议停止。
- **网络**：只在 `127.0.0.1` 上开本地 TCP 端口（UVSOCK 调试接口），不对外通信、不下载、不上传。
- **无认证的本地接口**：UVSOCK 协议本身没有握手与认证，端口开放期间同机进程可连接。它默认绑定本机，且随 uVision 关闭而消失。不要在不可信的多用户机器上长时间挂着调试端口。
- **不做安全审计声明**：本项目做过静态代码审查（路径拼接、临时文件、日志内容、子进程调用、依赖、下载执行、安装覆盖删除），**没有做过完整动态安全审计，不能宣称绝对安全**。

## 自检与测试

```powershell
$sk = "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj"

# 单元测试（秒级，不需要装 Keil）
& "$sk\scripts\run-unit-test.ps1"        # 83 项

# 场景测试（22 个场景，含真调 Keil 的用例）
& "$sk\scripts\run-scenario-test.ps1"

# 集成自检（真编译 + 真调试，约 1-2 分钟）
& "$sk\scripts\run-test.ps1" -Test all -OutputDirectory "$env:TEMP\keil5-tests"
```

| 套件 | 覆盖 | 结果判定 |
|---|---|---|
| 单元测试 | Keil 路径解析、工程解析、HEX 校验、进程清理拒绝条件、启动登记表、安装判定、日志解析、超时预算、修复账本 | `UNIT RESULT: PASS (n/m)` |
| 场景测试 | 任务书要求的 22 个场景（路径、工程、编译、HEX、进程、安装、修复） | `SCENARIO RESULT: PASS (n/m)` |
| 集成自检 | 真编译夹具工程 + 真起 uVision 做仿真调试 | `RESULT: PASS (n/m)` |

场景测试的每条结果都带 `mode` 字段：`real`（真调 Keil）/ `mock`（伪造 UV4 或合成日志）/ `offline`（纯离线）。**没真跑 Keil 的用例不会被写成「真实编译测试通过」。**

集成自检会把夹具工程复制到输出目录再操作，**不会写进技能安装目录**；跑完只清理自己启动的那个 uVision（`-KeepUvision` 可保留窗口自己看）。

## 目录结构

```
keil5-automatic-wwj/
├── README.md                        本文件
├── 使用教程.md                       中文使用教程（含速查表与避坑指南）
├── Install-Skill.ps1                 安装 / 更新 / 卸载到各平台技能目录
├── Publish-ToGitHub.ps1              一键发布到 GitHub
├── skill/                            技能本体（可整体复制到技能目录）
│   ├── SKILL.md                      技能说明与工作流程
│   ├── agents/openai.yaml            跨智能体接口描述
│   ├── scripts/
│   │   ├── KeilCommon.ps1            公共模块：Keil 路径、进程安全、HEX 校验、工程解析、日志解析、超时预算、启动登记表
│   │   ├── Set-KeilPath.ps1          配置 Keil 路径
│   │   ├── Build-Project.ps1         编译层入口
│   │   ├── Repair-Session.ps1        有限次自动修复的账本与安全闸
│   │   ├── Start-Uvision.ps1         启动 uVision 并等 UVSOCK 端口就绪
│   │   ├── UvSockClient.cs           UVSOCK 客户端源码（C#，零依赖）
│   │   ├── UvSockClient.exe          已编译的客户端
│   │   ├── run-test.ps1              集成自检（真编译 + 真调试）
│   │   ├── run-unit-test.ps1         单元测试
│   │   └── run-scenario-test.ps1     22 个场景测试
│   ├── references/
│   │   ├── install.md                各平台安装路径与验证方法
│   │   ├── protocol.md               UVSOCK 协议要点（要扩展客户端时读）
│   │   ├── commands.md               全部命令的参数与返回示例
│   │   └── troubleshooting.md        按症状查的排错指南
│   └── assets/test-project/          STM32F103 自检夹具工程
└── keil5-automatic-wwj-skill.zip     打包好的技能（可直接分发）
```

## 技术原理

- **编译层**用 Keil 官方命令行：`UV4.exe -b <工程> -o <日志> -j0`。注意参数要拼成一个自带引号的字符串传给 `Start-Process`，传数组时 UV4 不写日志（实测）。
- **调试层**用 Keil 官方 UVSOCK（TCP/IP）协议。uVision 带 `-s <端口>` 启动后在该端口开服务端，客户端发二进制命令、收二进制响应。协议无握手、无认证。报文头 32 字节（`#pragma pack(1)`），响应分同步（`0x3000`）与异步（`0x4000`）两类。

  完整协议细节（含结构体布局、状态码、异步流）见 [skill/references/protocol.md](skill/references/protocol.md)。

- **客户端**是单个 C# 文件，用系统自带的 `csc.exe` 编译：

  ```powershell
  & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize /out:"UvSockClient.exe" "UvSockClient.cs"
  ```

  不需要 .NET SDK、不需要 NuGet 包。

## 跨智能体使用

执行层是「PowerShell 脚本 + 一个 C# 命令行程序」，不依赖 DSH 专有接口，任何能执行命令行的智能体都能调用。移植时：

1. 把 `skill/` 复制到目标客户端的技能目录（见 [skill/references/install.md](skill/references/install.md)）。
2. 在目标机器上跑一次 `Set-KeilPath.ps1` 指定该机器的 Keil 位置。
3. 跑 `run-test.ps1 -Test all` 验证。

注意：技能目录里带用户名（如 `C:\Users\yebocan\...`），换机器后要按实际用户名替换。

## 许可

MIT
