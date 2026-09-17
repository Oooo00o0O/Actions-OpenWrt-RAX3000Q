#!/bin/sh
# Portal 会话统计汇总（只读，不写任何东西）
LOG=${1:-/etc/portal-stats.log}

echo "===== 当前状态 $(date '+%F %T') ====="
B=$(cat /etc/portal-session-start.ts 2>/dev/null)
case "$B" in ''|*[!0-9]*) B=0 ;; esac
if [ "$B" -gt 0 ]; then
  n=$(date +%s); d=$((n-B))
  echo "  本次会话已存活: $((d/3600))h$(( (d%3600)/60 ))m  (起点戳 $B)"
fi
H=$(curl -s --connect-timeout 4 --max-time 8 http://connect.rom.miui.com/generate_204 2>/dev/null)
case "$H" in
  *eportal*) echo "  在线状态: 被劫持(未登录)" ;;
  *)         echo "  在线状态: 在线" ;;
esac
echo "  TTL 规则: $(iptables -t mangle -S 2>/dev/null | grep -c 'ttl-set 64') 条"
echo "  ua2f=$(uci -q get ua2f.enabled.enabled)  ua3f=$(uci -q get ua3f.enabled.enabled)"
UA2=$(uci -q get ua2f.main.custom_ua 2>/dev/null)
UA3=$(uci -q get ua3f.main.ua 2>/dev/null)
[ -n "$UA2" ] && echo "  ua2f UA: $UA2"
[ -n "$UA3" ] && echo "  ua3f UA: $UA3"
echo "  overlay 可用: $(df -h /overlay 2>/dev/null | tail -1 | awk '{print $4}')"

echo
echo "===== 被踢记录 ====="
if [ -r "$LOG" ]; then
  grep -h 'KICK' "$LOG" 2>/dev/null | sed 's/^/  /'
else
  echo "  (无日志 $LOG)"
fi

echo
echo "===== 按日期+小时聚合（看检测器的作息）====="
grep -h 'KICK' "$LOG" 2>/dev/null | awk '{print $2" "substr($3,1,2)":00"}' | sort | uniq -c | sed 's/^/  /'

echo
echo "===== 存活时长序列（秒）====="
grep -h 'KICK' "$LOG" 2>/dev/null | sed -n 's/.*会话存活=\(-\{0,1\}[0-9]*\)s.*/\1/p' | tr '\n' ' '
echo
