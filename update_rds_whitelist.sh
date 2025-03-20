#!/bin/sh
# ---------------------------
# 阿里云RDS白名单更新脚本（纯净输出版）
# 版本：24.0
# ---------------------------

# 配置区
ACCESS_KEY_ID="xxx"
ACCESS_KEY_SECRET="xxx"
REGION_ID="cn-shanghai"
INSTANCE_ID="rm-ufxxxxxxx"
SECURITY_GROUP_NAME="xxxxx"
IP_FILE="/tmp/last_ip.txt"
LOG_FILE="/tmp/rds_whitelist.log"

# ----------- 初始化 -----------
exec >>"$LOG_FILE" 2>&1
echo "==== 任务开始: $(date '+%Y-%m-%d %H:%M:%S') ===="

# 函数：RFC 3986编码
url_encode() {
  echo -n "$1" | awk '
    BEGIN {
      hextab = "0123456789ABCDEF"
      for (i = 0; i <= 255; i++) ord[sprintf("%c",i)] = i
    }
    {
      len = length($0)
      for (i = 1; i <= len; i++) {
        c = substr($0, i, 1)
        if (c ~ /[a-zA-Z0-9_.~-]/) {
          printf c
        } else {
          printf "%%%s", toupper(sprintf("%02x", ord[c]))
        }
      }
    }'
}

# 函数：获取公网IP（修复输出污染）
get_public_ip() {
  echo "[DEBUG] 开始获取公网IP..." >&2
  for src in "http://checkip.amazonaws.com" "http://ipecho.net/plain" "http://ifconfig.me"; do
    echo "[DEBUG] 尝试从 $src 获取IP" >&2
    ip=$(curl -s -4 --connect-timeout 5 "$src" | grep -oE "[0-9]{1,3}(\\.[0-9]{1,3}){3}")
    [ -n "$ip" ] && { 
      echo "[INFO] 成功获取IP: $ip" >&2
      echo "$ip"  # 关键修复：仅输出IP到stdout
      return
    }
  done
  echo "[ERROR] 所有IP源均不可用" >&2
  echo ""
}

# 主流程
echo "[INFO] 正在检查公网IP..."
CURRENT_IP=$(get_public_ip)
[ -z "$CURRENT_IP" ] && {
  echo "[ERROR] IP获取失败"
  exit 1
}

# IP变动检查
echo "[INFO] 检查IP变动..."
if [ -f "$IP_FILE" ]; then
  LAST_IP=$(cat "$IP_FILE")
  echo "[DEBUG] 上次记录的IP: $LAST_IP" >&2
  [ "$CURRENT_IP" = "$LAST_IP" ] && {
    echo "[INFO] IP未变化，无需更新" >&2
    exit 0
  }
else
  echo "[DEBUG] 未找到历史IP记录文件" >&2
fi

# ----------- 签名参数构造 -----------
echo "[INFO] 开始构造签名参数..." >&2
ALGORITHM="ACS3-HMAC-SHA256"
HTTP_METHOD="POST"
HOST="rds.aliyuncs.com"
CANONICAL_URI="/"
ACTION="ModifySecurityIps"
VERSION="2014-08-15"
UTC_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
NONCE=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N | md5sum | cut -c1-32)

echo "[DEBUG] 生成随机数Nonce: $NONCE" >&2
echo "[DEBUG] UTC时间戳: $UTC_DATE" >&2

# 构造查询参数
PARAMS="Action=$ACTION
DBInstanceId=$INSTANCE_ID
SecurityIps=$CURRENT_IP
DBInstanceIPArrayName=$SECURITY_GROUP_NAME
WhitelistNetworkType=MIX
ModifyMode=Cover"

echo "[DEBUG] 原始参数列表:" >&2
echo "$PARAMS" >&2

# 参数排序编码
CANONICAL_QUERY=$(echo "$PARAMS" | while IFS='=' read -r key value; do
  encoded_key=$(url_encode "$key")
  encoded_value=$(url_encode "$value")
  echo "${encoded_key}=${encoded_value}"
done | sort -t= -k1 | tr '\n' '&' | sed 's/&$//')

echo "[DEBUG] 编码后的规范查询字符串:" >&2
echo "$CANONICAL_QUERY" >&2

# 构造规范请求
HASHED_PAYLOAD=$(echo -n "" | openssl sha256 | awk '{print $2}')
echo "[DEBUG] 空请求体哈希值: $HASHED_PAYLOAD" >&2

