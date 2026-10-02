# meshlink 开发与维护记录

最后更新：2026-10-01。

## 项目概况

让 Mac 上的 AI agent（优先 Codex）通过 SSH 控制局域网内另一台 Windows 电脑上的
Rhino 8 建模。建模能力来自上游 [rhinomcp](https://github.com/jingcheng-chen/rhinomcp)；
本项目负责跨机连接、安装准备和故障诊断。

- **范围**：只做 Rhino 8。其他设计软件和整机远程控制不在范围内（2026-09-30 决定，
  见 §5）。
- **方向**：方向 C，把现有方案做成别人能下载安装的工具（Mac CLI、诊断、Windows
  准备脚本），规划见 §8。
- **正式名称**：meshlink（2026-10-01 用户确定），README 副标题保留 “RhinoMCP over SSH”。

本文只记录项目本身：现状、架构、决策、踩坑、待办、规划和阶段记录。接手步骤、
验证与记录方法、文档维护、隐私与发布等**工作规则**统一放在根目录
[AGENTS.md](../AGENTS.md)（`CLAUDE.md` 是它的符号链接），不在本文重复。
面向使用者的入口是 [README.md](../README.md) 与 [README.zh-CN.md](../README.zh-CN.md)。

## 当前状态

| 文件 | 用途 |
|---|---|
| [README.md](../README.md)、[README.zh-CN.md](../README.zh-CN.md) | 面向使用者的入口。 |
| [AGENTS.md](../AGENTS.md)、`CLAUDE.md` | 面向 AI agent 与维护者的工作规则；`CLAUDE.md` 是指向 `AGENTS.md` 的符号链接。 |
| [docs/remote-setup.md](remote-setup.md) | 英文连接指南（两种 SSH 方式、Windows OpenSSH 配置、排障、安全）。内容与上游 PR #63 的 `docs/REMOTE.md` 相同。 |
| `docs/project-notes.md` | 项目现状、决策、踩坑与规划的统一记录（本文）。 |
| [scripts/rhino-tunnel.sh](../scripts/rhino-tunnel.sh) | 选项 2 的 SSH 隧道守护脚本：端口占用检查、端口配置不一致警告、断线退避重连、信号清理。 |
| [scripts/doctor.sh](../scripts/doctor.sh) | 只读诊断（2026-10-01 首版）：从 `codex mcp get --json` 读取 Codex 实际使用的命令，逐段检查到一次真实的 MCP 工具调用。设计见 §8 首版范围。 |
| [scripts/prepare-windows.ps1](../scripts/prepare-windows.ps1) | W1 Windows 准备脚本（2026-10-01 首版），由用户在 Windows 管理员 PowerShell 中运行，职责见 §5。 |
| [tests/prepare-windows-checklist.md](../tests/prepare-windows-checklist.md) | W1 脚本的手动测试清单，以及尚未实测的路径。 |
| [scripts/setup.sh](../scripts/setup.sh)、[scripts/client-codex.sh](../scripts/client-codex.sh) | Mac 端首次配置与 Codex 配置（2026-10-01 首版），职责见 §8 首版范围；共用代码在 `scripts/lib/common.sh`（doctor 也用）。 |
| [bin/meshlink](../bin/meshlink) | 统一命令 `meshlink`（2026-10-01）：只做分发，子命令转到 `scripts/` 下的脚本；导出 `MESHLINK_CLI`，让各脚本的提示写成 `meshlink ...`。 |
| [install.sh](../install.sh)、[uninstall.sh](../uninstall.sh)、[scripts/package.sh](../scripts/package.sh)、`VERSION` | 安装到 `~/.local`、卸载、打包（2026-10-01 首版），职责见 §8 首版范围。 |
| [tests/test-install.sh](../tests/test-install.sh) | 在临时 HOME 中验证打包、安装、升级、卸载与 `meshlink` 分发的 8 组场景（37 项断言）。 |
| [tests/test-setup.sh](../tests/test-setup.sh) | 在临时 HOME 中用 fake ssh、ssh-keyscan、codex 验证 setup 与 client-codex 的 12 组场景（54 项断言）。 |
| [tests/test-doctor.sh](../tests/test-doctor.sh) | 用 fake codex 与 fake ssh 验证 doctor 的 12 组场景（48 项断言）。 |
| [tests/test-rhino-tunnel.sh](../tests/test-rhino-tunnel.sh) | 用 fake SSH 验证隧道脚本的退出清理、断线分类与重连行为。 |
| [experiments/](../experiments/) | MCP stdio 探测脚本：Python 版 `mcp_stdio_probe.py`（`--hold` 可在调用后保持会话，用于断网实验）；纯 bash 3.2 版 `mcp_stdio_probe.sh`（一次工具调用并给出判定，验证 doctor 不依赖 Python 的可行性）。另有选项 1 的实验步骤 `ssh-stdio-test.md`。 |
| `private-notes.md`（不入库） | 真实主机地址、用户名、个人配置和个人环境问题；在 `.gitignore` 中。 |

现有内容是一份经过实测的连接指南、一个只读诊断脚本 `scripts/doctor.sh`、一个隧道
脚本，以及两者的模拟测试；Windows 准备脚本 `scripts/prepare-windows.ps1` 及其手动测试
清单；Mac 端 `scripts/setup.sh` 与 `scripts/client-codex.sh`；统一命令 `meshlink`
（`bin/meshlink`）、`install.sh` / `uninstall.sh` 与打包脚本 `scripts/package.sh`。
尚无已发布的版本、依赖清单或 CI。代码在公开仓库 `rigelmansid/meshlink`（`public`
分支，见 §5）。默认连接方式为选项 1（SSH stdio，见 §5），前提是 Windows sshd 设置
`ClientAliveInterval`（§3、坑 16）。首版范围已定（§8，版本号除外）。阶段 2 的脚本与
安装首版都已完成（2026-10-01）；剩下的主要是真实环境验收：全新 Windows（含
Windows 11）上的 W1 脚本、真实安装与卸载、首次 Release（§7）。

### 验证范围

| 时间与来源 | 已确认的内容 | 适用范围 |
|---|---|---|
| 2026-09-16 至 09-17，原搭建记录 | Mac 到 Windows Rhino 的真实链路已跑通（选项 2）。 | 当时的指定环境，不代表当前连接状态或其他机器兼容性。 |
| 2026-09-18，原搭建记录 | 核对上游源码，纠正 `RHINO_MCP_ALLOW_REMOTE` 的含义；记录了信号清理与重连测试经验。 | 历史结论，此后未重新核对上游。 |
| 2026-09-22，静态检查 | 隧道脚本与测试脚本均存在、可执行，并通过 `bash -n`。 | 仅静态检查。 |
| 2026-09-24，模拟测试 | `test-rhino-tunnel.sh` 24 项全部通过（约 41 秒），退出码 0；测试后端口、子进程和临时目录均无残留。 | 仅限模拟 SSH，环境见 §4；未验证真实 Rhino 链路或真实终端 `Ctrl-C`。 |
| 2026-09-25 23:06–00:05，真实使用 | 全链路可用（选项 2）：Codex 通过 Rhino MCP 完成一次卡车建模，`get_document_summary`、C# 执行、视口截图、保存 3dm 均成功；两个文件分别含 711 与 1204 个对象，0 个无效几何。 | 证据来自 Codex 会话日志（2026-09-26 事后核查）。环境：Codex CLI 0.155.1、Rhino 8.35.26237.11001。发现 Codex 自行启动隧道及进程残留问题，见坑 13。 |
| 2026-09-26 22:10–23:05，SSH stdio 实验 | 选项 1 可用：不开隧道，经 `ssh rhino-pc rhinomcp.exe` 在 Windows 上运行 rhinomcp；stdout 只含 JSON（PQ 警告与日志走 stderr，行尾 `\r\n` 可被解析）；握手 + 70 个工具；`get_document_summary` 与 250 KB 视口截图成功（首次握手约 2.7–3.1 s，之后单次调用 0.1–0.3 s）；Codex TUI 调用成功；正常结束、退出 Codex、`kill -9` ssh 三种情况下两端进程均回收。失败场景：`mcpstop` 后返回可读的 `Could not connect` 文本（`isError` 为 false）；路径写错时 ssh 退出；主机不可达约 11 s 后 ssh 退出码 255。 | 环境：Windows 默认 shell 为 cmd；uv 0.12.19、rhinomcp 0.4.1.1、Python 3.14.7；Codex CLI 0.155.1。主机不可达用未占用 IP 模拟；网络中断（无 RST）时 Windows 进程回收未测；只测了只读调用与截图，未做完整建模。 |
| 2026-09-28，整理目录后 | 移到 `tests/` 后 `test-rhino-tunnel.sh` 24/24 通过，两个脚本 `bash -n` 通过。 | 仅模拟 SSH。 |
| 2026-09-30 22:34 至 10-01 00:17，选项 1 断网回收实验 | 会话挂起时断开 Windows Wi-Fi（无 RST）。Mac 端 ssh 每轮都在断网后约 45–60 s 以 255 退出，无残留。Windows 端：sshd 默认配置下 `rhinomcp.exe` 与两个 `python.exe` 在恢复联网后仍残留（至少到 22:42:12），孤儿占着一条到 Rhino 1999 的连接，但不妨碍新会话；设置 `ClientAliveInterval 15` / `ClientAliveCountMax 3` 后，Windows 本机每 5 s 记录一次，进程与 sshd 连接在 00:14:07–00:14:12 之间消失，即断网后约 46–66 s，此时 Windows 仍未联网（首条 Wi-Fi 重连事件 00:14:42）。只读调用 `get_document_summary` 每轮成功。 | 环境：macOS 26.6.2、OpenSSH_10.3p1（Mac）；Windows 10 22H2 自带 OpenSSH Server（版本未记录）；rhinomcp 0.4.1.1；Rhino 版本未记录。断网时刻由 Mac 端 ssh 退出时间反推。默认配置下的孤儿后来在 22:42–23:27 之间以未知机制消失（坑 16）。两种配置下 OpenSSH 日志都没有该会话的断开记录。只测了断开 Windows Wi-Fi；Mac 断网、睡眠、长时间断网未测。计时有效的只有 1 轮（第 3 轮首次尝试时监视脚本启动过晚，作废）。 |
| 2026-10-01 00:32–01:13，选项 1 断线后 Codex 恢复 | Codex TUI 中只读调用成功后，断开 Windows Wi-Fi，Mac 端 ssh 退出（00:36:12、01:07:27）后再恢复。嵌入模式（`-c`）与正常模式（`config.toml`，由后台守护进程拉起 ssh）结果一致：同一会话显示 `rhino: failed`，调用报 `Transport closed`，不会自动重连；退出 TUI 后重新启动 Codex，`connected (70 tools)`，只读调用成功（坑 17）。重启后 Windows 上只剩新会话的进程。 | 环境：Codex CLI 0.159.2（自 0.155.1 自动升级）、macOS 26.6.2、rhinomcp 0.4.1.1，Windows sshd 已设 `ClientAliveInterval`。每种模式只测了 1 次；只做了只读调用。 |
| 2026-10-03，`prepare-windows.ps1` 报告去掉 `-l` | 修改后按手动清单在原环境运行 A（`-WhatIf`）、B（实际运行）、E（错误公钥）。 | **用户口头确认通过，没有截图或输出留存**，具体输出未经核对。脚本拷贝前后哈希一致；运行后用户已删除临时拷贝。 |
| 2026-10-02 23:09 至 10-03 00:20，方案 A：原环境上的全新账户验收 | Mac 端经 `meshlink` 真实运行全新流程：`setup --host rhino-test --user rhino-test --key <新密钥>` 生成密钥、写入 Host 条目、打印 Windows 命令；临时删除 `known_hosts` 中该 PC 的记录后，交互核对指纹回答 no 时不写入、回答 yes 时写入并登录成功（ssh 随后按 `UpdateHostKeys` 补回 RSA 与 ECDSA，`known_hosts` 内容与测试前一致）。Windows 端新建普通账户 `rhino-test`：未登录过时 `prepare-windows.ps1` 报 FAIL 并提示 `runas`；登录一次后新装公钥、权限通过、给出以该账户安装 uv 的命令；按命令装好后重跑无改动；sshd 改为手动并停止后重跑，恢复为自动并启动；无默认注释的 `sshd_config` 副本中两项插在 `Match` 之前。`client codex` 写入临时 `CODEX_HOME`，doctor 在 Rhino 未监听时报两项 FAIL 并提示 `mcpstart`，`mcpstart` 后 9 OK、1 WARN（测试机 UAC 设置）、MCP 往返约 2 s。测试后两端清理，`~/.ssh/config` 与测试前备份逐字节一致，真实 Codex 配置未改。 | 发现并修复两处：`setup` 生成的密钥注释原为 user@host，会把 Mac 主机名带到 PC 与屏幕上（改为固定的 `meshlink`）；重跑 `setup` 不带 `--key` 时用默认密钥而非 Host 条目里的密钥（改为读取条目）；另修正远端报错末尾缺换行。防火墙一项没有测到“新增规则”：PC 上原本另有一条名为 `sshd` 的规则，按我给的清理命令被删除，已由用户恢复。未覆盖的路径见 `tests/prepare-windows-checklist.md`。 |
| 2026-10-02 00:16–00:30，首次预发布 `v0.1.0-dev` | 发布前检查压缩包：内容中无个人信息与替换字符；元数据中发现打包人的 Mac 登录名与 `com.apple.provenance` 扩展属性（坑 21），修正 `scripts/package.sh` 后重打，属主为 `root:wheel`，原始字节中无扩展属性、用户名、本机路径。`gh release create` 建预发布 `v0.1.0-dev`，指向 `c83f064`（与 `origin/main` 一致），附压缩包与 `.sha256`；下载回来 `shasum -c` 通过，且与本地构建逐字节一致。 | 私有仓库，未公开。Release 说明列出已验证与未验证的范围。 |
| 2026-10-01 23:56，原环境真实安装 | 用 `scripts/package.sh` 打包、`shasum -c` 校验通过，解压到临时目录后运行其中的 `install.sh`：装到 `~/.local/share/meshlink`，`~/.local/bin/meshlink` 为两行启动文件，`~/.local/bin` 已在 PATH 中所以没有提示。在 `/tmp` 下经 `meshlink` 运行：`version`、`windows-script` 正常；`setup --host rhino-agent` 判定已配置好，提示措辞为 `meshlink client codex ...`；`client codex --host rhino-agent` 判定已一致，未改写，随后 doctor 9 OK、1 WARN（测试机 UAC 设置），MCP 往返约 2 s。 | 只验证了“已配置好的环境上什么都不改”的路径。卸载没有在原环境运行（安装保留）。Codex 0.159.3。 |
| 2026-10-01 16:30–17:00，安装与 `meshlink` 命令（模拟） | `tests/test-install.sh` 37/37：打包内容与 `install.sh --list` 完全一致、校验值可验证、无 `._` 文件；安装、PATH 提示、各子命令分发与提示措辞、升级后无残留目录；不覆盖他人的 `~/.local/bin/meshlink`；拒绝从已安装副本运行 `install.sh`；卸载只删本工具文件，保留其他工具、`~/.ssh` 与 Codex 条目（回答 no），`--remove-codex` 时先备份再删。另做 6 处人为破坏，均被发现。 | 只在临时 HOME 中运行，未在原环境真实安装（§7）。调试中发现并修正两处：比较安装路径时 `//` 与符号链接导致误判（改用 `pwd -P`）；测试 I7 在管道右侧调用函数，`$?` 来自上一场景（改用 here-string）。 |
| 2026-10-01 15:53–15:58，`setup.sh` 与 `client-codex.sh` 在原环境运行 | `setup.sh --host rhino-agent --user rhino-agent`：复用已有密钥，在第一个 `Host` 之前插入新条目（文件其余部分与备份一致），主机指纹与 `known_hosts` 一致，测试登录成功，未进入 Windows 步骤。`client-codex.sh --host rhino-agent`：先回答 no，列出将丢失的 3 个 env、`startup_timeout_sec = 60`、7 个工具审批，`config.toml` 未改；再用 `--yes` 覆盖，生成备份，写入后读回一致。与备份对比发现 `codex mcp add` 重写了整个文件、删掉全部注释（坑 19），于是用备份恢复、只改 `args` 一行；之后 `client-codex.sh` 判定已一致，doctor 9 OK、1 WARN（测试机 UAC 设置）。模拟测试 `tests/test-setup.sh` 54/54，另有 6 处人为破坏均被发现。 | 原环境已配置好，所以 `setup.sh` 的“新密钥、Windows 步骤、交互核对指纹”路径只在模拟中验证。Codex 0.159.3。 |
| 2026-10-01 15:24–15:40，W1 `scripts/prepare-windows.ps1` 首版 | 在原环境 Windows 10 22H2（PowerShell 5.1.19041.6456）由用户在管理员 PowerShell 中按 `tests/prepare-windows-checklist.md` 运行 A–E：A（`-WhatIf`，专用账户）全部 OK、无改动；B（实际运行）无 `[DONE]`，重复运行安全，`sshd -T` 读出 15/3；C（`sshd_config` 副本，两项为注释）在原行替换、位于 `Match` 之前、生成备份、`sshd -t` 通过、未重启；D（以管理员账户为目标，`-WhatIf`）警告管理员，`administrators_authorized_keys` 与权限 OK，uv 与 rhinomcp 0.4.1.1 OK；E（错误公钥）FAIL。脚本打印的主机指纹与 Mac `known_hosts` 一致。 | 原环境已配置好，所以“改动”路径只有 C 在副本上实际执行过；清单末尾列出的路径未运行。修复了两处：`-WhatIf` 下模块自动加载打印的 `Set Alias` 行；公钥检查原在 sshd 与防火墙步骤之后（E 暴露），已移到最前，移动后未重跑 E。Mac 端没有 PowerShell，无自动化测试。 |
| 2026-10-01 15:09–15:20，`scripts/doctor.sh` 首版 | 真实环境（选项 1，`rhino-agent` 登录）：9 项 OK、1 项 WARN（测试机 UAC 设置），端到端 `get_document_summary` 约 2 s，退出码 0；`SERVER=nope` 时报 FAIL 并跳过其余，退出码 1。模拟测试 `tests/test-doctor.sh` 48/48 通过（约 6 s）。另做了 4 处人为破坏（漏数 stdout 污染、UAC 判断失效、去掉 doctor 自加的 `BatchMode=yes`、GBK 解码失效），每处都被测试发现；其中第 3 处是在补了 D9 的断言之后才被发现。 | 环境：Codex 0.159.3、macOS bash 3.2.57。真实环境只跑了“全部正常”和“配置里没有该 server”两种情况，其余失败场景只在模拟中验证。选项 2 只在模拟中验证。“已写入 `sshd_config`”不等于“已生效”，doctor 读不到 `sshd -T`。 |
| 2026-10-01 14:51，bash 版 MCP 探测 | `experiments/mcp_stdio_probe.sh` 用 macOS 自带 bash 3.2.57 经 ssh（`rhino-agent`）测试 6 种情况，判定与退出码都正确：正常 → `OK`，退出码 0；端口错 → `RHINO NOT LISTENING`；rhinomcp 路径错 → `server exited (code 1)`，附转码后的 Windows 报错；远端多输出一行横幅 → `STDOUT POLLUTION`；工具名不存在 → `TOOL ERROR`；地址不可达 → `server exited (code 255)`。每次都没有残留临时目录或 ssh 进程。 | “Rhino 未监听”用错误端口模拟，没有真正执行 `mcpstop`。不可达地址用 192.0.2.1 模拟，本机得到的是立即返回的 `Connection closed by 192.0.2.1 port 22`，而不是超时，原因未查（可能与本机网络环境有关）。只测了单次只读工具调用。 |
| 2026-10-01 14:29–14:31，方案 B：专用普通账户登录 SSH | 新建本地普通账户 `rhino-agent`（只在 Users 组），在其目录下放公钥、装 uv 与 rhinomcp 0.4.1.1。用同一把密钥以 `-l rhino-agent` 登录：会话只在 Users 组、Medium 完整性级别。该账户下的 rhinomcp 跨账户连上了另一个桌面账户里的 Rhino：握手 3.1 s，`get_document_summary` 0.26 s，stdout 干净。只读 C# 调用显示代码以桌面账户身份在 Rhino 进程内执行，`IsInRole(Administrator)=True`。原因是测试机 UAC 关闭（`EnableLUA=0`）。 | 账户与 uv 安装由用户在 Windows 本机执行。只在 UAC 关闭的测试机上测过，UAC 开启时 Rhino 不带管理员权限这一点是 Windows 的默认行为，**本项目未实测**。只做了只读调用。14:37 起 Codex 0.159.2（正常模式）经该账户登录，只读调用成功；Mac 端 ssh 进程参数含 `-l rhino-agent`。 |

最近一次确认的端到端可用：选项 2 是 2026-09-25 的真实建模，选项 1 是 2026-09-26 的
实验。此后环境若有变化（升级、重启、换网络），以一次只读 Rhino 工具调用为准。

---

## 1. 架构

两种连接方式都用 SSH 密钥登录 Windows，Rhino 的端口在两台机器上都只留在 loopback。

**选项 1：SSH stdio**（2026-09-26 实测）。MCP 客户端直接启动 ssh，rhinomcp 在
Windows 上运行，连本机的 Rhino。

```
Mac                                   Windows
MCP 客户端 ──stdio──► ssh ═══SSH═══► rhinomcp.exe ──127.0.0.1:1999──► Rhino 8 + rhinomcp 插件
```

**选项 2：SSH 端口转发**（原方案，2026-09-25 完整建模实测）。rhinomcp 在 Mac 上运行，
`scripts/rhino-tunnel.sh` 把 Windows 的 1999 端口转发到 Mac 本机。

```
Mac                                                                 Windows
MCP 客户端 ──stdio──► rhinomcp ──127.0.0.1:1999──► ssh -L ═══SSH═══► 127.0.0.1:1999 ──► Rhino 8 + rhinomcp 插件
```

| | 选项 1 | 选项 2 |
|---|---|---|
| rhinomcp 在哪 | Windows | Mac |
| 需要常驻的进程 | 无，客户端按会话启动 ssh | `ssh -L` 隧道 |
| Windows 上需要 | OpenSSH Server、uv、rhinomcp | OpenSSH Server |
| 结束后清理 | 客户端退出时两端都退出；断网（无 RST）时靠 Windows sshd 的 `ClientAliveInterval` 回收（坑 16） | 需要手动停隧道 |
| 默认 | 是（2026-10-01 起，§5） | 备选 |

关键点（对应上游 rhinomcp 0.4.1.1，升级后需重新确认）：

- Rhino 插件的监听**只绑 127.0.0.1**，上游没有改绑网卡的配置，局域网上的机器直接
  连不到。跨机只能通过 SSH，这不是“更安全的选项”，而是唯一的方式。
- 桥接协议本身**没有认证**。所以客户端拨号目标也保持 127.0.0.1，
  `RHINO_MCP_ALLOW_REMOTE` 刻意不设（语义见 §5）。
- rhinomcp 当时向客户端提供 **70 个工具**。

---

## 2. 原部署环境

以下为历史部署值，此后未重新检查。主机地址、用户名和个人路径已替换为占位符，
实际值保存在不入库的 `private-notes.md`。

| 项 | 值 |
|---|---|
| Mac | 与 Windows 同一局域网，macOS 26（arm64） |
| Windows | `<pc-address>`，用户 `<windows-user>`，Win10 22H2 build 19045.6466 |
| SSH 登录账户 | 2026-10-01 起 Codex 用专用普通账户 `rhino-agent` 登录（方案 B，§5）；15:53 起由 `setup.sh` 在 `~/.ssh/config` 新增 `Host rhino-agent`，Codex 参数不再带 `-l`，uv 与 rhinomcp 0.4.1.1 装在该账户目录下；另有一个 Host 条目供维护和诊断 |
| meshlink | 2026-10-01 起从发布包安装 0.1.0-dev：文件在 `~/.local/share/meshlink`，命令 `~/.local/bin/meshlink` |
| Rhino | 8（插件仅支持 8，7 装不上）；2026-09-25 观察到 8.35.26237.11001 |
| rhinomcp | 0.4.1.1（PyPI）；Mac 上用 `uv tool install` 安装，Windows 上 2026-09-26 同版本安装在用户目录 |
| Codex | 2026-09-25/26 会话为 CLI 0.155.1（npm 安装，经 nvm 的 Node）；2026-10-01 上午 0.159.2，15:09 已自动升到 0.159.3（坑 14） |
| 桥接端口 | 1999 |

---

## 3. 各处配置

### `~/.ssh/config`（Mac）：连接参数的唯一来源

```
Host rhino-pc
    HostName <pc-address>
    User <windows-user>
    IdentityFile ~/.ssh/id_ed25519_rhino
    IdentitiesOnly yes
    ConnectTimeout 10
    ServerAliveInterval 15
    ServerAliveCountMax 3
```

`setup` 生成的密钥默认不设 passphrase（为了无人值守连接）。
代价：拿到该私钥即可免密登入 Windows，**勿同步到网盘或复制到其他机器**。

### `scripts/rhino-tunnel.sh`（Mac，选项 2）

主机、用户、密钥、keepalive 全部从 ssh config 读取，脚本内不重复声明。带端口占用
保护和断线退避重连。

- 退避判据是**转发是否真正绑定过**（探测本地端口是否监听过），并结合本次 SSH
  进程运行时长：绑定过且运行至少 5 秒，重试延迟重置为 `BASE_DELAY`（默认 5 秒）；
  否则延迟翻倍，最大为 `MAX_DELAY`（默认 60 秒）。计时从启动 SSH 前开始，包含
  连接和认证时间。
- ssh 与退避 sleep 都作为后台子进程运行并用 `wait` 等待；INT/TERM/HUP 任一信号都会
  在 trap 里终止并回收当前子进程（机制见坑 12）。
- 环境变量：`HOST`（默认 `rhino-pc`）、`LOCAL_PORT`、`REMOTE_PORT`（均默认 `1999`）、
  `CODEX_CONFIG`（默认 `~/.codex/config.toml`）、`BASE_DELAY`、`MAX_DELAY`。更换本地
  端口必须同步修改 Codex 的 `RHINO_MCP_PORT`；远端端口与 Rhino 实际监听一致，通常
  保持 `1999`。旧的 `PORT=` 用法以退出码 2 拒绝执行。

### `~/.codex/config.toml`（Mac）

选项 2（原部署一直使用的配置）：

```toml
[mcp_servers.rhino]
type = "stdio"
command = "/Users/<mac-user>/.local/bin/rhinomcp"
args = []
startup_timeout_sec = 60

[mcp_servers.rhino.env]
RHINO_MCP_HOST = "127.0.0.1"
RHINO_MCP_PORT = "1999"
RHINO_MCP_TIMEOUT = "30.0"
```

选项 1（2026-10-01 起写入原环境的常用配置，原文件备份为 `config.toml.bak-20261001`）：

```toml
[mcp_servers.rhino]
command = "ssh"
args = ["-T", "-o", "BatchMode=yes", "rhino-pc", "set RHINO_MCP_TIMEOUT=30&& C:\\Users\\<windows-user>\\.local\\bin\\rhinomcp.exe"]
startup_timeout_sec = 60
```

选项 1 的服务端环境变量要写在远端命令里：客户端配置中的 `env` 只作用于 Mac 上的
ssh 进程。Windows OpenSSH 的默认远端 shell 是 cmd，`30&&` 之间不能有空格。

用专用普通账户登录时（方案 B，§5），在 `args` 里加 `"-l", "<agent-user>"`，并把路径
换成该账户下的 `C:\Users\<agent-user>\.local\bin\rhinomcp.exe`（写进 TOML 时反斜杠要成对）。原环境 2026-10-01
起使用这种写法，修改前的备份为 `config.toml.bak-20261001-1430`。

Codex 0.159.2 的相关行为（2026-10-01 观察）：
- `type = "stdio"` 会被忽略，并在启动时给出警告；stdio 本来就是默认值，可以删掉。
- 正常启动时，MCP server（这里就是 ssh）由共享的后台守护进程 `codex app-server
  --managed-daemon` 拉起，而不是由 TUI 拉起。带 `-c` 覆盖时 Codex 改用嵌入模式，
  MCP server 挂在 TUI 下。两种模式的进程归属不同，测试时要注明用的是哪一种。
- 改完 `config.toml` 后重开 TUI 即生效，已在运行的守护进程也用上了新配置。
- `codex mcp add <name> -- <command...>` 写入 `[mcp_servers.<name>]`。同名条目已存在时
  **整条替换**：原有的 `startup_timeout_sec`、`env`、`tools.*` 审批设置全部丢失，不提示、
  不备份。而且它会**重写整个 `config.toml`**：删掉所有注释，其他条目被重新排版（键的
  顺序、`120` 写成 `120.0`、省略 `args = []`），值不变（坑 19）。**更正**：此前写的
  “其他 server 和顶层设置保持不变”来自一份没有注释的临时配置，不准确。

### `C:\ProgramData\ssh\sshd_config`（Windows，选项 1 必需）

```
ClientAliveInterval 15
ClientAliveCountMax 3
```

作用：断网且没有 RST 时，sshd 约 45–60 秒后自行结束会话，回收 Windows 上的
rhinomcp 与 python 进程。默认值 0 时会残留（坑 16）。

- **原地替换**默认文件第 66–67 行被注释的 `#ClientAliveInterval 0`、
  `#ClientAliveCountMax 3`，不要追加到文件末尾：默认文件以
  `Match Group administrators` 块结尾，追加的行会落进该块，只对管理员生效。
- 需要管理员 PowerShell。先备份；用 `sshd.exe -t` 检查语法（无输出、退出码 0），
  通过后 `Restart-Service sshd`；用 `sshd.exe -T | Select-String clientalive` 确认生效。
  写回时覆盖原文件内容，不要删除重建，否则可能丢掉文件 ACL。
- 2026-09-30 已在原环境按此修改，备份为 `sshd_config.bak-20260930`。

---

## 4. 日常使用

### 前置条件

- **Windows**：Rhino 8 与 rhinomcp 插件；OpenSSH Server，公钥位置与权限见坑 2，防火墙
  见坑 3；`sshd_config` 已设 `ClientAliveInterval`（§3）；用户目录下已用 uv 装好固定
  版本的 rhinomcp（§5）。
- **Mac**：`~/.ssh/config` 有 Host 条目；Codex 配置用选项 1（均见 §3）。
- 首次连接时要核对并接受主机指纹。`BatchMode=yes` 下的 ssh 不会交互询问，指纹没
  接受过就会直接失败。

用脚本完成以上配置的顺序（2026-10-01 起）：Windows 上装好 OpenSSH Server 和 Rhino
插件 → Mac 上 `scripts/setup.sh --address <pc-address> --user <windows-user>`，它会
打印要在 Windows 管理员 PowerShell 里运行的 `prepare-windows.ps1` 命令，并在之后
核对主机指纹 → `scripts/client-codex.sh` → `scripts/doctor.sh`。

### 启动与停止

```bash
# ① Windows 的 Rhino 命令行
mcpstart            # 每个 Rhino 会话都要重跑一次

# ② Mac 终端
codex               # Codex 经 ssh 在 Windows 上启动 rhinomcp，不需要另开窗口
```

③ **最终验收：调一次只读工具**（如 `get_document_summary`）。`/mcp` 显示
`rhino: connected` 只说明 rhinomcp server 活着，不说明 Rhino 可达（坑 8）。报
`Could not connect to Rhino at 127.0.0.1:1999` 时，在 Rhino 里运行 `mcpstart` 后重试。

停止：退出 Codex（`/quit`）即可，两端进程随之结束。关掉 Rhino 的监听用 `mcpstop`。

**断线后**（Wi-Fi 断开、Windows 睡眠等）：`/mcp` 显示 `rhino: failed`，调用报
`Transport closed`，Codex 不会自动重连。网络恢复后退出 Codex 再重新启动即可（坑 17）。
Windows 上遗留的进程由 sshd 在约 1 分钟内回收（坑 16）。

选项 1 不需要隧道，不要为它运行 `rhino-tunnel.sh`。

### 快速排查

先运行 `scripts/doctor.sh`：它只读，按下面的顺序自动检查，并给出下一步提示。需要
手动定位时，按链路逐段检查，前一段不通就不必往后查：

```bash
# 1. Codex 实际用的是哪种连接方式：command 应为 ssh
codex mcp get rhino

# 2. SSH 登录（认证失败查坑 2、5；连不上查坑 3、4）
ssh -o BatchMode=yes rhino-pc "echo ok"

# 3. 不经 Codex，直接测 MCP 层
python3 experiments/mcp_stdio_probe.py --call get_document_summary -- \
  ssh -T -o BatchMode=yes rhino-pc "set RHINO_MCP_TIMEOUT=30&& C:\Users\<windows-user>\.local\bin\rhinomcp.exe"

# 4. Windows 上的残留进程：没有 Codex 会话时应无输出
ssh rhino-pc "tasklist | findstr /I rhinomcp"
```

第 3 步的结果：
- 报 `server exited`：检查 rhinomcp.exe 路径和 Windows 上的 `uv tool list`。
- 返回 `Could not connect`：Rhino 没有运行 `mcpstart`。
- 有 `STDOUT POLLUTION`：远端输出混入了非 JSON 内容。
- 调用成功：链路本身没问题，回头查 Codex，比如重开 Codex、检查它的版本（坑 14）。

第 4 步有残留时，在 Windows 管理员 PowerShell 里运行
`C:\Windows\System32\OpenSSH\sshd.exe -T | Select-String clientalive`，确认两项设置已
生效（§3）。

### 备选：选项 2（端口转发）

需要把 Codex 配置换回 §3 的选项 2 写法。

```bash
# ① Windows 的 Rhino 命令行
mcpstart

# ② Mac 窗口 A
scripts/rhino-tunnel.sh   # 保持开着；断线时脚本自动退避重连

# ③ Mac 窗口 B
codex
```

验收同样是一次只读工具调用。隧道本地监听成功，不说明 Windows 侧 `mcpstart` 在跑：
远端要等每条连接建立时才拨号（坑 11）。停止隧道：在运行脚本的终端按 `Ctrl-C`。

排查：

```bash
lsof -nP -iTCP:1999 -sTCP:LISTEN  # 本地端口占用和实际绑定地址（坑 9、10）
ssh -v rhino-pc                   # 手动检查 SSH 配置与认证
```

端口存在但请求失败时，继续检查 Windows 上的 `mcpstart`、远端端口及 Codex 配置
（坑 11）。本地端口检查不能替代只读 Rhino 工具调用。

### 本地模拟测试

运行命令、前置条件和结果解读规则见 [AGENTS.md](../AGENTS.md) 的 Commands 与
Verification 两节。测试覆盖的场景：隧道运行中单独发送 SIGTERM、退避期间发送
SIGTERM、进程组 SIGHUP，以及正常断线、未连接、短连接抖动的重试行为；另有
`BatchMode=yes` 参数存在性检查。

最近一次运行：2026-09-28 整理目录后，24/24 通过（运行环境未单独记录）。环境记录
最完整的一次是 2026-09-24 23:24：

| 项 | 结果 |
|---|---|
| 环境 | macOS 26.6.2（arm64）、系统 bash 3.2.57、Python 3.9.6、OpenSSH_10.3p1（未被调用，测试用 fake ssh） |
| 语法检查 | 两个脚本 `bash -n` 通过 |
| 行为测试 | T1–T4c 及 BatchMode 检查共 24 项通过、0 失败，退出码 0，总耗时约 41 秒 |
| 清理 | 端口 29931–29936 已释放，无残留隧道/fake ssh 进程，临时目录已删除 |

已知问题：T4a 在 15 秒窗口内观察到 2 次断线，恰好等于断言下限（≥2）。机器繁忙或
CI 较慢时可能偶发失败；整理测试时应放宽窗口或改为事件驱动判断。

---

## 5. 已做的决策与理由

### Windows 账户：推荐专用普通账户登录 SSH，兼容管理员账户（2026-10-01）

**决定**：两种账户都支持。文档推荐方案 B：建一个专用的普通账户，只用于 SSH 登录，
uv 和 rhinomcp 装在它名下；Rhino 照常在用户自己的桌面账户下运行。方案 A，直接用
日常的管理员账户登录，继续支持，但文档要写明风险。不推荐方案 C，即专用账户同时
用来运行 Rhino：用户每次都得切换 Windows 账户。

**依据**（2026-10-01 实测，见验证范围）：
- 跨账户可行：专用账户名下的 rhinomcp 能连上另一个账户桌面上 Rhino 的
  127.0.0.1:1999。
- 专用账户的 SSH 会话只在 Users 组，Medium 完整性级别。管理员账户的 SSH 会话是
  High 完整性，不经 UAC 就能修改系统。
- 另外，`administrators_authorized_keys` 对所有管理员账户都生效。

**关键限制**：代码执行工具（C#、Python、`run_command`）在 **Rhino 进程**里运行，
权限是 Rhino 的，与 SSH 账户无关。
- UAC 开启时（Windows 默认），管理员用户日常启动的 Rhino 不带管理员权限，方案 B
  确实能把密钥泄露的后果限制在“普通用户 shell + 以桌面用户身份、无管理员权限地
  执行代码”。
- UAC 关闭，或 Rhino 以管理员身份运行时，经 Rhino 仍然能拿到完整的管理员权限，
  方案 B 的收益很小。测试机就是这种情况。

→ W1 准备脚本和 doctor 都要检查 `EnableLUA`，并检查 Rhino 是否以已提权身份运行；
不满足时给出警告，但不阻止使用。安全说明要写明：真正的边界是 Rhino 进程的权限。

**替代**：此前的“安全说明建议专用非管理员账户”指的是方案 C（专用账户同时用于 SSH
和 Rhino），由本条取代。

### Mac 端 CLI 用 bash 实现（2026-10-01）

**决定**：Mac 端 CLI 用 bash 实现，兼容 macOS 自带的 bash 3.2，与现有隧道脚本和测试
保持同一套。写入 MCP 客户端配置时，调用客户端自带的命令（Codex 用
`codex mcp add/get/remove`），不自己解析 TOML。

**理由**：
- 零依赖。选项 1 已经让 Mac 上不再需要 uv 和 Python；新装的 macOS 上
  `/usr/bin/python3` 只是占位程序，调用时会弹出安装开发者工具的提示。
- doctor 要用到的 ssh、lsof 等都是 shell 工具。
- Go 或 Rust 单文件二进制要搭编译发布流程，还要做 macOS 签名和公证，对首版来说成本
  太高。

**代价**：
- `codex mcp add` 覆盖已有条目时会丢掉原来的设置（§3）。CLI 覆盖前必须先备份，并
  告诉用户哪些设置会丢失。
- doctor 的 MCP 层检查要在 bash 里收发 JSON-RPC。2026-10-01 已验证可行：
  `experiments/mcp_stdio_probe.sh` 在 bash 3.2 下用两个 FIFO 完成握手和一次工具调用，
  能区分 6 种情况（见验证范围）。
- 以后要精确合并配置时，再考虑为这一部分单独引入 Python。

### Windows 端提供 PowerShell 准备脚本（W1）（2026-10-01）

**决定**：首版提供一个兼容 Windows PowerShell 5.1 的准备脚本，由用户在 Windows 本机
以管理员身份运行。脚本可以重复执行，并支持 `-WhatIf` 预览。

脚本负责：
- 防火墙规则；
- 按账户类型放置公钥、设置 ACL（坑 2），公钥作为参数传入；
- 在 `sshd_config` 中原地设置 `ClientAliveInterval`，语法检查通过后重启 sshd（§3）；
- 安装 uv 和固定版本的 rhinomcp。**实现时调整（2026-10-01）**：脚本以管理员身份运行，
  uv 只能装进当前账户的目录，所以只在 `-User` 就是当前账户时安装；`-User` 是其他账户
  （例如专用普通账户）时，只检查该账户下是否已有 rhinomcp.exe，没有就打印在
  `runas /user:<账户> powershell` 窗口里要执行的两条命令；
- 最后输出一份检查报告：`sshd -T` 的生效值、rhinomcp 路径、1999 是否在监听。

仍由用户手动完成：
- 安装 OpenSSH Server。脚本只检查状态并给出指引，因为 `Add-WindowsCapability` 可能
  卡死（坑 1）；
- 安装 Rhino 插件；
- 运行 `mcpstart`；
- 在 Mac 上核对主机指纹。

脚本不负责创建 Windows 账户。

**理由**：2026-09-30 手动修改 `sshd_config` 时，原地替换、避开 `Match` 块、语法检查、
保留 ACL，每一步都容易出错，适合由脚本来做。这类系统修改需要管理员权限，也不适合从
Mac 经 ssh 远程执行。

**未选的方案**：只写文档（W0）；连 OpenSSH 一起自动安装（W2）。

### 默认连接方式：选项 1（SSH stdio）（2026-10-01）

**决定**：首版默认使用选项 1，由 MCP 客户端按会话启动 `ssh rhino-pc rhinomcp.exe`。
选项 2（端口转发 + `rhino-tunnel.sh`）保留为文档中的备选。

**理由**：
- 没有常驻隧道，从根本上消除坑 13（agent 自行启动隧道、进程残留），CLI 也不需要
  `tunnel` 子命令。
- 客户端正常退出或 ssh 被杀时，两端进程都会回收（2026-09-26 实测）；断网且没有 RST
  时，设置 `ClientAliveInterval` 后 Windows 端约 1 分钟内回收（2026-09-30 实测，见验证
  范围与坑 16）。

**代价与前提**：
- Windows 上要装 uv 和固定版本的 rhinomcp，升级也在 Windows 上做。
- 每次会话首次握手约 1.3–3 s。
- Windows sshd 必须设置 `ClientAliveInterval`（§3），这一项要进 Windows 准备脚本和
  doctor 的检查。

### 只做 Rhino，方向 C（2026-09-30）

**决定**：项目范围收敛到 Rhino 8 一条线，把现有方案做成可安装的工具（方向 C）。
其他设计软件（Revit、AutoCAD 等）和整机远程控制不在范围内；相关调研、讨论和
“通用 Mac→Windows MCP 桥”（方向 D）的规划已从仓库删除，需要时从本地 git 历史找回。

**理由**：Rhino 这条线已经有真实可用的链路和完整的排障经验，先把它做成别人能装、
能诊断的工具，比同时铺开多个软件更可控。

**替代的旧决策**：2026-09-28 的方向复盘选了方向 B（给上游提文档 PR + 写踩坑总结），
C 暂缓、D 视反馈而定。B 的文档 PR 已提交（见下），不再作为主方向；踩坑总结文章仍在
§7 待办中。

### 本地 `main` 不推送，从孤立分支 `public` 发布（2026-09-28 决定，2026-10-01 执行）

**决定**：本地 `main` 分支及其全部历史永远不推送到任何远端，只作为本地归档。对外
发布使用孤立分支 `public`：它从一个只含当前文件的提交开始，与 `main` 没有共同历史，
跟踪 `origin/main`（仓库 `rigelmansid/meshlink`，2026-10-02 起公开）。之后的开发与推送都在 `public`
上进行。规则写在 [AGENTS.md](../AGENTS.md) 的 Privacy and publishing 一节。

**原因一：早期提交的文件内容含个人信息。** 项目最初是个人部署记录，直接写入了真实的
局域网 IP、Mac 用户名、Windows 用户名和个人路径。2026-09-28 整理目录时（提交
`549e553`），这些内容从入库文件中删除，移到不入库的 `private-notes.md`。但 git 的删除
只是新增一个提交，旧版本仍完整保留在历史中，任何拿到仓库的人都能用 `git show <旧提交>`
看到原文。2026-10-01 核对：`main` 上从第一个提交 `ef2e08d`（09-23）到 `d388a7d`（09-28）
共 8 个提交，其文件中仍能查到上述信息。

**原因二：每个提交的作者信息都是本机身份。** `main` 上全部提交的作者与提交者邮箱都是
git 自动生成的本机默认身份，由 Mac 用户名和电脑名组成。这部分在提交元数据里，改文件
内容去不掉，只能改写每一个提交。

**原因三：推送后难以收回。** git 推送的是整段历史，不只是最新文件。内容一旦到了
GitHub，就可能被 fork、缓存或索引，事后删除仓库或强制推送也不能保证完全收回。仓库
当时是私有的，但规则按“以后可能公开”来定；2026-10-02 已公开。

**为什么不改写历史**：用 `git filter-repo` 之类的工具改写全部提交，可以去掉文件内容和
作者信息，但要逐项列出需要替换的内容，容易漏掉，结果也难以核实；改写后的 `main` 与
本地记录不再一致。另起孤立分支更简单可靠：只有一个提交，内容是已脱敏、推送前又全文
检查过的当前文件，作者是 `Cheng Yuan` 与 GitHub noreply 地址。

**代价**：GitHub 上看不到 2026-09-16 以来逐步开发的提交历史。这段过程以文字形式保留在
本文 §9 阶段记录中，随 `public` 一起发布；完整的提交历史只在本地 `main`。

**配套做法**：
- 本仓库的 git 配置把提交身份设为 `Cheng Yuan` 与 noreply 地址，`push.default` 设为
  `upstream`，在 `public` 上直接 `git push` 即推到 `origin/main`。
- 推送前检查入库文件中没有真实 IP、用户名、主机名和个人路径（AGENTS.md 给出了检查
  命令），并检查没有替换字符 U+FFFD（坑 20）。
- 如果有人在 `main` 上提交，这些提交不会被推送；要发布的改动必须在 `public` 上。

**2026-10-02 转为公开前再次压缩历史**：用户要求公开前去掉描述测试机安全状态的措辞（UAC 关闭、管理员账户、密钥无 passphrase 等）和验证记录里的时区。这些内容也在 `public` 的旧提交里，只改当前文件不够，所以把 `public` 的 7 个提交（其中 5 个已推送到当时的私有仓库）压成一个新的孤立提交，强制推送到 `origin/main`，并把 `v0.1.0-dev` 的标签移到新提交（附件不变）。压缩前的 `public` 保留在本地分支 `public-presquash`，与 `main` 一样永不推送。被覆盖的旧提交在 GitHub 上成为悬空对象；仓库此前一直私有，这些提交哈希从未公开。

### 上游文档 PR #63（2026-09-28 提交）

- [jingcheng-chen/rhinomcp#63](https://github.com/jingcheng-chen/rhinomcp/pull/63)，
  标题 `docs: add guide for using RhinoMCP from another computer`。
- 内容：新增 `docs/REMOTE.md`（选项 1、选项 2、Windows OpenSSH 配置、关键坑、安全
  说明），中英文 README 各加一小节指向它。仅文档，无代码改动。文档正文即本仓库的
  `docs/remote-setup.md`。
- 提交前上游 README 与 issue 均无跨机使用说明；补丁基于上游 `70b63a2`。
- Fork 与分支：`rigelmansid/rhinomcp` 的 `docs/remote-setup`；署名 `Cheng Yuan`，
  使用 GitHub noreply 邮箱。
- PR 中的测试说明如实区分：选项 2 用于完整建模；选项 1 只测过只读调用、截图与进程
  回收；`mcpServers` JSON 示例未在具体客户端实测。
- 2026-10-01 追加一个提交：选项 1 一节补充断网后的进程残留与 `ClientAliveInterval`
  设置（坑 16）。本仓库 `docs/remote-setup.md` 同步修改。
- 2026-10-01 再追加一个提交：Security 一节改为推荐专用普通账户只用于 SSH，并说明
  执行工具的权限取决于 Rhino 进程本身（UAC），见 §5 账户类型决定。本仓库同步修改。

### 跨机一跳交给 SSH，不让客户端直连远程目标

链路两端各有一个“地址”，由不同的东西控制，不要混成一个开关：

| | 归属 | 控制者 | 本方案的值 |
|---|---|---|---|
| 插件监听地址 | Windows 侧 `mcpstart` 的 TCP listener | 插件自身，只绑 127.0.0.1，**无配置可改** | 127.0.0.1 |
| 客户端拨号目标 | rhinomcp（`RHINO_MCP_HOST`/`PORT`） | MCP 客户端配置 | 127.0.0.1 |

`RHINO_MCP_ALLOW_REMOTE` 属于**第二行**：它是客户端的出站闸门，上游 `server.py`
的判定是 "Refuse non-loopback connect targets unless the operator opts in
explicitly"。设为 1 只是允许客户端拨非 loopback 目标，**不改变 Rhino 侧监听绑定**。
（曾误以为它能让插件绑到局域网口，2026-09-18 核对上游源码后纠正。）

桥接协议无认证，所以两端各留一道边界：插件只听 loopback（上游决定）、客户端只拨
loopback（不设 ALLOW_REMOTE），SSH 在中间提供加密和密钥认证，并顺带绕开 Windows
防火墙问题。

### 保留全部代码执行工具

`run_command`、RhinoScript-Python、RhinoCommon C# 三条执行通道全开（对应
`RHINO_MCP_ENABLE_*` 三个开关，设 0 可分别关闭）。

理由：复杂建模需求模型会自己写脚本完成，不受预置工具限制。风险由 SSH 边界控制。
代价要如实写进安全说明：SSH 密钥 + 代码执行工具 = 对该 Windows 账户的完整代码执行
权限。

### 固定 rhinomcp 版本，不用 `uvx rhinomcp@latest`

| | `uvx rhinomcp@latest` | 固定版本 |
|---|---|---|
| 启动耗时 | 3.1s | 0.56s |
| PyPI 不可达时 | 重试 12.5s 后**彻底失败** | 0.69s 正常启动 |
| 版本决定权 | 上游今天发了什么 | 你测过的那一版 |

第二项最关键：控制局域网内的 Rhino 本不需要外网，没必要把整条链路绑在 PyPI 可达性上。
另外服务端和 Rhino 插件的版本必须一致。

```bash
uv tool list                          # 看当前版本
uv tool upgrade rhinomcp              # 主动升级
uv tool install rhinomcp==0.4.1.1     # 回滚
```

### 守护连接禁用交互认证（BatchMode=yes）

ssh 的密码提示和指纹确认读的是 **/dev/tty 而非 stdin**，bash 把后台子进程的 stdin
重定向到 /dev/null 挡不住它们，而隧道脚本刻意跑在用户的终端窗口里。一旦触发提示
（远端 authorized_keys 权限回归导致密钥被拒；或 Windows 重装 sshd 导致指纹变化），
整个守护循环会卡在一个没人看得见的提问上。

所以 ssh 命令带 `-o BatchMode=yes`：一切提示变成即时失败，由绑定探测归类为
never connected 走退避，问题打在日志里。这与“密钥无 passphrase 以支持无人值守重连”
是同一个设计决策的两半。选项 1 的客户端配置同样带 `BatchMode=yes`。

代价：密钥失效时不能顺手输密码，那本来就不该是守护脚本的能力。
**首次指纹确认是手动安装步骤**：连一台新机器前先手动 `ssh rhino-pc` 一次。

### 暂不设置 `mcpstart` 随 Rhino 自动执行（待定项）

Rhino 支持在 `Tools → Options → General → "Run these commands every time Rhino starts"`
填入 `mcpstart`。**目前不做**，原因是没必要，而不是有害：

- 单次 10 秒观测中，Rhino 空闲时监听的 CPU 增量为 0 ms（阻塞式 accept），也不碰
  文档和 undo 记录。这只能说明“该次未观察到影响”。
- 用之前总要主动做一步（开隧道或启动客户端），把这一步从 Windows 侧的 `mcpstart`
  挪走并没有净收益。

若将来改变主意，需要知道两个副作用：端口对该 Windows 上的**任何本地进程**开放；
agent 的改动与手动建模共用同一个 undo 栈，可能互相撤销。

### 许可证与文档语言（2026-09-28）

MIT 许可证，署名 `Cheng Yuan`。英文主 README + 中文 `README.zh-CN.md`；开发记录
（本文）保持中文。

---

## 6. 踩过的坑

按踩到的顺序。这部分是整个搭建过程里最难重新获得的信息。

### Windows 侧

1. **`Add-WindowsCapability` 长时间无响应** — 它从 Windows Update 拉 FoD 包，几分钟正常，
   但 `wuauserv` 被停用或走 WSUS 时会挂死。排查：`Get-WindowsCapability -Online -Name OpenSSH.Server*`
   看 State；绕过方案 `winget install Microsoft.OpenSSH.Beta` 或图形界面可选功能。

2. **管理员账户的公钥不放 `~/.ssh/authorized_keys`** — 要放
   `%ProgramData%\ssh\administrators_authorized_keys`，且**必须**用 `icacls` 收紧权限，
   否则 sshd 静默忽略该文件：
   ```powershell
   # S-1-5-32-544 = BUILTIN\Administrators, S-1-5-18 = NT AUTHORITY\SYSTEM
   icacls "$env:ProgramData\ssh\administrators_authorized_keys" /reset
   icacls "$env:ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "*S-1-5-32-544:F" "*S-1-5-18:F"
   icacls "$env:ProgramData\ssh\administrators_authorized_keys"   # 验证终态
   ```
   三个细节，缺一个 sshd 都可能继续**静默**拒绝（现象与没放公钥完全一致）：
   - **`/reset` 在前**：`/inheritance:r` 只摘掉**继承**的 ACE、`/grant` 只动**同名
     账户**的 ACE——此前排障留下的其他账户显式授权一条都不会掉。`/reset` 先把
     ACL 打回纯继承，整个序列幂等，终态确定为恰好两条 ACE。
   - **SID 而非组名**：组名靠 `LookupAccountName` 解析，德文系统是
     `Administratoren`、法文是 `Administrateurs`；中文系统恰好保留英文组名，但
     那是运气不是保证。`*` 前缀是 icacls"按 SID 解释"的语法要求。
   - **验证终态**：最后一条命令的输出必须**恰好两条 ACE**（显示名随系统语言变，
     数条数）。多一条即按"sshd 会拒绝"处理。若恰好两条仍失败，再查文件**所有者**
     是否属于 Administrators——sshd 连所有者一起查；管理员账户创建的文件天然满足，
     从别处复制来的可能不满足。

3. **装了 OpenSSH 但没加防火墙规则** — 现象与没装完全一致。别漏：
   ```powershell
   New-NetFirewallRule -Name sshd -DisplayName "OpenSSH Server (sshd)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
   ```

4. **ping 不通不代表机器有问题** — Windows 防火墙默认丢 ICMP。用端口探测判断可达性。

### Mac 侧

5. **非默认文件名的密钥不会被自动提交** — `id_ed25519_rhino` 不在 ssh 默认尝试列表里，
   裸跑 `ssh <windows-user>@<pc-address>` 会退回去要密码。解法是 ssh config 里显式
   `IdentityFile` + `IdentitiesOnly yes`。

6. **Codex 子进程的 PATH 不含 `~/.local/bin`** — `config.toml` 里的 `command`
   必须写绝对路径，写裸 `uvx` 或 `rhinomcp` 会 command not found。

### 协议/流程侧

7. **`mcpstart` 每个 Rhino 会话都要重跑** — 忘了的表现见下条。

8. **连不上时的真实行为**（曾被误判为"静默超时"，实测纠正）：
   端口无人监听时是 TCP 层立即 RST，1 秒内失败，且提示明确：
   ```
   Could not connect to Rhino at 127.0.0.1:1999.
   Please start Rhino, run the Rhino command `mcpstart`, then retry the MCP request.
   ```
   但这只是 WARNING 不是致命错误，**server 照常启动**，所以 `/mcp` 里 rhino 仍显示
   `connected`——看不出问题。错误要到第一次调工具时才浮现。
   `RHINO_MCP_TIMEOUT` 管的是连上之后读写卡住，不管连接建立失败。

9. **绝不用进程名匹配来检测隧道** — `pgrep -f "1999:localhost:1999"` 给过假阴性：
   隧道实际在跑，只是命令行写成了 `-L 127.0.0.1:1999:127.0.0.1:1999`。
   `-L` 至少有四种等价写法。**按端口探测**：`lsof -nP -iTCP:1999 -sTCP:LISTEN`。

10. **`-L` 必须写全两端地址，省略本地 bind address 是安全隐患** —
    省略时 ssh 按 `GatewayPorts` 决定绑哪里，而该设置住在 ssh_config 里、不在本脚本中。
    实测对照（强制 `GatewayPorts=yes`）：

    | 写法 | 实际绑定 |
    |---|---|
    | `-L 2999:localhost:1999` | `*:2999`（IPv4 + IPv6 全网卡） |
    | `-L 127.0.0.1:2999:127.0.0.1:1999` | `127.0.0.1:2999` |

    前者等于把无认证的 Rhino 接口摆到局域网上——**正是我们选隧道方案要避开的状态**，
    且无任何报错。显式 bind address 会覆盖 `GatewayPorts`，这是 ssh 保证的行为。

    远端同样写死 `127.0.0.1`：Rhino 监听是 IPv4-only，若 Windows 把 `localhost`
    解析到 `::1`，转发会表现为"端口在但连不上"。

    教训更一般化：优化②把配置挪进 `~/.ssh/config` 是对的，但副作用是脚本行为开始
    依赖外部文件。**安全边界不能由另一个文件的某一行决定**。

    → doctor 脚本应检查隧道实际绑定地址，发现 `*:1999` 或 `0.0.0.0:1999` 要报警。

11. **链路上有三个端口，只有两个该一起动** — 曾用单个 `PORT` 变量同时设置隧道两端，
    导致文档承诺的换端口方案本身是坏的。

    | 端口 | 归属 | 可变性 |
    |---|---|---|
    | Mac 本地监听 | rhinomcp 拨号目标 | 端口冲突时要改 |
    | `RHINO_MCP_PORT`（codex 配置） | 客户端拨的号 | **必须等于**上一项 |
    | Windows 远端 | Rhino `mcpstart` 监听口 | 由 Rhino 决定，别动 |

    `PORT=2999` 会把第一、三项一起改掉而第二项不动，三者两两不匹配。

    失败方式极难排查：`ExitOnForwardFailure` **只校验本地绑定**，远端是每条连接
    建立时才拨号——所以隧道正常启动、脚本打印连接成功，但每个建模请求都失败。

    现已拆成 `LOCAL_PORT` / `REMOTE_PORT`，并且脚本会读 codex 配置比对
    `RHINO_MCP_PORT`，不一致时警告。旧的 `PORT=` 用法直接报错退出（退出码 2）
    而非静默忽略。

    → doctor 脚本应同时核对这三个端口是否自洽。

12. **bash 在前台命令执行期间推迟 trap 执行** — 曾有版本 trap 只 `exit`、ssh 跑在前台。
    终端 Ctrl-C 把 SIGINT 发给整个前台进程组，ssh 先死，所以平时看不出问题；但单独
    对脚本发 SIGTERM 时，bash 要等前台 ssh 自行退出才执行 trap——而 ssh 没收到任何
    信号，结果脚本表现为"无视"TERM，ssh 成孤儿继续监听本地端口，下次启动还会撞上
    端口占用检查。修法：ssh 与退避 sleep 都放后台、记 PID，用 `wait` 等待——这是唯一
    能被 trap 信号打断的等待原语——trap 里 kill 并回收。顺带把 SIGHUP 也纳入同一
    cleanup：关闭终端窗口发的是 HUP，不接住的话同样孤儿化 ssh。

    同一改动里修正了退避判据：旧版"会话存活 <5s 即翻倍"会被 ConnectTimeout（10s）
    污染——对端宕机时每次连接失败都耗时约 10s，被误判成"存活过一段时间的真实断线"，
    退避被反复重置、永不增长。新版探测转发是否绑定过：ssh 只在连接并认证成功后才
    设置本地转发，绑定是确定性的"链路确实通过"信号。

    **测试环境教训**（调试 T3 时踩到）：被监督进程派生的环境里 SIGINT 可能整体不可
    投递（实测：直发、组发 INT 均被静默吞掉，TERM/HUP 正常；既非 SIG_IGN 继承也非
    信号屏蔽）。所以 `test-rhino-tunnel.sh` 用**组 SIGHUP** 复现 Ctrl-C 的机制——
    内核组投递 + trap + cleanup，这正是 Ctrl-C 发生的事，只是信号编号不同；INT 与
    TERM 走同一 trap handler，TERM 已被 T1/T2 端到端验证。真实 Ctrl-C 那个按键
    值得在改过 trap 行之后手动按一次确认。

13. **Codex 会自己启动隧道，并留下残留进程**（2026-09-25 实际使用中发现，
    2026-09-26 核查会话日志与进程确认）—— 用户没有先开隧道，第一次工具调用得到
    坑 8 那条 `Could not connect` 报错，Codex 随即在仓库里找到并运行
    `./rhino-tunnel.sh`：
    - **沙箱内启动必然失败，但不会退出**：第一次在默认沙箱里运行，ssh 报
      `Operation not permitted`（沙箱禁止网络），脚本按设计归类为 never connected
      并无限退避重试——它永远等不到网络权限。Codex 随后申请提权再启动一份才连通。
    - **会话结束后进程不回收**：2026-09-26 01:47 核查时，Codex 会话（TUI 仍开着）
      下挂着两份隧道脚本：沙箱里那份已空转约 2 小时 40 分，每 60 秒重试一次；另一份
      提权启动的仍在监听 1999。两者都是 Codex 进程的子进程，各自独立进程组。
    - 这说明第 4 节“用户在窗口 A 手动启动隧道”的流程在实际使用中会被 AI 绕开；
      隧道生命周期应由工具明确管理，而不是由 AI 临场决定。

    → 可选对策（待定）：在项目中放 `AGENTS.md` 说明隧道应由用户启动或由专用命令
    管理；隧道脚本检测到沙箱类错误（`Operation not permitted`）时直接退出而非重试；
    或改为随 MCP 会话启停的方案（经 SSH 直接运行 Windows 上的 rhinomcp，或由启动器
    按会话开关隧道）。

    **2026-09-26 更新**：“经 SSH 直接运行 Windows 上的 rhinomcp”已实测可行（结果见
    验证范围与第 9 节）。连接随 MCP 会话启停，退出 Codex 或 ssh 被 `kill -9` 后两端
    进程均在数秒内回收；不再有常驻隧道，Codex 也就无从自行启动。是否取代隧道成为
    默认方式尚未决定，见 §7 第一条与 §8 待确定事项。

    **2026-09-30 更新**：已添加 `AGENTS.md`，规定 agent 不得自行启动隧道、遇到
    `Could not connect` 时交给用户处理。这只是约定，不能从技术上阻止；隧道脚本
    识别沙箱错误后退出的对策仍未实施。

    **2026-10-01 更新**：默认连接方式定为选项 1（§5），默认流程里不再有常驻隧道。
    选项 2 作为备选时，上述约定和未实施的对策仍然适用。

14. **Codex CLI 自动升级中途失败，`codex` 命令消失**（2026-09-26 22:19 发生）——
    `@openai/codex` 从 0.155.1 被升到 0.157.1，但只做了一半：`bin/codex` 链接未建立
    （只剩 npm 临时链接 `.codex-XXXXXXXX`），新包缺 `@openai/codex-darwin-arm64`，
    旧版完整留在 `@openai/.codex-XXXXXXXX` 目录。此时 `npm install -g` 报
    `ENOTEMPTY`（npm 要把 `codex` 改名到那个已存在的临时目录）。发起者未查明：
    时间紧跟在一次 Codex TUI 会话之后，推测是退出时的自动更新，无直接证据。

    修法：把 `@openai/codex` 与 `@openai/.codex-*` 两个目录移走（本次移到 `/tmp`），
    再 `npm install -g @openai/codex@<版本>`。

    → 对项目的启示：doctor 应检查 MCP 客户端本身可执行（`codex --version`），
    不能只查隧道和 Rhino；Codex 版本也会在用户不知情时变化，兼容性记录要带版本。

15. **`codex exec` 看不到 MCP 工具**（2026-09-26，Codex CLI 0.155.1）—— 非交互的
    `codex exec` 中模型可见的 `mcp__rhino__*` 工具为 0，调用报
    `tools.mcp__rhino__get_document_summary is not a function`；同一配置在交互 TUI 中
    正常（70 个工具）。用默认配置（本机 rhinomcp）对照结果相同，与传输方式无关。
    原因未深究。→ 自动化验收不能用 `codex exec` 代替 TUI；链路本身用
    `experiments/mcp_stdio_probe.py` 直接测 MCP 协议。

16. **选项 1 断网（无 RST）后 Windows 端进程残留**（2026-09-30 实测）—— Mac 端 ssh 有
    `ServerAliveInterval`，断网后约 45–60 秒自行退出；但 Windows sshd 默认
    `ClientAliveInterval 0`，发现不了对端已消失，会话下的 `rhinomcp.exe` 和两个
    `python.exe`（约 90 MB）继续存在，恢复联网后也不会被清掉，其中一个 python 一直
    占着一条到 Rhino 1999 的连接。新会话不受影响（Rhino 接受多个连接），但网络反复
    中断时孤儿会累积。只有断网这一种情况会这样：Mac 端能发出 FIN/RST 时（正常退出、
    `kill`），Windows 会正常结束会话。

    修法：Windows `sshd_config` 设 `ClientAliveInterval 15` / `ClientAliveCountMax 3`
    （做法见 §3）。实测断网后约 46–66 秒回收，此时 Windows 仍处于断网状态。

    两个未解释的现象：
    - 默认配置下的那批孤儿，在 22:42:12 之后、23:27:57 之前的某个时刻消失了。
      sshd 没有重启（PID 未变），Rhino 也没有；同期有 Wi-Fi 网卡事件（23:17、
      23:26）。机制未查明。注册表未设 `KeepAliveTime`，Windows 默认 TCP keepalive
      为 2 小时，所以不是 keepalive 回收的。
    - 两种配置下，OpenSSH/Operational 日志都只有该会话的 `Accepted publickey`，
      没有 `Timeout` 或 `Disconnected` 记录，不能靠日志判断会话是否已被回收。

    → Windows 准备脚本应设置并检查这两项；doctor 应读取 `sshd -T` 的生效值，而不是
    只看配置文件。

17. **选项 1 断线后 Codex 不会自动重连，要重开 Codex**（2026-10-01 实测，Codex
    0.159.2）—— ssh 因断网退出后，rhino 在 `/mcp` 里显示 `failed (70 tools)`，工具
    调用报 `Transport closed`。恢复联网后，同一个会话里无论 `/mcp` 还是再次调用，
    都不会重新拉起 server。嵌入模式（`-c`）和正常模式（后台守护进程）表现相同。
    退出 TUI（`/quit`）再启动 `codex` 即可恢复：正常模式下，守护进程会在 TUI 重启时
    拉起新的 ssh，不需要重启守护进程。

    对比：选项 2 断线时，隧道脚本会自动重连，Mac 上的 rhinomcp 一直活着，所以
    Codex 不需要重开。这是选项 1 的一个代价。

    附带观察：
    - `/mcp` 以及 TUI 启动时，Codex 会额外开一个 1–2 秒就退出的 ssh 连接，推测是去
      查询状态，不影响主会话，也没有残留。
    - 同一句报错可能来自不同路径：一次重启 Codex 时漏了 `-c`，Codex 用了
      `config.toml` 里的选项 2 配置，在 Mac 本机跑 rhinomcp，报的是坑 8 那条
      `Could not connect to Rhino at 127.0.0.1:1999`，看起来像是 Rhino 出了问题。

    → §4 和 README 要写明“断线后重开 Codex”；doctor 应先报告客户端实际用的是哪种
    连接方式，再检查链路。

18. **Windows 端的报错是本地代码页，不是 UTF-8**（2026-10-01 发现）—— 远端 cmd 的报错
    在中文 Windows 上是 GBK 编码，例如 rhinomcp 路径写错时的“系统找不到指定的路径。”。
    Mac 端在 UTF-8 环境下用 `tr` 处理会报 `Illegal byte sequence`，直接显示则是乱码。
    处理时要按字节（`LC_ALL=C`），显示前用 `iconv -f GBK -t UTF-8` 转码；其他语言的
    Windows 使用不同的代码页，不能写死 GBK。

    → doctor 转述远端报错时要处理编码；转码失败时保留原始字节，并提示用户。

19. **`codex mcp add` 会重写整个 `config.toml`**（2026-10-01，Codex 0.159.3）—— 用它
    替换已有条目时，不只丢掉该条目的 env、启动超时和工具审批设置（§3），还会删掉文件
    里**所有注释**，并重新排版其他条目（值不变）。在临时配置里验证时没有注释，所以第一次
    没发现；在原环境真实运行后与备份对比才看出来。原环境用备份恢复后只改了 `args` 一行。

    → `client-codex.sh` 替换前列出会丢失的设置、提示注释会被删、先备份并要求确认。
    更好的做法是只改 `command` / `args` 两行、保留其余内容，见 §7。

20. **AI 编辑中文时写入替换字符 U+FFFD**（2026-10-01 发现两次）—— agent 写入中文时，
    个别汉字被写成了 替换字符（U+FFFD，UTF-8 字节 `EF BF BD`）。文件仍是合法 UTF-8，
    `iconv` 检查发现不了，git diff 里也不显眼。第一次是 §3 的“不备份”，在提交
    `267da23` 里引入，之后在多个提交里留存，直到 2026-10-01 编辑同一段时才发现；
    第二次是 §9 一行的“命名”，在推送前发现。用 perl 按字符替换时，命令里直接输入的
    汉字也没能匹配，最后改用 Unicode 码点（如 `\x{547D}`）才修好。

    → 提交前检查：`git ls-files | xargs grep -nI $'\xef\xbf\xbd'` 应无输出（已写入
    AGENTS.md）。修复时用码点而不是直接输入汉字。

21. **macOS 的 tar 把打包人的用户名和扩展属性写进压缩包**（2026-10-02 发现）——
    `tar -czf` 会记录每个文件的属主，即打包人的 Mac 登录名和组名，`tar -tv` 就能
    看到；还会以 pax 扩展头写入 `com.apple.provenance` 等扩展属性。入库文件和解压后
    的内容检查都发现不了，只有查看压缩包元数据或原始字节才看得出来。首次上传
    Release 前检查时发现。

    → `scripts/package.sh` 用 `--uid 0 --gid 0 --uname root --gname wheel` 和
    `--no-xattrs --no-mac-metadata`；`tests/test-install.sh` 断言属主是 `root:wheel`、
    压缩包里没有扩展属性。发布前的个人信息检查要包括压缩包的元数据。

---

## 7. 待办与遗留问题

已完成的事项移到 §9 阶段记录，这里只列未完成的。

### 近期可执行任务

- [ ] **W1 脚本剩余路径的验收**：方案 A（2026-10-02，见验证范围）已在原环境用新账户覆盖了
      一部分；`tests/prepare-windows-checklist.md` 的 “Not covered yet” 列出剩下的：未装
      OpenSSH、22 端口完全没有入站规则、管理员公钥文件多余权限、改动正在使用的
      `sshd_config` 并重启 sshd、为当前账户从零安装 uv 与 rhinomcp、`net localgroup`
      回退、Windows 11。需要一台全新的 Windows（虚拟机即可）。
- [ ] **`client-codex.sh` 不再整条覆盖**（首版之后）：现在靠 `codex mcp add`，会丢掉
      用户的工具审批等设置和全部注释（坑 19）。改为只替换 `command` / `args`，保留其余
      内容；需要在 bash 里安全地改 TOML，或等 Codex 提供只改部分字段的命令。
- [ ] **补测选项 1 的其他断线情形**（可选）：Mac 端断网或睡眠、Windows 睡眠、长时间
      断网。目前只测了断开 Windows Wi-Fi；断线后 Codex 的恢复方式已测（坑 17）。
- [ ] **真实终端 `Ctrl-C` 手动检查**：模拟测试无法投递 SIGINT（见坑 12），需在真实
      终端运行隧道后按一次 `Ctrl-C`，确认打印 `[tunnel] stopped.` 且端口释放。
- [ ] **收尾坑 13**：默认已改为选项 1，默认流程里没有常驻隧道。剩余的是选项 2
      备选：隧道脚本识别沙箱类错误（`Operation not permitted`）后是否直接退出。
      优先级低。
- [ ] **核实 rhinomcp 是否自动包撤销记录**：决定 `AGENTS.md` 中“生成脚本自行包
      undo record”的约定是否仍有必要。
- [ ] **跟进 PR #63**：作者要求修改时，在本地 clone 的 `docs/remote-setup` 分支修改后
      推送到 fork，PR 自动更新；约两周无回应再考虑留言提醒。本地工作副本位置与恢复
      方法见 `private-notes.md`。
- [ ] **写踩坑总结文章**：等 PR #63 有结果后再写，文中链接上游文档。

### 原环境遗留问题

继承自原搭建记录，此后未检查是否仍存在。个人部署环境特有的问题放在
`private-notes.md`，不属于本项目范围。

- [ ] **ssh 的 post-quantum WARNING 刷屏（待定）**：Mac 端 OpenSSH 较新，每次连接都
      警告对端不支持抗量子密钥交换（见 openssh.com/pq.html）。对局域网内控制 Rhino
      的威胁模型，实际风险约等于零。`~/.ssh/config` 的 `rhino-pc` 条目加
      `LogLevel ERROR` 可压掉，代价是该主机的所有真实警告（host key 变更、认证失败等）
      一并被压。是否值得加：待定。

---

## 8. 开发规划

以下范围、命令形式和阶段均为**建议方案**，尚未逐项确认或实施。规划中的命令不是
当前可执行接口。

### 目标与首版定位

帮助有 Rhino 使用经验、能按指引执行终端命令的用户，在 macOS 上通过 SSH 连接
Windows 上的 Rhino 8，完成 MCP 客户端配置、启动和故障诊断，而不需要自己理解和
拼接 SSH 参数。

首版范围于 2026-10-01 与用户逐项确认（名称与版本号除外）：

| 项目 | 首版范围 | 当前证据或限制 |
|---|---|---|
| 客户端系统 | macOS。只声明已验证的版本，其他版本写“可能可用，未验证”。 | 只在一台 macOS 26（arm64）上用过。CLI 只依赖 bash 3.2 和系统自带工具。 |
| Rhino 主机 | **只声明 Windows 10 22H2** + Rhino 8；Windows 11 标为未验证。 | 只验证过 Windows 10 22H2。微软已于 2025 年 10 月停止支持 Windows 10，新用户多半用 Windows 11，见下方风险。 |
| MCP 客户端 | **只支持 Codex**。其他客户端在文档里给手动配置示例，标为未验证。 | Codex 0.159.2 已验证（含断线恢复，坑 17）。Claude Code 有 `claude mcp add`，但未测。 |
| 连接方式 | SSH 密钥认证 + loopback；默认选项 1，选项 2 作为备选（§5）。 | 两种都实测过，见验证范围。 |
| 账户 | 推荐专用普通账户只用于 SSH，兼容管理员账户（§5）。 | 见验证范围 2026-10-01 方案 B。 |
| 依赖版本 | 固定一个验证过的 rhinomcp 版本。 | `0.4.1.1` 是当前基线，发布前重新核对。 |
| Mac 端 CLI | bash 3.2；**不设项目配置文件**；统一命令 `meshlink`，子命令 `setup`、`client codex`、`doctor`，见下；另有 `windows-script`、`tunnel`（选项 2 备选）、`uninstall`、`version`。 | 首版已实现（2026-10-01），模拟测试见 §4，真实环境运行见验证范围。 |
| Windows 端 | W1 准备脚本（§5）。 | 首版已实现（2026-10-01）；全新环境的路径未运行（§7）。 |
| 安装与升级 | GitHub Release 压缩包（附校验值）+ `install.sh`，装到 `~/.local/bin`，不需要管理员权限；重新安装即升级；`uninstall.sh` 只删除本工具安装的文件，客户端配置删不删先问用户。Windows 脚本放在同一 Release。不提供 `curl … \| bash`。 | `install.sh`、`uninstall.sh`、`scripts/package.sh` 首版已实现（2026-10-01）：文件装到 `~/.local/share/meshlink`，`~/.local/bin/meshlink` 是两行的启动文件；压缩包内容由 `install.sh --list` 唯一定义。尚未发布。 |
| 首版人工步骤 | 安装 OpenSSH Server、安装 Rhino 插件、在 Windows 上运行 W1 脚本、核对主机指纹、在 Rhino 中执行 `mcpstart`。 | — |

**不设项目配置文件的理由**：连接信息已经有两处来源。`~/.ssh/config` 管主机、用户和
密钥（AGENTS.md 的规定）；客户端配置里有完整的 ssh 命令，doctor 用
`codex mcp get rhino` 读出即可。再加一份项目配置，就会出现三处不一致的风险，
坑 11 就是这类问题。

**子命令职责**（统一命令 `meshlink`，2026-10-01）：
- `setup`：生成密钥（若不存在）。在 `~/.ssh/config` 追加 `Host` 条目，同名条目已存在
  时不覆盖、只提示。打印一条可直接粘贴到 Windows 管理员 PowerShell 的 W1 命令，
  里面带好公钥。最后引导首次核对主机指纹。为第二版的配对流程预留：装公钥和核对
  指纹各自是独立步骤（§8 长期方向）。
- `client codex`：先备份，再调用 `codex mcp add` 写入配置，并提示哪些原有设置会丢失
  （§3）。
- `doctor`：按 §4 快速排查的顺序逐段检查，最后做一次 MCP 层只读调用。远端报错的
  编码按坑 18 处理；UAC 关闭时给出警告（§5 账户类型）。

后置：其他 MCP 客户端（第一个候选是 Claude Code）、Windows 11 正式支持、Linux 与
Windows 客户端、Homebrew、图形界面、后台自启动、自动发现与配对（见下）。

### 目标用户流程

1. 从 GitHub 获取明确版本的发布包，安装工具并检查依赖。
2. 按 Windows 指引准备 OpenSSH 和 Rhino 插件；需要管理员权限的步骤明确标出。
3. 初始化连接信息（Windows 主机、用户名、密钥、端口），核对首次主机指纹。
4. 生成或合并 MCP 客户端配置，并说明如何重新加载客户端。
5. 在 Rhino 中执行 `mcpstart`，（选项 2 时）启动隧道，运行诊断。
6. 调用一次只读 Rhino 工具验收；之后能停止、重启、升级或卸载工具。

### 产品形态

一个**双端工具**：Mac 是控制端，Windows 是 Rhino 主机端，中间是 SSH。建模能力
仍来自 Rhino 8 与 rhinomcp，本项目负责安装准备、连接、配置和诊断。

- **Mac CLI**（主要入口）：保存连接信息；生成或安全合并 MCP 客户端配置（不覆盖无关
  配置）；逐段诊断；选项 2 时创建、维持和停止隧道。候选子命令 `init`、`doctor`、
  `tunnel`、`status`、`config codex`，名称未定。先做命令行，连接流程稳定后再考虑
  菜单栏应用，且图形界面必须调用同一套底层逻辑。
- **Windows 准备脚本**（候选为 PowerShell）：检查或安装 OpenSSH Server 并启动
  `sshd`；创建防火墙规则；按管理员/普通账户把公钥放到正确位置并设置 ACL（坑 2）；
  检查 Rhino 8、rhinomcp 插件和 `mcpstart` 监听；选项 1 时安装 uv 与固定版本的
  rhinomcp；输出主机地址、用户、指纹供 Mac 端初始化。系统修改要明确提示，支持
  `-WhatIf` 预览并可重复执行。
- **连接层**：MCP 客户端和 rhinomcp 永远只连 127.0.0.1，跨机一跳只走 SSH（§5）。
  Windows 不为 rhinomcp 开放任何入站端口。

不做：Rhino 建模引擎、云端中转、绕过用户确认的远程控制。

### 长期方向：自动发现与配对（第二版起，2026-10-01 与用户确认）

**理想流程**（用户提出）：Windows 上打开 Rhino，Mac 上启动工具后自动发现这台 PC；
Mac 端发起连接，Windows 弹出确认，用户同意后两边建立连接。

**分阶段**：
- 首版仍按上文的 SSH + CLI 方案做。但“安装公钥”和“核对主机指纹”要做成独立的
  步骤，以后由配对流程替换。
- 第二版增加：Windows 端一个 C# 组件，优先做成 Rhino 插件，Rhino 打开时就在运行；
  Mac 端增加发现与配对功能。

**设计要点**：
- **发现**：用 mDNS/DNS-SD 在局域网里广播。网络屏蔽组播时（公司网络、访客 Wi-Fi、
  AP 隔离），要能退回到手动输入地址。
- **确认**：只在首次配对时确认，两边显示同一个配对码，防止中间人冒充；之后 Rhino
  打开时自动连接。Rhino 内显示“已连接”状态，并提供断开、取消信任的入口。不做每次
  连接都弹窗：选项 1 每次启动客户端都会建一条新连接，`/mcp` 还会额外开短连接。
- **通道**：配对后底层仍然走 SSH，配对只是自动完成装公钥和核对指纹这两步。不自己
  实现加密通道。
- **无法省掉的一步**：首次让 Windows 允许外部连入（OpenSSH Server 或防火墙规则），
  需要一次管理员确认。

**待解决**：
- C# 组件是自己写插件，还是给上游 rhinomcp 提 PR；
- 往专用账户（§8 待确定事项“Windows 登录账户类型”）写公钥需要管理员权限；
- Windows 与 macOS 的代码签名；
- Windows 是否会对自己的主机名应答 mDNS，未核实。

### 实施阶段与验收标准

测试随相关功能同步补充，不等到发布前集中补测。

| 阶段 | 主要工作 | 验收标准 | 状态 |
|---|---|---|---|
| 1. 范围与基线 | 决定默认连接方式；确定首版范围和人工步骤；记录现有测试与真实链路结果。 | 支持目标与已验证环境分别列出；首版范围确认。 | 基本完成（2026-10-01）：首版范围已定，名称与版本号除外，二者在推送 GitHub 前确定。 |
| 2. 配置与核心工具 | 可移植的配置与统一入口；输入验证；MCP 客户端配置生成与合并。 | 换主机不需要改源码；本地端口与客户端配置一致；重复初始化不产生重复条目；无关配置保留且可恢复。 | 未开始 |
| 3. 安装与诊断 | 安装、升级、卸载流程；doctor；Windows 准备脚本。 | 新用户目录能完成安装；缺依赖和连接故障有可执行提示；卸载只移除本工具管理的内容。 | 进行中：`doctor`、`prepare-windows.ps1`、`setup`、`client-codex`、`install.sh` / `uninstall.sh` 首版完成（2026-10-01）；真实安装与全新 Windows 验收未做 |
| 4. 测试与 CI | 整理现有模拟测试，补充配置和安装测试，建立 GitHub Actions。 | 语法、静态检查和自动化测试通过；失败案例能被检测；真实 Rhino 验收单独记录。 | 未开始 |
| 5. 文档与发布材料 | README、排障、安全说明、贡献说明、变更记录。 | 新用户能从 README 找到前置条件、安装、使用、排障和卸载；公开材料无个人信息。 | 部分完成：README、LICENSE、连接指南已有 |
| 6. 独立安装与首发 | 用干净环境走完整流程，修复阻碍，发布首个版本。 | 他人能独立安装并完成只读 Rhino 调用；支持矩阵与证据一致；有校验值和升级/回退说明。 | 未开始 |

### 实现边界

- **配置**：SSH 连接参数仍由 `~/.ssh/config` 负责；若增加项目配置，每个字段只在一处
  维护。写入已有配置前先备份，只更新本项目的条目，用结构化解析而不是整文件覆盖。
- **密钥**：不复制私钥到项目或发布包；是否使用 passphrase / ssh-agent，以及无人值守
  重连的取舍要写清楚。
- **诊断**：逐段检查本地依赖、配置、SSH 认证、转发监听地址（`*:1999` 或
  `0.0.0.0:1999` 要报警，坑 10）、三个端口是否一致（坑 11）、远端 Rhino listener、
  MCP 客户端本身能否运行（坑 14）。每次都重新读取配置；结果区分成功、失败和未验证，
  并给出下一步操作。隧道监听和 server 启动成功不能标记为整条链路成功。
- **测试**：保留现有隧道测试作为回归基础；补充端口冲突、配置不一致、配置合并与
  恢复、重复安装等场景；`BatchMode=yes` 检查要核对每次调用而不是出现过一次。CI 从
  macOS 开始，Linux 上通过不等于承诺支持 Linux。真实 Windows/Rhino 验收单独记录。
- **发布**：引用上游 rhinomcp 并说明本项目提供的部分；上游升级后重新验证监听方式、
  依赖和工具调用。

### 待确定事项

| 事项 | 当前建议 | 状态 |
|---|---|---|
| 默认连接方式 | 选项 1（SSH stdio），选项 2 作为备选，见 §5。 | 已定（2026-10-01） |
| 项目、仓库及命令名称 | meshlink。仓库 `rigelmansid/meshlink`（2026-10-02 起公开）。命令也叫 `meshlink`。 | 已定（2026-10-01） |
| 首版系统与客户端范围 | macOS + Windows 10 22H2 + Rhino 8 + Codex，见上方首版范围。 | 已定（2026-10-01） |
| Windows 自动化程度 | W1：PowerShell 准备脚本负责 SSH 配置、公钥、uv 与 rhinomcp、检查报告；OpenSSH 安装、插件、`mcpstart`、指纹仍手动，见 §5。 | 已定（2026-10-01） |
| Windows 登录账户类型 | 推荐专用普通账户只用于 SSH（方案 B），兼容管理员账户；收益取决于 UAC 是否开启，见 §5。 | 已定（2026-10-01） |
| 实现语言、配置格式与 CLI | bash 3.2；不设项目配置文件；子命令 `setup`、`client codex`、`doctor`，见上方首版范围。命令名 `meshlink`。 | 已定（2026-10-01） |
| 安装路径、分发与升级 | Release 压缩包 + `install.sh` / `uninstall.sh`，装到 `~/.local/bin`，见上方首版范围。 | 已定（2026-10-01） |
| 首版版本号与发布时间 | `0.1.0-dev` 已作为预发布版发布（2026-10-02，用户决定；同日仓库公开）。正式 `0.1.0` 待全新 Windows / Windows 11 验收后再定。 | 预发布已发（2026-10-02） |

### 风险：上游变化

- **上游支持 HTTP 传输**：本方案的前提是 rhinomcp 只监听 loopback、只有 stdio 传输。
  若上游支持 HTTP，跨机最大的障碍会减小，但认证（桥接协议目前无认证）、TLS、防火墙
  和插件监听方式仍需解决，本项目的必要性会下降但不会消失。
- **用户直接打开 `RHINO_MCP_ALLOW_REMOTE`**：它没有认证，用户可能不看本项目就这样做。
  PR #63 的文档已在上游说明为什么不应这样用。
- **McNeel 官方 MCP**：目前只接受本机连接、不支持远程（见 §10），若官方加入远程能力
  需重新评估。

### 风险：只声明 Windows 10

首版只声明已验证的 Windows 10 22H2（2026-10-01 用户决定）。Windows 10 已于 2025 年
10 月停止支持，新用户多半使用 Windows 11，首版可能把大部分潜在用户挡在“未验证”
之外。Windows 11 上 OpenSSH 的安装方式、`sshd_config` 默认内容、UAC 默认值都可能不同。
发布前若能借到 Windows 11 机器或使用虚拟机，应补测一次完整流程。

---

## 9. 阶段记录

| 时间 | 进展 | 验证与限制 |
|---|---|---|
| 2026-09-16 至 09-17 | 完成 Mac 到 Windows Rhino MCP 部署，积累安装和排障记录。 | 原记录称真实链路已跑通；环境见 §2。 |
| 2026-09-18 | 原记录更新了客户端远程开关含义、端口设计、信号清理和测试经验。 | 历史记录，未复现。 |
| 2026-09-22，首次检查 | 创建 `HANDOFF.md`，总结项目现状与接手步骤。 | 当时未发现测试脚本，仅验证隧道脚本语法和可执行权限。 |
| 2026-09-22，文档合并 | 将 `rhino-mcp-setup.md` 与 `HANDOFF.md` 合为本文，移除旧文档；记录 GitHub 产品化讨论。 | 两个脚本通过语法检查；未运行行为测试或真实连接。 |
| 2026-09-22，规划整理 | 扩充 §8 开发规划：已确定目标、建议范围、待定选择、实施阶段与验收标准；§7 拆为近期待办和原环境问题。 | 仅修改本文。 |
| 2026-09-23，产品形态讨论 | 记录双端工具的目标形态、Mac/Windows 职责边界、SSH 连接层和分阶段演进方案。 | 规划存档；未实现任何功能。 |
| 2026-09-24，模拟测试 | 首次运行 `test-rhino-tunnel.sh` 并记录结果；新增真实终端 `Ctrl-C` 待办；记录 T4a 计时断言余量不足。 | 24/24 通过；仅模拟 SSH。 |
| 2026-09-24，整机控制讨论 | 讨论能否让 Codex 控制整台 Windows；决定项目继续聚焦 Rhino；新增 Windows 账户类型待定项。 | 讨论存档，未测试任何工具。该讨论已于 2026-09-30 从本文删除。 |
| 2026-09-26，真实使用核查 | 从 Codex 会话日志确认 2026-09-25 的建模任务成功，更新验证范围与 §2；新增坑 13 和两条待办；Codex 写在仓库根目录的两个建模脚本移出到项目外，未进入 Git。 | 基于日志与进程快照的事后核查；两个残留隧道进程已用 SIGTERM 停止，1999 端口已释放。 |
| 2026-09-26，SSH stdio 实验 | 新增 `experiments/mcp_stdio_probe.py` 和 `experiments/ssh-stdio-test.md`；在 Windows 装 uv 与 rhinomcp 0.4.1.1，完成 Q1–Q7 实测；新增坑 14、坑 15 和两条待办。 | 真实 Windows + Rhino 实测；不可达场景为模拟；隧道方式未作同条件对照。 |
| 2026-09-26 至 09-28，调研与方向复盘 | 调研其他设计软件的 MCP 方案，写成 `cad-mcp-research.md`；复盘项目意义，选定方向 B；提交上游 rhinomcp PR #63。 | 调研文件与方向复盘已于 2026-09-30 删除，Rhino 相关结论并入 §10，PR 记录见 §5。 |
| 2026-09-28，按公开发布标准整理目录 | 目录改为 `scripts/`、`tests/`、`docs/`、`experiments/`；新增英文 README、中文 README、MIT `LICENSE`、`.gitignore`；上游 PR 文档改为 `docs/remote-setup.md`；本文与实验记录脱敏，个人环境信息移到不入库的 `private-notes.md`。 | `tests/test-rhino-tunnel.sh` 24/24 通过、两个脚本 `bash -n` 通过；文档相对链接无失效；入库文件未检出真实地址或用户名。 |
| 2026-09-30，拆分工作规则 | 新增根目录 `AGENTS.md`（`CLAUDE.md` 为其符号链接），集中面向 agent 与维护者的工作规则；从本文移出接手顺序、维护方式和测试运行说明。 | 仅文档改动；未运行测试。 |
| 2026-09-30，收敛到 Rhino | 决定只做 Rhino、改为方向 C（§5）；删除 `docs/cad-mcp-research.md`、整机控制讨论和方向复盘；重写本文：§1 同时描述两种连接方式，§3 补选项 1 配置，§5 新增范围决定与 PR #63 记录，§7 只保留未完成事项，§8 压缩为 Rhino 路线图；章节编号与坑 1–15 编号保持不变。README 去掉调研文件链接。 | 仅文档改动。`tests/test-rhino-tunnel.sh` 24/24 通过、两个脚本 `bash -n` 通过；入库文档无失效相对链接，未检出真实地址或用户名；范围扫描只剩 §5 决定与 §9 历史记录。未连接 Windows 或调用 Rhino 工具。 |
| 2026-09-30 至 10-01，选项 1 断网回收实验与默认连接方式 | `mcp_stdio_probe.py` 新增 `--hold`；断开 Windows Wi-Fi 做了 4 轮实验（第 3 轮作废）；原环境 Windows `sshd_config` 设 `ClientAliveInterval 15` / `ClientAliveCountMax 3`（由用户在 Windows 本机管理员 PowerShell 执行）；决定默认用选项 1（§5）；§3 新增 sshd_config 配置，§6 新增坑 16，§7、§8 相应更新；`docs/remote-setup.md` 补充断网回收与 `ClientAliveInterval`，并向 PR #63 追加同样内容的提交。 | 真实 Windows + Rhino，结果与限制见验证范围。未运行 `tests/test-rhino-tunnel.sh`（隧道脚本未改动）；当时 §4 尚未按选项 1 改写；未做建模调用。 |
| 2026-10-01，断线后 Codex 恢复测试 | 分别用嵌入模式和正常模式测试选项 1 断线后 Codex 能否恢复；原环境 `~/.codex/config.toml` 切到选项 1（备份 `config.toml.bak-20261001`，删去已被忽略的 `type` 行）；§3 补 Codex 0.159.2 的相关行为，§6 新增坑 17，§7 相应更新。 | 真实 Windows + Rhino + Codex TUI，结果与限制见验证范围。仅文档改动，未运行隧道测试。 |
| 2026-10-01，按选项 1 改写 §4 | §4 改为选项 1 主线：前置条件、启动与停止、断线后重开 Codex、逐段排查；选项 2 压缩为备选小节。中英文 README 把方式一标为推荐，并注明断线后需重启 Codex。 | 仅文档改动。§4 排查步骤里的命令本次会话都实际运行过（`codex mcp get rhino`、探测脚本、`tasklist`）。 |
| 2026-10-01，实现语言与 Windows 自动化 | 决定 Mac 端 CLI 用 bash、Windows 端提供 W1 准备脚本（§5）；§3 记录 `codex mcp add` 覆盖已有条目的行为；§8 待确定事项更新；§7 新增“验证 bash 能否做 MCP 层诊断”。修正 §9 表中 2026-09-30 那一行被前几次编辑拆散的“验证与限制”一栏。 | `codex mcp add` 行为用临时 `CODEX_HOME` 验证（Codex 0.159.2），未触碰真实配置。其余为文档改动。 |
| 2026-10-01，长期方向：发现与配对 | 用户提出“自动发现 + Windows 确认 + 握手连接”的理想流程；讨论后确定分阶段：首版保持 SSH + CLI，第二版加 Windows 端配对组件和 Mac 端发现，底层仍走 SSH。写入 §8 新小节。 | 仅讨论与文档，未做任何原型或验证。 |
| 2026-10-01，Windows 账户类型 | 实测方案 B（专用普通账户 `rhino-agent` 只用于 SSH）；发现测试机 UAC 关闭、Rhino 以已提权身份运行；决定推荐 B、兼容 A（§5），§2、§3、§8 相应更新，§7 新增连接指南的账户与 UAC 说明。原环境 Codex 改用 `rhino-agent` 登录（备份 `config.toml.bak-20261001-1430`）。 | 真实 Windows + Rhino，结果与限制见验证范围。Codex 经新账户的只读调用已确认成功。 |
| 2026-10-01，连接指南安全说明 | `docs/remote-setup.md` 的 Security 一节改写：两条执行途径（登录账户的 shell、Rhino 内的执行工具）；推荐专用普通账户只用于 SSH；检查 Rhino 不以已提权身份运行（UAC / `EnableLUA`）。同样内容追加到 PR #63。 | 仅文档改动。“UAC 开启时 Rhino 不带管理员权限”是 Windows 默认行为，本项目未实测。 |
| 2026-10-01，bash 版 MCP 探测 | 新增 `experiments/mcp_stdio_probe.sh`，验证 doctor 可以只用 bash 3.2 做 MCP 层诊断；§5 bash 决定中“可行性尚未验证”一条更新为已验证；新增坑 18（Windows 报错的代码页）；§7 删除对应待办。 | 真实 Windows + Rhino，结果与限制见验证范围。 |
| 2026-10-01，首版范围 | 与用户确定首版范围：只支持 Codex；只声明 Windows 10 22H2；不设项目配置文件，子命令 `setup` / `client codex` / `doctor`；Release 压缩包 + `install.sh` 安装。§8 首版定位表重写，待确定事项更新，新增“只声明 Windows 10”风险；§7 换成阶段 2 的实现任务；当前状态更新。 | 仅讨论与文档。名称与版本号仍待定。 |
| 2026-10-01，`doctor` 首版 | 新增 `scripts/doctor.sh` 与 `tests/test-doctor.sh`：10 项检查（本机工具、Codex 配置与连接方式、ssh 参数、登录、rhinomcp.exe、账户类型、UAC、`ClientAliveInterval` 及其是否在 Match 块之后、Rhino 监听、MCP 往返），选项 2 只查本机隧道。README（中英）、AGENTS.md、§4、§7、§8 相应更新。设计中确认：普通账户能读取 `EnableLUA` 与 `sshd_config`；ssh 会话里 `chcp 65001` 不能把输出变成 UTF-8，所以 doctor 只依据退出码和与语言无关的内容判断。 | 见验证范围 15:09 一行。 |
| 2026-10-01，W1 Windows 准备脚本首版 | 新增 `scripts/prepare-windows.ps1`（PowerShell 5.1，纯 ASCII，`-WhatIf`，可重复运行）与 `tests/prepare-windows-checklist.md`；§5 W1 决定记录实现时的调整（其他账户的 uv 与 rhinomcp 只检查和打印命令）；README（中英）、AGENTS.md、§7、§8 相应更新。 | 见验证范围 15:24 一行。 |
| 2026-10-01，`setup` 与 `client-codex` 首版 | 新增 `scripts/setup.sh`、`scripts/client-codex.sh`、`scripts/lib/common.sh`（doctor 改为共用它，并改用 `ssh -G` 显示实际账户）、`tests/test-setup.sh`；原环境新增 `Host rhino-agent`，Codex 改为不带 `-l` 的产品默认写法；新增坑 19，更正 §3 关于 `codex mcp add` 的说法；修正 §3 中一处乱码（“不备份”被写成了三个替换字符，2026-10-01 引入）；README（中英）、AGENTS.md、§2、§4、§7、§8 相应更新。 | 见验证范围 15:53 一行。 |
| 2026-10-01，命名与首次推送 | 用户将项目命名为 meshlink、仓库先私有；README 标题与 §8 更新，AGENTS.md 改为“本地 `main` 归档、在 `public` 分支继续并推送、提交署名用 noreply”。从本地 `main` 当前文件树建立孤立分支 `public`（单个提交，署名 Cheng Yuan + GitHub noreply），用 `gh` 在 rigelmansid 下建私有仓库 `meshlink`，推送 `public` → `main`。 | 推送前对 21 个入库文件做了全文检查（真实 IP、本机与 Windows 用户名、主机名、卷标、本机邮箱、含真实用户名的路径），无命中；`private-notes.md` 被 `.gitignore` 排除。本地 `main` 的 25 个提交未推送。 |
| 2026-10-01，记录不推送 `main` 的原因 | 用户要求详细记录。§5 新增决定“本地 `main` 不推送，从孤立分支 `public` 发布”：三条原因、不改写历史的理由、代价与配套做法；新增坑 20（AI 编辑中文时写入 U+FFFD）；AGENTS.md 的规则加上简要原因、指向 §5，并把 U+FFFD 检查加入提交前检查。 | 仅文档改动。“8 个提交仍含个人信息”为 2026-10-01 用 `git grep` 逐个提交核对的结果。 |
| 2026-10-01，安装、卸载与 `meshlink` 命令 | 新增 `bin/meshlink`、`install.sh`、`uninstall.sh`、`scripts/package.sh`、`VERSION`（0.1.0-dev）、`tests/test-install.sh`；`.gitignore` 加 `dist/`；`scripts/lib/common.sh` 按是否经 `meshlink` 调用选择提示措辞；`setup.sh` 打印 `prepare-windows.ps1` 的实际路径。README（中英）加“快速开始”与测试说明，AGENTS.md、§7、§8 相应更新。关闭两项过时待办：“修正本机 rhinomcp 的版本固定”（默认已是选项 1，rhinomcp 在 Windows 上按固定版本安装，Mac 上那份只供选项 2）与“盘点迁移所需配置”（已由不设项目配置文件、`setup` / `client codex` 取代）。当前状态中“仓库只在本地”等过时描述一并更正。 | 见验证范围 16:30 一行。 |
| 2026-10-01，推送与原环境真实安装 | 推送 `8beaea5`、`55b8989` 到 `origin/main`。从发布包在原环境安装 meshlink 0.1.0-dev 并保留；§2 记录安装位置，§7 删除“在原环境真实安装一次”。 | 见验证范围 23:56 一行。 |
| 2026-10-02，首次预发布 | 用户定版本号 `0.1.0-dev` 并选择发布为预发布版。发现并修正压缩包元数据泄露打包人用户名与 macOS 扩展属性（坑 21，`scripts/package.sh`、`tests/test-install.sh` 新增两项断言，共 39 项）；推送 `c83f064`；在私有仓库发布 `v0.1.0-dev`。§7 删除“首次发布 Release”，§8 更新版本号。编辑本文时一次 awk 命令因变量为空误删 867 行，未提交，已从 `HEAD` 恢复后重做。 | 见验证范围 2026-10-02 一行。 |
| 2026-10-02，脱敏并转为公开 | 公开前按用户选择脱敏：描述测试机安全状态的措辞改为中性（§2、§3、§5 与几条验证记录），去掉 13 处时区；`rhino-agent`、`rigelmansid`、`Cheng Yuan` 保留。把 `public` 压成一个新的孤立提交并强制推送，移动 `v0.1.0-dev` 标签，仓库改为公开（§5）。 | 公开前检查：当前文件、`public` 全部提交、提交说明与作者、Release 附件与说明中无私有网段 IP、本机与 Windows 用户名、主机名、卷标、主机指纹、真实邮箱、硬件与其他软件信息。 |
| 2026-10-02 至 10-03，方案 A 验收 | 用户没有全新 Windows 或 Windows 11 电脑，选择方案 A：在原环境用新账户 `rhino-test` 真实运行全新流程（结果见验证范围）。修复 `setup.sh` 的密钥注释与 `--key` 重跑问题、`lib/common.sh` 的换行；`tests/test-setup.sh` 增至 57 项；手动清单区分已覆盖与未覆盖的路径；§7 更新 W1 剩余验收并新增 Codex 命令示例一项。 | 见验证范围 2026-10-02 23:09 一行。Hyper-V 下的 Windows 11 虚拟机（方案 B）未做。 |
| 2026-10-03，Windows 脚本的 Codex 命令示例 | `prepare-windows.ps1` 报告末尾改为三行：rhinomcp.exe 路径、下一步 `meshlink client codex --host <host>`、Codex 将运行的不带 `-l` 的命令；§7 删除对应一项。 | 见验证范围 2026-10-03 一行（用户口头确认）。 |

---

## 10. 参考

- [jingcheng-chen/rhinomcp](https://github.com/jingcheng-chen/rhinomcp)：本方案依赖的上游项目。
- [bindreams/ssh-tunnel-windows](https://github.com/bindreams/ssh-tunnel-windows)：Windows SSH 隧道的权限坑。
- [Rhino 8 启动命令设置](https://docs.mcneel.com/rhino/8/help/en-us/information/startingrhino.htm)

### 相关项目（2026-09-26 调研，未实测）

- [mcneel/RhinoAI](https://github.com/mcneel/RhinoAI)（McNeel 官方，Yak 包
  Rhino-MCP-Platform）：HTTP `127.0.0.1:10500/mcp`，只接受本机连接，不支持远程。
  它同样注册了 `MCPStart` 命令，**可能与 rhinomcp 冲突（未验证）**，排除之前不要装进
  同一个 Rhino。默认分支是 rhino-9.x，是否支持 Rhino 8 未验证。
- [xunliudesign/rhino-gh-mcp](https://lobehub.com/mcp/xunliudesign-rhino-gh-mcp)：
  替代实现，Grasshopper 支持更完整，路线图里有 Streamable HTTP。

### 建模实践（调研结论，未系统验证）

- 让 agent 写 RhinoCommon（C# 或 Python 3）脚本并通过执行代码的工具运行，再读回几何
  数据核对结果。RhinoCommon 能拿到公差、对象 ID 和 `IsValid`；rhinoscriptsyntax 会
  隐藏失败状态；命令宏（`run_command`）受命令提示和界面状态影响，可重复性最差。
- 渲染自动化：V-Ray for Rhino 有 Python API（`rhVRay`），也可导出 `.vrscene` 用命令行
  渲染；Rhino Render（Cycles）可用 `_-Render` 等命令加 RhinoCommon 材质 API；Enscape
  与 D5 没有公开 API。
