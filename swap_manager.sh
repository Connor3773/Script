#!/usr/bin/env bash
set -euo pipefail

SWAP_FILE="/swapfile"
FSTAB_FILE="/etc/fstab"
BACKUP_SUFFIX=".bak.$(date +%F-%H%M%S)"

log() {
  printf '%s\n' "$*"
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请用 root 运行：sudo bash $0"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少必要命令: $1"
}

check_basic_commands() {
  local cmd
  for cmd in awk chmod cp dd df grep mkswap mv rm stat swapon swapoff; do
    need_cmd "$cmd"
  done
}

parse_size_to_mib() {
  local size="$1"
  local number
  local unit

  if [[ ! "$size" =~ ^([1-9][0-9]*)([MmGg])$ ]]; then
    die "大小格式无效，仅支持整数 M/G，例如 512M、2G"
  fi

  number="${BASH_REMATCH[1]}"
  unit="${BASH_REMATCH[2]}"

  case "$unit" in
    M|m) printf '%s\n' "$number" ;;
    G|g) printf '%s\n' "$((number * 1024))" ;;
  esac
}

swap_is_active() {
  awk -v swap_file="$SWAP_FILE" 'NR > 1 && $1 == swap_file { found = 1 } END { exit !found }' /proc/swaps
}

fstab_has_swap() {
  [[ -f "$FSTAB_FILE" ]] || return 1
  awk -v swap_file="$SWAP_FILE" '
    /^[[:space:]]*#/ || NF == 0 { next }
    $1 == swap_file && $3 == "swap" { found = 1 }
    END { exit !found }
  ' "$FSTAB_FILE"
}

swap_file_size_mib() {
  local bytes
  [[ -f "$SWAP_FILE" ]] || return 1
  bytes="$(stat -c '%s' "$SWAP_FILE")"
  printf '%s\n' "$((bytes / 1024 / 1024))"
}

show_status() {
  log
  log "=========== SWAP 状态 ==========="
  log "SWAP 文件: $SWAP_FILE"

  if [[ -f "$SWAP_FILE" ]]; then
    log "文件存在: 是"
    log "文件大小: $(swap_file_size_mib)M"
  else
    log "文件存在: 否"
  fi

  if swap_is_active; then
    log "当前启用: 是"
  else
    log "当前启用: 否"
  fi

  if fstab_has_swap; then
    log "开机启用: 是"
  else
    log "开机启用: 否"
  fi

  log
  if command -v free >/dev/null 2>&1; then
    free -h || true
  fi

  log
  if ! swapon --show 2>/dev/null; then
    cat /proc/swaps
  fi
}

backup_fstab() {
  [[ -f "$FSTAB_FILE" ]] || return 0
  cp -a "$FSTAB_FILE" "${FSTAB_FILE}${BACKUP_SUFFIX}"
  log "fstab 已备份: ${FSTAB_FILE}${BACKUP_SUFFIX}"
}

remove_fstab_entry() {
  local tmp_file

  [[ -f "$FSTAB_FILE" ]] || return 0
  fstab_has_swap || return 0

  tmp_file="$(mktemp)"
  awk -v swap_file="$SWAP_FILE" '
    /^[[:space:]]*#/ || NF == 0 { print; next }
    $1 == swap_file && $3 == "swap" { next }
    { print }
  ' "$FSTAB_FILE" > "$tmp_file"

  cp "$tmp_file" "$FSTAB_FILE"
  rm -f "$tmp_file"
  log "已移除 fstab 中的 $SWAP_FILE"
}

add_fstab_entry() {
  remove_fstab_entry
  printf '%s\n' "$SWAP_FILE none swap sw 0 0" >> "$FSTAB_FILE"
  log "已写入开机启用: $FSTAB_FILE"
}

check_free_space() {
  local required_mib="$1"
  local available_mib

  available_mib="$(df -Pm / | awk 'NR == 2 { print $4 }')"
  [[ -n "$available_mib" ]] || die "无法读取根分区剩余空间"

  if (( available_mib <= required_mib )); then
    die "根分区空间不足，需要 ${required_mib}M，可用 ${available_mib}M"
  fi
}

create_swap_file() {
  local size_mib="$1"
  local size_text="$2"
  local backup_file

  check_free_space "$size_mib"

  if swap_is_active; then
    swapoff "$SWAP_FILE"
    log "已关闭旧 SWAP: $SWAP_FILE"
  fi

  if [[ -e "$SWAP_FILE" ]]; then
    backup_file="${SWAP_FILE}${BACKUP_SUFFIX}"
    mv "$SWAP_FILE" "$backup_file"
    log "旧 SWAP 文件已备份: $backup_file"
  fi

  log "创建 SWAP 文件: $SWAP_FILE ($size_text)"
  if command -v fallocate >/dev/null 2>&1 && fallocate -l "$size_text" "$SWAP_FILE" 2>/dev/null; then
    :
  else
    dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mib"
  fi

  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
  swapon "$SWAP_FILE"
  log "已启用: $SWAP_FILE"
}

enable_or_resize_swap() {
  local size_text
  local size_mib

  read -r -p "请输入 SWAP 大小，例如 512M 或 2G: " size_text
  size_mib="$(parse_size_to_mib "$size_text")"

  backup_fstab
  remove_fstab_entry
  create_swap_file "$size_mib" "$size_text"
  add_fstab_entry
  show_status
}

disable_swap() {
  backup_fstab

  if swap_is_active; then
    swapoff "$SWAP_FILE"
    log "已关闭: $SWAP_FILE"
  else
    log "$SWAP_FILE 当前未启用"
  fi

  remove_fstab_entry
  show_status
}

delete_swap() {
  backup_fstab

  if swap_is_active; then
    swapoff "$SWAP_FILE"
    log "已关闭: $SWAP_FILE"
  fi

  remove_fstab_entry

  if [[ -e "$SWAP_FILE" ]]; then
    rm -f "$SWAP_FILE"
    log "已删除: $SWAP_FILE"
  else
    log "$SWAP_FILE 不存在，无需删除"
  fi

  show_status
}

confirm() {
  local answer
  local prompt="$1"

  read -r -p "$prompt [y/N]: " answer
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

menu() {
  while true; do
    cat <<EOF

======================================
 SWAP 文件管理
 文件位置: $SWAP_FILE
======================================
1) 查看状态
2) 开启 / 重建 SWAP
3) 关闭 SWAP（保留文件）
4) 删除 SWAP（关闭并删除文件）
0) 退出
EOF

    read -r -p "请选择: " choice

    case "$choice" in
      1)
        show_status
        ;;
      2)
        enable_or_resize_swap
        ;;
      3)
        if confirm "确认关闭 SWAP 并移除开机启用吗？"; then
          disable_swap
        fi
        ;;
      4)
        if confirm "确认关闭并删除 $SWAP_FILE 吗？"; then
          delete_swap
        fi
        ;;
      0)
        exit 0
        ;;
      *)
        log "无效选择"
        ;;
    esac
  done
}

main() {
  require_root
  check_basic_commands
  menu
}

main "$@"
