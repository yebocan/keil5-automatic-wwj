# UVSOCK 协议要点

本 skill 的调试层直接说 Keil 官方的 UVSOCK（TCP/IP）协议。这里记录实测确认的格式，供扩展 [scripts/UvSockClient.cs](../scripts/UvSockClient.cs) 时参考。

来源：Keil 官方头文件 `UVSOCK.h`（V2.24，`UV3_SOCKIF_VERS 223`）。本机 uVision 5.35 运行时报告 `UVSOCK=V2.29`（版本号 229）。

## 架构

uVision 启动时带 `-s <端口>`，它会在这个 TCP 端口上开一个服务端。客户端连上去发二进制命令，收二进制响应。**没有握手、没有登录、没有认证、没有 keepalive**，连上就能发。头文件明确说明支持多个 TCP 连接同时存在。

```
UV4.exe "<工程路径>" -s 41950
```

## 报文格式

请求与响应用同一个 32 字节头（`#pragma pack(1)`，无对齐填充）：

| 偏移 | 类型 | 字段 | 说明 |
|---|---|---|---|
| 0 | UINT | `m_nTotalLen` | 整包长度，含这 32 字节头 |
| 4 | UV_OPERATION | `m_eCmd` | 命令码 |
| 8 | UINT | `m_nBufLen` | data 区长度 |
| 12 | xU64 | `cycles` | 时间戳计数器 |
| 20 | double | `tStamp` | 时间戳 |
| 28 | UINT | `m_Id` | 消息 ID |
| 32 | — | `data` | 载荷，最大 `SOCK_NDATA = 32768` |

**拼包时 `cycles`、`tStamp`、`m_Id` 填 0 即可**，uVision 不校验。

## 响应的两种外层

| 外层命令码 | 含义 | body 结构 |
|---|---|---|
| `0x3000` `UV_CMD_RESPONSE` | 同步响应 | `cmd(4) + status(4) + payload` |
| `0x4000` `UV_ASYNC_MSG` | 异步消息 | `cmd(4) + status(4) + payload` |

**解析事件码时要注意位置差异**（这是最容易踩的坑）：

- 同步响应（外层 `0x3000`）：事件码在 **body 前 4 字节**（内层 cmd）。
- 异步消息（外层 ≥ `0x4000`）：事件码**就是外层报文头的 `m_eCmd`**，body 里那 4 字节是别的东西。

客户端里的统一写法：

```csharp
m.code = (outer == CMD_RESPONSE) ? m.inner : outer;
```

早期没区分这两者，导致 `targets`/`groups` 全部返回空数组。

## 三种特殊的裸格式

以下消息的 body **不是** `cmd + status + payload`，而是裸 `PRJDATA{nLen(0), nCode(4), szNames[8...]}`：

- `0x5000` `UV_PRJ_BUILD_COMPLETE`
- `0x5001` `UV_PRJ_BUILD_OUTPUT`
- `0x6000` `UV_RTA_MESSAGE`

客户端以 `legacyPrj` 标志区分：`inner = nLen`、`status = nCode`、payload 从偏移 0 起就是字符串。没做这个区分时，构建输出的每一行都会被吃掉前 8 个字符（`"arted: Project: yuan"`），构建码也读成 0。

**构建完成码在 `status` 字段**，取值 `UVBUILDCODES`：`1`=OK、`2`=OK_WARNINGS、`3`=ERRORS、`4`=CANCELLED、`5`=CLEANED。

## 错误响应布局

`status != 0` 时，payload 是 `UVSOCK_ERROR_RESPONSE`：

| 偏移 | 类型 | 字段 |
|---|---|---|
| 0 | UINT | `nRes1` |
| 4 | UINT | `nRes2` |
| 8 | UINT | `StrLen` |
| 12 | BYTE[] | `str` |

**`StrLen` 在偏移 8，字符串从偏移 12 开始。** 实测例：`status=6` 时字符串是 `"Target is not in debug mode"`。

## 关键结构体（pack(1) 逐字段累加，不要按自然对齐算）

```
SSTR        { int nLen; char szStr[256]; }                          = 260，串在 4
PRJDATA     { UINT nLen; UINT nCode; char szNames[1]; }             串在 8
AMEM        { xU64 nAddr; UINT nBytes; xU64 ErrAddr; UINT nErr;
              xUC8 aBytes[1]; }                                     数据在 24
TVAL        { VTT_TYPE vType; union { ... } v; }                    = 12，值在 4
VSET        { TVAL val; SSTR str; }                                 串在 16
AFLMAP      { UINT nLine; xU64 nAdr; UINT iFile; UINT iFunc;
              int nRes[5]; char szFile[1]; }                        文件名在 40
EXECCMD     { UINT bEcho:1; UINT nRes[7]; SSTR sCmd; }              串在 32
iPATHREQ    { UINT bFull:1; UINT nRes[7]; }                         = 32
ADRMTFL     { UINT bFull:1; UINT :31; xU64 nAdr; UINT nRes[7]; }
BKPARM      { BKTYPE type; UINT count; UINT accSize; UINT nExpLen;
              UINT nCmdLen; char szBuffer[1024]; }                  表达式在 20
BKRSP       { BKTYPE type; UINT count; UINT enabled; UINT nTickMark;
              xU64 nAddress; UINT nExpLen; char szBuffer[512]; }    表达式在 32
REGENUM     { xWORD16 nGi; xWORD16 nItem; char szReg[16];
              xUC8 flags:1+canChg:1+:6; char szVal[32]; }           = 53
VARINFO     { int nID; int index; int count; int typeSize;
              UINT 位域; SSTR value; SSTR type; SSTR name;
              SSTR qualifiedName; }                                 = 1056
EXTVERS     { UINT iV_Uv3; UINT iV_Sock; UINT nRes[30];
              char szBuffer[3]; }                                   串区在 128
DBGTGTOPT   { DWORD target:1; DWORD :31; DWORD nRes[10]; }          = 44，target 0=硬件 1=仿真
```

