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

### D-5 暂不设置 `mcpstart` 随 Rhino 自动执行（待定项）（日期未记录）（已被 D-23 替代）

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

### D-7 上游文档 PR #63（2026-09-28 提交）（已被 D-30 替代）

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

### D-17 不发 0.1.0-dev.2，等全新 Windows 验收后发正式 0.1.0（2026-10-04，用户决定）（已被 D-31 替代）

- 背景：`v0.1.0-dev`（2026-10-02）之后的修复（密钥注释、重跑 `setup` 的密钥、远端报错
  换行、Windows 报告去掉 `-l`）不在已发布的压缩包里。
- 选项：A 现在发预发布 `0.1.0-dev.2` / B 不再发预发布，等全新 Windows / Windows 11 验收后
  发正式 `0.1.0`
- 选择：B
- 理由：用户决定。
- 影响：§7 删除“决定是否重新发布”一项；roadmap 首版版本号一行写明不再发中间预发布；在此
  之前从源码或 `v0.1.0-dev` 使用的人拿不到上述修复。

### D-18 下一步推进发现与配对，作为 0.2 方向；全新 Windows 验收暂缓（2026-10-04，用户决定）

- 背景：用户自己的 Mac 到 Windows 操控已经跑通，想继续推进 roadmap「长期方向」里的
  交互方式，并做成便于安装复用的安装包；全新 Windows / Windows 11 验收暂时不排。
- 选项：方向 A 发现与配对（Windows 端 Rhino 插件 + Mac 端发现与配对）/ B 只把现有流程
  做成两端安装包 / C Mac 菜单栏应用；版本 A 作为 0.2 方向开发 / B 并入首个正式版
- 选择：方向 A；版本 A
- 理由：用户决定。配对能省掉现在最麻烦的手动步骤（粘贴命令、装公钥、核对指纹）；
  作为 0.2 开发不改变 0.1.0 的范围。
- 影响：0.1.0 范围与 D-17 不变，仍等全新 Windows 验收后发布；§7 的 W1 验收标为暂缓；
  roadmap「长期方向」从第二版设想转为当前开发方向，具体设计另行记录。

### D-19 Windows 端配对组件做成自己的 Rhino 插件（2026-10-04，用户决定）

- 背景：roadmap「长期方向」待解决的第一项：C# 组件自己写插件，还是给上游 rhinomcp 提 PR。
- 选项：A 独立插件 `meshlink`（C#、net8.0，Yak 包），rhinomcp 作为前提 / B 给 rhinomcp 提 PR
- 选择：A
- 理由：提权、写公钥、局域网配对都不在 rhinomcp 的职责内；PR #63 至今无回应，进度不应
  依赖上游。rhinomcp 只面向 net8.0，插件跟随它，不做 net48。
- 影响：仓库新增插件源码目录；发布物多一个 Windows 端 Yak 包。

### D-20 配对由 Mac 广播并监听，Rhino 发现后弹窗并主动连出（2026-10-04，用户决定）

- 背景：配对前两端还没有 SSH 信任，需要一条临时通道交换 Mac 公钥和 Windows 主机公钥。
- 选项：A Mac 用 `dns-sd -R` 广播、`nc -l` 临时监听，Rhino 插件发现后弹窗并连出 /
  B Rhino 插件广播并开配对端口，Mac 连过去
- 选择：A
- 理由：Windows 不开新的入站端口，不触发“允许 Rhino 通过防火墙”的管理员对话框，与 D-1
  只让 SSH 跨机的思路一致；Mac 端只用系统自带的 `dns-sd`、`nc`、`shasum`。
- 影响：协议用“先承诺后揭示 + 两端显示同一个 6 位配对码”防中间人（细节见
  `docs/pairing.md`）；写公钥由插件以 UAC 提权运行 `prepare-windows.ps1`，UAC 即管理员确认。

### D-21 插件在 Mac 上用 .NET 8 SDK 编译（2026-10-04，用户决定）

