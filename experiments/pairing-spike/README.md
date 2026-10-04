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

尚未运行。

Mac 端本地自测（2026-10-04，macOS 26，不涉及 Windows）：`mac-probe.sh` 广播后
`dns-sd -B` 能看到实例，用本机 `nc` 冒充 Rhino 完成一次收发，结束后无残留进程、端口释放。