**位域陷阱**：pack(1) 下 `UINT :31` 只占 4 字节（不是 8），`xU64` 紧跟其后。早期把 `TVAL` 当 16 字节、把 `AMEM` 数据当偏移 16 都是错的，导致 `eval` 全部读成垃圾值。

**版本串编码**：`EXTVERS` 的字符串区在偏移 128，用 `szBuffer[iV_Uv3]` / `szBuffer[iV_Sock]` 定位。字符串里有单字节 `0xB5`（Latin-1 的 `µ`，即 "µVision"），按 UTF-8 解会变替换字符。客户端先按严格 UTF-8 试，失败回退 Windows-1252。**不要用 `Encoding.Default`**：系统启用 UTF-8 代码页时它也是 UTF-8。

## 请求格式易错点

| 命令 | 请求结构 | 说明 |
|---|---|---|
| `0x1010` `UV_PRJ_ENUM_FILES` | **SSTR**（组名） | 不是 PRJDATA。用错会返回 `9 NOT_FOUND` |
| `0x2025` `UV_DBG_FILELINE_TO_ADR` | **AFLMAP** | 响应 VSET，地址在 TVAL.v（偏移 4）。必须传绝对路径 |
| `0x2027` `UV_DBG_ENUM_REGISTERS` | **REGENUM** | 响应 REGENUM 流 |
| `0x2028` `UV_DBG_READ_REGISTERS` | **SSTR** | 响应 `char[]` |
| `0x2026` `UV_DBG_ENUM_REGISTER_GROUPS` | **VSET** | 响应 SSTR |
| `0x202E` `UV_DBG_ENUM_VARIABLES` | IVARENUM | 响应 VARINFO |
| `0x100B` `UV_PRJ_GET_DEBUG_TARGET` | 无 | 响应 DBGTGTOPT 位域，不是字符串 |
| `0x1014` `UV_PRJ_GET_OUTPUTNAME` | iPATHREQ | 响应 SSTR |

## 枚举命令的异步流

`targets`、`groups`、`files`、`bp-enum`、`regs`、`vars`、`stack`、`tasks`、`menus` 这些枚举命令走「同步响应 + 异步流」：

```
0x3000 (同步响应, payloadLen=0)
0x50xx START
0x50xx ENU   ← 每个元素一条
0x50xx END
```

**不能读完同步响应就返回**，否则拿到空数组。要一直读到 END 或超时。

常用异步码：

| 码 | 含义 |
|---|---|
| `0x5004/0x5005/0x5006` | 断点枚举 START/ENU/END |
| `0x5007/0x5008/0x5009` | 组枚举 |
| `0x500A/0x500B/0x500C` | 文件枚举 |
| `0x5014/0x5015/0x5016` | 调用栈 |
| `0x5021/0x5022/0x5023` | 目标枚举（名字在 payload 偏移 4） |
| `0x5024/0x5025/0x5026` | 寄存器组 |
| `0x5027/0x5028/0x5029` | 寄存器（REGENUM，53 字节/条） |
| `0x5040/0x5041/0x5042` | 变量 |
| `0x5050/0x5051/0x5052` | 任务 |
| `0x5060/0x5061/0x5062` | 菜单 |
| `0x5020` | 命令输出（`exec` 的回显） |
| `0x5120` | 串口输出 |

## 状态码

| 值 | 名称 | 值 | 名称 |
|---|---|---|---|
| 0 | SUCCESS | 12 | TARGET_STOPPED |
| 1 | FAILED | 13 | PARSE_ERROR |
| 2 | NO_PROJECT | 14 | OUT_OF_RANGE |
| 3 | WRITE_PROTECTED | 15-24 | BP_* |
| 4 | NO_TARGET | 25 | BUILD_OK_WARNINGS |
| 5 | NO_TOOLSET | 26 | BUILD_FAILED |
| 6 | NOT_DEBUGGING | 27 | BUILD_CANCELLED |
| 7 | ALREADY_PRESENT | 28 | NOT_SUPPORTED |
| 8 | INVALID_NAME | 29 | TIMEOUT |
| 9 | NOT_FOUND | 30 | UNEXPECTED_MSG |
| 10 | DEBUGGING | 32 | NO_ADRMAP |
| 11 | TARGET_EXECUTING | 36 | BUILDING |
| 31 | VERIFY_FAILED | 37 | HARDWARE |
| 33 | INFO | 38 | SIMULATOR |
| 34 | NO_MEM_ACCESS | 39 | BUFFER_TOO_SMALL |
| 35 | FLASH_DOWNLOAD | | |

