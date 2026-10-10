#!/bin/bash
# km-c266-print-auth 一键安装脚本
# 交互式输入打印机 IP / 用户名 / 密码，配置 CUPS 认证打印后端
#
# 用法:
#   交互式        : sudo ./install.sh [打印机名]
#   非交互(脚本化) : sudo KM_HOST=192.168.88.8 KM_USER=用户名 KM_PASS=密码 ./install.sh [打印机名]
#
# 前置条件: 打印机已在"系统设置 → 打印机"中添加并选用柯尼卡美能达 PPD
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PRINTER="${1:-$(lpstat -p 2>/dev/null | awk '/printer/{print $2; exit}')}"
[ -n "$PRINTER" ] || { echo "用法: sudo $0 打印机名"; exit 1; }

if [ "$(id -u)" != 0 ]; then
    echo "请用 sudo 运行: sudo $0 $PRINTER"
    exit 1
fi

# ---------- 收集凭据（优先环境变量，否则交互输入） ----------
if [ -z "$KM_HOST" ]; then read -r -p "打印机 IP 地址: " KM_HOST; fi
if [ -z "$KM_USER" ]; then read -r -p "设备用户认证用户名: " KM_USER; fi
if [ -z "$KM_PASS" ]; then
    read -r -s -p "密码: " KM_PASS; echo
fi
[ -n "$KM_HOST" ] && [ -n "$KM_USER" ] && [ -n "$KM_PASS" ] \
    || { echo "错误: IP / 用户名 / 密码不能为空"; exit 1; }

# ---------- URL 编码（用户名/密码可能含中文或特殊字符） ----------
urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}
URI="km9100auth://$(urlencode "$KM_USER"):$(urlencode "$KM_PASS")@$KM_HOST"

# ---------- 安装后端 ----------
cp "$DIR/km9100auth" /usr/libexec/cups/backend/km9100auth
chown root:wheel /usr/libexec/cups/backend/km9100auth
chmod 700 /usr/libexec/cups/backend/km9100auth
launchctl kickstart -k system/com.apple.cupsd 2>/dev/null || true

# ---------- 配置打印机 ----------
if lpstat -p "$PRINTER" >/dev/null 2>&1; then
    lpadmin -p "$PRINTER" -v "$URI"
    cupsenable "$PRINTER" 2>/dev/null || true
    echo "完成: $PRINTER -> km9100auth://<凭据已隐藏>@$KM_HOST"
else
    echo "警告: 打印机 \"$PRINTER\" 不存在。请先在系统设置添加打印机（选用柯尼卡美能达 PPD），再运行:"
    echo "  sudo $0 $PRINTER"
    exit 1
fi

echo "验证: lpstat -v $PRINTER ; lp -d $PRINTER <文件>"
