# 实验：经 SSH 直接运行 Windows 上的 rhinomcp（无隧道）

对应坑 13 的对策之一。现方案是 Mac 上跑 rhinomcp、经隧道连 Windows 的 1999；
本实验改为让 Codex 直接启动 `ssh rhino-pc rhinomcp.exe`，MCP 的 stdio 由 SSH
承载，rhinomcp 在 Windows 本机连 `127.0.0.1:1999`。这样连接随 MCP 会话启停，
不再需要常驻隧道，Codex 也无从自行启动隧道。

> **2026-09-26 已执行，Q1–Q7 全部通过**，结果记录在 `docs/project-notes.md` 验证范围
> 与第 9 节。第 5 步必须用交互 TUI：`codex exec` 看不到 MCP 工具（坑 15）。

## 要回答的问题

| # | 问题 | 通过标准 |
|---|---|---|
| Q1 | SSH 承载的 stdout 是否干净（无横幅、PQ 警告、`\r`）？ | 探测脚本打印 `stdout clean`，退出码 0 |
| Q2 | 握手与工具列表正常？ | `initialize` ok，`tools: 70` |
| Q3 | 真实工具调用可用？ | `get_document_summary` 返回文档摘要，而非 `Could not connect` |
| Q4 | 大响应（截图 base64）是否完整、延迟可接受？ | `capture_viewport` 返回图片内容，耗时与隧道方式同量级 |
| Q5 | 会话结束后两端进程是否回收？ | Mac 无残留 ssh；Windows 无残留 `rhinomcp.exe` / `python.exe` |
| Q6 | Codex 实际能用？ | `/mcp` 显示 70 个工具，只读调用成功，退出后同 Q5 |
| Q7 | 失败时报错是否可理解？ | Rhino 未 `mcpstart`、Windows 不可达时，Codex 给出可定位的错误而非卡死 |

## 前置条件

- Windows：Rhino 8 已打开，命令行执行过 `mcpstart`。
- Mac：**不要开隧道**。确认 1999 未被占用，避免结果被隧道“帮忙”：
  ```sh
  lsof -nP -iTCP:1999 -sTCP:LISTEN   # 应无输出
  pgrep -fl rhino-tunnel             # 应无输出
  ```
- 以下命令在 Mac 上、项目根目录执行；Windows 路径中的 `<user>` 替换为你的 Windows 用户名。

## 步骤 1：确认 Windows 远程命令使用的 shell

```sh
ssh -o BatchMode=yes rhino-pc 'echo %USERPROFILE%'
```

- 输出 `C:\Users\<user>` → 默认 shell 是 cmd（后续命令按 cmd 语法）。
- 原样输出 `%USERPROFILE%` → 默认 shell 已改为 PowerShell，把后文 `set X=1&& cmd`
  改写为 `$env:X='1'; cmd`，并记录下来。

同时留意这条命令是否带出 PQ 警告等额外输出——警告走 stderr 不影响 MCP，
走 stdout 则 Q1 会失败。

## 步骤 2：在 Windows 安装 uv 与固定版本 rhinomcp

```sh
ssh rhino-pc 'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://astral.sh/uv/install.ps1 | iex"'
ssh rhino-pc 'C:\Users\<user>\.local\bin\uv.exe tool install rhinomcp==0.4.1.1'
ssh rhino-pc 'C:\Users\<user>\.local\bin\uv.exe tool list'
```

预期 `rhinomcp v0.4.1.1`，入口 `C:\Users\<user>\.local\bin\rhinomcp.exe`。
若 uv 装到了别处，以实际路径替换后文 `RMCP`。记录 uv 自动下载的 Python 版本。

## 步骤 3：探测脚本（Q1–Q4）

