# 各平台安装说明

本技能是纯文件形态（`SKILL.md` + `scripts/` + `references/` + `assets/`），没有安装程序、没有依赖。所谓"安装"就是把 `skill\` 目录整体复制到目标客户端的技能目录，改名为技能名。

本页路径均已在作者机器（Windows 10/11，用户 `yebocan`）上核实。**换机器后请先确认目标客户端实际扫描哪个目录，不要照抄本文档的用户名。**

## 路径速查

| 平台 | 安装目标路径 | 说明 |
|---|---|---|
| **DSH** | `%USERPROFILE%\.dsh\skills\keil5-automatic-wwj\` | DSH 原生技能目录，优先级最高 |
| **Codex** | `%USERPROFILE%\.codex\skills\keil5-automatic-wwj\` | Codex 的技能目录；DSH 也会扫描它 |
| **豆包（工作电脑版）** | `%USERPROFILE%\Doubao\skills\keil5-automatic-wwj\` | 豆包客户端登记的本地技能路径 |
| **豆包（官方用户技能）** | `%LOCALAPPDATA%\Doubao\User Data\Default\.doubao\agent_mode\workspace\.user_skills\keil5-automatic-wwj\` | 豆包内置 `skill-creator-for-work` 指定的用户技能目录 |
| **WorkBuddy** | `%USERPROFILE%\.workbuddy\skills\keil5-automatic-wwj\` | WorkBuddy 用户技能目录 |

> `%USERPROFILE%` 通常是 `C:\Users\<你的用户名>`；`%LOCALAPPDATA%` 通常是 `C:\Users\<你的用户名>\AppData\Local`。

## 一键安装（推荐）

仓库根目录的 `Install-Skill.ps1` 会按上表逐个安装：

```powershell
cd "D:\deepseek harness gongzuoqu\keil5-automatic-wwj"

# 先看看会装到哪里，不实际复制
pwsh -File .\Install-Skill.ps1 -DryRun

# 全部平台
pwsh -File .\Install-Skill.ps1

# 只装某一个
pwsh -File .\Install-Skill.ps1 -Target dsh
pwsh -File .\Install-Skill.ps1 -Target doubao
pwsh -File .\Install-Skill.ps1 -Target workbuddy
```

`-Target` 可选：`all`（默认）、`dsh`、`codex`、`doubao`、`doubao-user`、`workbuddy`，可多选。

脚本行为：目标目录已存在同名技能时先删后拷（属于覆盖安装）；结束时打印每个平台的文件数并输出 JSON 汇总。

## 手工安装

任一平台都可以直接复制：

```powershell
$src  = "D:\deepseek harness gongzuoqu\keil5-automatic-wwj\skill"

# DSH
Copy-Item -Recurse -Force $src "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj"

# 豆包（工作电脑版）
Copy-Item -Recurse -Force $src "$env:USERPROFILE\Doubao\skills\keil5-automatic-wwj"

# WorkBuddy
Copy-Item -Recurse -Force $src "$env:USERPROFILE\.workbuddy\skills\keil5-automatic-wwj"
```

目标目录的**父目录不存在时先建**（`New-Item -ItemType Directory -Force`）。装完检查目标目录里有 `SKILL.md`。

## 各平台注意事项

### DSH

- DSH 的技能管理器（Skills Manager）会扫描多个来源：`.dsh\skills`（原生，优先级最高）、`.agents\skills`、`.codex\skills`、`.claude\skills`、`.workbuddy\skills` 等。
- **同名技能只会出现一个条目**，按来源优先级取第一个。所以装了 `.dsh\skills` 之后，`.codex\skills` 里那份不会再单独显示，但仍可被 Codex 使用。
- 装好后不需要额外注册，新开对话即可用中文描述需求触发；也可以直接用 `$keil5-automatic-wwj` 点名调用。

### Codex

- 技能目录就是 `%USERPROFILE%\.codex\skills`，与 DSH 共用同一份文件。
- `agents/openai.yaml` 提供 `display_name` / `short_description` / `default_prompt`，供支持该约定的客户端展示。

### 豆包（工作电脑版）

- 豆包客户端会把它登记的本地技能路径传给运行时。在作者机器上，日志里记录的值是 `local_skill_paths: ["C:\Users\yebocan\Doubao\skills"]`，所以装到 `%USERPROFILE%\Doubao\skills` 即可被识别。
- 豆包内置的 `skill-creator-for-work` 另有官方约定目录 `workspace\.user_skills`（完整路径见上表）。本技能**两处都装**，哪条路径生效都不会落空。
- 豆包侧只支持"技能（提示词 + 文件）"这一种形态。本技能的执行层是 PowerShell 脚本加一个 C# 命令行程序，**由豆包调用本地命令行执行**，不需要在豆包里额外配置 MCP 连接器。
- 若豆包在沙箱里执行、拿不到本机路径，需要在其设置里允许访问本地文件系统，否则脚本读不到 `F:\Keil5\UV4\UV4.exe`。

### WorkBuddy

- 目录是 `%USERPROFILE%\.workbuddy\skills`，技能列表缓存里这类条目的 `source` 字段为 `userSettings`，表示来自用户目录、随放随用。
- 放进去后重启客户端或等技能列表刷新即可看到。

## 装完怎么验证

**第一步：确认文件到位**

```powershell
$skill = "$env:USERPROFILE\.dsh\skills\keil5-automatic-wwj"
Test-Path "$skill\SKILL.md"        # 应为 True
(Get-ChildItem $skill -Recurse -File).Count   # 应为 20
```

**第二步：跑自检（真正验证可用性）**

```powershell
& "$skill\scripts\run-test.ps1" -Test all -OutputDirectory "$env:TEMP\keil5-tests"
```

看到 `RESULT: PASS (20/20 checks passed)` 才算装好。这一步会真的启动 Keil、编译并调试，约 1-2 分钟。

**只看到技能出现在列表里、或 Keil 窗口弹出来了，都不算装好。**

## 改了源码怎么同步

仓库里的 `skill\` 是唯一源，各平台的副本是拷贝。改完源码后重新跑一次：

```powershell
pwsh -File .\Install-Skill.ps1
```

只改了文档（`SKILL.md`、`references\`）也要重跑，否则客户端读到的还是旧副本。

改了 `scripts\UvSockClient.cs` 还需要重新编译：

```powershell
$skill = "D:\deepseek harness gongzuoqu\keil5-automatic-wwj\skill"
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /optimize `
    /out:"$skill\scripts\UvSockClient.exe" "$skill\scripts\UvSockClient.cs"
```

编译要在**源目录**做，再跑 `Install-Skill.ps1` 分发；直接编译安装目录里的副本会被下次同步覆盖。

## 前置条件

| 项 | 要求 |
|---|---|
| 操作系统 | Windows（脚本用 PowerShell，客户端是 .NET Framework 程序） |
| Keil MDK | 已安装。本项目在 MDK V5.35 上验证；其他版本若 UVSOCK 版本号不同，协议报文格式一致 |
| .NET Framework | 4.x（Windows 10/11 自带，无需单独安装） |
| Python | **不需要** |
| 调试探针 | 可选。没有探针就用软件仿真 |

`UV4.exe` 不在常见位置时，用脚本的 `-Uv4` 参数指定实际路径，或设 `KEIL_UV4` 环境变量。
