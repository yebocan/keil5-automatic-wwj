# 命令参考

所有调试命令通过同一个客户端执行：

```powershell
& "<skill>\scripts\UvSockClient.exe" <端口> <命令> [参数...]
```

输出一行 JSON。成功 `{"ok":true,...}` 退出码 0；失败 `{"ok":false,"error":"..."}` 退出码 1。加 `--out <文件>` 可同时写入文件。

下文的「返回」是实测值，可直接用来对照。

## 会话与信息

### `info`
读 uVision 与 UVSOCK 版本。

```json
{"ok":true,"command":"info","result":{"uvsockVersion":229,"uvision":"μVision=V5.35.0.0","uvsock":"UVSOCK=V2.29"}}
```

### `license`
检查许可证状态。

### `dbg-enter` / `dbg-exit` / `dbg-status`
进入 / 退出调试会话，查询状态。

```
dbg-enter     → {"ok":true,"result":{"status":0,"statusName":"SUCCESS"}}
dbg-status    → {"ok":true,"result":{"debugging":true,"nVal":0,"running":false}}
```

`nVal`：`0` = 目标已停止，`1` = 目标正在运行。`dbg-enter` 是异步的，**要轮询 `dbg-status` 到 `debugging:true`** 才算就绪。

### `debugtarget` / `set-debugtarget <simulator|hardware>`
查询 / 切换调试器驱动。

```
debugtarget              → {"target":1,"debugTarget":"simulator"}
set-debugtarget simulator → {"ok":true}
```

没有硬件探针时必须切到 `simulator`，否则 `dbg-enter` 会假装成功然后所有调试命令报 `6 NOT_DEBUGGING`。

## 执行控制

| 命令 | 参数 | 说明 |
|---|---|---|
| `reset` | — | 复位目标。之后等约 2 秒再 `run` |
| `run` | — | 全速运行，直到断点命中或用户停止 |
| `stop` | — | 停止运行 |
| `run-to` | `<地址>` | 运行到指定地址（如 `0x08000335`） |
| `step` | — | 高级语言单步（Step Over） |
| `step-n` | `<N>` | 单步 N 次 |
| `step-into` | — | 步入函数 |
| `step-into-n` | `<N>` | 步入 N 次 |
| `step-asm` | — | 汇编级单步 |
| `step-asm-n` | `<N>` | 汇编单步 N 次 |
| `step-out` | — | 跳出当前函数 |

`run` 在目标已停止时返回 `12 TARGET_STOPPED`，这是正常语义不是错误。

## 断点

```
bp-create <表达式> [类型] [计数]
```

类型：`exec`（执行，默认）、`read`、`write`、`readwrite`、`complex`。

```
bp-create main exec 1
→ {"ok":true,"result":{"status":0,"statusName":"SUCCESS"}}

bp-enum
→ {"ok":true,"result":{"breakpoints":[
    {"type":1,"count":1,"enabled":true,"address":134218488,"exprLen":11,"expression":"accumulate"}]}}
```

`address` 是十进制，`134218488` = `0x080002F8`。

```
bp-del <索引>     # 索引来自 bp-enum 的顺序，从 0 开始
```

**断点地址要在 `run` 之前读**（目标运行时不能求值）。

## 求值与变量

```
eval <表达式>          → {"expression":"global_counter","value":0}
eval-str <表达式>      → {"expression":"global_array","text":"0X20000008"}
```

`eval` 只返回数值（`value`），`eval-str` 返回 uVision 的原始文本（`text`），看数组地址、结构体成员、指针时用后者。

支持 C 表达式：`global_array[2]`、`&global_counter`、`acc + 5`。

目标正在运行时 `eval` 会返回空结果，客户端已转成 `TARGET_NOT_STOPPED` 错误：

```json
{"ok":false,"error":"TARGET_NOT_STOPPED","detail":"目标正在运行，无法求值。先 stop 或等断点命中。"}
```

`watch` 与 `watch-del` 在本机 Keil 5.35 上返回 `28 NOT_SUPPORTED`，**用 `eval` 代替**。

