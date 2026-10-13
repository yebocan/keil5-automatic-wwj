// UvSockClient.cs - UVSOCK 协议客户端（Keil uVision 远程控制）
//
// 编译：csc /nologo /out:UvSockClient.exe UvSockClient.cs
// 用法：UvSockClient.exe <port> <command> [args...] [--out <jsonfile>]
//
// 重要：uVision 必须由 PowerShell/cmd 启动（UV4.exe <proj> -s <port>）。
// 由 C# 进程 Process.Start 启动的 uVision 会在约 2 秒内以 0xC0000005 崩溃，
// 因此本客户端只负责“接入”，绝不负责“启动”。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Threading;

class UvSockClient
{
    const int SOCK_NDATA = 32768;
    const uint CMD_RESPONSE = 0x3000;
    const uint ASYNC_MSG = 0x4000;

    // ---- 命令码 ----
    const uint C_VER = 0x0001, C_UI_UNLOCK = 0x0002, C_UI_LOCK = 0x0003;
    const uint C_HIDE = 0x0004, C_SHOW = 0x0005, C_RESTORE = 0x0006;
    const uint C_MIN = 0x0007, C_MAX = 0x0008, C_EXIT = 0x0009, C_EXTVERS = 0x000A;
    const uint C_LICENSE = 0x000B;

    const uint C_PRJ_LOAD = 0x1000, C_PRJ_CLOSE = 0x1001;
    const uint C_PRJ_BUILD = 0x1006, C_PRJ_REBUILD = 0x1007, C_PRJ_CLEAN = 0x1008;
    const uint C_PRJ_CANCEL = 0x1009, C_PRJ_FLASH = 0x100A;
    const uint C_PRJ_GET_DBGTGT = 0x100B, C_PRJ_SET_DBGTGT = 0x100C;
    const uint C_PRJ_ENUM_GROUPS = 0x100F;
    const uint C_PRJ_ENUM_FILES = 0x1010, C_PRJ_ACTIVE_FILES = 0x1012;
    const uint C_PRJ_FLASH_ERASE = 0x1013, C_PRJ_GET_OUTNAME = 0x1014;
    const uint C_PRJ_ENUM_TARGETS = 0x1015, C_PRJ_SET_TARGET = 0x1016;
    const uint C_PRJ_GET_CUR_TARGET = 0x1017;

    const uint C_DBG_ENTER = 0x2000, C_DBG_EXIT = 0x2001;
    const uint C_DBG_RUN = 0x2002, C_DBG_STOP = 0x2003, C_DBG_STATUS = 0x2004;
    const uint C_DBG_RESET = 0x2005, C_DBG_STEP_HLL = 0x2006, C_DBG_STEP_INTO = 0x2007;
    const uint C_DBG_STEP_ASM = 0x2008, C_DBG_STEP_OUT = 0x2009;
    const uint C_DBG_CALC = 0x200A, C_DBG_MEM_READ = 0x200B, C_DBG_MEM_WRITE = 0x200C;
    const uint C_DBG_TIME = 0x200D, C_DBG_VTR_GET = 0x200F, C_DBG_VTR_SET = 0x2010;
    const uint C_DBG_SERIAL_GET = 0x2011, C_DBG_SERIAL_PUT = 0x2012;
    const uint C_DBG_CREATE_BP = 0x2014, C_DBG_ENUM_BP = 0x2015, C_DBG_CHANGE_BP = 0x2016;
    const uint C_DBG_ADR2FL = 0x2018, C_DBG_ENUM_STACK = 0x2019, C_DBG_ENUM_VTR = 0x201A;
    const uint C_DBG_EXEC_CMD = 0x2020;
    const uint C_DBG_EVAL_STR = 0x2024, C_DBG_FL2ADR = 0x2025;
    const uint C_DBG_ENUM_REGGROUPS = 0x2026, C_DBG_ENUM_REG = 0x2027;
    const uint C_DBG_READ_REG = 0x2028, C_DBG_REG_SET = 0x2029;
    const uint C_DBG_DSM_READ = 0x202A, C_DBG_WATCH = 0x202B;
    const uint C_DBG_WATCH_DEL = 0x202D, C_DBG_ENUM_VARS = 0x202E;
    const uint C_DBG_VAR_SET = 0x202F, C_DBG_ENUM_TASKS = 0x2030;
    const uint C_DBG_ENUM_MENUS = 0x2031, C_DBG_MENU_EXEC = 0x2032;
    const uint C_DBG_RUN_TO = 0x2102, C_DBG_STEP_HLL_N = 0x2106;
    const uint C_DBG_STEP_INTO_N = 0x2107, C_DBG_STEP_ASM_N = 0x2108;

    // ---- 异步码 ----
    const uint A_BUILD_COMPLETE = 0x5000, A_BUILD_OUTPUT = 0x5001;
    const uint A_BP_START = 0x5004, A_BP_ENU = 0x5005, A_BP_END = 0x5006;
    const uint A_GRP_START = 0x5007, A_GRP_ENU = 0x5008, A_GRP_END = 0x5009;
    const uint A_FILE_START = 0x500A, A_FILE_ENU = 0x500B, A_FILE_END = 0x500C;
    const uint A_STACK_START = 0x5014, A_STACK_ENU = 0x5015, A_STACK_END = 0x5016;
    const uint A_VTR_START = 0x5017, A_VTR_ENU = 0x5018, A_VTR_END = 0x5019;
    const uint A_CMD_OUTPUT = 0x5020, A_SERIAL_OUTPUT = 0x5120;
    const uint A_TGT_START = 0x5021, A_TGT_ENU = 0x5022, A_TGT_END = 0x5023;
    const uint A_REGG_START = 0x5024, A_REGG_ENU = 0x5025, A_REGG_END = 0x5026;
    const uint A_REG_START = 0x5027, A_REG_ENU = 0x5028, A_REG_END = 0x5029;
    const uint A_VAR_START = 0x5040, A_VAR_ENU = 0x5041, A_VAR_END = 0x5042;
    const uint A_TASK_START = 0x5050, A_TASK_ENU = 0x5051, A_TASK_END = 0x5052;
    const uint A_MENU_START = 0x5060, A_MENU_ENU = 0x5061, A_MENU_END = 0x5062;

    static NetworkStream ns;
    static int readTimeoutMs = 8000;
    static readonly StringBuilder json = new StringBuilder();
    static readonly List<string> messages = new List<string>();

    // ================= 协议底层 =================

