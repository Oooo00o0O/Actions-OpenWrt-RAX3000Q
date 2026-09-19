#!/bin/sh
# 被劫持才登录。记录会话存活时长 + 被踢现场快照。日志超 64KB 自动截断。
LOG=/etc/portal-stats.log
STATE=/tmp/portal-autologin.lastfail
BASE=/etc/portal-session-start.ts
LOCK=/tmp/portal-autologin.lock
PROBE1='http://123.123.123.123/'
PROBE2='http://connect.rom.miui.com/generate_204'

now=$(date +%s)

# 自带过期时间的锁，避免残留导致永久失效
if [ -f "$LOCK" ]; then
  l=$(cat "$LOCK" 2>/dev/null)
  case "$l" in ''|*[!0-9]*) l=0 ;; esac
  [ $((now - l)) -lt 90 ] && exit 0
fi
echo "$now" > "$LOCK"

# curl 退出码 0 = 拿到完整响应（204 空体也算）=> 有网
SEEN=0
HIJACK=0
UA=$(uci -q get ua2f.main.custom_ua 2>/dev/null)
[ -z "$UA" ] && UA='Mozilla/5.0 (Android 14; Mobile; rv:128.0) Gecko/128.0 Firefox/128.0'

for P in "$PROBE1" "$PROBE2"; do
  RESP=$(curl --http1.1 -sS -i -A "$UA" --connect-timeout 5 --max-time 10 "$P" 2>/dev/null)
  [ $? -eq 0 ] && SEEN=1
  # 从响应中提取服务器 Date 头，若刚开机未对时可先做秒级时间对齐
  HDATE=$(printf '%s\n' "$RESP" | sed -n 's/^[Dd]ate:[[:space:]]*//p' | tr -d '\r' | head -n 1)
  if [ -n "$HDATE" ]; then
    date -u -D "%a, %d %b %Y %H:%M:%S GMT" -s "$HDATE" >/dev/null 2>&1
    now=$(date +%s)
  fi
  case "$RESP" in
    *eportal/index.jsp*) HIJACK=1; break ;;
  esac
done

if [ "$HIJACK" -eq 0 ]; then
  if [ "$SEEN" -eq 1 ]; then
    ntpd -q -p ntp.aliyun.com >/dev/null 2>&1 || true
    now=$(date +%s)
    if [ ! -f "$BASE" ]; then
      echo "$now" > "$BASE"
      echo "[$(date '+%F %T')] BASELINE 会话起点(近似)" >> "$LOG"
    fi
  fi
  exit 0
fi

if [ -f "$STATE" ]; then
  last=$(cat "$STATE" 2>/dev/null)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((now - last)) -lt 300 ] && exit 0
fi

# 日志体积保护
if [ -f "$LOG" ]; then
  sz=$(wc -c < "$LOG" 2>/dev/null)
  case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
  if [ "$sz" -gt 65536 ]; then
    tail -n 50 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
fi

t0=$(cat "$BASE" 2>/dev/null)
case "$t0" in ''|*[!0-9]*) t0=0 ;; esac
if [ "$t0" -gt 0 ]; then dur=$((now - t0)); else dur=-1; fi
UP=$(cut -d. -f1 /proc/uptime)
LEASES=$(grep -c . /tmp/dhcp.leases 2>/dev/null)
TTLN=$(iptables -t mangle -S 2>/dev/null | grep -c 'ttl-set 64')
UA=$(uci -q get ua2f.main.custom_ua 2>/dev/null)
U2=$(uci -q get ua2f.enabled.enabled 2>/dev/null)
U3=$(uci -q get ua3f.enabled.enabled 2>/dev/null)

{
  echo "[$(date '+%F %T')] KICK 会话存活=${dur}s ($((dur/3600))h$(( (dur%3600)/60 ))m)"
  echo "  路由运行=${UP}s DHCP租约=${LEASES}个 TTL规则=${TTLN} ua2f=${U2} ua3f=${U3}"
  echo "  UA=${UA}"
  if /usr/bin/portal-login.sh; then
    rm -f "$STATE"
    ntpd -q -p ntp.aliyun.com >/dev/null 2>&1 || true
    date +%s > "$BASE"
    echo "  -> 重新登录成功，会话起点已重置"
  else
    date +%s > "$STATE"
    echo "  -> 登录失败(惩戒期?)，5 分钟后再试"
  fi
} >> "$LOG" 2>&1
