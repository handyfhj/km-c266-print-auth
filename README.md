# km-c266-print-auth

Konica Minolta bizhub C266 **macOS 认证打印**解决方案（可复用版）。
[English](README.en.md) | [中文](#中文)

解决开启**设备用户认证**的柯尼卡美能达 bizhub 打印机在 macOS 上打印作业被设备
以 **"登录错误（LoginError）"** 取消的问题。Windows 打印正常、Mac 打印失败时适用。

**凭据在安装时输入**（交互式或环境变量），不写死在脚本/文档中。

---

## 适用环境

| 维度 | 说明 |
|---|---|
| 机型 | Konica Minolta bizhub C266（**实测通过**）；同系列开启设备用户认证的机型（C258 / C308 / C364 / C652 等）原理相同 |
| 认证模式 | 设备用户认证（AuthType=Device），非账户跟踪（TrackType=None） |
| macOS | 实测 macOS 27（Apple Silicon）；官方 PS 驱动 7.7.0（Apple 公证，支持 macOS 11+） |
| 症状匹配 | Mac 打印作业被设备取消、设备显示"登录错误"；Windows / 网页直接打印均正常 |

> 若你的设备不是"登录错误"而是其他报错，本方案可能不适用，请先确认认证模式与症状一致。

## 症状

- **Windows**：正常打印（驱动自带凭据管理，发送密码哈希）。
- **网页直接打印**（Web Connection）：正常。
- **macOS**：所有打印作业被设备取消，设备屏幕显示"登录错误"。
  尝试 IPP / socket(9100) / LPD 三条通道、8+ 种 PJL 编排、`lp -U` 等方式均失败。

## 完整排障记录

以下为从 0 到 1 的完整排查过程（脱敏：真实账号、密码及驱动密码哈希不在此公开）。

### 1. 驱动与 PPD 环境

- 驱动：柯尼卡美能达亚太官网下载中心下载 Mac PS 驱动 `BHC266PSMACOS_770MU.dmg`
  （Apple 公证，支持 macOS 11+ / Apple Silicon）。
- PPD 生效路径：`/Library/Printers/PPDs/Contents/Resources/KONICAMINOLTAC266.gz`
- 过滤器：`/Library/Printers/KONICAMINOLTA/C266/Filters/psToKMC266PS`
- 认证模板：`/Library/Printers/KONICAMINOLTA/C266/Plist/FilterCustomize.plist`

### 2. 决定性证据：设备作业历史对比

通过 Web Connection 以设备用户账号登录，读取 `/wcd/job_history.xml`：

| 来源 | UserName | Result | 说明 |
|---|---|---|---|
| Windows 驱动 | 用户A / 用户B | End | 正常打印，带 DriverJobID |
| 网页直接打印 | 用户A | End | 正常打印 |
| **Mac 驱动（所有通道）** | 用户A（解析正确） | **Delete / LoginError** | 用户名正确，但凭据不被接受 |

结论：**设备能正确解析用户名，问题出在密码/认证格式**，而非用户名或网络通道。

### 3. 破局证据：Windows 打印数据（.prn）分析

从 Windows"打印到文件"得到 `.prn`（PCL6，数百 KB，含 66 条 PJL），
认证相关 PJL 结构如下（数值已脱敏）：

```
@PJL SET KMCOETYPE = 2
@PJL SET BOXHOLDTYPE = PRIVATE
@PJL SET KMUSERNAME = "<用户名>"
@PJL SET KMUSERKEY2 = "<32位十六进制驱动哈希>"   ← 不是明文密码！
@PJL SET KMCERTSERVTYPE = NONE
@PJL SET KMCERTSIMPLEAUTHREQ = OFF
```

关键发现：

- **Windows 驱动不发送明文密码，而是发送密码的驱动哈希**（32 位十六进制，
  非标准 MD5，为柯尼卡驱动私有算法；实测尝试 MD5 等 20+ 种常见候选均不匹配）。
- 驱动同时发送 `KMCOETYPE = 2`。

### 4. 根因锁定：外部资料印证

- GitHub 搜索 `KMUSERKEY2` 命中 `wbern/room-business-center-skrivare` 仓库的
  `docs/km9100auth`，其结论原文口径：
  **"KMCOETYPE ABSENT (its presence = guaranteed login error)"**。
- Mozilla Bug [1333572](https://bugzilla.mozilla.org/show_bug.cgi?id=1333572)：
  柯尼卡官方确认缺认证 PJL 时设备报 LoginError，并给出所需 PJL 行清单
  （`KMUSERNAME` + `KMUSERKEY2` 等）。

### 5. 对照实验矩阵（验证根因）

在 IPP / socket(9100) / LPD 三通道发送测试作业，以设备作业历史判定：

| 密码格式 | KMCOETYPE | 结果 |
|---|---|---|
| 明文 | = 2 | **LoginError**（此前一直失败的原因） |
| 明文 | = 0 | **End ✓** |
| 明文 | 无 | **End ✓** |
| 驱动哈希 | = 2 | **End ✓**（与 Windows 行为一致） |
| 驱动哈希 | 无 | LoginError |

### 6. 根因结论

1. macOS 版柯尼卡驱动在每个作业的 PJL 头中**固定写入 `@PJL SET KMCOETYPE = 2`**，
   该标记使设备按"密码 = 驱动哈希"模式校验；
2. 新版 macOS 上驱动的**用户认证弹窗不再弹出**（与 Mozilla Bug 1333572 同源），
   用户无法输入凭据，驱动发出空密码 → 设备端登录错误；
3. Windows 驱动发送驱动哈希密码，故一直正常。

> 因此有两种可行修复路径：a) 复刻 Windows 的哈希算法（未破解，不可行）；
> b) **剥掉 KMCOETYPE 并注入明文认证**（设备实测接受明文，采用此方案）。

