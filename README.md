# km-c266-print-auth

Konica Minolta bizhub C266 **macOS 认证打印**解决方案（可复用版）。

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

## 根因

1. macOS 版柯尼卡驱动在每个作业的 PJL 头中**固定写入 `@PJL SET KMCOETYPE = 2`**，
   该标记使设备按"密码 = 哈希"模式校验；
2. 新版 macOS 上驱动的**用户认证弹窗不再弹出**，用户无法输入凭据，驱动发送空密码
   → 设备端登录错误；
3. Windows 驱动自带凭据管理并发送密码哈希，故一直正常。

## 解决方案原理

安装一个 CUPS 打印后端 `km9100auth`：

1. 连接打印机的 **9100 端口**；
2. 读取驱动滤镜输出，**剥掉 `KMCOETYPE` 及残留的认证 SET 行**；
3. 在 `@PJL JOB` 后**注入明文认证块**（实测：无 KMCOETYPE 时设备接受明文）；
4. 将改写后的作业发送到设备。

凭据保存在 CUPS 队列 URI 中，**打印时无需弹窗输入**。

## 安装（一键，输入账号密码）

```bash
# 1) 克隆本仓库
git clone https://github.com/handyfhj/km-c266-print-auth.git
cd km-c266-print-auth

# 2) 交互式安装（会提示输入 IP / 用户名 / 密码）
sudo ./install.sh 打印机名
```

非交互方式（适合脚本化）：

```bash
sudo KM_HOST=192.168.88.8 KM_USER=用户名 KM_PASS=密码 ./install.sh 打印机名
```

> 前置条件：打印机已通过"系统设置 → 打印机"添加，并选用柯尼卡美能达 PPD。
> `install.sh` 只负责安装后端并改写该打印机的连接地址。

手动安装（等价步骤）：

```bash
sudo cp km9100auth /usr/libexec/cups/backend/km9100auth
sudo chown root:wheel /usr/libexec/cups/backend/km9100auth
sudo chmod 700 /usr/libexec/cups/backend/km9100auth
sudo launchctl kickstart -k system/com.apple.cupsd

# 用户名含中文等非 ASCII 需 URL 编码（示例用户名"技术" = %E6%8A%80%E6%9C%AF）
lpadmin -p <打印机名> -v "km9100auth://<URL编码用户名>:<URL编码密码>@<IP>"
cupsenable <打印机名>

lpstat -v <打印机名>          # 验证设备 URI
lp -d <打印机名> 测试文件.txt  # 打印后到设备 Web 页面核对作业历史 Result=End
```

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
4. CUPS 后端运行在沙箱中，**禁止写 /tmp 等路径**，调试请输出到 STDERR；
5. 后端只执行 `/usr/libexec/cups/backend/` 下 root:wheel 0700 的文件。

## 文件说明

| 文件 | 说明 |
|---|---|
| `km9100auth` | CUPS 后端脚本（Perl，macOS 自带 perl） |
| `install.sh` | 一键安装脚本（交互式/环境变量输入凭据） |

## 参考

- Mozilla Bug [1333572](https://bugzilla.mozilla.org/show_bug.cgi?id=1333572)：
  相同现象的官方确认（PJL 命令缺失导致 LoginError）
- [wbern/room-business-center-skrivare](https://github.com/wbern/room-business-center-skrivare)：
  原始思路来源（KMCOETYPE=2 会导致登录错误）
- 柯尼卡美能达官网驱动下载：`https://www.btapac.konicaminolta.com/`
