#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 运行：sudo bash $0"
  exit 1
fi

CONF_FILE="/etc/sysctl.d/99-z-bbr-proxy.conf"
BACKUP_SUFFIX=".bak.$(date +%F-%H%M%S)"
OBSOLETE_CONF_FILES=(
  "/etc/sysctl.d/99-bbr-proxy.conf"
)

SYSCTL_SETTINGS=(
  "net.core.default_qdisc=fq"
  "net.core.rmem_max=134217728"
  "net.core.wmem_max=134217728"
  "net.core.somaxconn=65535"
  "net.core.netdev_max_backlog=250000"
  "net.ipv4.tcp_congestion_control=bbr"
  "net.ipv4.tcp_window_scaling=1"
  "net.ipv4.tcp_timestamps=1"
  "net.ipv4.tcp_sack=1"
  "net.ipv4.tcp_rmem=4096 87380 134217728"
  "net.ipv4.tcp_wmem=4096 65536 134217728"
  "net.ipv4.tcp_moderate_rcvbuf=1"
  "net.ipv4.tcp_mtu_probing=1"
  "net.ipv4.tcp_slow_start_after_idle=0"
  "net.ipv4.tcp_fastopen=3"
  "net.ipv4.tcp_max_syn_backlog=65535"
  "net.ipv4.tcp_keepalive_time=60"
  "net.ipv4.tcp_keepalive_intvl=10"
  "net.ipv4.tcp_keepalive_probes=5"
  "net.ipv4.ip_local_port_range=1024 65535"
)

SYSCTL_KEYS=()
for setting in "${SYSCTL_SETTINGS[@]}"; do
  SYSCTL_KEYS+=("${setting%%=*}")
done

echo "======================================"
echo " BBR + Provider Sysctl (高速去重版)"
echo "======================================"

echo "[1/7] 当前内核"
uname -r

echo
echo "[2/7] 检查 BBR 模块"

if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
  echo "BBR 已可用"
else
  if ! modinfo tcp_bbr >/dev/null 2>&1; then
    echo "错误：当前内核未包含 tcp_bbr 模块，且拥塞控制列表中没有 bbr"
    exit 1
  fi

  echo "BBR 未加载 -> 正在加载"
  modprobe tcp_bbr

  if ! sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"; then
    echo "错误：tcp_bbr 已尝试加载，但拥塞控制列表中仍没有 bbr"
    exit 1
  fi
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

report_unmanaged_duplicates() {
  local file="$1"
  local key_pattern="$2"

  [[ -f "$file" ]] || return 0
  [[ "$file" != "$CONF_FILE" ]] || return 0

  if grep -Eq "^[[:space:]]*(${key_pattern})[[:space:]]*=" "$file"; then
    echo "提示: 发现非 /etc 重复项，本脚本不直接修改包管理目录: $file"
  fi
}

remove_obsolete_empty_files() {
  local file
  local backup_file

  for file in "${OBSOLETE_CONF_FILES[@]}"; do
    [[ -f "$file" ]] || continue
    [[ "$file" != "$CONF_FILE" ]] || continue

    if ! grep -Eq "^[[:space:]]*[^#[:space:]]" "$file"; then
      backup_file="${file}.removed${BACKUP_SUFFIX}"
      cp -a "$file" "$backup_file"
      rm -f "$file"
      echo "已删除空旧配置: $file"
      echo "删除前备份: $backup_file"
    fi
  done
}

KEY_PATTERN="$(build_key_pattern)"
shopt -s nullglob
SYSCTL_FILES=(/etc/sysctl.conf /etc/sysctl.d/*.conf)
READONLY_SYSCTL_FILES=(/run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf)
shopt -u nullglob

for file in "${SYSCTL_FILES[@]}"; do
  cleanup_sysctl_duplicates "$file" "$KEY_PATTERN"
done

remove_obsolete_empty_files

for file in "${READONLY_SYSCTL_FILES[@]}"; do
  report_unmanaged_duplicates "$file" "$KEY_PATTERN"
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
# ===== BBR High Throughput Network Tuning =====
EOF

for setting in "${SYSCTL_SETTINGS[@]}"; do
  key="${setting%%=*}"
  value="${setting#*=}"
  proc_path="/proc/sys/${key//./\/}"

  # 不同内核支持的 sysctl 项可能不同；只写入当前系统真实存在的参数。
  if [[ -e "$proc_path" ]]; then
    printf '%s = %s\n' "$key" "$value" >> "$CONF_FILE"
  else
    echo "跳过不支持参数: $key"
  fi
done

echo
echo "[7/7] 应用配置"
if ! sysctl --system; then
  echo "警告: sysctl --system 返回失败，继续单独应用本脚本配置"
fi
sysctl -p "$CONF_FILE"

echo
echo "=========== 验证结果 ==========="
for setting in "${SYSCTL_SETTINGS[@]}"; do
  key="${setting%%=*}"
  proc_path="/proc/sys/${key//./\/}"
  [[ -e "$proc_path" ]] && sysctl "$key"
done
sysctl net.ipv4.tcp_available_congestion_control
lsmod | grep '^tcp_bbr' || true

echo
echo "完成"
echo "配置文件: $CONF_FILE"