## 解决方案

### 原理

安装一个 CUPS 打印后端 `km9100auth`：

1. 连接打印机的 **9100 端口**；
2. 读取驱动滤镜输出，**剥掉 `KMCOETYPE` 及残留的认证 SET 行**
   （BOXHOLDTYPE / KMUSERNAME / KMUSERKEY2 / KMCERTSERVTYPE / KMCERTSERVNUM /
   KMCERTSELECTTYPE / KMCERTSIMPLEAUTHREQ / KMCOETYPE）；
3. 在 `@PJL JOB` 后**注入明文认证块**：
   ```
   @PJL SET BOXHOLDTYPE = PRIVATE
   @PJL SET KMUSERNAME = "<用户名>"
   @PJL SET KMUSERKEY2 = "<密码>"
   @PJL SET KMCERTSERVTYPE = NONE
   @PJL SET KMCERTSIMPLEAUTHREQ = OFF
   ```
4. 将改写后的作业发送到设备。

凭据保存在 CUPS 队列 URI 中，**打印时无需弹窗输入**。

### 一键安装（输入账号密码）

```bash
git clone https://github.com/handyfhj/km-c266-print-auth.git
cd km-c266-print-auth

# 交互式：提示输入 IP / 用户名 / 密码（密码不回显）
sudo ./install.sh 打印机名

# 或非交互（脚本化）：
sudo KM_HOST=<IP> KM_USER=<用户名> KM_PASS=<密码> ./install.sh 打印机名
```

> 前置条件：打印机已通过"系统设置 → 打印机"添加并选用柯尼卡美能达 PPD。
> 脚本自动做 URL 编码（中文用户名如"技术"→ `%E6%8A%80%E6%9C%AF`），
> 兼容中英文系统输出。

### 手动安装（等价步骤）

```bash
sudo cp km9100auth /usr/libexec/cups/backend/km9100auth
sudo chown root:wheel /usr/libexec/cups/backend/km9100auth
sudo chmod 700 /usr/libexec/cups/backend/km9100auth
sudo launchctl kickstart -k system/com.apple.cupsd

# 用户名含中文等非 ASCII 需 URL 编码
lpadmin -p <打印机名> -v "km9100auth://<URL编码用户名>:<URL编码密码>@<IP>"
cupsenable <打印机名>

lpstat -v <打印机名>          # 验证设备 URI
lp -d <打印机名> 测试文件.txt  # 打印后到设备 Web 页面核对作业历史 Result=End
```

### 实现要点与踩坑记录

