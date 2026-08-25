#!/bin/bash
# diy-n1.sh — Phicomm N1 DIY 脚本
# 用法: diy-n1.sh [24.10|25.12]（不传则自动检测）
set -euo pipefail

# ── 版本检测 ─────────────────────────────────────────────────
VERSION="${1:-}"
[ -z "$VERSION" ] && { grep -q 'openwrt-25.12' feeds.conf.default 2>/dev/null && VERSION="25.12" || VERSION="24.10"; }
log() { echo ">>> [$VERSION] $*"; }

# ============================================================
# 基础设置（IP / 主机名）
# ============================================================
log "设置默认 IP 与主机名"
sed -i 's/192.168.1.1/192.168.123.2/g' package/base-files/files/bin/config_generate
sed -i 's/ImmortalWrt/OpenWrt/g' package/base-files/files/bin/config_generate

# ============================================================
# 升级 Golang
# ============================================================
log "替换 Golang → 26.x"
rm -rf feeds/packages/lang/golang
git clone --depth=1 -b 26.x https://github.com/sbwml/packages_lang_golang feeds/packages/lang/golang

# ============================================================
# 修复 rust host 编译失败（25.12 专属问题）
# 原因：rust 包 bootstrap 默认 download-ci-llvm=true，会去
# https://ci-artifacts.rust-lang.org 下载对应 commit 的预编译 LLVM，
# 但该 CI 产物有保留期限，过期后 404，导致 host-compile 失败。
# 上游 immortalwrt/packages 的 openwrt-25.12 分支尚未修复此问题
# （openwrt/packages#26623、immortalwrt/packages#1607 均已 closed
# as not planned），故在此手动关闭该开关，强制本地编译 LLVM。
# 注意：会增加编译耗时（预计 +20~40 分钟），请留意 Actions 超时设置。
# ============================================================
log "修复 rust: 禁用 download-ci-llvm（避免 CI LLVM 快照过期 404）"
RUST_MK="feeds/packages/lang/rust/Makefile"
if [ -f "$RUST_MK" ] && ! grep -q 'download-ci-llvm=false' "$RUST_MK"; then
  sed -i '/^HOST_CONFIGURE_ARGS = \\/a\  --set=llvm.download-ci-llvm=false \\' "$RUST_MK"
  log "已为 $RUST_MK 注入 --set=llvm.download-ci-llvm=false"
else
  log "rust Makefile 未找到或已包含该设置，跳过"
fi

# ============================================================
# 清理 feeds 冲突包
# ============================================================
log "清理冲突包"
PASSWALL_PKGS=(chinadns-ng dns2socks geoview hysteria ipt2socks microsocks naiveproxy \
  shadow-tls shadowsocks-libev shadowsocks-rust shadowsocksr-libev simple-obfs sing-box \
  tcping trojan-plus tuic-client v2ray-geodata v2ray-plugin xray-core xray-plugin)
for pkg in "${PASSWALL_PKGS[@]}"; do rm -rf "feeds/packages/net/$pkg"; done

rm -rf feeds/luci/applications/luci-app-{lucky,mosdns,nikki,openclash,openlist,openlist2,passwall,passwall2} \
  feeds/packages/net/{mosdns,openlist} \
  feeds/luci/luci-app-mjpg-streamer feeds/packages/onionshare-cli \
  package/feeds/luci/luci-app-mjpg-streamer package/feeds/packages/onionshare-cli

[ "$VERSION" = "24.10" ] && rm -rf feeds/packages/admin/zabbix
sed -i '/mjpg-streamer/d;/onionshare/d' .config 2>/dev/null || true
find feeds/packages -type d -name "*python*ubus*" -exec rm -rf {} + 2>/dev/null || true

sed -i 's/+PACKAGE_mihomo-alpha//g; s/+PACKAGE_mihomo-meta//g' package/feeds/mihomo/luci-app-mihomo/Makefile 2>/dev/null || true

# 25.12 去除 dockerman （代码示例）
#[ "$VERSION" = "25.12" ] && sed -i '/CONFIG_PACKAGE_luci-app-dockerman/d' .config 2>/dev/null || true

# ============================================================
# 克隆 Passwall 2
# ============================================================
log "克隆 Passwall 2"
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git package/passwall-packages
[ "$VERSION" = "25.12" ] && rm -rf package/passwall-packages/shadowsocksr-libev
git clone --depth=1 https://github.com/Openwrt-Passwall/openwrt-passwall2.git package/passwall2