- 背景：这台 Mac 没有 .NET SDK，也没有 Mac 版 Rhino。
- 选项：A 用户在 Mac 上安装 .NET 8 SDK，编译后拷到 PC 测试 / B 在 Windows PC 上编译
- 选择：A
- 理由：agent 能在本机编译和跑单元测试；RhinoCommon 从 NuGet 获取，不需要 Mac 版 Rhino。
- 影响：SDK 由用户安装；协议部分写成不依赖 RhinoCommon 的库，单元测试在 Mac 上运行；
  加载与真实配对仍需在 PC 上由用户操作。

### D-22 Windows 端以 Rhino 弹窗为必需的确认，UAC 只是附加（2026-10-05，agent 选择）

- 背景：Phase 0 探针在原环境通过了发现与连出（P1、P2），但测试机 UAC 关闭，`runas` 不弹
  窗直接提权。D-20 原把 UAC 当作管理员确认。
- 选项：A 只在 UAC 开启时允许配对 / B Rhino 弹窗（显示配对码、允许/拒绝）始终是必需的
  确认，UAC 开启时再多一次系统确认
- 选择：B
- 理由：UAC 关闭的机器上 Rhino 本来就有完整管理员权限（D-13），拒绝配对不会更安全，
  只会让这类用户退回手动流程；配对码的比对已经由 Rhino 弹窗完成。
- 影响：插件弹窗写明“允许后将以管理员身份修改 SSH 配置”；UAC 开启时的路径（未提权读
  主机公钥、UAC 弹窗与拒绝）需要一台 UAC 开启的 Windows 验证，并入暂缓的全新 Windows
  验收（§7）。D-20 的方向不变。

### D-23 配对成功后 Rhino 启动时自动运行 mcpstart，配对提示默认开启（2026-10-05，agent 选择）

- 背景：路线图要求配对后“Rhino 打开即可用”；rhinomcp 的监听要在每次打开 Rhino 后手动
  `mcpstart`。插件随 Rhino 启动加载，可以代为执行。
- 选项：A 插件不碰 `mcpstart` / B 配对成功后打开“启动时运行 mcpstart”，可在
  `MeshlinkOptions` 关闭 / C 装上插件就自动运行
- 选择：B；另外“发现配对请求时提示”（ListenForPairing）默认开启
- 理由：配对成功是用户明确要从 Mac 使用这台 Rhino 的信号，没配对过的机器行为不变；监听
  仍只在 127.0.0.1（D-1）。不想在办公网络里收到提示的，可以关掉 ListenForPairing，
  改用 `MeshlinkPair` 命令。
- 影响：插件设置 `ListenForPairing`（默认 On）与 `StartMcpOnLaunch`（默认 Off，配对成功
  后置 On）；1999 端口已在监听时不再运行 `mcpstart`。

### D-24 Yak 包用官方 yak 工具打，工具放在仓库外（2026-10-07，用户决定）

- 背景：Phase 3 要把插件做成 Yak 包，用 Package Manager 安装与卸载。这台 Mac 没有 Rhino，
  也就没有随 Rhino 附带的 `yak`。
- 选项：A 从 files.mcneel.com 下载独立的官方 `yak`，放在 `../materials/scratch/tools/` /
  B 用户自己安装 `yak` / C 不用 `yak`，脚本按文档结构自己压 zip
- 选择：A
- 理由：官方工具读 `.rhp` 算出兼容的 Rhino 版本标记并检查 manifest，不用手工猜；放在仓库外，
  不装进系统。
- 影响：新增 `scripts/package-yak.sh`，通过环境变量 `YAK` 或 PATH 找 `yak`；包输出到
  `dist/`。推送到公共 Yak 服务器仍是对外操作，由用户决定。

### D-25 MeshlinkUnpair 只列出经插件配对过的 Mac（2026-10-07，用户决定）

- 背景：撤销配对要从 Windows 账户的 `authorized_keys` 删掉对应公钥；配对装的公钥和
  `setup` 手工装的公钥注释都是 `meshlink`，单看文件分不出来。
- 选项：A 配对成功时插件记下 Mac 名字、账户和公钥，`MeshlinkUnpair` 只列这些 / B 列出
  某个账户的全部公钥，任选删除 / C 暂不做
- 选择：A
- 理由：不会误删不是配对装上的公钥；删除对象明确。
- 影响：插件设置里保存配对记录；`prepare-windows.ps1` 增加只删公钥的 `-RemoveKey` 模式，
  插件以提权方式运行它。配对前已有的公钥不在列表里，需要时按手动方法删除。

