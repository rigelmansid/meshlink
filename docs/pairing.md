# 配对协议（草案，版本 1）

0.2 的发现与配对（D-18–D-21）。配对只完成两件事：把 Mac 的公钥装到 Windows，让 Mac
信任 Windows sshd 的主机公钥。之后的连接仍然走 SSH（D-1），本协议不传输任何建模数据。

状态：计算部分（承诺值、配对码）已实现于 `scripts/lib/pairing.sh`，由
`tests/test-pair.sh` 对照 [`tests/pairing-vectors.txt`](../tests/pairing-vectors.txt)
检查。传输方向按 D-20，Phase 0 探针已在真实 PC 上确认发现与连出可行（D-22）。Mac 端
`meshlink pair`（`scripts/pair.sh`）已实现，`tests/test-pair.sh` 用一个假的 Rhino 端
（Python）检查四步交换与各种失败；Rhino 插件还不存在，所以没有和真实 Windows 配对过。

## 角色与流程

- **Mac（M）**：`meshlink pair` 用 `dns-sd -R` 广播 `_meshlink-pair._tcp`，TXT 带
  `v=1`，每一步用一次性的 `nc -l` 在同一个端口上接受连接；第 1 步完成后停止广播。
- **Windows（W）**：Rhino 插件发现广播后提示用户；用户选择配对后主动连出，完成下面的
  四次交换。

每次交换是一条 TCP 连接：W 发送请求后关闭写方向，M 回复后关闭连接。M 的回复不依赖
W 的请求内容，所以可以事先写好，用 `nc -l < 回复 > 请求` 完成。M 只在准备好某一步的
回复后才监听，所以 W 每一步遇到连接被拒都要重试；第 3 步尤其如此，因为 M 要等本机
用户回答完才开始监听。

M 收到的请求如果缺少本步必需的键（例如另一台 PC 的第 1 步请求落到了第 2 步），就忽略
这条连接、继续监听，直到本步超时。

## 消息格式

ASCII 文本，每行 `键 值`，以 LF 结尾（收到的 CR 一律去掉）。第一行固定为
`MESHLINK-PAIR 1`，其后必须有一行 `STEP <n>`，与本步一致。未知的键忽略。

| 步 | W → M | M → W |
|---|---|---|
| 1 | `COMMIT <承诺值>` | `NAME <Mac 显示名>`、`MACPUB <Mac 公钥>`、`NONCE <nonce_m>` |
| 2 | `HOSTKEY <主机公钥>`、`NONCE <nonce_w>`、一行或多行 `ADDR <IPv4>` | （仅 `STEP 2`） |
| — | 两端各自显示配对码，各自的用户确认 | |
| 3 | （仅 `STEP 3`） | `CONFIRM yes\|no`：Mac 用户是否确认 |
| 4 | `RESULT ok\|fail\|declined`；`ok` 时必须有 `USER <Windows 账户>`；可有多行 `MESSAGE <说明>` | （仅 `STEP 4`） |

- 公钥行写 `类型 base64`，不带注释；主机公钥必须是 `ssh-ed25519`。
- nonce 是 16 个随机字节，写成 32 位小写十六进制。
- `ADDR` 的第一行是 W 连到 M 时所用的本机地址，其余是 W 的其他 IPv4 地址。
- 第 3 步得到 `CONFIRM no` 时，W 不做任何修改，也不进行第 4 步。
- 第 4 步的 `declined` 表示 Windows 用户在弹窗或 UAC 中拒绝；`USER` 是公钥实际装给的账户
  （用户可在弹窗里改选），所以放在最后一步。

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

**Mac 端**：除了开始时按需创建密钥（与 `setup` 相同），任何一步失败都不写入
`~/.ssh/config` 和 known_hosts。

1. 开始前：要写的 Host 别名不能已存在，端口必须空闲。
2. 第 2 步收到的主机公钥与 nonce_w 必须符合第 1 步的承诺值。
3. 显示配对码，用户确认与 Rhino 上一致（回答 `yes`）；第 3 步把回答告诉 W。
4. 第 4 步必须是 `RESULT ok`，`USER` 只能由字母、数字和 `._-` 组成（它要写进
   `~/.ssh/config`）。
5. 按 `ADDR` 的顺序用 `ssh-keyscan` 读主机公钥，取第一个与配对所得一致的地址；都不一致
   就失败。known_hosts 里该地址已有不同的公钥时也失败。
6. 写入 known_hosts 与 Host 条目（复用 `scripts/lib/sshcfg.sh`），再用 `BatchMode=yes`
   试登录一次。

收到的文本（`NAME` 以外的值都来自网络）先校验格式再使用；`MESSAGE` 去掉控制字符后
才显示。请求文件限制在 64 KiB 以内。

**Windows 端**：

1. 只有用户在弹窗里看到配对码并点“允许”，且第 3 步得到 `CONFIRM yes`，才启动提权步骤。
2. 提权运行 `prepare-windows.ps1` 装公钥、设权限（坑 2）。UAC 开启时这里会再弹一次系统
   确认；UAC 关闭时不会，弹窗是唯一的确认（D-22）。
3. 用户拒绝弹窗或 UAC 时，第 4 步发 `RESULT declined`，不写任何文件。

## 默认值

- 端口 29950（`--port`）。
- 等待 W 连入第 1 步、等待第 4 步结果：各 300 秒（`--timeout`）；第 2 步 30 秒；第 3 步在
  Mac 用户确认后 120 秒，回答 `no` 时 20 秒。

## 待定

- Rhino 弹窗的具体文字。
