cat > /root/cf_auto_bestip/push_to_kv.sh << 'EOF'
#!/bin/bash
PROJ_DIR="/root/cf_auto_bestip"
DATA_DIR="$PROJ_DIR/data"
POOL_FILE="$DATA_DIR/cfst_preferred_ips.txt"
CHECK_RESULT="$DATA_DIR/health_result.csv"

# ---- 读取敏感配置 -------------------------------------------
[ -f "$PROJ_DIR/.env" ] && source "$PROJ_DIR/.env"

TOP_KV=10
TOP_DNS=3
TS="[$(date '+%Y-%m-%d %H:%M:%S')]"

echo "============================================================"
echo "$TS 开始健康检测 + 推送"
echo "============================================================"

# ---- 找二进制 -----------------------------------------------
CFST_BIN=""
for c in "$PROJ_DIR/CloudflareST" "$PROJ_DIR/CloudflareSpeedTest" "$PROJ_DIR/cfst"; do
  [ -x "$c" ] && CFST_BIN="$c" && break
done
if [ -z "$CFST_BIN" ]; then
  CFST_BIN=$(find "$PROJ_DIR" -maxdepth 3 -type f \( -name "CloudflareST" -o -name "cfst" \) -perm /111 2>/dev/null | head -1)
fi
if [ -z "$CFST_BIN" ]; then
  echo "$TS [ERROR] 未找到 CloudflareST 二进制"
  exit 1
fi

# ---- 检查IP池 -----------------------------------------------
if [ ! -f "$POOL_FILE" ] || [ ! -s "$POOL_FILE" ]; then
  echo "$TS [ERROR] IP池为空"
  exit 1
fi
TOTAL=$(wc -l < "$POOL_FILE")
echo "$TS [INFO]  IP池共 ${TOTAL} 个，开始健康检测..."

# ---- 关闭Clash，健康检测 ------------------------------------
/etc/init.d/openclash stop 2>/dev/null
sleep 3

"$CFST_BIN" \
  -f "$POOL_FILE" \
  -tl 900 \
  -sl 0 \
  -dn 999 \
  -dt 8 \
  -o "$CHECK_RESULT"

/etc/init.d/openclash start 2>/dev/null
sleep 5

if [ ! -f "$CHECK_RESULT" ]; then
  echo "$TS [ERROR] 健康检测无结果"
  exit 1
fi

PASS=$(tail -n +2 "$CHECK_RESULT" | wc -l)
echo "$TS [INFO]  通过检测: ${PASS} 个IP"

# ---- 过滤美国机场，精确匹配，按速度排序 ---------------------
echo "$TS [INFO]  过滤地区码，精确匹配美国机场..."

SORTED_IPS=$(tail -n +2 "$CHECK_RESULT" \
  | awk -F',' '{
      ip=$1; speed=$6; region=$7;
      gsub(/:[0-9]+$/, "", ip);
      gsub(/[^A-Za-z]/, "", region);
      if (region ~ /^(LAX|SEA|SJC|DFW|IAD|ORD|MIA|ATL|EWR)$/)
        print speed " " ip " " region
    }' \
  | sort -rn \
  | awk '{print $2}')

US_COUNT=$(echo "$SORTED_IPS" | grep -c '.' 2>/dev/null || echo 0)
echo "$TS [INFO]  美国机场IP: ${US_COUNT} 个"

if [ -z "$SORTED_IPS" ] || [ "$US_COUNT" -eq 0 ]; then
  echo "$TS [ERROR] 无美国机场IP，退出"
  exit 1
fi

# ---- 动态平衡：删除最慢N个 ----------------------------------
NEW_COUNT=0
[ -f /tmp/cfst_new_count.txt ] && NEW_COUNT=$(cat /tmp/cfst_new_count.txt | tr -d '[:space:]')

if [ "$NEW_COUNT" -gt 0 ]; then
  echo "$TS [INFO]  动态平衡：删除最慢 ${NEW_COUNT} 个IP..."

  WORST_IPS=$(tail -n +2 "$CHECK_RESULT" \
    | awk -F',' '{
        ip=$1; speed=$6;
        gsub(/:[0-9]+$/, "", ip);
        print speed " " ip
      }' \
    | sort -n \
    | head -n "$NEW_COUNT" \
    | awk '{print $2}')

  while IFS= read -r BAD_IP; do
    [ -z "$BAD_IP" ] && continue
    sed -i "/^${BAD_IP}$/d" "$POOL_FILE"
    echo "$TS [INFO]  已淘汰慢IP: $BAD_IP"
  done <<< "$WORST_IPS"

  AFTER_BALANCE=$(wc -l < "$POOL_FILE")
  echo "$TS [INFO]  动态平衡后池子: ${AFTER_BALANCE} 个"
  rm -f /tmp/cfst_new_count.txt
else
  echo "$TS [INFO]  今天无新增IP，跳过动态平衡"
fi

# ---- 推送前10个到KV ----------------------------------------
DATE=$(date '+%m%d')
ADD_VALUE=""
COUNT=0
while IFS= read -r IP && [ $COUNT -lt $TOP_KV ]; do
  IP=$(echo "$IP" | tr -d '[:space:]')
  [ -z "$IP" ] && continue
  NUM=$(printf "%02d" $((COUNT+1)))
  ENTRY="${IP}:443#US 美国优选${NUM} ${DATE}"
  [ -z "$ADD_VALUE" ] && ADD_VALUE="$ENTRY" || ADD_VALUE="${ADD_VALUE}