### D-26 插件的 Yak 包暂不推送到公共服务器（2026-10-07，用户决定）

- 背景：Phase 3 做出了 Yak 包并在原环境验证了安装、撤销配对与卸载（R12–R14）。推送到公共
  Yak 服务器后撤不回（只能 yank），首个公开版本号也会影响以后的预发布排序。
- 选项：A 现在推送 / B 暂不推送，继续其他工作
- 选择：B
- 理由：用户决定。插件只在一台 UAC 关闭的 Windows 10 上验证过；版本号方案还要再讨论。
- 影响：包只在本地 `dist/` 生成，在 PC 上用拖入 `.yak` 的方式安装；推送与首个公开版本号
  留到以后再定（§7）。

### D-27 `client codex` 直接编辑 config.toml，不再默认用 `codex mcp add`（2026-10-07，agent 选择）

- 背景：`codex mcp add` 会重写整个 `config.toml`，删掉所有注释，并丢掉被替换条目的 env、
  启动超时和工具审批（坑 19）。原来的做法只是事先列出损失、备份并要求确认。
- 选项：A 继续用 `codex mcp add` / B 在 bash 里直接编辑：已有条目只替换 `command` 与
  `args` 两行，没有条目就在文件末尾追加一节，写后由 Codex 读回核对 / C 等 Codex 提供只改
  部分字段的命令
- 选择：B；条目不是 Codex 写出的形式（`args` 跨行、内联表等）时退回 A，并照旧列出损失、
  备份、要求确认
- 理由：其余内容逐字节不变，不再需要用户在丢设置和不更新之间二选一；只认 Codex 自己写出
  的简单形式，认不出就退回，不去解析完整 TOML。
- 影响：`scripts/client-codex.sh`；Codex 读回的命令、参数与 env、启动超时不符时从备份恢复；
  读不了的 `config.toml` 不碰。`tests/test-setup.sh` 的假 codex 改为读写 `config.toml`。

### D-28 不再要求生成的脚本自己包撤销记录（2026-10-07，agent 选择）

- 背景：AGENTS.md 要求每段生成的建模脚本用 `BeginUndoRecord` / `EndUndoRecord` 包成一步
  撤销。§7 待核实 rhinomcp 是否已经这样做。
- 选项：A 保留这条规定 / B 删除，改为说明 rhinomcp 的行为与升级后要重新核对
- 选择：B
- 理由：rhinomcp 0.4.1.1 的 Rhino 插件把每条非只读命令（含执行 Python、C# 脚本的两条）
  包在一条 `MCP: <命令名>` 撤销记录里（`plugin/RhinoMCPServer.cs`，标签 `releases/0.4.1.1`）；
  RhinoCommon 文档说明记录已在进行时 `BeginUndoRecord` 返回 0、不开新记录。脚本自己再包
  一层不起作用。
- 影响：AGENTS.md 的建模安全规则改写；rhinomcp 升级后要重新核对（坑 14）。

### D-29 用 GitHub Actions 在 macOS 上跑全部自动化测试（2026-10-08，用户决定）

- 背景：roadmap 阶段 4（测试与 CI）未开始，五组 bash 测试和 .NET 测试只在维护者本机运行。
  用户同意先做 CI。
- 选项：A 继续只在本机跑 / B GitHub Actions，macOS runner / C 同时加 Linux runner
- 选择：B
- 理由：项目只支持 macOS，测试依赖 macOS 的 `lsof`、`nc` 与系统 bash 3.2；公开仓库的
  macOS runner 免费。Linux 上通过不说明任何支持（roadmap 实现边界），先不加。
- 影响：新增 `.github/workflows/tests.yml`：推送到 `main` 与每个 PR 时，用系统 bash 3.2
  （放在 PATH 最前）做语法检查并运行五组 bash 测试，装 .NET 8 与 10 后运行 .NET 测试、
  dotnet 模式的配对测试并编译插件。打包（`package-yak.sh` 需要 yak）不在 CI 里。

### D-30 关闭上游 PR #63、删除 fork，项目结束后再定是否提交（2026-10-08，用户决定）

