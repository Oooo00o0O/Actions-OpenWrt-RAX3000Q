#!/bin/sh

set -u

CONF='/etc/portal-login.conf'
BOOT_URL='http://123.123.123.123/'
SSO_API='https://api.215123.cn'

[ -r "$CONF" ] || {
    echo "配置文件不存在: $CONF" >&2
    exit 1
}

. "$CONF"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "缺少命令: $1" >&2
        exit 1
    }
}

need_cmd curl
need_cmd jsonfilter
need_cmd sed

echo "[1/4] 获取当前 Portal 参数..."

BOOT_HTML="$(
    curl --http1.1 -sS \
        --connect-timeout 8 \
        --max-time 15 \
        "$BOOT_URL"
)" || {
    echo "无法访问 Portal 探测地址" >&2
    exit 2
}

INDEX_URL="$(
    printf '%s\n' "$BOOT_HTML" |
    sed -n "s/.*location\.href='\([^']*\)'.*/\1/p"
)"

if [ -z "$INDEX_URL" ]; then
    echo "没有发现 Portal 跳转。可能已经在线，或者返回格式发生变化。"
    exit 0
fi

case "$INDEX_URL" in
    http://*/eportal/index.jsp\?*)
        ;;
    *)
        echo "发现未知 Portal URL，停止：" >&2
        printf '%s\n' "$INDEX_URL" >&2
        exit 3
        ;;
esac

PORTAL_ORIGIN="${INDEX_URL%%/eportal/*}"
QUERY="${INDEX_URL#*\?}"

# oauthRedirect 要求 login_sso.jsp 后面的 ? 先编码成 %3F，
# 随后由 curl --data-urlencode 再整体编码一次。
REDIRECT_URI="${PORTAL_ORIGIN}/eportal/login_sso.jsp%3F${QUERY}"

# 尝试从 ePortal 的 302 重定向中动态提取中心 SSO 的 client_id (有兜底)
DYN_LOC="$(
    curl -sS -I \
        --connect-timeout 8 \
        --max-time 15 \
        "$INDEX_URL" 2>/dev/null |
    sed -n 's/^[Ll]ocation:[[:space:]]*//p' |
    tr -d '\r'
)"
DYN_CLIENT="$(
    printf '%s' "$DYN_LOC" |
    sed -n 's/.*[?&]client_id=\([^&]*\).*/\1/p'
)"
if [ -n "$DYN_CLIENT" ]; then
    CLIENT_ID="$DYN_CLIENT"
fi

echo "[2/4] 获取 SSO token..."

LOGIN_JSON="$(
    curl -fsSk \
        --connect-timeout 10 \
        --max-time 20 \
        "${SSO_API}/ac/auth/loginByPhoneAndUid" \
        -H 'Accept: application/json' \
        -H 'Content-Type: application/json' \
        -H 'Origin: https://broadband.215123.cn' \
        -H 'Referer: https://broadband.215123.cn/' \
        --data-binary \
        "{\"phone\":\"${PHONE}\",\"uid\":\"${UID_VALUE}\",\"captchaKey\":\"\"}"
)" || {
    echo "SSO 登录请求失败" >&2
    exit 4
}

TOKEN="$(
    printf '%s' "$LOGIN_JSON" |
    jsonfilter -e '@.data.token' 2>/dev/null
)"

if [ -z "$TOKEN" ]; then
    echo "没有取得 satoken，服务器返回：" >&2
    printf '%s\n' "$LOGIN_JSON" >&2
    exit 5
fi

echo "[3/4] 获取本次 ePortal 登录 URL..."

OAUTH_JSON="$(
    curl -fsSk -G \
        --connect-timeout 10 \
        --max-time 20 \
        "${SSO_API}/ac/auth/oauthRedirect" \
        -H 'Accept: application/json' \
        -H 'Origin: https://broadband.215123.cn' \
        -H 'Referer: https://broadband.215123.cn/' \
        -H "satoken: ${TOKEN}" \
        --data-urlencode 'response_type=code' \
        --data-urlencode "client_id=${CLIENT_ID}" \
        --data-urlencode "redirect_uri=${REDIRECT_URI}" \
        --data-urlencode "serviceName=${SERVICE_NAME}"
)" || {
    echo "oauthRedirect 请求失败" >&2
    exit 6
}

LOGIN_URL="$(
    printf '%s' "$OAUTH_JSON" |
    jsonfilter -e '@.data' 2>/dev/null
)"

case "$LOGIN_URL" in
    http://*/eportal/login_sso.jsp\?*)
        ;;
    *)
        echo "没有得到有效的 ePortal 登录地址：" >&2
        printf '%s\n' "$OAUTH_JSON" >&2
        exit 7
        ;;
esac

echo "[4/4] 提交 ePortal 认证..."

HDR="/tmp/portal-login.headers.$$"
trap 'rm -f "$HDR"' EXIT INT TERM

curl -sS \
    --connect-timeout 10 \
    --max-time 20 \
    -D "$HDR" \
    -o /dev/null \
    "$LOGIN_URL" || {
        echo "无法连接 ePortal" >&2
        exit 8
    }

LOCATION="$(
    sed -n 's/^[Ll]ocation:[[:space:]]*//p' "$HDR" |
    tr -d '\r' |
    head -n 1
)"

case "$LOCATION" in
    *'/success.jsp?'*)
        echo "认证成功。"
        exit 0
        ;;

    *'/fail.jsp?'*)
        echo "认证服务器明确拒绝本次登录：" >&2
        printf '%s\n' "$LOCATION" >&2
        exit 20
        ;;

    *)
        echo "收到未知认证结果：" >&2
        cat "$HDR" >&2
        exit 9
        ;;
esac