${ENTRY}"
  COUNT=$((COUNT+1))
done <<< "$SORTED_IPS"

echo "$TS [INFO]  推送 ${COUNT} 个IP到KV..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/storage/kv/namespaces/$KV_NAMESPACE_ID/values/$KV_KEY" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: text/plain" \
  --data "$ADD_VALUE")

if [ "$HTTP_CODE" -eq 200 ]; then
  echo "$TS [SUCCESS] KV推送成功 (HTTP 200)"
else
  echo "$TS [ERROR]  KV推送失败 (HTTP $HTTP_CODE)"
fi

# ---- 取前3个IP ----------------------------------------------
IP1=$(echo "$SORTED_IPS" | sed -n '1p')
IP2=$(echo "$SORTED_IPS" | sed -n '2p')
IP3=$(echo "$SORTED_IPS" | sed -n '3p')

echo "$TS [INFO]  更新DNS A记录（前 ${TOP_DNS} 个）..."

# ---- 分页删除所有现有A记录（含重试+验证）--------------------
delete_all_a_records() {
  local page=1
  local per_page=100
  local max_pages=10

  echo "$TS [INFO]  开始删除所有A记录..."

  while [ $page -le $max_pages ]; do
    RESPONSE=$(curl -s \
      "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN&page=$page&per_page=$per_page" \
      -H "Authorization: Bearer $API_TOKEN")

    IDS=$(echo "$RESPONSE" | jq -r '.result[].id' 2>/dev/null)
    [ -z "$IDS" ] && break

    while IFS= read -r RID; do
      [ -z "$RID" ] && continue
      for retry in 1 2 3; do
        RES=$(curl -s -X DELETE \
          "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RID" \
          -H "Authorization: Bearer $API_TOKEN")
        SUCCESS=$(echo "$RES" | jq -r '.success' 2>/dev/null)
        if [ "$SUCCESS" = "true" ]; then
          echo "$TS [INFO]  已删除: $RID"
          break
        else
          echo "$TS [WARN]  删除失败(第${retry}次): $RID"
          sleep 1
        fi
      done
    done <<< "$IDS"

    page=$((page+1))
  done

  sleep 2
  CHECK=$(curl -s \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?type=A&name=$DOMAIN" \
    -H "Authorization: Bearer $API_TOKEN")
  LEFT=$(echo "$CHECK" | jq '.result | length' 2>/dev/null || echo "?")
  if [ "$LEFT" = "0" ]; then
    echo "$TS [INFO]  A记录已清空 ✅"
  else
    echo "$TS [WARN]  仍有 ${LEFT} 条残留A记录"
  fi
}

delete_all_a_records

# ---- 创建3条新A记录 -----------------------------------------
sleep 2
for IP in "$IP1" "$IP2" "$IP3"; do
  [ -z "$IP" ] && continue
  curl -s -X POST \
    "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records" \
    -H "Authorization: Bearer $API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$DOMAIN\",\"content\":\"${IP}\",\"ttl\":60,\"proxied\":false}" > /dev/null
  echo "$TS [INFO]  已创建DNS A记录: $IP"
done

# ---- TG通知 -------------------------------------------------
SP1=$(grep "^${IP1}" "$CHECK_RESULT" | cut -d',' -f6 | tr -d '\r\n')
SP2=$(grep "^${IP2}" "$CHECK_RESULT" | cut -d',' -f6 | tr -d '\r\n')
SP3=$(grep "^${IP3}" "$CHECK_RESULT" | cut -d',' -f6 | tr -d '\r\n')
DC1=$(grep "^${IP1}" "$CHECK_RESULT" | cut -d',' -f7 | tr -d '\r\n[:space:]' | sed 's/[^A-Za-z0-9]//g')
DC2=$(grep "^${IP2}" "$CHECK_RESULT" | cut -d',' -f7 | tr -d '\r\n[:space:]' | sed 's/[^A-Za-z0-9]//g')
DC3=$(grep "^${IP3}" "$CHECK_RESULT" | cut -d',' -f7 | tr -d '\r\n[:space:]' | sed 's/[^A-Za-z0-9]//g')

MSG="<b>✅ Cloudflare 优选 IP 更新通知 (LAX/SEA/SJC)</b>

<b>🕐 更新时间：</b>$(date '+%Y-%m-%d %H:%M')

<b>📡 ${DOMAIN} DNS：</b>
1️⃣ ${IP1}  ${SP1} MB/s  ${DC1}
2️⃣ ${IP2}  ${SP2} MB/s  ${DC2}
3️⃣ ${IP3}  ${SP3} MB/s  ${DC3}

<b>📦 KV面板：</b>${KV_PANEL_URL}"

curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
  -d "chat_id=${TG_CHAT_ID}" \
  -d "parse_mode=HTML" \
  --data-urlencode "text=$MSG" > /dev/null

echo "$TS [OK]   TG通知已发送"

# ---- dnspush记录 --------------------------------------------
curl -s -X POST "${DNSPUSH_URL}?log=1&domain=${DNSPUSH_DOMAIN}" \
  -H "x-key: ${DNSPUSH_TOKEN}" \
  --data "${IP1},${IP2},${IP3}" > /dev/null

echo "$TS [OK]   dnspush记录完成"

echo "============================================================"
echo "$TS 全部完成！KV: ${TOP_KV}个  DNS: ${TOP_DNS}个"
echo "============================================================"
EOF