# ============================================================
# 克隆第三方插件
# ============================================================
log "克隆第三方插件"
git clone --depth=1 https://github.com/ophub/luci-app-amlogic package/amlogic
git clone --depth=1 https://github.com/vernesong/OpenClash package/openclash

git clone --depth=1 https://github.com/nikkinikki-org/OpenWrt-nikki package/nikki
# ── nikki 自定义三处设置为‘不修改’ ─────────────────────────────
log "nikki: 清除默认值 log_level/ui_url/tun_stack"
sed -i "/option 'log_level' 'warning'/d" package/nikki/nikki/files/nikki.conf
sed -i "\#option 'ui_url' 'https://github.com/Zephyruso/zashboard/releases/latest/download/dist-cdn-fonts.zip'#d" package/nikki/nikki/files/nikki.conf
sed -i "/option 'tun_stack' 'mixed'/d" package/nikki/nikki/files/nikki.conf

git clone --depth=1 -b v5 https://github.com/sbwml/luci-app-mosdns package/mosdns
git clone --depth=1 https://github.com/sbwml/luci-app-openlist2 package/openlist2
git clone --depth=1 https://github.com/sbwml/luci-app-quickfile package/luci-app-quickfile

git clone --depth=1 https://github.com/gdy666/luci-app-lucky package/lucky
# ── 修复 luci-app-lucky 在虚拟内存受限环境下调用 lucky 二进制返回空、
#    导致误报"未安装"/"收集数据..."/"复位"静默失效的问题 ─────────────
log "lucky: 修复 uhttpd 环境下 lucky 二进制调用因内存限制静默失败的问题"
LUCKY_CTRL=package/lucky/luci-app-lucky/luasrc/controller/lucky.lua
sed -i 's#luci.sys.exec("/usr/bin/lucky -info")#luci.sys.exec("ulimit -v unlimited 2>/dev/null; /usr/bin/lucky -info")#' "$LUCKY_CTRL"
sed -i 's#luci.sys.exec("lucky -baseConfInfo -cd "..configPath)#luci.sys.exec("ulimit -v unlimited 2>/dev/null; lucky -baseConfInfo -cd "..configPath)#' "$LUCKY_CTRL"
sed -i 's#luci.sys.exec(cmd)#luci.sys.exec("ulimit -v unlimited 2>/dev/null; "..cmd)#' "$LUCKY_CTRL"

git clone --depth=1 https://github.com/timsaya/luci-app-bandix package/luci-app-bandix
git clone --depth=1 https://github.com/timsaya/openwrt-bandix package/openwrt-bandix

# ============================================================
# 注入软件源配置文件（仅 24.10）
# ============================================================

# ── opkg 配置（仅 24.10）───────────────────────────────────
[ "$VERSION" = "24.10" ] && {
  log "24.10 软件源配置"
  mkdir -p package/base-files/files/etc/opkg
  
  cat > package/base-files/files/etc/opkg.conf << 'EOF'
dest root /
dest ram /tmp
lists_dir ext /var/opkg-lists
option overlay_root /overlay
# option check_signature
arch all 100
arch aarch64_generic 200
arch aarch64_cortex-a53 300
EOF

  cat > package/base-files/files/etc/opkg/customfeeds.conf << 'EOF'
# add your custom package feeds here
#
# src/gz example_feed_name http://www.example.com/path/to/files
src/gz openwrt_kiddin9 https://dl.openwrt.ai/latest/packages/aarch64_cortex-a53/kiddin9
EOF
}

# ============================================================
log "注入 Nginx Quickfile 修复"
mkdir -p package/base-files/files/etc/uci-defaults
cat > package/base-files/files/etc/uci-defaults/99-fix-nginx-quickfile << 'EOF'
#!/bin/sh
uci set nginx.global.uci_enable='true'
uci del nginx._lan; uci del nginx._redirect2ssl
uci add nginx server; uci rename nginx.@server[0]='_lan'
uci set nginx._lan.server_name='_lan'
uci add_list nginx._lan.listen='80 default_server'
uci add_list nginx._lan.listen='[::]:80 default_server'
uci add_list nginx._lan.include='conf.d/*.locations'
uci set nginx._lan.access_log='off'
uci commit nginx
/etc/init.d/nginx restart
exit 0
EOF
chmod +x package/base-files/files/etc/uci-defaults/99-fix-nginx-quickfile
# ============================================================

log "完成 ✓"
