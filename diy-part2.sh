#!/bin/bash

set -euo pipefail

echo "========================================="
echo " Add UA2F v5.2.0"
echo "========================================="

# 删除 ImmortalWrt feed 里面的旧 UA2F
rm -rf package/feeds/packages/ua2f
rm -rf feeds/packages/net/ua2f
rm -rf package/UA2F

git clone \
    --depth 1 \
    --branch v5.2.0 \
    https://github.com/Zxilly/UA2F.git \
    package/UA2F


# ----------------------------------------------------------
# UA2F / OpenWrt 21.02 compatibility fixes
# ----------------------------------------------------------

# 1. OpenWrt 21.02 使用 CMake 3.19.x
#    CMP0135 是 CMake 3.24 才加入的。
#    给这个 policy 加版本存在性检查。
python3 - <<'PY'
from pathlib import Path

p = Path("package/UA2F/CMakeLists.txt")
s = p.read_text()

old = "cmake_policy(SET CMP0135 NEW)"
new = """if(POLICY CMP0135)
    cmake_policy(SET CMP0135 NEW)
endif()"""

if old not in s:
    raise SystemExit("UA2F: CMP0135 line not found")

s = s.replace(old, new, 1)
p.write_text(s)
PY


# 2. GitHub Actions 自动设置 CI=true。
#    UA2F 会因此强制打开 code coverage。
#    固件交叉编译不需要 coverage，关闭它。
python3 - <<'PY'
from pathlib import Path

p = Path("package/UA2F/CMakeLists.txt")
s = p.read_text()

old = "if(DEFINED ENV{CI})"
new = "if(FALSE) # OpenWrt cross build: disable CI coverage"

if old not in s:
    raise SystemExit("UA2F: CI coverage condition not found")

s = s.replace(old, new, 1)
p.write_text(s)
PY


# 3. v5.2.0 tag 中 OpenWrt package 版本号仍可能显示 4.10.2
#    只影响 ipk 显示版本，不影响源码。
sed -i \
    's/^PKG_VERSION:=4\.10\.2$/PKG_VERSION:=5.2.0/' \
    package/UA2F/openwrt/Makefile


# 4. 当前固件明确使用 fw3 + iptables，
#    OpenWrt 21.02 没有我们不需要的 nft TPROXY package。
#    去掉 nft-only dependency warning。
sed -i \
    '/kmod-nft-tproxy/d; /kmod-nft-queue/d' \
    package/UA2F/openwrt/Makefile


echo "========================================="
echo " Configure Anti-Sharing (UA2F)"
echo "========================================="

rm -rf package/UA3F
# RAX3000Q 双核 A7 架构性能与内存敏感，实测主力采用轻量 C 语言的 UA2F (占用仅 ~2.4MB)
# UA3F (Go 编写) 存在 musl 1.1 与 内存墙问题，默认不编译 UA3F


echo "========================================="
echo " Modify OpenWrt config"
echo "========================================="

cfg_y() {
    local key="$1"

    sed -i \
        -e "/^${key}=/d" \
        -e "/^# ${key} is not set$/d" \
        .config

    echo "${key}=y" >> .config
}

cfg_n() {
    local key="$1"

    sed -i \
        -e "/^${key}=/d" \
        -e "/^# ${key} is not set$/d" \
        .config

    echo "# ${key} is not set" >> .config
}


# ==========================================================
# UA2F
# ==========================================================

cfg_y CONFIG_PACKAGE_ua2f
cfg_n CONFIG_PACKAGE_ua3f

# libbacktrace 只是 debug 功能，第一版关闭
cfg_n CONFIG_UA2F_ENABLE_LIBBACKTRACE


# ==========================================================
# curl (校园网自动认证守护 portal-autologin 必需依赖)
# ==========================================================

cfg_y CONFIG_PACKAGE_curl
cfg_y CONFIG_PACKAGE_libcurl
cfg_y CONFIG_PACKAGE_libnghttp2
cfg_y CONFIG_PACKAGE_ca-bundle


# ==========================================================
# iproute2 / ipset
# ==========================================================

cfg_y CONFIG_PACKAGE_ip-full
cfg_n CONFIG_PACKAGE_ip-tiny

cfg_y CONFIG_PACKAGE_ipset


# ==========================================================
# firewall3 + iptables
# ==========================================================

cfg_y CONFIG_PACKAGE_iptables

cfg_y CONFIG_PACKAGE_iptables-mod-conntrack-extra
cfg_y CONFIG_PACKAGE_iptables-mod-filter
cfg_y CONFIG_PACKAGE_iptables-mod-ipopt
cfg_y CONFIG_PACKAGE_iptables-mod-nfqueue
cfg_y CONFIG_PACKAGE_iptables-mod-tproxy

cfg_y CONFIG_PACKAGE_kmod-nfnetlink-queue
cfg_y CONFIG_PACKAGE_libnetfilter-queue

# UA2F conntrack listener / CONNMARK
cfg_y CONFIG_PACKAGE_kmod-nf-conntrack-netlink


# ==========================================================
# 不切 firewall4 / nftables
# ==========================================================

cfg_n CONFIG_PACKAGE_nftables-json
cfg_n CONFIG_PACKAGE_nftables-nojson
cfg_n CONFIG_IPTABLES_NFTABLES


# ==========================================================
# SQM / CAKE
# ==========================================================

cfg_y CONFIG_PACKAGE_tc-full
cfg_n CONFIG_PACKAGE_tc-tiny

cfg_y CONFIG_PACKAGE_kmod-sched
cfg_y CONFIG_PACKAGE_kmod-sched-core
cfg_y CONFIG_PACKAGE_kmod-sched-cake
cfg_y CONFIG_PACKAGE_kmod-sched-connmark
cfg_y CONFIG_PACKAGE_kmod-sched-ctinfo

cfg_y CONFIG_PACKAGE_kmod-ifb

cfg_y CONFIG_PACKAGE_sqm-scripts
cfg_y CONFIG_PACKAGE_luci-app-sqm


# ==========================================================
# NSS qdisc 第一版不启用
# ==========================================================

cfg_n CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc



# 新增 package 后强制 OpenWrt 重建 metadata
rm -rf tmp

if [ -d "files" ]; then
    chmod +x files/etc/uci-defaults/* 2>/dev/null || true
    chmod +x files/etc/hotplug.d/iface/* 2>/dev/null || true
    chmod +x files/usr/bin/* 2>/dev/null || true
fi


echo "========================================="
echo " Versions"
echo "========================================="

echo -n "UA2F: "
git -C package/UA2F describe --tags --always

if [ -d "package/UA3F" ]; then
    echo -n "UA3F: "
    git -C package/UA3F describe --tags --always
fi

echo
echo "UA2F CMake compatibility patch:"
grep -A3 -B1 'POLICY CMP0135' package/UA2F/CMakeLists.txt

echo
echo "UA2F coverage:"
grep -A3 -B1 'OpenWrt cross build' package/UA2F/CMakeLists.txt

echo
echo "Done."