HEADERS="host:$HOST
x-acs-action:$ACTION
x-acs-version:$VERSION
x-acs-date:$UTC_DATE
x-acs-signature-nonce:$NONCE
x-acs-content-sha256:$HASHED_PAYLOAD"

# 处理规范头
CANONICAL_HEADERS=$(echo "$HEADERS" | while read line; do
  key=$(echo "$line" | cut -d':' -f1 | tr 'A-Z' 'a-z')
  value=$(echo "$line" | cut -d':' -f2- | sed 's/^ *//')
  echo "${key}:${value}"
done | sort | tr '\n' '\n')

SIGNED_HEADERS=$(echo "$HEADERS" | cut -d':' -f1 | tr 'A-Z' 'a-z' | sort | tr '\n' ';' | sed 's/;$//')

echo "[DEBUG] 规范头内容:" >&2
echo "$CANONICAL_HEADERS" >&2
echo "[DEBUG] 签名头列表: $SIGNED_HEADERS" >&2

CANONICAL_REQUEST="${HTTP_METHOD}\n${CANONICAL_URI}\n${CANONICAL_QUERY}\n${CANONICAL_HEADERS}\n\n${SIGNED_HEADERS}\n${HASHED_PAYLOAD}"
echo "[DEBUG] 规范请求内容:" >&2
echo -e "$CANONICAL_REQUEST" >&2

# 计算签名
HASHED_REQUEST=$(echo -en "$CANONICAL_REQUEST" | openssl sha256 | awk '{print $2}')
STRING_TO_SIGN="${ALGORITHM}\n${HASHED_REQUEST}"
echo "[DEBUG] 签名字符串:" >&2
echo -e "$STRING_TO_SIGN" >&2

SIGNATURE=$(echo -en "$STRING_TO_SIGN" | openssl dgst -sha256 -mac HMAC -macopt "key:${ACCESS_KEY_SECRET}" | awk '{print $2}')
echo "[DEBUG] 计算得到的签名: $SIGNATURE" >&2

# 构造Authorization头
AUTHORIZATION="${ALGORITHM} Credential=${ACCESS_KEY_ID},SignedHeaders=${SIGNED_HEADERS},Signature=${SIGNATURE}"
echo "[DEBUG] Authorization头: $AUTHORIZATION" >&2

# 发送请求
echo "[INFO] 正在发送API请求..." >&2
FULL_URL="https://${HOST}/?${CANONICAL_QUERY}"
echo "[DEBUG] 完整请求URL: ${FULL_URL%&Signature=*}" >&2

RESPONSE=$(curl -s -X POST \
  -H "host: $HOST" \
  -H "x-acs-action: $ACTION" \
  -H "x-acs-version: $VERSION" \
  -H "x-acs-date: $UTC_DATE" \
  -H "x-acs-signature-nonce: $NONCE" \
  -H "x-acs-content-sha256: $HASHED_PAYLOAD" \
  -H "Authorization: $AUTHORIZATION" \
  "$FULL_URL")

echo "[DEBUG] 原始响应内容:" >&2
echo "$RESPONSE" >&2

# 处理响应
if echo "$RESPONSE" | grep -q '"TaskId"'; then
  echo "[INFO] 白名单更新成功" >&2
  TASK_ID=$(echo "$RESPONSE" | grep -o '"TaskId":"[^"]*"' | cut -d'"' -f4)
  REQUEST_ID=$(echo "$RESPONSE" | grep -o '"RequestId":"[^"]*"' | cut -d'"' -f4)
  echo "$CURRENT_IP" > "$IP_FILE"
  echo "[SUCCESS] 任务ID: $TASK_ID, 请求ID: $REQUEST_ID" >&2
else
  ERROR_MSG=$(echo "$RESPONSE" | grep -o '"Message":"[^"]*"' | cut -d'"' -f4)
  REQUEST_ID=$(echo "$RESPONSE" | grep -o '"RequestId":"[^"]*"' | cut -d'"' -f4)
  echo "[ERROR] API请求失败" >&2
  echo "[ERROR] 错误信息: $ERROR_MSG" >&2
  echo "[ERROR] 请求ID: $REQUEST_ID" >&2
  echo "[ERROR] 诊断链接: https://api.aliyun.com/troubleshoot?q=IncompleteSignature&product=Rds&requestId=$REQUEST_ID" >&2
  exit 1
fi
