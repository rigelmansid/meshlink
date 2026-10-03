# 决策记录

做出决策时当场追加，编号递增，旧条目不改编号。推翻旧决策时在旧条目标题后加
“（已被 D-n 替代）”，新条目写明替代了谁。新条目的格式：标题带日期和“用户决定 / agent
选择”，正文分背景、选项、选择、理由、影响五项（见 D-14）。D-1–D-13 迁移自 project-notes
原 §5（2026-10-03），保留原来的写法。

文中 §n 指 [project-notes.md](project-notes.md) 的章节，坑 n 见 [pitfalls.md](pitfalls.md)，
“验证范围”指 [log.md](log.md) 的验证记录。

### D-1 跨机一跳交给 SSH，不让客户端直连远程目标（日期未记录）

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

### D-2 保留全部代码执行工具（日期未记录）

`run_command`、RhinoScript-Python、RhinoCommon C# 三条执行通道全开（对应
`RHINO_MCP_ENABLE_*` 三个开关，设 0 可分别关闭）。

理由：复杂建模需求模型会自己写脚本完成，不受预置工具限制。风险由 SSH 边界控制。
代价要如实写进安全说明：SSH 密钥 + 代码执行工具 = 对该 Windows 账户的完整代码执行
权限。

### D-3 固定 rhinomcp 版本，不用 `uvx rhinomcp@latest`（日期未记录）

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

### D-4 守护连接禁用交互认证（BatchMode=yes）（日期未记录）

ssh 的密码提示和指纹确认读的是 **/dev/tty 而非 stdin**，bash 把后台子进程的 stdin
重定向到 /dev/null 挡不住它们，而隧道脚本刻意跑在用户的终端窗口里。一旦触发提示
（远端 authorized_keys 权限回归导致密钥被拒；或 Windows 重装 sshd 导致指纹变化），
整个守护循环会卡在一个没人看得见的提问上。

所以 ssh 命令带 `-o BatchMode=yes`：一切提示变成即时失败，由绑定探测归类为
never connected 走退避，问题打在日志里。这与“密钥无 passphrase 以支持无人值守重连”
是同一个设计决策的两半。选项 1 的客户端配置同样带 `BatchMode=yes`。

代价：密钥失效时不能顺手输密码，那本来就不该是守护脚本的能力。
**首次指纹确认是手动安装步骤**：连一台新机器前先手动 `ssh rhino-pc` 一次。

### D-5 暂不设置 `mcpstart` 随 Rhino 自动执行（待定项）（日期未记录）

Rhino 支持在 `Tools → Options → General → "Run these commands every time Rhino starts"`
填入 `mcpstart`。**目前不做**，原因是没必要，而不是有害：

- 单次 10 秒观测中，Rhino 空闲时监听的 CPU 增量为 0 ms（阻塞式 accept），也不碰
  文档和 undo 记录。这只能说明“该次未观察到影响”。
- 用之前总要主动做一步（开隧道或启动客户端），把这一步从 Windows 侧的 `mcpstart`
  挪走并没有净收益。

若将来改变主意，需要知道两个副作用：端口对该 Windows 上的**任何本地进程**开放；
agent 的改动与手动建模共用同一个 undo 栈，可能互相撤销。

### D-6 许可证与文档语言（2026-09-28）

MIT 许可证，署名 `Cheng Yuan`。英文主 README + 中文 `README.zh-CN.md`；开发记录
（本文）保持中文。

### D-7 上游文档 PR #63（2026-09-28 提交）

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

### D-8 本地 `main` 不推送，从孤立分支 `public` 发布（2026-09-28 决定，2026-10-01 执行）

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

### D-9 只做 Rhino，方向 C（2026-09-30）

**决定**：项目范围收敛到 Rhino 8 一条线，把现有方案做成可安装的工具（方向 C）。
其他设计软件（Revit、AutoCAD 等）和整机远程控制不在范围内；相关调研、讨论和
“通用 Mac→Windows MCP 桥”（方向 D）的规划已从仓库删除，需要时从本地 git 历史找回。

**理由**：Rhino 这条线已经有真实可用的链路和完整的排障经验，先把它做成别人能装、
能诊断的工具，比同时铺开多个软件更可控。