| 坑 | 说明 |
|---|---|
| Perl 字符串插值 | 双引号字符串中 `@PJL` 必须写成 `\@PJL`，否则被当数组插值导致编译失败 |
| CUPS 自动停用打印机 | 后端崩溃/报错时 CUPS 会把打印机设为"已停用"，需 `cupsenable` 恢复 |
| 后端沙箱 | macOS CUPS 后端运行在沙箱中，**禁止写 /tmp 等路径**；调试日志输出到 STDERR（CUPS 捕获到 error_log） |
| 后端权限 | CUPS 只执行 `/usr/libexec/cups/backend/` 下 root:wheel 0700 的文件 |
| 新后端识别 | 安装后需重启 cupsd（`launchctl kickstart -k system/com.apple.cupsd`） |
| `lpstat -v` 不显示凭据 | 显示层隐去 userinfo，实际 CUPS 存储的 URI 含凭据，后端可正常解析 |

## 使用方法（日常打印）

安装完成后，日常打印**无需任何额外操作**：

1. 在任意应用按 **Cmd + P** 打开打印对话框；
2. 选择**已指向后端的打印机**（名称与安装时一致，如 `_192_168_88_8`）；
3. 直接点击"打印"——**不需要输入用户名密码**（凭据已内置在队列 URI 中）。

> 注意：如果"系统设置 → 打印机"自动发现并新建了 IPP 队列，不要选它
> （那台会报登录错误），请删除新队列、保留指向后端的打印机。

**如何确认正在使用认证后端**：

- 本机执行 `lpstat -v <打印机名>`，设备 URI 以 `km9100auth://` 开头；
- 打印后到设备 Web Connection（`http://<IP>/wcd/`）→ 作业历史，
  Result=**End** 且 UserName 为安装时输入的账号，即打印成功。

### 常见问题（FAQ）

| 现象 | 原因 | 解决 |
|---|---|---|
| 打印时弹出账号密码框 | 选到了 IPP 自动发现的新队列 | 改选后端队列；删除新建队列 |
| 打印仍报"登录错误" | 队列被系统设置重建为 IPP | 删除新队列保留后端队列；或重跑 `sudo ./install.sh 打印机名` |
| 打印对话框中找不到打印机 | 后端队列被 CUPS 停用 | `cupsenable 打印机名`；或重跑安装脚本 |
| 改密码后打印失败 | 队列 URI 仍是旧密码 | 重跑 `sudo ./install.sh 打印机名` 输入新密码 |
| 打印任务无反应/立即失败 | 后端未生效（权限/未重启 CUPS） | 检查 `/usr/libexec/cups/backend/km9100auth`（root:wheel 0700）存在，重启 cupsd 后重试 |

## 验证结果（实测）

本机实测设备作业历史（结果可追溯）：

| 作业ID | 结果 |
|---|---|
| 18847 / 18849 / 18851 / 18853 | **End（打印成功）** |

Windows 打印、网页直接打印均不受影响。

## 维护与注意事项

1. **改密码**：重新运行 `sudo ./install.sh 打印机名` 输入新密码即可；
2. **系统设置重新添加打印机**：自动发现会新建 IPP 队列，回到登录错误状态；
   请删除新队列，不要动已指向后端的那台；
3. **凭据位置**：账号密码以 URL 编码形式保存在 CUPS 队列配置中（root 可读），
   请按公司安全策略管理；
4. 后端脚本适用于柯尼卡美能达 bizhub 全系开启设备用户认证的场景，仅需更换
   队列 URI 中的 IP / 用户名 / 密码。

## 文件说明

| 文件 | 说明 |
|---|---|
| `km9100auth` | CUPS 后端脚本（Perl，macOS 自带 perl） |
| `install.sh` | 一键安装脚本（交互式/环境变量输入凭据） |
| `README.en.md` | 英文说明 |

## 参考

- Mozilla Bug [1333572](https://bugzilla.mozilla.org/show_bug.cgi?id=1333572)：
  相同现象的官方确认（PJL 命令缺失导致 LoginError）
- [wbern/room-business-center-skrivare](https://github.com/wbern/room-business-center-skrivare)：
  原始思路来源（KMCOETYPE=2 会导致登录错误）
- 柯尼卡美能达官网驱动下载：`https://www.btapac.konicaminolta.com/`