- 背景：PR #63（D-7）自 2026-09-28 提交后无回复；meshlink 不依赖它，§7 一直留着“跟进”和“约两周后
  留言”两项。fork `rigelmansid/rhinomcp` 只为它存在：`main` 与上游相同，`harness` 分支没有自己的提交。
- 选项：A 继续开着并跟进 / B 开着不管 / C 关闭 PR、删除 fork，项目结束后再看是否重新提交
- 选择：C
- 理由：没有回应时持续跟进只占待办；指南全文在 `docs/remote-setup.md`，以后重新 fork 并提交只需几分钟。
- 影响：2026-10-08 关闭 PR 并留言说明以后可能重新提交；fork 由用户在网页删除；本机的临时 clone
  （已为空）删除。§7 删去“跟进 PR #63”，文章不再等 PR；AGENTS.md 删去与 PR 保持一致的规定；
  `docs/remote-setup.md` 开头改注 PR 已关闭。

### D-31 发 demo 预发布 `v0.3.0-dev`，Mac、插件与 GitHub 统一版本号（2026-10-09，用户决定）

- 背景：用户想先出一版 demo：完整的 Mac 端安装包和 Windows 端插件包。D-17 定的是全新 Windows
  验收前不发中间预发布；Mac 端版本 `0.1.0-dev`（与 2026-10-02 的预发布同名但内容不同），插件
  `0.2.0-dev`，两者不一致。
- 选项：版本 A `0.2.0-dev.1`（沿用 0.1 / 0.2 规划）/ B `0.3.0-dev`；发布 A 只在本地打包 /
  B 在 GitHub 发预发布
- 选择：版本 B，发布 B。写成三段的 `0.3.0-dev`：yak 会把 `0.3-dev` 补成 `0.3.0-dev`，
  两段写法会让三处不一致。
- 理由：用户决定。`0.3.0-dev` 高于 PC 上已装的 `0.2.0-dev`，插件可直接覆盖升级。
- 影响：替代 D-17。`VERSION` 与插件 `<Version>` 改为 `0.3.0-dev`，GitHub 发预发布 `v0.3.0-dev`，
  附 Mac 压缩包、`.yak` 与两者的校验文件；发布说明写明只在一台 UAC 关闭的 Windows 10 上验证。
  原规划的 0.2（发现与配对，D-18）并入此版；之后不再单独发 0.1.0 或 0.2.x（版本号会低于已发布的
  `0.3.0-dev`），全新 Windows 验收后的正式版为 `0.3.0`。Yak 仍不推送到公共服务器（D-26）。

### D-32 Mac 端用一行命令安装（`get.sh`），双击安装的 `.pkg` 作为完整形态（2026-10-09，用户决定）

- 背景：首次安装要五步：下载、双击解压、在终端 `cd` 进去、运行 `./install.sh`、按提示把
  `~/.local/bin` 加进 PATH。用户希望简化。
- 选项：A 一行命令 `curl … get.sh | bash` / B Homebrew tap / C 只让 `install.sh` 自动加 PATH /
  D 双击安装的 `.pkg`（需要 Apple 开发者账号签名与公证，否则 macOS 拦截）
- 选择：现在做 A（含 C 的自动加 PATH）；D 记为完整形态，以后朝这个方向优化。
- 理由：A 不需要新账号或新仓库，能用测试覆盖，一步完成；D 对非开发者最友好，但要先解决签名与
  公证（年费、证书、CI 中的公证流程）。
- 影响：新增仓库根目录的 `get.sh`：从 GitHub 发布列表（`releases.atom`，含预发布；不用 REST API，
  它对匿名请求每个地址每小时只允许 60 次）找到最新版，下载并核对 SHA-256，运行包内 `install.sh`，
  PATH 里没有 `~/.local/bin` 时写入 `~/.zshrc` 或 `~/.bash_profile`（`MESHLINK_NO_MODIFY_PATH=1`
  可关闭）。手动解压安装仍保留。新增 `tests/test-get.sh` 并加入 CI。roadmap 产品形态与 §7 记下 D。
  替代 roadmap 待确定事项“安装路径、分发与升级”中“只用 Release 压缩包 + `install.sh`”的说法。

