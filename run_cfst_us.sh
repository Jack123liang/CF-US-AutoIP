cat > /root/cf_auto_bestip/run_cfst_us.sh << 'EOF'
#!/bin/bash
PROJ_DIR="/root/cf_auto_bestip"
DATA_DIR="$PROJ_DIR/data"
LOG_DIR="$PROJ_DIR/logs"
RESULT_CSV="$PROJ_DIR/result.csv"
SAMPLE_FILE="$DATA_DIR/cfst_ips.txt"
ACCUM_FILE="$DATA_DIR/cfst_preferred_ips.txt"
TEMP_FILE="$DATA_DIR/cfst_us_new.txt"

# ---- 读取敏感配置 -------------------------------------------
[ -f "$PROJ_DIR/.env" ] && source "$PROJ_DIR/.env"

COLO="LAX,SEA,SJC"
LATENCY_MAX=300
LATENCY_MIN=10
SPEED_MIN=1
DN=20
DT=10
PORT=443
MAX_POOL_SIZE=500
SAMPLE_COUNT=1500

mkdir -p "$DATA_DIR" "$LOG_DIR"
TIMESTAMP="[$(date '+%Y-%m-%d %H:%M:%S')]"

echo "============================================================"
echo "$TIMESTAMP 美国CF节点专项测速开始"
echo "  目标机场 : $COLO"
echo "============================================================"

# ---- 找二进制 -----------------------------------------------
CFST_BIN=""
for candidate in "$PROJ_DIR/CloudflareST" "$PROJ_DIR/CloudflareSpeedTest" "$PROJ_DIR/cfst"; do
  if [ -x "$candidate" ]; then
    CFST_BIN="$candidate"
    break
  fi
done
if [ -z "$CFST_BIN" ]; then
  found=$(find "$PROJ_DIR" -maxdepth 3 -type f \( -name "CloudflareST" -o -name "CloudflareSpeedTest" -o -name "cfst" \) -perm /111 2>/dev/null | head -1)
  [ -n "$found" ] && CFST_BIN="$found"
fi
if [ -z "$CFST_BIN" ]; then
  echo "$TIMESTAMP [ERROR] 未找到 CloudflareST 二进制"
  exit 1
fi
echo "$TIMESTAMP [INFO]  使用二进制: $CFST_BIN"

# ---- 第一步：从公共源拉取IP ---------------------------------
echo "$TIMESTAMP [INFO]  从公共源拉取IP..."

curl -s --max-time 30 "https://zip.cm.edu.kg/all.txt" \
  | sed 's/:[0-9]*#.*//' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  > "$DATA_DIR/src1.tmp" 2>/dev/null

curl -s --max-time 30 "https://www.cloudflare.com/ips-v4" \
  > "$DATA_DIR/src2_cidr.tmp" 2>/dev/null

> "$DATA_DIR/src2.tmp"
while IFS= read -r CIDR; do
  [ -z "$CIDR" ] && continue
  BASE=$(echo "$CIDR" | cut -d'/' -f1)
  PREFIX=$(echo "$CIDR" | cut -d'/' -f2)
  if [ "$PREFIX" -ge 16 ] && [ "$PREFIX" -le 24 ]; then
    IFS='.' read -r a b c d <<< "$BASE"
    for i in $(seq 0 10); do
      echo "${a}.${b}.${c}.${i}" >> "$DATA_DIR/src2.tmp"
    done
  fi
done < "$DATA_DIR/src2_cidr.tmp"
rm -f "$DATA_DIR/src2_cidr.tmp"

cat "$DATA_DIR/src1.tmp" "$DATA_DIR/src2.tmp" \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -u \
  | awk 'BEGIN{srand()}{print rand(),$0}' \
  | sort -n \
  | cut -d' ' -f2- \
  | head -"$SAMPLE_COUNT" \
  > "$SAMPLE_FILE"

rm -f "$DATA_DIR/src1.tmp" "$DATA_DIR/src2.tmp"

