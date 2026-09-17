#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

#
# RAX3000Q/QY custom build
# QSDK 11.5 / Linux 5.4
# NSS + UA2F + UA3F + SQM/CAKE
#

set -euo pipefail

echo "========================================="
echo " Add UA2F v5.2.0"
echo "========================================="

# 删除 ImmortalWrt 21.02 feed 自带的旧 UA2F
rm -rf package/feeds/packages/ua2f
rm -rf feeds/packages/net/ua2f
rm -rf package/UA2F

# v5.2.0 是 tag；--branch 同样可以用于 tag
git clone \
    --depth 1 \
    --branch v5.2.0 \
    https://github.com/Zxilly/UA2F.git \
    package/UA2F

# UA2F v5.2.0 tag 中 OpenWrt Makefile 的版本号仍写成 4.10.2。
# 不影响实际源码，但这里修正包版本显示。
sed -i 's/^PKG_VERSION:=4\.10\.2$/PKG_VERSION:=5.2.0/' \
    package/UA2F/openwrt/Makefile


echo "========================================="
echo " Add UA3F v3.6.0"
echo "========================================="

rm -rf package/UA3F

git clone \
    --depth 1 \
    --branch v3.6.0 \
    https://github.com/SunBK201/UA3F.git \
    package/UA3F


echo "========================================="
echo " Modify OpenWrt configuration"
echo "========================================="

# ----------------------------------------------------------
# 修改 .config 的辅助函数
# ----------------------------------------------------------

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
# UA2F / UA3F
# ==========================================================

cfg_y CONFIG_PACKAGE_ua2f
cfg_y CONFIG_PACKAGE_ua3f


# ==========================================================
# iproute2
#
# UA2F 5.2.0 明确依赖 ip-full
# 不再使用 ip-tiny
# ==========================================================

cfg_y CONFIG_PACKAGE_ip-full
cfg_n CONFIG_PACKAGE_ip-tiny


# ==========================================================
# ipset
#
# UA3F 明确依赖
# ==========================================================

cfg_y CONFIG_PACKAGE_ipset


# ==========================================================
# iptables / Netfilter
#
# 继续使用 firewall3 + iptables
# 不切 nftables/firewall4
# ==========================================================

cfg_y CONFIG_PACKAGE_iptables

cfg_y CONFIG_PACKAGE_iptables-mod-conntrack-extra
cfg_y CONFIG_PACKAGE_iptables-mod-filter
cfg_y CONFIG_PACKAGE_iptables-mod-ipopt
cfg_y CONFIG_PACKAGE_iptables-mod-nfqueue
cfg_y CONFIG_PACKAGE_iptables-mod-tproxy

# NFQUEUE userspace/kernel support
cfg_y CONFIG_PACKAGE_kmod-nfnetlink-queue
cfg_y CONFIG_PACKAGE_libnetfilter-queue

# UA2F 要求的 conntrack netlink。
# kkstone 原本就已经开启，再明确保留。
cfg_y CONFIG_PACKAGE_kmod-nf-conntrack-netlink


# ==========================================================
# 禁止切到 nftables
# ==========================================================

cfg_n CONFIG_PACKAGE_nftables-json
cfg_n CONFIG_PACKAGE_nftables-nojson
cfg_n CONFIG_IPTABLES_NFTABLES


# ==========================================================
# Traffic Control / SQM / CAKE
# ==========================================================

# 完整 tc，而不是 tiny 版本
cfg_y CONFIG_PACKAGE_tc-full
cfg_n CONFIG_PACKAGE_tc-tiny

# Linux traffic scheduler
cfg_y CONFIG_PACKAGE_kmod-sched

# CAKE
cfg_y CONFIG_PACKAGE_kmod-sched-cake

# conntrack mark -> tc
cfg_y CONFIG_PACKAGE_kmod-sched-connmark
cfg_y CONFIG_PACKAGE_kmod-sched-ctinfo

# SQM
cfg_y CONFIG_PACKAGE_sqm-scripts
cfg_y CONFIG_PACKAGE_luci-app-sqm


# ==========================================================
# NSS qdisc
#
# 第一版明确不开。
# NSS NAT/ECM 保持 kkstone 原配置；
# Linux CAKE/SQM 先作为独立的数据路径测试。
# ==========================================================

cfg_n CONFIG_PACKAGE_kmod-qca-nss-drv-qdisc


# ==========================================================
# 强制刷新 package metadata
#
# 因为 UA2F / UA3F 是在 feeds install 之后才加入 package/
# ==========================================================

rm -rf tmp


echo "========================================="
echo " Custom packages installed:"
echo "========================================="

echo "UA2F:"
git -C package/UA2F describe --tags --always

echo "UA3F:"
git -C package/UA3F describe --tags --always

echo
echo "Configuration will be resolved by: make defconfig"
echo "========================================="