**替代的旧决策**：2026-09-28 的方向复盘选了方向 B（给上游提文档 PR + 写踩坑总结），
C 暂缓、D 视反馈而定。B 的文档 PR 已提交（见下），不再作为主方向；踩坑总结文章仍在
§7 待办中。

### D-10 默认连接方式：选项 1（SSH stdio）（2026-10-01）

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

### D-11 Mac 端 CLI 用 bash 实现（2026-10-01）

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

### D-12 Windows 端提供 PowerShell 准备脚本（W1）（2026-10-01）

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

### D-13 Windows 账户：推荐专用普通账户登录 SSH，兼容管理员账户（2026-10-01）

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

### D-14 文档按读取频率拆成四个文件，决策当场编号记录（2026-10-03，用户决定）

- 背景：本文件拆分前 project-notes 有 1140 行，每次会话都要读；开新对话后，过程中的决策
  难以衔接，后续操作看不懂；文档维护集中在收尾，费时间。
- 选项：A 保持单文件 / B 按读取频率拆成 project-notes（热：进行中、现状、待办、规划）与
  decisions、pitfalls、log（冷，只追加），决策编号 D-n 并在做出时记录，project-notes 顶部加
  「进行中」区块
- 选择：B
- 理由：每次会话只需读「进行中」与待办；决策有编号后，规则、代码注释和提交信息可以引用
  编号，看不懂的操作能追溯到原因；当场记录让收尾只剩汇总。
- 影响：原 §5 移到本文件，按时间重新编号为 D-1–D-13，正文未改，原文无日期的标“日期未
  记录”；原 §6 移到 pitfalls.md，编号不变；原 §9 与「验证范围」表移到 log.md。project-notes
  保留原章节号，§5、§6、§9 留指向新文件的占位，所以历史记录里的 “§n” 仍然有效。AGENTS.md
  的文档维护规则相应改写，仍可独立使用。

### D-15 项目资料放在仓库旁的 materials/（2026-10-03，用户决定）

- 背景：参考资料、待整理资料不想放进仓库；规则只说“临时文件不写进项目目录”，没有
  固定位置，建模脚本等临时产出每次要另选目录。仓库旁有空的 `meshlink bak`，仓库里有
  空的 `temp/`。
- 选项：A 仓库内建 git-ignored 目录 / B 仓库同级的 `materials/`（`refs/`、`inbox/`、
  `scratch/`）/ C 统一的资料库（如 iCloud）
- 选择：B，并写进 `~/agent-system`，对所有项目生效
- 理由：在仓库外，`git add -A`、`scripts/package.sh` 和全仓搜索都碰不到，不会误提交或
  进发布包；和项目放在同一个容器文件夹里，好找；入库文件用相对路径 `../materials/`，
  不含个人路径。
- 影响：`meshlink bak` 改名为 `materials/` 并建三个子目录，删除空的 `temp/`；AGENTS.md
  的建模临时文件规则指向 `../materials/scratch/`；project-notes 文件表加一行。
  agent-system：RULE.md 第 4 节写入约定，profiles/code.md、模板 AGENTS.md 与
  project-notes、README.md 相应补充，`bin/new-project` 自动建 `../materials/` 三个子目录。
  约定假设每个项目有自己的容器文件夹；项目直接放在共享目录下时，`../materials/` 会被
  多个项目共用。

### D-16 开发规划移到 docs/roadmap.md，用中文（2026-10-04，用户决定）

- 背景：project-notes 有 612 行，超过约 600 行的上限；§8 开发规划约 160 行，变动少，
  每次会话不必读。AGENTS.md 原规定计划扩大后再拆成根目录的英文 `ROADMAP.md`。
- 选项：A `docs/roadmap.md`，中文，按标题整段原样搬过去 / B 根目录 `ROADMAP.md`，英文，
  只写面向使用者的未完成部分
- 选择：A，替代 AGENTS.md 原来“拆成 `ROADMAP.md`”的写法
- 理由：与 D-14 的拆分方式一致，不用翻译和取舍内容；docs/ 下的文件统一用中文。
- 影响：新增 `docs/roadmap.md`（原 §8，小节标题升一级，指向其他章节的引用改为
  “project-notes §n”或 log.md）；project-notes 的 §8 只留占位，所以历史记录里的 “§8”
  仍然有效，行数降到约 460；AGENTS.md 的文档列表与规划规则、README（中英）的文档表
  相应更新。