## 内存与寄存器

```
mem-read <地址> <字节数>     # 两个参数都必须给
→ {"address":134217728,"byteCount":32,"bytes":"1804002049010008...","errCount":0,"errAddress":0}

mem-write <地址> <十六进制字节>
→ {"ok":true,"bytesWritten":4}

dsm <地址> <长度>            # 反汇编视图
→ {"disassembly":"    34: { \n"}
```

`mem-read` 只传地址会报「参数不足。用法: mem-read <地址> <字节数>」。

`dsm` 返回的是**源码行文本**，不是反汇编指令 —— 本机实测如此，不要指望它给指令。

```
regs
→ {"ok":true,"result":{"registers":[
    {"group":0,"index":0,"name":"R0","value":"0x00000000","isPC":false,"canChange":true}, ...],
   "count":37}}
```

`regs` 返回 37 项，含 `R0`-`R15`、`xPSR`、`MSP`、`PSP` 等。`R15 (PC)` 的 `isPC` 为 `true`。

```
reg-groups    → {"groups":["Core","Banked","System","Internal"]}
reg-set <寄存器名> <值>
```

## 符号

```
line2adr <绝对路径> <行号>
→ {"file":"D:\\...\\main.c","line":56,"address":134218570}     # 0x0800034A
```

**必须传绝对路径。** 传 `main.c` 或 `.\main.c` 会返回 `32 NO_ADRMAP`。

```
adr2line <地址>
```

**本机 Keil 5.35 上该命令始终返回 `32 NO_ADRMAP`，不可用。** 要地址反查源码行，读 `.map` 文件或 `Listings\*.lst`。

```
stack     → 调用栈（仿真下可能为空）
vars      → 局部变量枚举
tasks     → RTOS 任务（无 RTOS 时为空）
```

## 工程信息

```
targets        → {"targets":["Target 1"]}
curtarget      → {"currentTarget":"Target 1"}
settarget <名> → 切换当前目标
groups         → {"groups":["CORE","HARWARE","LIB","SYS","OBJ","USER"]}
files <组名>   → {"group":"USER","files":[".\\main.c",".\\stm32f10x_it.c"]}
activefiles    → {"activeFiles":19}
outputname     → {"outputName":".\\Objects\\test.axf"}
```

**调试模式下这些枚举命令不可用**，返回 `10 DEBUGGING`。需要工程结构信息时先 `dbg-exit`。

## 构建

```
build      → {"completed":true,"code":3,"codeName":"ERRORS","lineCount":10,"output":["Build started...", ...]}
rebuild    → 重建全部
clean      → 清理产物
cancel     → 取消进行中的构建
flash      → 下载到 Flash（需要真实探针）
flash-erase → 擦除 Flash
```

`code` 是 `UVBUILDCODES`：`1`=OK、`2`=OK_WARNINGS、`3`=ERRORS、`4`=CANCELLED、`5`=CLEANED。

调试模式下 `build` 会返回 `10 DEBUGGING`，**先 `dbg-exit`**。日常编译用 [Build-Project.ps1](Build-Project.ps1) 更省事。

## 其他

```
exec <uVision命令>     # 执行 uVision 命令语言，如 exec "BS main.c 56"
menus                  # 枚举菜单项
time                   # 目标运行时间
serial-get             # 读串口缓冲
serial-put <数据>      # 写串口
ui-lock / ui-unlock    # 锁定/解锁界面（自动化时防误触）
show / hide / minimize / maximize / restore
exit                   # 退出 uVision
load <工程>            # 加载工程
close                  # 关闭当前工程
raw <命令码十六进制> [载荷十六进制]   # 直接发原始包，用于调试协议
```

`exec` 是逃生口：uVision 命令语言的任何能力都能用。注意非调试态下 `exec` 返回 `6 NOT_DEBUGGING`。

`raw` 用于协议扩展排查，例如 `raw 0001` 等价于 `info` 的底层请求。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 命令成功（`ok:true`） |
| 1 | 命令失败（`ok:false`，看 `error` 字段） |
| 2 | 参数错误 |
