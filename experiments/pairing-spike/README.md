# 配对 Phase 0 探针

验证 D-20 方案所依赖的四个前提，在写正式插件之前做。不随发布包分发。

| 编号 | 前提 | 失败时的影响 |
|---|---|---|
| P1 | Rhino 内用 Win32 `DnsServiceBrowse` / `DnsServiceResolve` 能发现 Mac 上 `dns-sd -R` 广播的 `_meshlink-pair._tcp`，并拿到 IPv4 与端口 | 改用 Makaretu 托管库，或退回手动输入地址 |
| P2 | Rhino 主动连出到 Mac 的 `nc -l` 时两端都不弹防火墙对话框 | 需要重新考虑连接方向 |
| P3 | 未提权的 Rhino 能读 `%ProgramData%\ssh\ssh_host_ed25519_key.pub` | 主机公钥改由提权步骤读取 |
| P4 | `Verb=runas` 启动 PowerShell 会弹 UAC，提权后的子进程能把结果写到父进程的临时目录 | 结果改走其他位置（如 `%ProgramData%`） |

## 运行

1. Mac 上编译（需要 .NET 8 SDK，D-21）：

   ```sh
   cd experiments/pairing-spike && dotnet build -c Release
   ```

   产物是 `bin/Release/net8.0/MeshlinkProbe.rhp`，拷到 PC 任意目录。
2. PC 上把 `.rhp` 拖进 Rhino 8 窗口加载（只需一次）。
3. Mac 上运行 `experiments/pairing-spike/mac-probe.sh`（默认端口 29950，等 120 秒）。
4. Rhino 命令行运行 `MeshlinkProbe`，出现 UAC 时按“是”；再运行一次并按“否”，看 P4
   的拒绝分支。
5. 记录 Rhino 命令行里的 `[probe]` 行和 Mac 端输出；两端是否出现防火墙对话框要人工观察。

测试后在 Rhino 的插件管理器里卸载 MeshlinkProbe。

## 结果

**2026-10-05 22:30，原环境 PC**（Rhino 8.35.26237.11001、.NET 8.0.22、Windows 10 22H2
19045、64 位；Mac 为 macOS 26。探针由 Mac 上 .NET SDK 10.0.401 编译，目标 net8.0、
RhinoCommon 8.17.25066.7001）。用户把 `.rhp` 拖进 Rhino 加载，Mac 运行 `mac-probe.sh`，
Rhino 运行一次 `MeshlinkProbe`。

| 编号 | 结果 | 说明 |
|---|---|---|
| P1 | 通过 | `DnsServiceBrowse` 返回 pending，回调 4 次 status=0 后找到 Mac 的实例；取消后最后一次回调为 1223（已取消，正常）。`DnsServiceResolve` 解析出 `<mac>.local`、Mac 的 IPv4、端口 29950 与 TXT `v=0`、`probe=1`，64 位结构偏移读取正确。 |
| P2 | 通过 | Rhino 连出到 Mac 的 `nc -l` 并收到回复；Mac 收到 `PROBE from <pc-name>`，结束后端口释放。两端都没有弹防火墙对话框（用户确认）。 |
| P3 | 部分 | 读到了 `ssh_host_ed25519_key.pub`。但测试机 UAC 关闭，Rhino 以已提权身份运行，“未提权也能读”没有被证明。 |
| P4 | 部分 | `Verb=runas` 启动的 PowerShell 为 High Mandatory Level，退出码 0，结果文件写在父进程临时目录并被读回。没有弹 UAC：测试机 `EnableLUA=0`，`runas` 直接提权，与预期一致。“UAC 开启时会弹窗、用户拒绝时返回 1223”未测。 |

限制：只在一台 UAC 关闭、桌面账户为管理员的 PC 上测过；只运行了一次；UAC 开启的
路径（P3 未提权读取、P4 弹窗与拒绝）需要另一台 UAC 开启的 Windows。

Mac 端本地自测（2026-10-04，macOS 26，不涉及 Windows）：`mac-probe.sh` 广播后
`dns-sd -B` 能看到实例，用本机 `nc` 冒充 Rhino 完成一次收发，结束后无残留进程、端口释放。
