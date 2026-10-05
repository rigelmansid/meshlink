# 配对协议（草案，版本 1）

0.2 的发现与配对（D-18–D-21）。配对只完成两件事：把 Mac 的公钥装到 Windows，让 Mac
信任 Windows sshd 的主机公钥。之后的连接仍然走 SSH（D-1），本协议不传输任何建模数据。

状态：计算部分（承诺值、配对码）已实现于 `scripts/lib/pairing.sh`，由
`tests/test-pair.sh` 对照 [`tests/pairing-vectors.txt`](../tests/pairing-vectors.txt)
检查。传输方向按 D-20，尚待 Phase 0 探针（`experiments/pairing-spike/`）在真实 PC 上
确认；`meshlink pair` 与 Rhino 插件都还不存在。

## 角色与流程

- **Mac（M）**：`meshlink pair` 用 `dns-sd -R` 广播 `_meshlink-pair._tcp`，TXT 带
  `v=1`，并用 `nc -l` 在一个端口上依次接受三次连接。
- **Windows（W）**：Rhino 插件发现广播后主动连出，完成三次交换；第 2 次之后在 Rhino 里
  弹窗显示配对码，用户允许后以 UAC 提权运行 `prepare-windows.ps1` 装公钥。

每次交换是一条 TCP 连接：W 发送请求后关闭写方向，M 回复后关闭连接。M 的回复不依赖
W 的请求内容，所以可以事先写好，用 `nc -l < 回复 > 请求` 完成。

## 消息格式

ASCII 文本，每行 `键 值`，以 LF 结尾（收到的 CR 一律去掉）。第一行固定为
`MESHLINK-PAIR 1`。未知的键忽略；缺少必需的键视为失败。

| 交换 | W → M | M → W |
|---|---|---|
| 1 | `COMMIT <承诺值>` | `NAME <Mac 显示名>`、`MACPUB <Mac 公钥>`、`NONCE <nonce_m>` |
| 2 | `HOSTKEY <主机公钥>`、`NONCE <nonce_w>`、`USER <Windows 账户>`、一行或多行 `ADDR <IPv4>` | `OK` |
| 3 | `RESULT ok\|fail\|declined`、可选 `MESSAGE <说明>` | `OK` |

- 公钥行写 `类型 base64`，不带注释。
- nonce 是 16 个随机字节，写成 32 位小写十六进制。

## 计算

先把公钥规整为 `类型 base64`：取前两个字段，去掉 CR 与注释。.pub 文件和 known_hosts
里的注释不同，注释不参与计算。

```text
承诺值 = hex(SHA-256("meshlink-pair-v1 commit\n" + 主机公钥 + "\n" + nonce_w + "\n"))
h      = SHA-256("meshlink-pair-v1 sas\n" + Mac 公钥 + "\n" + 主机公钥 + "\n"
                 + nonce_m + "\n" + nonce_w + "\n")
配对码 = (h 前 4 字节按大端读成无符号整数) mod 1000000，补零到 6 位，显示为 "123 456"
```

hex 为小写。`tests/pairing-vectors.txt` 由 Python `hashlib` 生成，与 bash 实现相互独立；
Rhino 插件的实现也必须通过同一组向量。

## 为什么能防中间人

W 在看到 nonce_m 之前先用承诺值锁定 nonce_w，M 在看到 nonce_w 之前就交出了 nonce_m。
中间人要让两边显示同一个配对码，必须在不知道对方随机数的情况下事先选定自己的随机数，
成功率约为百万分之一，且失败会被用户看到。这与蓝牙“数字比较”配对的思路相同。

前提与限制：

- 用户必须真的比对两边的配对码。只点“允许”而不看，等于没有保护。
- 配对码只保护这一次交换。之后的信任落在 SSH 上：M 把配对得到的主机公钥写入
  known_hosts，W 把配对得到的 Mac 公钥写入 authorized_keys。
- 局域网内任何人都能发起配对请求，造成弹窗骚扰（拒绝服务）；不能借此装上公钥。
- 不用 PAKE（如 SPAKE2）：Mac 端只能依赖系统自带工具，bash 3.2 下无法实现。

## 两端各自的检查

**Mac 端**，任何一步失败都不写入 `~/.ssh/config` 和 known_hosts：

1. 交换 2 收到的主机公钥与 nonce_w 必须符合交换 1 的承诺值。
2. 显示配对码，用户确认与 Rhino 上一致（回答 `yes`）。
3. 交换 3 必须是 `RESULT ok`。
4. 从 `ADDR` 中选出地址，`ssh-keyscan` 读到的主机公钥必须与配对得到的一致，才写入
   known_hosts（复用 `scripts/lib/sshcfg.sh`）。
5. 用 `BatchMode=yes` 试登录一次。

**Windows 端**：

1. 只有用户在弹窗里看到配对码并点“允许”，才会启动提权步骤。
2. 提权由 UAC 确认。装公钥、设权限沿用 `prepare-windows.ps1`（坑 2）。
3. 用户拒绝弹窗或 UAC 时，交换 3 发 `RESULT declined`，不写任何文件。

## 待定

- 传输方向与发现方式以探针结果为准（D-20）。
- 默认端口、超时时间、Rhino 弹窗的具体文字。
