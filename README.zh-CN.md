# meshlink

RhinoMCP over SSH。

[English](README.md)

用 Mac 上的 AI agent（Codex、Claude Code 等 MCP 客户端），通过局域网操控另一台
Windows 电脑上的 Rhino 8，同时不把 Rhino 那个没有认证的桥接端口暴露到网络上。

```
Mac                                        Windows 电脑
AI 客户端 ── rhinomcp ── 127.0.0.1:1999 ══ SSH ══► 127.0.0.1:1999 ── Rhino 8 + RhinoMCP 插件
```

建模能力来自 [RhinoMCP](https://github.com/jingcheng-chen/rhinomcp)。本项目负责
RhinoMCP 没有涉及的部分：安全地连通两台电脑，以及那些出错时不报错的配置问题。

> **状态：早期。** [0.3.0-dev 预发布版](https://github.com/rigelmansid/meshlink/releases/tag/v0.3.0-dev)是一个 demo：Mac 端的 `meshlink` 命令
> （首次配置、配对、Codex 配置、只读的 `doctor` 诊断）及其安装脚本，以及 Windows 端的
> meshlink Rhino 插件。只在一台 UAC 关闭的 Windows 10 电脑上测试过。还没有发布正式版本。
> 项目只支持 Rhino 8。

## 快速开始

1. Windows 上：安装 OpenSSH Server，并在 Rhino 8 中安装 RhinoMCP 插件。安装 OpenSSH
   Server 时按 **Win + R**，输入 `ms-settings:optionalfeatures` 打开“可选功能”（也可以在
   设置里搜索“可选功能”），再添加 **OpenSSH 服务器**。各版本 Windows 的菜单位置不同。
2. Mac 上，在解压后的发布包或克隆下来的仓库目录里运行 `./install.sh`。它安装到
   `~/.local`，不需要 `sudo`。
3. 运行 `meshlink setup --address <pc-address> --user <windows-user>`。它会打印一条
   要在 Windows 管理员 PowerShell 里执行的命令（`meshlink windows-script` 显示脚本
   位置），之后和你一起核对 Windows 的主机指纹。
4. 运行 `meshlink client codex`。它把 Codex 指向 Windows 上的 `rhinomcp`，然后运行
   `meshlink doctor`。
5. 在 Rhino 里运行 `mcpstart`，然后重启 Codex。

之后随时可以用 `meshlink doctor` 检查整条链路；`meshlink uninstall` 用于卸载。

## 配对

可以不做第 3 到 5 步，改由 Windows 上的 meshlink Rhino 插件和 Mac 上的
`meshlink pair` 在局域网里完成配对。两边屏幕会显示同一个 6 位配对码；双方都确认后，
插件安装 Mac 的 SSH 公钥（以管理员身份运行 `prepare-windows.ps1`），Mac 核对 Windows
的主机公钥并添加 Host 条目。只要有一方没有确认，两台电脑都不会有任何改动。协议见
[docs/pairing.md](docs/pairing.md)。

目前只在一台 UAC 关闭的 Windows 10 电脑上测试过。试用方法：

1. 从 [0.3.0-dev 预发布版](https://github.com/rigelmansid/meshlink/releases/tag/v0.3.0-dev)下载 `meshlink-<版本>-rh8_17-win.yak`。想自己打包的话，
   需要 .NET SDK 和 McNeel 的
   [`yak` 工具](https://developer.rhino3d.com/guides/yak/yak-cli-reference/)：
   `YAK=/path/to/yak scripts/package-yak.sh` 会把它生成到 `dist/`。
2. 在 Windows 上按第 1 步装好 OpenSSH Server 和 RhinoMCP，再把 `.yak` 文件拖进
   Rhino 8（8.17 或更新），然后重启 Rhino。
3. 在 Mac 上运行 `meshlink pair`。几秒内 Rhino 会弹出配对请求。核对两边的配对码，
   选择 Mac 要登录的 Windows 账户（专用的普通账户更安全），然后在两边确认。
4. 和上面第 4 步一样运行 `meshlink client codex`。此后每次打开 Rhino，插件都会自动
   运行 `mcpstart`；在 Rhino 里用 `MeshlinkOptions` 可以关掉。

在 Rhino 里运行 `MeshlinkUnpair` 可以删掉配对时装给某台 Mac 的公钥；Mac 上再删掉
`meshlink pair` 在 `~/.ssh/config` 里添加的 Host 条目。

## 仓库内容

| 路径 | 内容 |
|---|---|
| [docs/remote-setup.md](docs/remote-setup.md) | **从这里开始。** 配置指南（英文）：Windows OpenSSH、两种连接方式、排障、安全。 |
| [bin/meshlink](bin/meshlink) | `meshlink` 命令。只负责转发到下面的各个脚本，这些脚本也可以单独运行。 |
| [install.sh](install.sh)、[uninstall.sh](uninstall.sh) | 安装到 `~/.local`（重新运行即升级），以及卸载。两者都不改 `~/.ssh`；卸载时删除 Codex 条目前会先询问。 |
| [scripts/package.sh](scripts/package.sh) | 生成 `dist/meshlink-<版本>.tar.gz` 及其 SHA-256 校验文件。 |
| [tests/test-install.sh](tests/test-install.sh) | 在临时 HOME 中测试打包、安装、升级、卸载和 `meshlink` 命令。 |
| [scripts/setup.sh](scripts/setup.sh) | Mac 端首次配置：SSH 密钥、`~/.ssh/config` 中的 Host 条目、要在 Windows 上执行的完整命令、对照 Windows 报告核对主机指纹、测试登录。不会覆盖已有的密钥或 Host 条目。 |
| [scripts/pair.sh](scripts/pair.sh) | `meshlink pair`：在局域网里宣告本机，带 Rhino 插件走完 [docs/pairing.md](docs/pairing.md) 的四步，双方都确认后添加 Host 条目。 |
| [scripts/client-codex.sh](scripts/client-codex.sh) | 把 Codex 的 MCP 条目指向 Windows 上的 `rhinomcp`，然后运行 `doctor`。直接编辑 `config.toml`：已有条目只改命令和参数两行，其他设置和所有注释都保留。修改已有的不同条目前要确认，并先备份。 |
| [tests/test-setup.sh](tests/test-setup.sh) | 在临时 HOME 中用假的 `ssh` 和 `codex` 测试 `setup.sh` 与 `client-codex.sh`。 |
| [scripts/doctor.sh](scripts/doctor.sh) | 只读诊断：逐段检查整条链路，最后做一次真实的工具调用。配置从 Codex 读取，不需要输入，也不修改任何东西。 |
| [tests/test-doctor.sh](tests/test-doctor.sh) | 用假的 `codex` 和 `ssh` 测试 `doctor.sh`，不需要 Windows 电脑。 |
| [scripts/prepare-windows.ps1](scripts/prepare-windows.ps1) | 在 Windows 管理员 PowerShell 中运行一次：防火墙、按 sshd 要求的权限放置 Mac 的公钥、`ClientAliveInterval`、uv 与固定版本的 `rhinomcp`，最后输出报告（含主机指纹）。可重复运行，`-WhatIf` 可预览。不安装 OpenSSH Server 和 Rhino 插件。 |
| [tests/prepare-windows-checklist.md](tests/prepare-windows-checklist.md) | Windows 脚本的手动测试清单（英文；Mac 端只检查语法）。 |
| [rhino-plugin/](rhino-plugin) | 用于配对的 Rhino 插件（C#、.NET 8），以及它的配对库、单元测试和测试驱动程序。 |
| [scripts/package-yak.sh](scripts/package-yak.sh) | 把插件打成 Yak 包，连同 SHA-256 校验文件输出到 `dist/`。 |
| [tests/test-pair.sh](tests/test-pair.sh) | 用假的插件端测试 `pair.sh`；加 `PAIR_CLIENT=dotnet` 时改用插件自己的配对代码。 |
| [tests/rhino-plugin-checklist.md](tests/rhino-plugin-checklist.md) | 插件在 Rhino 里的手动测试清单（英文）。 |
| [scripts/rhino-tunnel.sh](scripts/rhino-tunnel.sh) | 维持 SSH 端口转发：断线后按退避策略重连；端口被占用时拒绝启动；Codex 配置里的 `RHINO_MCP_PORT` 不一致时发出警告；ssh 完全不能联网时（例如在沙箱里）停止并以退出码 3 结束。 |
| [tests/test-rhino-tunnel.sh](tests/test-rhino-tunnel.sh) | 用假的 `ssh` 测试隧道脚本，不需要 Windows 电脑。 |
| [experiments/](experiments/) | `mcp_stdio_probe.py`：一个小型 MCP 客户端，用来端到端检查服务是否可用；以及方式一的测试记录。 |
| [docs/project-notes.md](docs/project-notes.md) | 开发记录：当前状态、待办。同目录还有[开发规划](docs/roadmap.md)、[设计决策](docs/decisions.md)、[踩过的全部坑](docs/pitfalls.md)和[阶段与验证记录](docs/log.md)。 |
| [AGENTS.md](AGENTS.md) | 在本仓库工作的 AI agent 与贡献者需要遵守的规则（英文）。 |
| [CHANGELOG.md](CHANGELOG.md) | 各版本的变更记录（英文）。 |
| [.github/workflows/tests.yml](.github/workflows/tests.yml) | 每次推送到 `main` 和每个 PR 时，在 macOS 上运行全部自动化测试。 |

## 两种连接方式

两种方式都需要 Mac 能用密钥 SSH 登录 Windows。Rhino 的端口在两台电脑上都只监听本机。

- **方式一：通过 SSH 运行服务（推荐）。** MCP 客户端执行 `ssh rhino-pc rhinomcp.exe`，
  服务在 Windows 上运行，在本机连接 Rhino。两次会话之间不需要任何常驻进程。
  Windows 上需要安装 `uv` 和 `rhinomcp`。测试中，网络中断后 Codex 不会自动重连，
  网络恢复后重启 Codex 即可恢复。
- **方式二：SSH 端口转发。** `rhinomcp` 在 Mac 上运行，由 `scripts/rhino-tunnel.sh`
  转发端口。Windows 上只需要 Rhino 插件和 OpenSSH Server。

两种方式的详细步骤见 [docs/remote-setup.md](docs/remote-setup.md)。

## 环境要求

- **Mac：** macOS，系统自带 `bash`、`ssh`、`lsof`。方式二还需要
  [`uv`](https://docs.astral.sh/uv/) 和 `rhinomcp`。
- **Windows 电脑：** Windows 10 或 11，安装 OpenSSH Server；Rhino 8 并安装 RhinoMCP
  插件（**Tools → Package Manager → `rhinomcp`**）。
- **MCP 客户端：** 例如 Codex CLI 或 Claude Code。

实测环境：macOS 26（arm64）、Windows 10 22H2、Rhino 8.35、rhinomcp 0.4.1.1、
Codex CLI 0.155.1 至 0.159.3。其他版本大概率可用，但没有验证过。

## 使用隧道脚本（方式二）

先按指南在 `~/.ssh/config` 里配置好 `rhino-pc` 主机，并运行一次 `ssh rhino-pc`
确认主机指纹。然后在 Rhino 里运行 `mcpstart`，再执行：

```sh
scripts/rhino-tunnel.sh        # 保持运行；按 Ctrl-C 停止
```

主机、用户、密钥和保活参数都从 `~/.ssh/config` 读取。其余设置通过环境变量调整：

| 变量 | 默认值 | 含义 |
|---|---|---|
| `HOST` | `rhino-pc` | `~/.ssh/config` 中的主机名 |
| `LOCAL_PORT` | `1999` | Mac 上的端口。修改后，客户端配置里的 `RHINO_MCP_PORT` 要改成同一个值 |
| `REMOTE_PORT` | `1999` | Rhino 监听的端口，保持不变 |
| `CODEX_CONFIG` | `~/.codex/config.toml` | 检查 `RHINO_MCP_PORT` 是否一致时读取的配置文件 |
| `BASE_DELAY` / `MAX_DELAY` | `5` / `60` | 重连退避时间（秒） |

MCP 服务显示已连接，并不代表 Rhino 真的连得上。要检查整条链路，请让 agent 调用一次
只读工具，例如 `get_document_summary`。

## 运行测试

```sh
tests/test-install.sh        # 约 10 秒
tests/test-setup.sh          # 约 4 秒
tests/test-doctor.sh         # 约 6 秒，使用本地端口 29941–29942
tests/test-rhino-tunnel.sh   # 约 40 秒，使用本地端口 29931–29937
tests/test-pair.sh           # 约 25 秒，使用本地端口 29951–29952
dotnet test rhino-plugin/Meshlink.Pairing.Tests   # 需要 .NET SDK
```

测试使用假的 `ssh`、`codex`、`dns-sd` 和临时 HOME，需要 `python3`；不会读写 `~/.ssh`
和 Codex 的配置，也不会连接任何真实主机。GitHub Actions 会在 macOS 上用系统自带的
bash 3.2 运行它们。Windows 脚本和插件分别按
[tests/prepare-windows-checklist.md](tests/prepare-windows-checklist.md) 和
[tests/rhino-plugin-checklist.md](tests/rhino-plugin-checklist.md) 手动测试。

## 安全

任何能使用这把 SSH 密钥的人，都能以该 Windows 用户身份执行任意命令；RhinoMCP 的
代码执行工具也能通过 Rhino 做到同样的事。真正的安全边界是 SSH 密钥和 Windows 账户。
建议使用专用的普通（非管理员）Windows 账户。详见指南中的 Security 一节。

## 许可证

[MIT](LICENSE)。RhinoMCP 是 Jingcheng Chen 开发的独立项目，同样采用 MIT 许可证。
本项目与 McNeel 及 RhinoMCP 均无隶属关系。
