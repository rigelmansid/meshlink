# 踩过的坑

迁移自 project-notes 原 §6（2026-10-03），编号不变，新坑按下一个编号追加。每条写：现象、
原因、修法、→ 对后续工作的启示；由此得出的行为规则写进 [AGENTS.md](../AGENTS.md) 并标注
“坑 n”。文中 §n 指 [project-notes.md](project-notes.md) 的章节（原 §5 的决策现在是
[decisions.md](decisions.md) 的 D-n），“验证范围”指 [log.md](log.md) 的验证记录。

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

7. **`mcpstart` 每个 Rhino 会话都要重跑** — 忘了的表现见下条。装了 meshlink 插件时由插件在
   Rhino 启动时自动运行（D-23，可在 `MeshlinkOptions` 关掉）。

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

    **2026-10-08 更新**：已实施“识别沙箱错误后退出”。ssh 的 stderr 经 `tee` 同时写入
    临时文件；转发从未绑定且其中有 `Operation not permitted` 时，脚本说明原因并以退出码
    3 结束，不再重试（`test-rhino-tunnel.sh` T5）。用 `sandbox-exec` 禁网运行 ssh 实测，
    报错为 `ssh: connect to host <地址> port 22: Operation not permitted`，与匹配的文字一致。
    这只覆盖“完全不能联网”的沙箱；能联网但不能绑定本地端口等其他限制未见过，未处理。

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
    更好的做法是只改 `command` / `args` 两行、保留其余内容：2026-10-07 起如此（D-27），
    只有认不出的写法才退回 `codex mcp add`。

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


22. **推送 workflow 文件被拒：令牌没有 `workflow` 权限**（2026-10-08 发现）—— 首次推送
    `.github/workflows/tests.yml` 时 GitHub 拒绝：`refusing to allow a Personal Access Token to
    create or update workflow ... without workflow scope`，整个推送没有生效。git 的凭据来自
    macOS 钥匙串（`credential.helper=osxkeychain`），其中的令牌和 gh 的令牌都只有 `repo` 等
    权限。普通文件的推送不受影响，所以平时看不出来。

    → 用户运行 `gh auth refresh -h github.com -s workflow` 给 gh 的令牌加权限，之后只在
    改动 workflow 文件的那次推送里临时改用 gh 的令牌，不改 `~/.gitconfig`：
    `git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin public:main`。

23. **GitHub REST API 对匿名请求限流，共享网络很快用完**（2026-10-09 发现）—— 写 `get.sh` 时
    用 `api.github.com/repos/.../releases` 查最新版，直接得到 403：`API rate limit exceeded`，
    `x-ratelimit-limit: 60`、`remaining: 0`。匿名请求按出口地址每小时 60 次，同一网络里的
    其他人和工具也在消耗；办公室、学校等共享出口的用户会随机碰到。

    → 安装脚本找最新版改读 `https://github.com/<repo>/releases.atom`（含预发布，最新在前，
    条目 id 以标签结尾），不走 REST API（D-32）。`/releases/latest` 不含预发布，也不能用。