SAMPLE_TOTAL=$(wc -l < "$SAMPLE_FILE")
if [ "$SAMPLE_TOTAL" -eq 0 ]; then
  echo "$TIMESTAMP [ERROR] 无法从公共源获取IP，退出"
  exit 1
fi
echo "$TIMESTAMP [INFO]  抽样完成，共 ${SAMPLE_TOTAL} 个候选IP"

# ---- 第二步：关闭Clash，美国机场专项测速 --------------------
/etc/init.d/openclash stop 2>/dev/null
sleep 3

echo "$TIMESTAMP [INFO]  开始美国机场专项测速（$COLO）..."

"$CFST_BIN" \
  -httping \
  -url https://cf.xiu2.xyz/url \
  -cfcolo "$COLO" \
  -f "$SAMPLE_FILE" \
  -tp "$PORT" \
  -tl "$LATENCY_MAX" \
  -tll "$LATENCY_MIN" \
  -sl "$SPEED_MIN" \
  -dn "$DN" \
  -dt "$DT" \
  -o "$RESULT_CSV"

EXIT_CODE=$?
/etc/init.d/openclash start 2>/dev/null

if [ $EXIT_CODE -ne 0 ] || [ ! -f "$RESULT_CSV" ]; then
  echo "$TIMESTAMP [ERROR] 测速失败或无结果"
  exit 1
fi

# ---- 第三步：提取IP，按机场码过滤 ---------------------------
tail -n +2 "$RESULT_CSV" \
  | grep -E 'LAX|SJC|SEA' \
  | cut -d',' -f1 \
  | sed 's/:[0-9]*$//' \
  | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
  > "$TEMP_FILE"

NEW_COUNT=$(wc -l < "$TEMP_FILE")
echo "$TIMESTAMP [INFO]  本次测速得到 ${NEW_COUNT} 个美国优质IP"

if [ "$NEW_COUNT" -eq 0 ]; then
  echo "$TIMESTAMP [WARN]  无新IP，池文件保持不变"
  echo "0" > /tmp/cfst_new_count.txt
  exit 0
fi

# ---- 第四步：合并去重写入池文件 -----------------------------
if [ -f "$ACCUM_FILE" ] && [ -s "$ACCUM_FILE" ]; then
  BEFORE=$(wc -l < "$ACCUM_FILE")
  cat "$ACCUM_FILE" "$TEMP_FILE" | sort -u > "${ACCUM_FILE}.tmp"
  mv "${ACCUM_FILE}.tmp" "$ACCUM_FILE"
  AFTER=$(wc -l < "$ACCUM_FILE")
  ADDED=$((AFTER - BEFORE))
  echo "$TIMESTAMP [INFO]  合并去重: ${BEFORE} → ${AFTER} 个IP（新增 ${ADDED} 个）"
else
  cp "$TEMP_FILE" "$ACCUM_FILE"
  AFTER=$(wc -l < "$ACCUM_FILE")
  ADDED=$AFTER
  echo "$TIMESTAMP [INFO]  初始化池，写入 ${AFTER} 个IP"
fi

echo "$ADDED" > /tmp/cfst_new_count.txt
echo "$TIMESTAMP [INFO]  本次真实新增 ${ADDED} 个，已记录"

# ---- 第五步：超出上限裁剪 -----------------------------------
if [ "$(wc -l < "$ACCUM_FILE")" -gt "$MAX_POOL_SIZE" ]; then
  tail -n "$MAX_POOL_SIZE" "$ACCUM_FILE" > "${ACCUM_FILE}.tmp"
  mv "${ACCUM_FILE}.tmp" "$ACCUM_FILE"
  echo "$TIMESTAMP [INFO]  池裁剪至 ${MAX_POOL_SIZE} 条"
fi

FINAL_COUNT=$(wc -l < "$ACCUM_FILE")
echo "============================================================"
echo "$TIMESTAMP 测速完成，累积池: ${FINAL_COUNT} / ${MAX_POOL_SIZE} 个"
echo "============================================================"
EOF
