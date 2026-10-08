# meshlink 开发与维护记录

最后更新：2026-10-08。

## 进行中

更新：2026-10-08 11:40
- 任务：§7 剩余项。已推送（`57cfe98`）：探测脚本 stderr、隧道遇沙箱错误退出（坑 13）、CI（D-29，
  首次运行通过）、AGENTS.md 精简、CHANGELOG；本次：关闭上游 PR #63、删本机临时 clone（D-30）
- 停在：CI 结果与 D-30 的文档改动已提交，未推送；fork `rigelmansid/rhinomcp` 待用户在网页删除
- 本次决策：D-29、D-30
- 待用户确认：推送；插件发布方式与首个公开版本号（D-26）
- 下一步：1. 用户删 fork 后用 `gh api repos/rigelmansid/rhinomcp` 确认（应为 404）；2. UAC 开启
  路径与 W1 剩余验收随全新 Windows 做（暂缓，D-18）
- 不要重复：PR #63 已关闭（不要再跟进或留言）；推送 workflow 文件要用 gh 的令牌；探针 P1–P4、插件
  R1–R10 与 R12–R14、清单 G、三处小改动、隧道真实终端 Ctrl-C（tee 改动前后）已在原环境做过

## 项目概况

让 Mac 上的 AI agent（优先 Codex）通过 SSH 控制局域网内另一台 Windows 电脑上的
Rhino 8 建模。建模能力来自上游 [rhinomcp](https://github.com/jingcheng-chen/rhinomcp)；
本项目负责跨机连接、安装准备和故障诊断。

- **范围**：只做 Rhino 8。其他设计软件和整机远程控制不在范围内（2026-09-30 决定，
  见 D-9）。
- **方向**：方向 C，把现有方案做成别人能下载安装的工具（Mac CLI、诊断、Windows
  准备脚本），规划见 [roadmap.md](roadmap.md)。
- **正式名称**：meshlink（2026-10-01 用户确定），README 副标题保留 “RhinoMCP over SSH”。

本文记录项目的进行中工作、现状、架构与待办。规划见 [roadmap.md](roadmap.md)，决策见
[decisions.md](decisions.md)（D-n），踩过的坑见 [pitfalls.md](pitfalls.md)（坑 n），
阶段记录与验证记录见 [log.md](log.md)。接手步骤、验证与记录方法、文档维护、隐私与发布等**工作规则**统一放在
根目录 [AGENTS.md](../AGENTS.md)（`CLAUDE.md` 是它的符号链接），不在本文重复。
面向使用者的入口是 [README.md](../README.md) 与 [README.zh-CN.md](../README.zh-CN.md)。

## 当前状态

| 文件 | 用途 |
|---|---|
| [README.md](../README.md)、[README.zh-CN.md](../README.zh-CN.md) | 面向使用者的入口。 |
| [CHANGELOG.md](../CHANGELOG.md) | 面向使用者的变更记录（英文，2026-10-08 新增）。 |
| [.github/workflows/tests.yml](../.github/workflows/tests.yml) | CI（D-29）：在 macOS 上用系统 bash 3.2 运行全部自动化测试并编译插件。 |
| [AGENTS.md](../AGENTS.md)、`CLAUDE.md` | 面向 AI agent 与维护者的工作规则；`CLAUDE.md` 是指向 `AGENTS.md` 的符号链接。 |
| [docs/remote-setup.md](remote-setup.md) | 英文连接指南（两种 SSH 方式、Windows OpenSSH 配置、排障、安全）。曾提交为上游 PR #63，2026-10-08 关闭（D-30）。 |
| `docs/project-notes.md` | 进行中的工作、现状、架构、配置、待办与规划（本文）。 |
| [docs/decisions.md](decisions.md) | 决策记录 D-1 起：背景、选项、选择、理由、影响。 |
| [docs/pitfalls.md](pitfalls.md) | 踩过的坑 1–21：现象、原因、修法、启示。 |
| [docs/log.md](log.md) | 阶段记录与验证记录（原 §9 与原「验证范围」表），只追加。 |
| [scripts/rhino-tunnel.sh](../scripts/rhino-tunnel.sh) | 选项 2 的 SSH 隧道守护脚本：端口占用检查、端口配置不一致警告、断线退避重连、信号清理；ssh 完全不能联网（沙箱）时以退出码 3 结束（坑 13）。 |
| [scripts/doctor.sh](../scripts/doctor.sh) | 只读诊断（2026-10-01 首版）：从 `codex mcp get --json` 读取 Codex 实际使用的命令，逐段检查到一次真实的 MCP 工具调用。设计见 [roadmap.md](roadmap.md) 首版范围。 |
| [scripts/prepare-windows.ps1](../scripts/prepare-windows.ps1) | W1 Windows 准备脚本（2026-10-01 首版），由用户在 Windows 管理员 PowerShell 中运行，职责见 D-12。 |
| [tests/prepare-windows-checklist.md](../tests/prepare-windows-checklist.md) | W1 脚本的手动测试清单，以及尚未实测的路径。 |
| [scripts/setup.sh](../scripts/setup.sh)、[scripts/client-codex.sh](../scripts/client-codex.sh) | Mac 端首次配置与 Codex 配置（2026-10-01 首版），职责见 [roadmap.md](roadmap.md) 首版范围；共用代码在 `scripts/lib/common.sh`（doctor 也用）；密钥、Host 条目、主机公钥三步在 `scripts/lib/sshcfg.sh`，供以后的配对复用（2026-10-04）。 |
| [scripts/pair.sh](../scripts/pair.sh) | Mac 端配对（2026-10-05，0.2 开发中）：广播、四步交换、显示配对码、写 Host 条目与 known_hosts。协议见 [pairing.md](pairing.md)，计算在 `scripts/lib/pairing.sh`；2026-10-06 与插件在原环境 PC 上配对成功。 |
| [bin/meshlink](../bin/meshlink) | 统一命令 `meshlink`（2026-10-01）：只做分发，子命令转到 `scripts/` 下的脚本；导出 `MESHLINK_CLI`，让各脚本的提示写成 `meshlink ...`。 |
| [install.sh](../install.sh)、[uninstall.sh](../uninstall.sh)、[scripts/package.sh](../scripts/package.sh)、`VERSION` | 安装到 `~/.local`、卸载、打包（2026-10-01 首版），职责见 [roadmap.md](roadmap.md) 首版范围。 |
| [tests/test-install.sh](../tests/test-install.sh) | 在临时 HOME 中验证打包、安装、升级、卸载与 `meshlink` 分发的 8 组场景（39 项断言）。 |
| [tests/test-setup.sh](../tests/test-setup.sh) | 在临时 HOME 中用 fake ssh、ssh-keyscan、codex 验证 setup 与 client-codex 的 17 组场景（85 项断言）；假 codex 读写 `config.toml`。 |
| [tests/test-doctor.sh](../tests/test-doctor.sh) | 用 fake codex 与 fake ssh 验证 doctor 的 12 组场景（48 项断言）。 |
| [tests/test-rhino-tunnel.sh](../tests/test-rhino-tunnel.sh) | 用 fake SSH 验证隧道脚本的退出清理、断线分类、重连与沙箱错误退出的 5 组场景（34 项断言）。 |
| [rhino-plugin/](../rhino-plugin) | Windows 端（2026-10-05，0.2 开发中，D-19–D-23）：`Meshlink.Pairing` 协议库（四步会话、配对码、校验、Windows mDNS 发现）、`Meshlink.Pairing.Tests`（含 `prepare-windows.ps1` 语法检查）、`Meshlink.Pairing.Driver`（供 `PAIR_CLIENT=dotnet tests/test-pair.sh`）、`Meshlink.Rhino`（插件 `Meshlink.rhp`：配对弹窗、提权运行 `prepare-windows.ps1`、启动时 `mcpstart`、`MeshlinkUnpair`）。在 Mac 上用 .NET SDK 编译；2026-10-06 在原环境 PC 上按清单 R1–R10 测试通过（UAC 关闭）。 |
| [scripts/package-yak.sh](../scripts/package-yak.sh) | 用官方 `yak`（D-24，维护者机器上在 `../materials/scratch/tools/yak`）把插件打成 `dist/meshlink-<版本>-rh8_17-win.yak`（2026-10-07）。2026-10-07 在原环境 PC 上验证了从包安装、撤销配对与卸载（清单 R12–R14）。 |
| [tests/rhino-plugin-checklist.md](../tests/rhino-plugin-checklist.md) | 插件的手动测试清单（PC 上执行）。 |
| [tests/test-pair.sh](../tests/test-pair.sh) | 配对：对照 [测试向量](../tests/pairing-vectors.txt) 检查承诺值与配对码；用 Python 假 Rhino 端、fake dns-sd / ssh / ssh-keyscan 和真实 `nc` 验证 `pair.sh` 的 15 组场景（共 118 项断言）。 |
| [experiments/](../experiments/) | MCP stdio 探测脚本：Python 版 `mcp_stdio_probe.py`（`--hold` 可在调用后保持会话，用于断网实验）；纯 bash 3.2 版 `mcp_stdio_probe.sh`（一次工具调用并给出判定，验证 doctor 不依赖 Python 的可行性）。另有选项 1 的实验步骤 `ssh-stdio-test.md`。 |
| `private-notes.md`（不入库） | 真实主机地址、用户名、个人配置和个人环境问题；在 `.gitignore` 中。 |
| `../materials/`（仓库外） | 参考资料 `refs/`、待整理 `inbox/`、agent 临时产出 `scratch/`（建模脚本、生成的模型、实验输出）。见 D-15。 |

现有内容：实测过的连接指南；Mac 端统一命令 `meshlink`（`bin/meshlink`，子命令 `setup`、
`pair`、`client codex`、`doctor` 等，实现都在 `scripts/`）、`install.sh` / `uninstall.sh` 与打包
脚本 `scripts/package.sh`；Windows 准备脚本 `scripts/prepare-windows.ps1` 及其手动测试清单；
0.2 开发中的配对：Mac 端 `meshlink pair` 与 Windows 端 Rhino 插件（`rhino-plugin/`），已在原环境
真实配对（2026-10-06）。自动化测试：五组 bash 测试（install 39、setup 85、doctor 48、
tunnel 34、pair 118 项）与 .NET 测试 62 项。CI 见 `.github/workflows/tests.yml`（D-29，
2026-10-08 首次运行通过）；尚无依赖清单。

仓库 `rigelmansid/meshlink` 已公开（2026-10-02）。开发与推送都在本地 `public` 分支，
本地 `main` 与 `public-presquash` 永不推送（D-8）。预发布 `v0.1.0-dev`（2026-10-02）落后于
`main`：之后又推送了 5 个提交，其中修复有密钥注释、重跑 `setup` 的密钥、远端报错换行、
Windows 报告去掉 `-l`；不发中间预发布，等全新 Windows 验收后发正式 `0.1.0`（D-17）。原环境（§2）已从发布包安装 meshlink
并在使用，Codex 经专用普通账户以选项 1 连接。

默认连接方式为选项 1（SSH stdio），前提是 Windows sshd 设置 `ClientAliveInterval`
（§3、坑 16）。首版范围已定（[roadmap.md](roadmap.md)）。用户没有全新 Windows 或
Windows 11 电脑；方案 A（2026-10-02 至 10-03）已在原环境用新账户真实跑通全新流程。

### 验证现状

原「验证范围」表已移到 [log.md](log.md) 的验证记录；本文和其他文件中“见验证范围”均指那里。

最近一次确认的端到端可用：选项 2 是 2026-09-25 的真实建模，选项 1 是 2026-09-26 的
实验。此后环境若有变化（升级、重启、换网络），以一次只读 Rhino 工具调用为准。

最近的真实验证：2026-10-08 PC 上重装插件包、三处小改动（用户报告）与 doctor（除 UAC 警告外全部
OK）；同日隧道脚本在真实终端按 `Ctrl-C` 停止、端口释放（原环境，用户报告，tee 改动前后各一次）；
2026-10-07 插件包安装、撤销配对、卸载与重装（R12–R14，原环境）；
2026-10-06 配对插件 R1–R10（原环境，UAC 关闭；配对、Codex 经测试条目
的只读调用、重启后自动 `mcpstart`），测后清理并以真实配置运行 doctor：9 OK、1 WARN。
更早：2026-10-02 23:09 至 10-03 00:20 方案 A（原环境上的全新账户，`setup`、
`prepare-windows.ps1`、`client codex`、doctor 全流程）；2026-10-03 `prepare-windows.ps1` 报告
去掉 `-l`，用户口头确认，没有留存输出。

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
| 默认 | 是（2026-10-01 起，D-10） | 备选 |

关键点（对应上游 rhinomcp 0.4.1.1，升级后需重新确认）：

- Rhino 插件的监听**只绑 127.0.0.1**，上游没有改绑网卡的配置，局域网上的机器直接
  连不到。跨机只能通过 SSH，这不是“更安全的选项”，而是唯一的方式。
- 桥接协议本身**没有认证**。所以客户端拨号目标也保持 127.0.0.1，
  `RHINO_MCP_ALLOW_REMOTE` 刻意不设（语义见 D-1）。
- rhinomcp 当时向客户端提供 **70 个工具**。

---

## 2. 原部署环境

以下为历史部署值，此后未重新检查。主机地址、用户名和个人路径已替换为占位符，
实际值保存在不入库的 `private-notes.md`。

| 项 | 值 |
|---|---|
| Mac | 与 Windows 同一局域网，macOS 26（arm64） |
| Windows | `<pc-address>`，用户 `<windows-user>`，Win10 22H2 build 19045.6466 |
| SSH 登录账户 | 2026-10-01 起 Codex 用专用普通账户 `rhino-agent` 登录（方案 B，D-13）；15:53 起由 `setup.sh` 在 `~/.ssh/config` 新增 `Host rhino-agent`，Codex 参数不再带 `-l`，uv 与 rhinomcp 0.4.1.1 装在该账户目录下；另有一个 Host 条目供维护和诊断 |
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

用专用普通账户登录时（方案 B，D-13），在 `args` 里加 `"-l", "<agent-user>"`，并把路径
换成该账户下的 `C:\Users\<agent-user>\.local\bin\rhinomcp.exe`（写进 TOML 时反斜杠要成对）。原环境 2026-10-01
起使用这种写法，修改前的备份为 `config.toml.bak-20261001-1430`。

Codex 0.159.2 的相关行为（2026-10-01 观察）：
- `type = "stdio"` 会被忽略，并在启动时给出警告；stdio 本来就是默认值，可以删掉。
- 正常启动时，MCP server（这里就是 ssh）由共享的后台守护进程 `codex app-server
  --managed-daemon` 拉起，而不是由 TUI 拉起。带 `-c` 覆盖时 Codex 改用嵌入模式，
  MCP server 挂在 TUI 下。两种模式的进程归属不同，测试时要注明用的是哪一种。
- 改完 `config.toml` 后重开 TUI 即生效，已在运行的守护进程也用上了新配置。
- `meshlink client codex` 自 2026-10-07 起直接编辑 `config.toml`，只改该条目的 `command` 与
  `args` 两行（D-27），下面 `codex mcp add` 的问题只在它退回旧做法时出现。
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
  版本的 rhinomcp（D-3）。
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

已移到 [decisions.md](decisions.md)（2026-10-03，D-14），编号 D-1 起。

---

## 6. 踩过的坑

已移到 [pitfalls.md](pitfalls.md)（2026-10-03，D-14），坑 1–21 编号不变。

---

## 7. 待办与遗留问题

已完成的事项移到 §9 阶段记录，这里只列未完成的。

### 近期可执行任务

- [ ] **配对：发布与剩余检查**（Phase 3 已于 2026-10-07 在原环境验证 R12–R14）：Yak 包暂不
      推送（D-26），以后再定推送时机与首个公开版本号（预发布标签按字母排序，`dev` 之后改用
      `beta` 会被当成更旧）；发布方式可随 GitHub Release 附 `.yak`，或推送公共 Yak
      （2026-10-08 讨论，倾向先用前者，未定）。G、三处小改动已做过（见 log）。
- [ ] **W1 脚本剩余路径的验收**（暂缓，D-18；正式 `0.1.0` 仍以它为前提，D-17）：方案 A（2026-10-02，见验证范围）已在原环境用新账户覆盖了
      一部分；`tests/prepare-windows-checklist.md` 的 “Not covered yet” 列出剩下的：未装
      OpenSSH、22 端口完全没有入站规则、管理员公钥文件多余权限、改动正在使用的
      `sshd_config` 并重启 sshd、为当前账户从零安装 uv 与 rhinomcp、`net localgroup`
      回退、Windows 11。需要一台全新的 Windows（虚拟机即可）。
- [ ] **配对的 UAC 开启路径**（随全新 Windows 验收一起做，D-22；插件清单 R11）：探针 P3、
      P4 与插件 R1–R10 都只在 UAC 关闭的原环境通过。需验证未提权的 Rhino 能读 `ssh_host_ed25519_key.pub`（读不到时
      改由别的方式取得主机公钥），以及 `runas` 弹 UAC、用户拒绝时得到 1223。
- [ ] **补测选项 1 的其他断线情形**（可选）：Mac 端断网或睡眠、Windows 睡眠、长时间
      断网。目前只测了断开 Windows Wi-Fi；断线后 Codex 的恢复方式已测（坑 17）。
- [ ] **写踩坑总结文章**：时机未定；文中链接本仓库的连接指南（PR #63 已关闭，D-30）。

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

已移到 [roadmap.md](roadmap.md)（2026-10-04，D-16）。

---

## 9. 阶段记录

已移到 [log.md](log.md) 的阶段记录（2026-10-03，D-14）。

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