实测语义要点：

- `0x2004 UV_DBG_STATUS` 的 `nVal` 只有 `0`/`1` 两个观测值：`0`=目标已停止（可读寄存器），`1`=正在运行。**不是位掩码。**
- `0x2002 UV_DBG_START_EXECUTION` 在目标已停止时返回 `12 TARGET_STOPPED`，这是正常的，不是错误。
- 调试模式下 `UV_PRJ_ENUM_TARGETS` 等工程类命令返回 `10 DEBUGGING`。

## 命令码全表

### 通用 `0x00xx`

`0x0001` GET_VERSION · `0x0002` UI_UNLOCK · `0x0003` UI_LOCK · `0x0004` HIDE · `0x0005` SHOW · `0x0006` RESTORE · `0x0007` MINIMIZE · `0x0008` MAXIMIZE · `0x0009` EXIT · `0x000A` GET_EXTVERSION · `0x000B` CHECK_LICENSE · `0x000C` CPLX_COMPLETE · `0x000D` SET_OPTIONS

### 工程 `0x10xx`

`0x1000` LOAD · `0x1001` CLOSE · `0x1002` ADD_GROUP · `0x1003` DEL_GROUP · `0x1004` ADD_FILE · `0x1005` DEL_FILE · `0x1006` BUILD · `0x1007` REBUILD · `0x1008` CLEAN · `0x1009` BUILD_CANCEL · `0x100A` FLASH_DOWNLOAD · `0x100B` GET_DEBUG_TARGET · `0x100C` SET_DEBUG_TARGET · `0x100D` GET_OPTITEM · `0x100E` SET_OPTITEM · `0x100F` ENUM_GROUPS · `0x1010` ENUM_FILES · `0x1011` CMD_PROGRESS · `0x1012` ACTIVE_FILES · `0x1013` FLASH_ERASE · `0x1014` GET_OUTPUTNAME · `0x1015` ENUM_TARGETS · `0x1016` SET_TARGET · `0x1017` GET_CUR_TARGET · `0x1018` SET_OUTPUTNAME

### 调试 `0x20xx`

`0x2000` ENTER · `0x2001` EXIT · `0x2002` START_EXECUTION · `0x2003` STOP_EXECUTION · `0x2004` STATUS · `0x2005` RESET · `0x2006` STEP_HLL · `0x2007` STEP_INTO · `0x2008` STEP_INSTRUCTION · `0x2009` STEP_OUT · `0x200A` CALC_EXPRESSION · `0x200B` MEM_READ · `0x200C` MEM_WRITE · `0x200D` TIME_INFO · `0x200F` VTR_GET · `0x2010` VTR_SET · `0x2011` SERIAL_GET · `0x2012` SERIAL_PUT · `0x2013` VERIFY_CODE · `0x2014` CREATE_BP · `0x2015` ENUMERATE_BP · `0x2016` CHANGE_BP · `0x2017` ENUM_SYMTP · `0x2018` ADR_TOFILELINE · `0x2019` ENUM_STACK · `0x201A` ENUM_VTR · `0x201C` ADR_SHOWCODE · `0x201D` WAKE · `0x201E` SLEEP · `0x2020` EXEC_CMD · `0x2024` EVAL_EXPRESSION_TO_STR · `0x2025` FILELINE_TO_ADR · `0x2026` ENUM_REGISTER_GROUPS · `0x2027` ENUM_REGISTERS · `0x2028` READ_REGISTERS · `0x2029` REGISTER_SET · `0x202A` DSM_READ · `0x202B` EVAL_WATCH_EXPRESSION · `0x202D` REMOVE_WATCH_EXPRESSION · `0x202E` ENUM_VARIABLES · `0x202F` VARIABLE_SET · `0x2030` ENUM_TASKS · `0x2031` ENUM_MENUS · `0x2032` MENU_EXEC

N 步变体：`0x2102` RUN_TO_ADDRESS · `0x2106` STEP_HLL_N · `0x2107` STEP_INTO_N · `0x2108` STEP_INSTRUCTION_N

### 枚举值与类型

`BKTYPE`：`1`=EXEC `2`=READ `3`=WRITE `4`=READWRITE `5`=COMPLEX

`VTT_TYPE`：`0`=void `1`=bit `2`=char `3`=uchar `4`=int `5`=uint `6`=short `7`=ushort `8`=long `9`=ulong `10`=float `11`=double `12`=ptr `13`=union `14`=struct `15`=func `16`=string `17`=enum `18`=field `19`=int64 `20`=uint64

`UVBUILDCODES`：`1`=OK `2`=OK_WARNINGS `3`=ERRORS `4`=CANCELLED `5`=CLEANED