```sh
RMCP='C:\Users\<user>\.local\bin\rhinomcp.exe'
python3 experiments/mcp_stdio_probe.py --stderr /tmp/ssh_probe_err.log \
  --call get_document_summary \
  --call 'capture_viewport:{"width":800}' \
  -- ssh -T -o BatchMode=yes rhino-pc "set RHINO_MCP_TIMEOUT=30&& $RMCP"
echo "exit=$?"; cat /tmp/ssh_probe_err.log
```

注意 `30&&` 之间不能有空格，否则 cmd 会把空格算进变量值。
`RHINO_MCP_HOST/PORT` 默认值已是 `127.0.0.1:1999`，无需设置；
超时默认 15 秒，设成 30 与现配置一致。

记录：各行耗时与字节数、`total`、是否 `stdout clean`、stderr 内容。

**对照组**（可选，量化差异）：开隧道后用本机 rhinomcp 跑同样的调用：

```sh
scripts/rhino-tunnel.sh  # 另一个窗口
python3 experiments/mcp_stdio_probe.py --call get_document_summary \
  --call 'capture_viewport:{"width":800}' -- ~/.local/bin/rhinomcp
# 结束后 Ctrl-C 停隧道——顺便完成第 7 节“真实终端 Ctrl-C”待办
```

## 步骤 4：进程回收（Q5）

探测脚本结束（stdin EOF）后立即检查：

```sh
pgrep -fl 'ssh.*rhino-pc'                                            # Mac，应无输出
ssh rhino-pc 'tasklist | findstr /I "rhinomcp python uv"'            # Windows
```

uv 生成的 `rhinomcp.exe` 是启动器，实际进程可能是 `python.exe`，所以一并查。
注意别把 Rhino 自带的 Python 进程误判为残留（看 PID 与启动时间）。

再测**异常断开**：让一个会话挂着，直接杀掉 Mac 端 ssh，看 Windows 是否回收：

```sh
ssh -T -o BatchMode=yes rhino-pc "$RMCP" </dev/zero >/dev/null &   # 保持 stdin 打开
sleep 5; kill -9 $!
sleep 5; ssh rhino-pc 'tasklist | findstr /I "rhinomcp python"'
```

Windows OpenSSH 断线后子进程是否被结束是本实验最不确定的一点；如有残留，
记录现象，再试 `ServerAliveInterval` 触发的服务端超时（约 45 秒）后是否回收。

## 步骤 5：接入 Codex（Q6）

用 `-c` 临时覆盖，不改 `~/.codex/config.toml`：

```sh
codex \
  -c 'mcp_servers.rhino.command="ssh"' \
  -c 'mcp_servers.rhino.args=["-T","-o","BatchMode=yes","rhino-pc","set RHINO_MCP_TIMEOUT=30&& C:\\Users\\<user>\\.local\\bin\\rhinomcp.exe"]'
```

在 Codex 里：

1. `/mcp` —— rhino 应显示 70 个工具。
2. 让它“只调用 get_document_summary 并报告结果，不要修改文档”。
3. 退出 Codex，重复步骤 4 的两条检查。

配置里原有的 `[mcp_servers.rhino.env]` 此时只作用于 Mac 上的 ssh 进程，无害。

## 步骤 6：失败场景（Q7）

分别制造以下情况，各启动一次步骤 5 的 Codex 并执行 `/mcp` 与一次只读调用：

| 场景 | 制造方法 | 记录 |
|---|---|---|
| Rhino 未监听 | Rhino 里 `mcpstop`（或关掉 Rhino） | Codex 看到的报错原文 |
| Windows 不可达 | 断开 Windows 网络或关机 | 多久报错（ConnectTimeout 10s + startup_timeout 60s）、报错原文 |
| rhinomcp 路径错 | `args` 里故意写错路径 | 报错原文 |

## 记录结果

结果写入 `docs/project-notes.md`：验证范围表加一行，第 9 节加阶段记录，坑 13 的对策
更新为“已验证/不可行”。若全部通过，再讨论是否把它作为首版的默认连接方式
（写入第 8 节），及对 `rhino-tunnel.sh`、doctor 设计的影响。