### D-33 Windows 端：插件仍下载 `.yak` 手动安装，OpenSSH Server 用一条命令装好并启动（2026-10-09，用户决定）

- 背景：D-32 之后 Mac 端一行命令即可安装。Windows 端要在“可选功能”里找 OpenSSH Server（Windows 10
  的菜单位置各版本不同），再把 `.yak` 拖进 Rhino。
- 选项：A 一行命令 `irm … get.ps1 | iex` 同时装 OpenSSH 与插件（已写成并测过语法与纯函数，未在
  Windows 运行）/ B 插件仍手动下载 `.yak` 安装，OpenSSH 用管理员 PowerShell 里的一行内置命令
- 选择：B。A 的脚本由用户撤回，存于仓库外 `../materials/scratch/withdrawn/`，未进入仓库。
- 理由：用户决定。B 不需要下载和信任额外脚本，命令本身就是 Windows 自带的三条，可重复运行。
- 影响：README（中英）快速开始：Windows 上装 Rhino 8 与 RhinoMCP、下载 `.yak` 拖进 Rhino、在管理员
  PowerShell 运行 `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0; Set-Service sshd -StartupType Automatic; Start-Service sshd`；Mac 上 `get.sh`，然后配对。启动一次 sshd 才会生成配对要读的主机公钥；防火墙
  规则与公钥仍在配对时由 `prepare-windows.ps1` 设置。手动 `setup` 移到“不用配对”。

### D-34 `v0.3.0-dev` 原地更新，不升版本号（2026-10-09，用户决定）

- 背景：`v0.3.0-dev` 发布后又有一行命令安装（D-32）、OpenSSH 一行命令（D-33）、`--help` 与卸载提示的修复。
- 选项：A 发新的预发布（如 `0.3.0-dev.2`）/ B 原地更新 `v0.3.0-dev`：标签移到最新提交，替换附件与发布说明
- 选择：B
- 理由：用户决定，demo 阶段只保留一个最新的预发布。
- 影响：强制移动已公开的标签 `v0.3.0-dev`，重传 4 个附件（`--clobber`），重写发布说明；CHANGELOG 把这些
  改动并入 `0.3.0-dev`。之前下载过的人拿到的是同名的旧内容：Mac 端重跑 `get.sh` 或 `install.sh` 即可更新；
  PC 上同版本的 `.yak` 要先在 Package Manager 卸载再装。以后发正式版时不再这样原地替换。

### D-35 去掉 code profile 声明，接入后的文件全部保留（2026-10-09，用户决定）

- 背景：agent-system 收敛为 RULE.md 和 /adopt、/pickup、/wrap、/private 四个命令，删除了 profile
  （agent-system D-62）；有 `docs/project-notes.md` 就算接入，AGENTS.md 第一行的 profile 声明不再起作用。
- 选项：A 保留这行声明 / B 删掉声明，接入后的文件全部保留
- 选择：B
- 理由：用户决定；不起作用的声明留着，会让人以为还在按 code profile 工作。
- 影响：AGENTS.md 第一行。code profile 的规则不再自动加载，测试、提交、验证、发布等规则 AGENTS.md 里已有；`log.md` 照
  AGENTS.md「Keeping docs current」一节继续更新；新记的坑按 agent-system RULE.md 第 2 节的格式，旧条目不改；pre-commit 钩子不变。

### D-36 AGENTS.md 去掉和 agent-system 重复的会话流程（2026-10-09，用户决定）

- 背景：Getting started 第 1 条（开场读 Handoff 和待办、先向用户复述）和 Keeping docs current 里 Handoff 的写法，与 agent-system 的 RULE.md、/pickup、/wrap 重复（agent-system D-38）；开场先读状态
  还和 RULE.md 1.1 冲突，而本文件的优先级更高。
- 选项：A 保留 / B 删掉重复的部分，只留本项目特有的
- 选择：B。开场不再自动读状态，要看现状时用户输入 /pickup；收尾用 /wrap，另外更新当前状态、验证现状，并在 `docs/log.md` 追加阶段记录和验证记录。
- 理由：用户决定。
- 影响：AGENTS.md Getting started 第 1 条、Keeping docs current 第 2 条。