    static byte[] MakeMsg(uint cmd, byte[] data)
    {
        int n = data == null ? 0 : data.Length;
        byte[] m = new byte[32 + n];
        BitConverter.GetBytes((uint)m.Length).CopyTo(m, 0);
        BitConverter.GetBytes(cmd).CopyTo(m, 4);
        BitConverter.GetBytes((uint)n).CopyTo(m, 8);
        if (n > 0) Array.Copy(data, 0, m, 32, n);
        return m;
    }

    static byte[] ReadExact(int n)
    {
        byte[] b = new byte[n];
        int got = 0;
        while (got < n)
        {
            int r = ns.Read(b, got, n - got);
            if (r <= 0) return null;
            got += r;
        }
        return b;
    }

    class Msg
    {
        public uint outer, inner, status;
        // code = 本条消息的“事件码”：
        //   同步响应(0x3000) -> 内层 cmd（即我们发出的命令）
        //   异步事件(>=0x4000) -> 外层 cmd（如 0x5022 ENUM_TARGETS_ENU）
        public uint code;
        public byte[] payload;
        // legacyPrj = 使用旧式 PRJDATA 裸格式的异步消息（无 cmd+status 前缀）
        //   0x5000 BUILD_COMPLETE / 0x5001 BUILD_OUTPUT / 0x6000 RTA_MESSAGE
        //   此时 inner=nLen, status=nCode, payload=szNames（从 0 开始就是字符串）
        public bool legacyPrj;
        public bool isAsync { get { return outer != CMD_RESPONSE; } }
    }

    // 读取一条消息；超时返回 null
    static Msg ReadMsg()
    {
        byte[] hdr;
        try { hdr = ReadExact(32); }
        catch (TimeoutException) { return null; }
        catch (System.IO.IOException) { return null; }
        if (hdr == null) return null;

        uint total = BitConverter.ToUInt32(hdr, 0);
        if (total < 32 || total > SOCK_NDATA) throw new Exception("协议错误：total=" + total);
        uint outer = BitConverter.ToUInt32(hdr, 4);

        byte[] body = null;
        if (total > 32) body = ReadExact((int)(total - 32));

        Msg m = new Msg();
        m.outer = outer;

        // 旧式 PRJDATA 裸格式的异步消息：body 本身就是 PRJDATA{nLen, nCode, szNames[]}
        // （0x5000 BUILD_COMPLETE / 0x5001 BUILD_OUTPUT / 0x6000 RTA_MESSAGE）
        m.legacyPrj = (outer == A_BUILD_COMPLETE || outer == A_BUILD_OUTPUT || outer == 0x6000);

        if (m.legacyPrj)
        {
            byte[] b = body ?? new byte[0];
            m.inner = b.Length >= 4 ? BitConverter.ToUInt32(b, 0) : 0;   // nLen
            m.status = b.Length >= 8 ? BitConverter.ToUInt32(b, 4) : 0;  // nCode
            int off = 8;
            m.payload = b.Length > off ? new byte[b.Length - off] : new byte[0];
            if (m.payload.Length > 0) Array.Copy(b, off, m.payload, 0, m.payload.Length);
            m.code = outer;
        }
        else if (body != null && body.Length >= 8)
        {
            m.inner = BitConverter.ToUInt32(body, 0);
            m.status = BitConverter.ToUInt32(body, 4);
            m.payload = new byte[body.Length - 8];
            if (m.payload.Length > 0) Array.Copy(body, 8, m.payload, 0, m.payload.Length);
            // 关键：同步响应的事件码在内层，异步事件的事件码在外层
            m.code = (outer == CMD_RESPONSE) ? m.inner : outer;
        }
        else
        {
            m.payload = new byte[0];
            m.code = (outer == CMD_RESPONSE) ? m.inner : outer;
        }

        messages.Add("{\"outer\":\"0x" + outer.ToString("X4") + "\",\"code\":\"0x" + m.code.ToString("X4") +
                     "\",\"status\":" + m.status + ",\"payloadLen\":" + m.payload.Length + "}");
        return m;
    }

