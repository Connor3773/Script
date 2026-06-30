#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

CONF_FILE="/etc/sysctl.d/99-bbr-proxy.conf"
BACKUP_SUFFIX=".bak.$(date +%F-%H%M%S)"

SYSCTL_KEYS=(
  "net.ipv4.tcp_keepalive_time"
  "net.ipv4.tcp_keepalive_intvl"
  "net.ipv4.tcp_keepalive_probes"
  "net.core.default_qdisc"
  "net.ipv4.tcp_congestion_control"
  "net.ipv4.ip_local_port_range"
)

echo "======================================"
echo " BBR + Provider Sysctl (去重配置版)"
echo "======================================"

echo "[1/7] 当前内核"
uname -r

echo
echo "[2/7] 检查 BBR 模块"

if ! modinfo tcp_bbr >/dev/null 2>&1; then
  echo "错误：当前内核未包含 tcp_bbr 模块"
  exit 1
fi

if ! lsmod | grep -q '^tcp_bbr'; then
  echo "BBR 未加载 -> 正在加载"
  modprobe tcp_bbr
else
  echo "BBR 已加载"
fi

echo "设置开机自动加载"
printf '%s\n' "tcp_bbr" > /etc/modules-load.d/bbr.conf

echo
echo "[3/7] 检查拥塞控制支持"
sysctl -n net.ipv4.tcp_available_congestion_control || true

echo
echo "[4/7] 清理重复 sysctl 配置"

build_key_pattern() {
  printf '%s\n' "${SYSCTL_KEYS[@]}" \
    | sed 's/[.[\*^$()+?{}|\\]/\\&/g' \
    | paste -sd '|' -
}

cleanup_sysctl_duplicates() {
  local file="$1"
  local key_pattern="$2"
  local tmp_file

  [[ -f "$file" ]] || return 0
  [[ "$file" != "$CONF_FILE" ]] || return 0

  # 只清理本脚本接管的生效配置行，保留注释、空行与其它参数。
  if ! grep -Eq "^[[:space:]]*(${key_pattern})[[:space:]]*=" "$file"; then
    return 0
  fi

  cp -a "$file" "${file}${BACKUP_SUFFIX}"
  tmp_file="$(mktemp)"

  awk -v keys="$(IFS=','; echo "${SYSCTL_KEYS[*]}")" '
    BEGIN {
      split(keys, key_list, ",")
      for (i in key_list) managed[key_list[i]] = 1
    }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ {
      print
      next
    }
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      split(line, parts, "=")
      key = parts[1]
      sub(/[[:space:]]*$/, "", key)
      if (managed[key]) next
      print
    }
  ' "$file" > "$tmp_file"

  cat "$tmp_file" > "$file"
  rm -f "$tmp_file"
  echo "已清理重复项: $file"
  echo "备份文件: ${file}${BACKUP_SUFFIX}"
}

KEY_PATTERN="$(build_key_pattern)"
shopt -s nullglob
SYSCTL_FILES=(/etc/sysctl.conf /etc/sysctl.d/*.conf)
shopt -u nullglob

for file in "${SYSCTL_FILES[@]}"; do
  cleanup_sysctl_duplicates "$file" "$KEY_PATTERN"
done

echo
echo "[5/7] 备份当前独立配置"

if [[ -f "$CONF_FILE" ]]; then
  cp -a "$CONF_FILE" "${CONF_FILE}${BACKUP_SUFFIX}"
  echo "旧配置已备份: ${CONF_FILE}${BACKUP_SUFFIX}"
else
  echo "未发现旧配置，跳过备份"
fi

echo
echo "[6/7] 写入唯一生效配置 -> $CONF_FILE"

cat > "$CONF_FILE" <<'EOF'
# ===== Default Network Tuning =====
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.ip_local_port_range = 1024 65535
EOF

echo
echo "[7/7] 应用配置"
sysctl --system

echo
echo "=========== 验证结果 ==========="
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_congestion_control
sysctl net.ipv4.tcp_available_congestion_control
lsmod | grep '^tcp_bbr' || true

echo
echo "完成"
echo "配置文件: $CONF_FILE"