    // 发命令并收集消息，直到 stop(m) 为 true 或超时
    static List<Msg> Exchange(uint cmd, byte[] data, Func<Msg, bool> stop, int timeoutMs)
    {
        byte[] m = MakeMsg(cmd, data);
        ns.Write(m, 0, m.Length);
        List<Msg> got = new List<Msg>();
        DateTime deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            int remain = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
            if (remain <= 0) break;
            ns.ReadTimeout = Math.Min(remain, readTimeoutMs);
            Msg r = ReadMsg();
            if (r == null) break;
            got.Add(r);
            if (stop != null && stop(r)) break;
        }
        return got;
    }

    static List<Msg> Simple(uint cmd) { return Exchange(cmd, null, m => !m.isAsync, readTimeoutMs); }
    static List<Msg> Simple(uint cmd, byte[] data) { return Exchange(cmd, data, m => !m.isAsync, readTimeoutMs); }

    // ================= 数据构造 =================

    static byte[] PrjData(string s)
    {
        byte[] str = Encoding.UTF8.GetBytes(s);
        byte[] b = new byte[8 + str.Length + 1];
        BitConverter.GetBytes((uint)(str.Length + 1)).CopyTo(b, 0);  // nLen 含终止符
        BitConverter.GetBytes((uint)0).CopyTo(b, 4);
        Array.Copy(str, 0, b, 8, str.Length);
        return b;
    }

    static byte[] SStr(string s)
    {
        byte[] str = Encoding.UTF8.GetBytes(s);
        byte[] b = new byte[4 + 256];
        BitConverter.GetBytes(str.Length + 1).CopyTo(b, 0);
        Array.Copy(str, 0, b, 4, Math.Min(str.Length, 255));
        return b;
    }

    static byte[] AMem(ulong addr, uint nBytes)
    {
        byte[] b = new byte[24 + nBytes];
        BitConverter.GetBytes(addr).CopyTo(b, 0);
        BitConverter.GetBytes(nBytes).CopyTo(b, 8);
        return b;
    }

    static byte[] AMemWrite(ulong addr, byte[] data)
    {
        byte[] b = new byte[24 + data.Length];
        BitConverter.GetBytes(addr).CopyTo(b, 0);
        BitConverter.GetBytes((uint)data.Length).CopyTo(b, 8);
        Array.Copy(data, 0, b, 24, data.Length);
        return b;
    }

    static byte[] IpathReq(bool full)
    {
        byte[] b = new byte[32];
        BitConverter.GetBytes(full ? 1u : 0u).CopyTo(b, 0);
        return b;
    }

    static byte[] ExecCmd(string cmd)
    {
        byte[] s = SStr(cmd);
        byte[] b = new byte[32 + s.Length];
        BitConverter.GetBytes(1u).CopyTo(b, 0);  // bEcho = 1
        Array.Copy(s, 0, b, 32, s.Length);
        return b;
    }

    static byte[] BkParm(uint type, uint count, uint accSize, string expr)
    {
        byte[] e = Encoding.UTF8.GetBytes(expr);
        byte[] b = new byte[20 + 1024];
        BitConverter.GetBytes(type).CopyTo(b, 0);
        BitConverter.GetBytes(count).CopyTo(b, 4);
        BitConverter.GetBytes(accSize).CopyTo(b, 8);
        BitConverter.GetBytes((uint)(e.Length + 1)).CopyTo(b, 12);
        BitConverter.GetBytes(0u).CopyTo(b, 16);
        Array.Copy(e, 0, b, 20, Math.Min(e.Length, 1023));
        return b;
    }

    static byte[] U32(uint v) { return BitConverter.GetBytes(v); }

    // ================= 数据解析 =================

    static string CStr(byte[] b, int off)
    {
        if (b == null || off >= b.Length) return "";
        int e = off;
        while (e < b.Length && b[e] != 0) e++;
        return DecodeText(b, off, e - off);
    }

    // uVision 的多数字符串走 UTF-8，但版本串（如 "µVision=..."）里的是单字节
    // Latin-1 的 0xB5。先按严格 UTF-8 解，失败再回退到 Windows-1252，避免出现
    // 替换字符。不要用 Encoding.Default：系统启用 UTF-8 代码页时它也是 UTF-8。
    static readonly Encoding Latin1 = Encoding.GetEncoding(1252);

    static string DecodeText(byte[] b, int off, int len)
    {
        if (len <= 0) return "";
        try
        {
            return new UTF8Encoding(false, true).GetString(b, off, len);
        }
        catch (DecoderFallbackException)
        {
            try { return Latin1.GetString(b, off, len); }
            catch { return Encoding.UTF8.GetString(b, off, len); }
        }
    }

    static string HexStr(byte[] b, int off, int len)
    {
        if (b == null) return "";
        StringBuilder sb = new StringBuilder();
        for (int i = off; i < Math.Min(b.Length, off + len); i++) sb.Append(b[i].ToString("X2"));
        return sb.ToString();
    }

    static string J(string s)
    {
        if (s == null) return "null";
        StringBuilder sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            if (c == '"') sb.Append("\\\"");
            else if (c == '\\') sb.Append("\\\\");
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\r') sb.Append("\\r");
            else if (c == '\t') sb.Append("\\t");
            else if (c < 32) sb.Append("\\u").Append(((int)c).ToString("x4"));
            else sb.Append(c);
        }
        return sb.Append('"').ToString();
    }

    static string JA(List<string> items)
    {
        return "[" + string.Join(",", items.ToArray()) + "]";
    }

    static string StatusName(uint s)
    {
        switch (s)
        {
            case 0: return "SUCCESS"; case 1: return "FAILED"; case 2: return "NO_PROJECT";
            case 3: return "WRITE_PROTECTED"; case 4: return "NO_TARGET"; case 5: return "NO_TOOLSET";
            case 6: return "NOT_DEBUGGING"; case 7: return "ALREADY_PRESENT"; case 8: return "INVALID_NAME";
            case 9: return "NOT_FOUND"; case 10: return "DEBUGGING"; case 11: return "TARGET_EXECUTING";
            case 12: return "TARGET_STOPPED"; case 13: return "PARSE_ERROR"; case 14: return "OUT_OF_RANGE";
            case 25: return "BUILD_OK_WARNINGS"; case 26: return "BUILD_FAILED"; case 27: return "BUILD_CANCELLED";
            case 28: return "NOT_SUPPORTED"; case 29: return "TIMEOUT"; case 30: return "UNEXPECTED_MSG";
            case 31: return "VERIFY_FAILED"; case 32: return "NO_ADRMAP"; case 33: return "INFO";
            case 34: return "NO_MEM_ACCESS"; case 35: return "FLASH_DOWNLOAD"; case 36: return "BUILDING";
            case 37: return "HARDWARE"; case 38: return "SIMULATOR"; case 39: return "BUFFER_TOO_SMALL";
            default: return "STATUS_" + s;
        }
    }

    static string BuildCodeName(uint c)
    {
        switch (c)
        {
            case 1: return "OK"; case 2: return "OK_WARNINGS"; case 3: return "ERRORS";
            case 4: return "CANCELLED"; case 5: return "CLEANED"; default: return "CODE_" + c;
        }
    }

    // ================= 主流程 =================

    static int Main(string[] args)
    {
        try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }

        if (args.Length < 2)
        {
            Console.WriteLine("{\"ok\":false,\"error\":\"用法: UvSockClient.exe <port> <command> [args...] [--out file]\"}");
            return 2;
        }

        int port = int.Parse(args[0], CultureInfo.InvariantCulture);
        string command = args[1].ToLowerInvariant();
        string outFile = null;
        List<string> rest = new List<string>();
        for (int i = 2; i < args.Length; i++)
        {
            if (args[i] == "--out" && i + 1 < args.Length) { outFile = args[++i]; }
            else rest.Add(args[i]);
        }

        bool ok;
        string err = null;
        string resultJson;

        try
        {
            TcpClient tcp = new TcpClient();
            tcp.Connect("127.0.0.1", port);
            tcp.NoDelay = true;
            ns = tcp.GetStream();

            resultJson = Dispatch(command, rest);
            ok = true;
        }
        catch (Exception ex)
        {
            ok = false;
            err = ex.Message;
            resultJson = "null";
        }

        StringBuilder o = new StringBuilder();
        o.Append("{\"ok\":").Append(ok ? "true" : "false");
        o.Append(",\"command\":").Append(J(command));
        o.Append(",\"port\":").Append(port);
        if (err != null) o.Append(",\"error\":").Append(J(err));
        o.Append(",\"result\":").Append(resultJson);
        o.Append(",\"messages\":").Append(JA(messages));
        o.Append("}");

        string text = o.ToString();
        Console.WriteLine(text);
        if (outFile != null)
        {
            try { System.IO.File.WriteAllText(outFile, text, new UTF8Encoding(false)); } catch { }
        }
        return ok ? 0 : 1;
    }

    static string Dispatch(string cmd, List<string> a)
    {
        switch (cmd)
        {
            case "info":
            case "version":
                {
                    List<Msg> v = Simple(C_VER);
                    uint sockVer = 0;
                    foreach (Msg m in v) if (m.payload.Length >= 4) sockVer = BitConverter.ToUInt32(m.payload, 0);
                    List<Msg> e = Simple(C_EXTVERS);
                    string uvStr = "", sockStr = "";
                    foreach (Msg m in e)
                    {
                        if (m.payload.Length >= 132)
                        {
                            int ia = BitConverter.ToInt32(m.payload, 0);
                            int ib = BitConverter.ToInt32(m.payload, 4);
                            uvStr = CStr(m.payload, 128 + ia);
                            sockStr = CStr(m.payload, 128 + ib);
                        }
                    }
                    return "{\"uvsockVersion\":" + sockVer + ",\"uvision\":" + J(uvStr) + ",\"uvsock\":" + J(sockStr) + "}";
                }

            case "targets":
                return EnumStrings(C_PRJ_ENUM_TARGETS, A_TGT_START, A_TGT_ENU, A_TGT_END, "targets");

            case "curtarget":
            case "current-target":
                {
                    List<Msg> r = Simple(C_PRJ_GET_CUR_TARGET, IpathReq(false));
                    foreach (Msg m in r)
                        if (m.payload.Length >= 4) return "{\"target\":" + J(CStr(m.payload, 4)) + "}";
                    return "null";
                }

            case "settarget":
                {
                    Need(a, 1, "settarget <目标名>");
                    List<Msg> r = Simple(C_PRJ_SET_TARGET, PrjData(a[0]));
                    return StatusJson(r, "set target '" + a[0] + "'");
                }

            case "groups":
                return EnumStrings(C_PRJ_ENUM_GROUPS, A_GRP_START, A_GRP_ENU, A_GRP_END, "groups");

            case "files":
                {
                    // UV_PRJ_ENUM_FILES 请求格式是 SSTR（组名），不是 PRJDATA
                    byte[] data = SStr(a.Count > 0 ? a[0] : "");
                    List<Msg> r = Exchange(C_PRJ_ENUM_FILES, data,
                        m => m.isAsync && m.code == A_FILE_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    uint st = 0;
                    foreach (Msg m in r)
                    {
                        if (!m.isAsync) st = m.status;
                        if (m.isAsync && m.code == A_FILE_ENU && m.payload.Length >= 4)
                            items.Add(J(CStr(m.payload, 4)));
                    }
                    return "{\"group\":" + J(a.Count > 0 ? a[0] : "") + ",\"files\":" + JA(items) +
                           ",\"count\":" + items.Count + ",\"status\":" + st + "}";
                }

            case "outputname":
                {
                    List<Msg> r = Simple(C_PRJ_GET_OUTNAME, IpathReq(false));
                    foreach (Msg m in r)
                        if (m.payload.Length >= 4) return "{\"outputName\":" + J(CStr(m.payload, 4)) + "}";
                    return "null";
                }

            case "activefiles":
                {
                    List<Msg> r = Simple(C_PRJ_ACTIVE_FILES);
                    foreach (Msg m in r)
                        if (m.payload.Length >= 4) return "{\"activeFiles\":" + BitConverter.ToUInt32(m.payload, 0) + "}";
                    return "null";
                }

            case "debugtarget":
                {
                    // DBGTGTOPT: DWORD target:1 + DWORD :31 + DWORD nRes[10]
                    // target 位 = 0 硬件调试, 1 软件仿真
                    List<Msg> r = Simple(C_PRJ_GET_DBGTGT);
                    foreach (Msg m in r)
                        if (m.payload.Length >= 4)
                        {
                            uint t = BitConverter.ToUInt32(m.payload, 0) & 1u;
                            return "{\"target\":" + t + ",\"debugTarget\":" +
                                   J(t == 0 ? "hardware" : "simulator") + "}";
                        }
                    return "null";
                }

            case "set-debugtarget":
                {
                    Need(a, 1, "set-debugtarget <hardware|simulator>");
                    string v = a[0].ToLowerInvariant();
                    bool sim = (v == "simulator" || v == "sim" || v == "1" || v == "true");
                    byte[] b = new byte[44];
                    BitConverter.GetBytes(sim ? 1u : 0u).CopyTo(b, 0);
                    return StatusJson(Simple(C_PRJ_SET_DBGTGT, b), "set debug target to " + (sim ? "simulator" : "hardware"));
                }

            // ---- 构建类：收集异步输出直到 BUILD_COMPLETE ----
            case "build":
            case "rebuild":
            case "clean":
                {
                    uint c = cmd == "build" ? C_PRJ_BUILD : cmd == "rebuild" ? C_PRJ_REBUILD : C_PRJ_CLEAN;
                    List<Msg> r = Exchange(c, null, m => m.isAsync && m.code == A_BUILD_COMPLETE, 600000);
                    List<string> outLines = new List<string>();
                    uint code = 0; bool gotComplete = false;
                    foreach (Msg m in r)
                    {
                        // legacyPrj：payload 从偏移 0 起就是字符串
                        if (m.isAsync && m.code == A_BUILD_OUTPUT && m.payload.Length > 0)
                            outLines.Add(J(CStr(m.payload, 0)));
                        if (m.isAsync && m.code == A_BUILD_COMPLETE)
                        {
                            gotComplete = true;
                            code = m.status;   // PRJDATA.nCode = UVBUILDCODES
                        }
                    }
                    return "{\"action\":" + J(cmd) + ",\"completed\":" + (gotComplete ? "true" : "false") +
                           ",\"code\":" + code + ",\"codeName\":" + J(BuildCodeName(code)) +
                           ",\"lineCount\":" + outLines.Count + ",\"output\":" + JA(outLines) + "}";
                }

            case "cancel":
                return StatusJson(Simple(C_PRJ_CANCEL), "cancel build");

            case "flash":
                return StatusJson(Simple(C_PRJ_FLASH), "flash download");

            case "flash-erase":
                return StatusJson(Simple(C_PRJ_FLASH_ERASE), "flash erase");

            // ---- 调试类 ----
            case "dbg-enter":
                return StatusJson(Simple(C_DBG_ENTER), "enter debug");

            case "dbg-exit":
                return StatusJson(Simple(C_DBG_EXIT), "exit debug");

            case "dbg-status":
                {
                    List<Msg> r = Simple(C_DBG_STATUS);
                    foreach (Msg m in r)
                    {
                        if (m.status != 0)
                            return "{\"debugging\":false,\"status\":" + m.status +
                                   ",\"statusName\":" + J(StatusName(m.status)) +
                                   ",\"error\":" + J(ErrText(m)) + "}";
                        if (m.payload.Length >= 4)
                        {
                            uint n = BitConverter.ToUInt32(m.payload, 0);
                            // nVal 只有 0/1 两个观测值：0=目标已停止（停住可读寄存器），
                            // 1=目标正在运行。它不是位掩码，不要按位解释。
                            return "{\"debugging\":true,\"nVal\":" + n +
                                   ",\"running\":" + (n == 1 ? "true" : "false") + "}";
                        }
                    }
                    return "null";
                }

            case "reset":
                return StatusJson(Simple(C_DBG_RESET), "reset target");

            case "run":
                return StatusJson(Simple(C_DBG_RUN), "start execution");

            case "stop":
                return StatusJson(Simple(C_DBG_STOP), "stop execution");

            case "step":
                return StatusJson(Simple(C_DBG_STEP_HLL), "step over (HLL)");

            case "step-into":
                return StatusJson(Simple(C_DBG_STEP_INTO), "step into");

            case "step-asm":
                return StatusJson(Simple(C_DBG_STEP_ASM), "step instruction");

            case "step-out":
                return StatusJson(Simple(C_DBG_STEP_OUT), "step out");

            case "step-n":
                {
                    Need(a, 1, "step-n <次数>");
                    return StatusJson(Simple(C_DBG_STEP_HLL_N, U32(uint.Parse(a[0]))), "step " + a[0] + " lines");
                }

            case "step-into-n":
                {
                    Need(a, 1, "step-into-n <次数>");
                    return StatusJson(Simple(C_DBG_STEP_INTO_N, U32(uint.Parse(a[0]))), "step into " + a[0]);
                }

            case "step-asm-n":
                {
                    Need(a, 1, "step-asm-n <次数>");
                    return StatusJson(Simple(C_DBG_STEP_ASM_N, U32(uint.Parse(a[0]))), "step asm " + a[0]);
                }

            case "run-to":
                {
                    Need(a, 1, "run-to <地址>");
                    byte[] b = new byte[8];
                    BitConverter.GetBytes(ParseAddr(a[0])).CopyTo(b, 0);
                    return StatusJson(Simple(C_DBG_RUN_TO, b), "run to " + a[0]);
                }

            case "mem-read":
                {
                    Need(a, 2, "mem-read <地址> <字节数>");
                    ulong addr = ParseAddr(a[0]);
                    uint len = uint.Parse(a[1]);
                    List<Msg> r = Simple(C_DBG_MEM_READ, AMem(addr, len));
                    foreach (Msg m in r)
                    {
                        if (m.status != 0)
                            return "{\"error\":" + J(StatusName(m.status) + ": " + ErrText(m)) + "}";
                        if (m.payload.Length >= 24)
                        {
                            ulong ra = BitConverter.ToUInt64(m.payload, 0);
                            uint rb = BitConverter.ToUInt32(m.payload, 8);
                            uint rerr = BitConverter.ToUInt32(m.payload, 20);
                            int avail = m.payload.Length - 24;
                            int take = (int)Math.Min((uint)Math.Max(avail, 0), rb);
                            return "{\"address\":" + ra + ",\"requested\":" + rb + ",\"errCount\":" + rerr +
                                   ",\"bytes\":" + J(HexStr(m.payload, 24, take)) + "}";
                        }
                    }
                    return "null";
                }

            case "mem-write":
                {
                    Need(a, 2, "mem-write <地址> <十六进制字节串>");
                    ulong addr = ParseAddr(a[0]);
                    byte[] data = ParseHex(a[1]);
                    List<Msg> r = Simple(C_DBG_MEM_WRITE, AMemWrite(addr, data));
                    return StatusJson(r, "write " + data.Length + " bytes at 0x" + addr.ToString("X"));
                }

            case "eval":
                {
                    Need(a, 1, "eval <表达式>");
                    string expr = string.Join(" ", a.ToArray());
                    List<Msg> r = Simple(C_DBG_CALC, VSet(expr));
                    foreach (Msg m in r)
                    {
                        if (m.status != 0)
                            return "{\"expression\":" + J(expr) + ",\"error\":" + J(StatusName(m.status) + ": " + ErrText(m)) + "}";
                        if (m.payload.Length >= 12)
                        {
                            // vType=0（void）表示目标未停下、uVision 无法求值，
                            // 此时数值区是垃圾，必须报错而不是返回假数字。
                            if (IsVoidResult(m.payload))
                                return "{\"expression\":" + J(expr) +
                                       ",\"error\":\"TARGET_NOT_STOPPED: target is running, stop it before evaluating\",\"value\":null}";
                            return "{\"expression\":" + J(expr) + ",\"value\":" + TVAL(m.payload) + "}";
                        }
                    }
                    return "null";
                }

            case "eval-str":
                {
                    Need(a, 1, "eval-str <表达式>");
                    string expr = string.Join(" ", a.ToArray());
                    List<Msg> r = Simple(C_DBG_EVAL_STR, VSet(expr));
                    foreach (Msg m in r)
                    {
                        if (m.status != 0)
                            return "{\"expression\":" + J(expr) + ",\"error\":" + J(StatusName(m.status) + ": " + ErrText(m)) + "}";
                        // VSET: TVAL(12) + SSTR(260)；结果字符串在 SSTR.szStr (偏移 16)
                        if (m.payload.Length >= 20) return "{\"expression\":" + J(expr) + ",\"text\":" + J(VSetStr(m.payload)) + "}";
                    }
                    return "null";
                }

            case "watch":
                {
                    Need(a, 1, "watch <表达式>");
                    string expr = string.Join(" ", a.ToArray());
                    List<Msg> r = Exchange(C_DBG_WATCH, VSet(expr), m => !m.isAsync, readTimeoutMs);
                    foreach (Msg m in r)
                        if (m.status != 0)
                            return "{\"expression\":" + J(expr) + ",\"error\":" + J(StatusName(m.status) + ": " + ErrText(m)) + "}";
                    foreach (Msg m in r)
                        if (m.payload.Length >= 12)
                        {
                            if (IsVoidResult(m.payload))
                                return "{\"expression\":" + J(expr) +
                                       ",\"error\":\"TARGET_NOT_STOPPED: target is running, stop it before evaluating\",\"value\":null}";
                            return "{\"expression\":" + J(expr) + ",\"value\":" + TVAL(m.payload) + "}";
                        }
                    return "{\"expression\":" + J(expr) + ",\"value\":null}";
                }

            case "watch-del":
                {
                    Need(a, 1, "watch-del <索引>");
                    List<Msg> r = Simple(C_DBG_WATCH_DEL, U32(uint.Parse(a[0])));
                    return StatusJson(r, "remove watch " + a[0]);
                }

            case "bp-create":
                {
                    Need(a, 1, "bp-create <表达式> [类型:exec|read|write|rw|complex] [命中次数]");
                    uint type = 1;
                    if (a.Count > 1)
                    {
                        switch (a[1].ToLowerInvariant())
                        {
                            case "exec": type = 1; break;
                            case "read": type = 2; break;
                            case "write": type = 3; break;
                            case "rw": case "readwrite": type = 4; break;
                            case "complex": case "expr": type = 5; break;
                            default: type = 1; break;
                        }
                    }
                    uint count = a.Count > 2 ? uint.Parse(a[2]) : 1;
                    List<Msg> r = Simple(C_DBG_CREATE_BP, BkParm(type, count, 0, a[0]));
                    return StatusJson(r, "create breakpoint '" + a[0] + "'");
                }

            case "bp-enum":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_BP, null, m => m.isAsync && m.code == A_BP_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_BP_ENU && m.payload.Length >= 16)
                        {
                            // BKRSP: type(4) count(4) enabled(4) nTickMark(4) nAddress(8) nExpLen(4) szBuffer[]
                            uint bt = BitConverter.ToUInt32(m.payload, 0);
                            uint cnt = BitConverter.ToUInt32(m.payload, 4);
                            uint en = BitConverter.ToUInt32(m.payload, 8);
                            ulong adr = BitConverter.ToUInt64(m.payload, 16);
                            uint el = BitConverter.ToUInt32(m.payload, 24);
                            string expr = CStr(m.payload, 28);
                            items.Add("{\"type\":" + bt + ",\"count\":" + cnt + ",\"enabled\":" + (en != 0 ? "true" : "false") +
                                      ",\"address\":" + adr + ",\"exprLen\":" + el + ",\"expression\":" + J(expr) + "}");
                        }
                    return "{\"breakpoints\":" + JA(items) + "}";
                }

            case "bp-del":
                {
                    Need(a, 1, "bp-del <索引>");
                    // BKCHG: type(4) nTickMark(4) action(4) ... 用 action=2 删除
                    byte[] b = new byte[64];
                    BitConverter.GetBytes(1u).CopyTo(b, 0);
                    BitConverter.GetBytes(uint.Parse(a[0])).CopyTo(b, 4);
                    BitConverter.GetBytes(2u).CopyTo(b, 8);
                    return StatusJson(Simple(C_DBG_CHANGE_BP, b), "delete breakpoint " + a[0]);
                }

            case "adr2line":
                {
                    Need(a, 1, "adr2line <地址>");
                    byte[] b = new byte[40];
                    BitConverter.GetBytes(1u).CopyTo(b, 0);      // bFull
                    BitConverter.GetBytes(ParseAddr(a[0])).CopyTo(b, 8);
                    List<Msg> r = Simple(C_DBG_ADR2FL, b);
                    foreach (Msg m in r)
                        if (m.payload.Length >= 4) return "{\"fileLine\":" + J(CStr(m.payload, 4)) + "}";
                    return "null";
                }

            case "line2adr":
                {
                    Need(a, 2, "line2adr <文件> <行号>");
                    // AFLMAP (pack(1)): nLine@0(4) nAdr@4(8) iFile@12(4) iFunc@16(4) nRes[5]@20(20) szFile@40
                    byte[] fn = Encoding.UTF8.GetBytes(a[0]);
                    byte[] b = new byte[40 + fn.Length + 1];
                    BitConverter.GetBytes(uint.Parse(a[1])).CopyTo(b, 0);
                    Array.Copy(fn, 0, b, 40, fn.Length);
                    List<Msg> r = Simple(C_DBG_FL2ADR, b);
                    foreach (Msg m in r)
                    {
                        if (m.status != 0)
                            return "{\"ok\":false,\"status\":" + m.status + ",\"statusName\":" + J(StatusName(m.status)) +
                                   ",\"error\":" + J(ErrText(m)) + "}";
                        // 响应 VSET: TVAL(12) + SSTR(260)；地址在 TVAL.v (偏移 4)
                        if (m.payload.Length >= 12)
                        {
                            ulong addr = VSetAddr(m.payload);
                            return "{\"ok\":true,\"address\":\"0x" + addr.ToString("X8") +
                                   "\",\"addressDec\":" + addr + "}";
                        }
                    }
                    return "null";
                }

            case "stack":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_STACK, null, m => m.isAsync && m.code == A_STACK_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_STACK_ENU)
                            items.Add("{\"raw\":" + J(HexStr(m.payload, 0, Math.Min(64, m.payload.Length))) + "}");
                    return "{\"frames\":" + JA(items) + ",\"count\":" + items.Count + "}";
                }

            case "tasks":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_TASKS, null, m => m.isAsync && m.code == A_TASK_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_TASK_ENU && m.payload.Length >= 4)
                            items.Add(J(CStr(m.payload, 4)));
                    return "{\"tasks\":" + JA(items) + "}";
                }

            case "vars":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_VARS, null, m => m.isAsync && m.code == A_VAR_END, 20000);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_VAR_ENU)
                            items.Add("{\"raw\":" + J(HexStr(m.payload, 0, Math.Min(64, m.payload.Length))) + "}");
                    return "{\"variables\":" + JA(items) + ",\"count\":" + items.Count + "}";
                }

            case "vtr":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_VTR, null, m => m.isAsync && m.code == A_VTR_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_VTR_ENU && m.payload.Length >= 4)
                            items.Add(J(CStr(m.payload, 0)));
                    return "{\"vtrs\":" + JA(items) + ",\"count\":" + items.Count + "}";
                }

            case "reg-groups":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_REGGROUPS, null, m => m.isAsync && m.code == A_REGG_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_REGG_ENU && m.payload.Length >= 4)
                            items.Add(J(CStr(m.payload, 4)));   // SSTR: nLen@0, szStr@4
                    return "{\"registerGroups\":" + JA(items) + "}";
                }

            case "regs":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_REG, null, m => m.isAsync && m.code == A_REG_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                    {
                        if (!(m.isAsync && m.code == A_REG_ENU)) continue;
                        // REGENUM (pack(1), 53 bytes): nGi@0(2) nItem@2(2) szReg@4(16) flags@20(1) szVal@21(32)
                        if (m.payload.Length >= 53)
                        {
                            int nGi = BitConverter.ToUInt16(m.payload, 0);
                            int nItem = BitConverter.ToUInt16(m.payload, 2);
                            string regName = CStr(m.payload, 4);
                            string regVal = CStr(m.payload, 21);
                            byte flags = m.payload[20];
                            items.Add("{\"group\":" + nGi + ",\"item\":" + nItem +
                                      ",\"name\":" + J(regName) + ",\"value\":" + J(regVal) +
                                      ",\"isPC\":" + (((flags & 1) != 0) ? "true" : "false") +
                                      ",\"canChange\":" + (((flags & 2) != 0) ? "true" : "false") + "}");
                        }
                        else
                        {
                            items.Add("{\"raw\":" + J(HexStr(m.payload, 0, Math.Min(80, m.payload.Length))) + "}");
                        }
                    }
                    return "{\"registers\":" + JA(items) + ",\"count\":" + items.Count + "}";
                }

            case "reg-set":
                {
                    Need(a, 2, "reg-set <寄存器名或索引> <值>");
                    return StatusJson(Simple(C_DBG_REG_SET, VSet(a[0])), "set register " + a[0]);
                }

            case "menus":
                {
                    List<Msg> r = Exchange(C_DBG_ENUM_MENUS, null, m => m.isAsync && m.code == A_MENU_END, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_MENU_ENU && m.payload.Length >= 4)
                            items.Add(J(CStr(m.payload, 0)));
                    return "{\"menus\":" + JA(items) + ",\"count\":" + items.Count + "}";
                }

            case "dsm":
                {
                    Need(a, 2, "dsm <地址> <字节数>");
                    byte[] b = new byte[24];
                    BitConverter.GetBytes(ParseAddr(a[0])).CopyTo(b, 0);
                    BitConverter.GetBytes(uint.Parse(a[1])).CopyTo(b, 8);
                    List<Msg> r = Simple(C_DBG_DSM_READ, b);
                    foreach (Msg m in r)
                    {
                        if (m.status != 0)
                            return "{\"ok\":false,\"status\":" + m.status + ",\"statusName\":" + J(StatusName(m.status)) +
                                   ",\"error\":" + J(ErrText(m)) + "}";
                        // AMEM (pack(1)): nAddr(8) nBytes(4) ErrAddr(8) nErr(4) aBytes[] -> 数据从偏移 24
                        if (m.payload.Length > 24)
                        {
                            int nb = (int)BitConverter.ToUInt32(m.payload, 8);
                            return "{\"ok\":true,\"address\":\"0x" + BitConverter.ToUInt64(m.payload, 0).ToString("X8") +
                                   "\",\"requested\":" + nb +
                                   ",\"disassembly\":" + J(CStr(m.payload, 24)) + "}";
                        }
                    }
                    return "null";
                }

            case "time":
                {
                    List<Msg> r = Simple(C_DBG_TIME);
                    foreach (Msg m in r)
                        if (m.payload.Length >= 16)
                        {
                            ulong cyc = BitConverter.ToUInt64(m.payload, 0);
                            double ts = BitConverter.ToDouble(m.payload, 8);
                            return "{\"cycles\":" + cyc + ",\"timestamp\":" + ts.ToString(CultureInfo.InvariantCulture) + "}";
                        }
                    return "null";
                }

            case "serial-get":
                {
                    byte[] b = new byte[16];
                    BitConverter.GetBytes((ushort)3).CopyTo(b, 0);   // channel 3 = debug/printf
                    BitConverter.GetBytes((ushort)0).CopyTo(b, 2);
                    BitConverter.GetBytes((uint)4096).CopyTo(b, 4);
                    List<Msg> r = Exchange(C_DBG_SERIAL_GET, b, m => !m.isAsync, 2000);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        if (m.isAsync && m.code == A_SERIAL_OUTPUT && m.payload.Length >= 8)
                            items.Add(J(Encoding.UTF8.GetString(m.payload, 8, m.payload.Length - 8)));
                    return "{\"serial\":" + JA(items) + "}";
                }

            case "serial-put":
                {
                    Need(a, 1, "serial-put <文本>");
                    byte[] txt = Encoding.UTF8.GetBytes(a[0]);
                    byte[] b = new byte[8 + txt.Length];
                    BitConverter.GetBytes((ushort)3).CopyTo(b, 0);
                    BitConverter.GetBytes((ushort)0).CopyTo(b, 2);
                    BitConverter.GetBytes((uint)txt.Length).CopyTo(b, 4);
                    Array.Copy(txt, 0, b, 8, txt.Length);
                    return StatusJson(Simple(C_DBG_SERIAL_PUT, b), "serial put");
                }

            case "exec":
                {
                    Need(a, 1, "exec <uVision 命令>");
                    string line = string.Join(" ", a.ToArray());
                    List<Msg> r = Exchange(C_DBG_EXEC_CMD, ExecCmd(line),
                        m => !m.isAsync, 5000);
                    List<string> outLines = new List<string>();
                    uint st = 0;
                    foreach (Msg m in r)
                    {
                        if (m.isAsync && m.code == A_CMD_OUTPUT && m.payload.Length >= 8)
                            outLines.Add(J(CStr(m.payload, 8)));
                        if (!m.isAsync) st = m.status;
                    }
                    return "{\"command\":" + J(line) + ",\"status\":" + st +
                           ",\"statusName\":" + J(StatusName(st)) + ",\"output\":" + JA(outLines) + "}";
                }

            // ---- 窗口控制 ----
            case "ui-lock": return StatusJson(Simple(C_UI_LOCK), "ui lock");
            case "ui-unlock": return StatusJson(Simple(C_UI_UNLOCK), "ui unlock");
            case "show": return StatusJson(Simple(C_SHOW), "show");
            case "hide": return StatusJson(Simple(C_HIDE), "hide");
            case "minimize": return StatusJson(Simple(C_MIN), "minimize");
            case "maximize": return StatusJson(Simple(C_MAX), "maximize");
            case "restore": return StatusJson(Simple(C_RESTORE), "restore");
            case "exit": return StatusJson(Simple(C_EXIT), "exit uVision");
            case "license": return StatusJson(Simple(C_LICENSE), "check license");

            case "load":
                {
                    Need(a, 1, "load <工程路径>");
                    return StatusJson(Simple(C_PRJ_LOAD, PrjData(a[0])), "load project");
                }

            case "close":
                return StatusJson(Simple(C_PRJ_CLOSE), "close project");

            case "raw":
                {
                    Need(a, 1, "raw <十六进制命令码>");
                    uint c = Convert.ToUInt32(a[0], 16);
                    List<Msg> r = Exchange(c, null, m => !m.isAsync, readTimeoutMs);
                    List<string> items = new List<string>();
                    foreach (Msg m in r)
                        items.Add("{\"outer\":\"0x" + m.outer.ToString("X4") + "\",\"inner\":\"0x" + m.inner.ToString("X4") +
                                  "\",\"status\":" + m.status + ",\"hex\":" + J(HexStr(m.payload, 0, Math.Min(64, m.payload.Length))) + "}");
                    return "{\"raw\":" + JA(items) + "}";
                }

            default:
                throw new Exception("未知命令: " + cmd);
        }
    }

    static byte[] VSet(string expr)
    {
        // pack(1): TVAL = vType(4) + union v(8) = 12 字节；随后 SSTR(nLen@12, szStr@16)
        byte[] b = new byte[12 + 260];
        byte[] s = Encoding.UTF8.GetBytes(expr);
        BitConverter.GetBytes(s.Length + 1).CopyTo(b, 12);
        Array.Copy(s, 0, b, 16, Math.Min(s.Length, 255));
        return b;
    }

    // 读取 VSET 响应里的地址（TVAL.v 位于偏移 4）
    static ulong VSetAddr(byte[] p)
    {
        if (p.Length < 12) return 0;
        uint t = BitConverter.ToUInt32(p, 0);
        switch (t)
        {
            case 1: case 3: return p[4];
            case 2: return (ulong)(sbyte)p[4];
            case 7: return BitConverter.ToUInt16(p, 4);
            case 6: return (ulong)BitConverter.ToInt16(p, 4);
            case 5: return BitConverter.ToUInt32(p, 4);
            case 4: return (ulong)BitConverter.ToInt32(p, 4);
            default: return BitConverter.ToUInt64(p, 4);
        }
    }

    // 读取 VSET 响应里的字符串（SSTR.szStr 位于偏移 16）
    static string VSetStr(byte[] p)
    {
        return p.Length >= 20 ? CStr(p, 16) : "";
    }

    static string TVAL(byte[] p)
    {
        // pack(1): vType(4) + union v(8) = 12 字节，值从偏移 4 开始
        if (p.Length < 12) return "null";
        uint t = BitConverter.ToUInt32(p, 0);
        switch (t)
        {
            case 1: return ((BitConverter.ToUInt64(p, 4) & 1) != 0 ? "true" : "false");
            case 2: return ((sbyte)p[4]).ToString();
            case 3: return p[4].ToString();
            case 4: return BitConverter.ToInt32(p, 4).ToString();
            case 5: return BitConverter.ToUInt32(p, 4).ToString();
            case 6: return BitConverter.ToInt16(p, 4).ToString();
            case 7: return BitConverter.ToUInt16(p, 4).ToString();
            case 8: return BitConverter.ToInt32(p, 4).ToString();
            case 9: return BitConverter.ToUInt32(p, 4).ToString();
            case 10: return BitConverter.ToSingle(p, 4).ToString(CultureInfo.InvariantCulture);
            case 11: return BitConverter.ToDouble(p, 4).ToString(CultureInfo.InvariantCulture);
            case 12: return "0x" + BitConverter.ToUInt32(p, 4).ToString("X8");
            case 19: return BitConverter.ToInt64(p, 4).ToString();
            case 20: return BitConverter.ToUInt64(p, 4).ToString();
            default: return "{\"vType\":" + t + ",\"raw\":" + J(HexStr(p, 4, 8)) + "}";
        }
    }

    // 表达式求值的响应是 VSET = TVAL(12) + SSTR(260)。当 TVAL.vType 为
    // VTT_void(0) 时数值区无意义，真实结果在 SSTR.szStr（偏移 16）里。
    // 目标正在运行（未停下）时 uVision 就会这样回包，直接当成数字会读到垃圾。
    static bool IsVoidResult(byte[] p)
    {
        return p != null && p.Length >= 4 && BitConverter.ToUInt32(p, 0) == 0;
    }

    static string ErrText(Msg m)
    {
        // 错误响应：nRes1(4) nRes2(4) StrLen(4) str[]
        if (m.payload.Length >= 12)
        {
            uint sl = BitConverter.ToUInt32(m.payload, 8);
            if (sl > 0 && sl < 4096) return CStr(m.payload, 12);
        }
        return "";
    }

    static string StatusJson(List<Msg> r, string what)
    {
        uint st = 0; string errText = ""; bool got = false;
        foreach (Msg m in r)
        {
            if (!m.isAsync) { st = m.status; got = true; errText = ErrText(m); break; }
        }
        if (!got) return "{\"action\":" + J(what) + ",\"ok\":false,\"error\":\"无响应（超时）\"}";
        return "{\"action\":" + J(what) + ",\"ok\":" + (st == 0 ? "true" : "false") +
               ",\"status\":" + st + ",\"statusName\":" + J(StatusName(st)) +
               ",\"error\":" + J(errText) + "}";
    }

    static string EnumStrings(uint cmd, uint startA, uint enuA, uint endA, string key)
    {
        List<Msg> r = Exchange(cmd, null, m => m.isAsync && m.code == endA, readTimeoutMs);
        List<string> items = new List<string>();
        uint st = 0;
        foreach (Msg m in r)
        {
            if (!m.isAsync) st = m.status;
            if (m.isAsync && m.code == enuA && m.payload.Length >= 4)
                items.Add(J(CStr(m.payload, 4)));
        }
        return "{\"" + key + "\":" + JA(items) + ",\"count\":" + items.Count + ",\"status\":" + st + "}";
    }

    static void Need(List<string> a, int n, string usage)
    {
        if (a.Count < n) throw new Exception("参数不足。用法: " + usage);
    }

    static ulong ParseAddr(string s)
    {
        s = s.Trim();
        if (s.StartsWith("0x") || s.StartsWith("0X")) return Convert.ToUInt64(s.Substring(2), 16);
        return ulong.Parse(s, CultureInfo.InvariantCulture);
    }

    static byte[] ParseHex(string s)
    {
        s = s.Replace(" ", "").Replace("-", "");
        if (s.Length % 2 != 0) throw new Exception("十六进制串长度必须为偶数");
        byte[] b = new byte[s.Length / 2];
        for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(s.Substring(i * 2, 2), 16);
        return b;
    }
}
