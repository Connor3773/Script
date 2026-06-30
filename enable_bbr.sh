#!/usr/bin/env bash
set -euo pipefail

CONF_FILE="/etc/sysctl.d/99-z-bbr-proxy.conf"
MODULES_FILE="/etc/modules-load.d/bbr.conf"
BACKUP_SUFFIX=".bak.$(date +%F-%H%M%S)"
DRY_RUN=0
RESTORE=0
TMP_FILES=()

OBSOLETE_CONF_FILES=(
  "/etc/sysctl.d/99-bbr-proxy.conf"
)

REQUIRED_COMMANDS=(
  "awk"
  "cat"
  "cp"
  "date"
  "grep"
  "install"
  "mktemp"
  "paste"
  "rm"
  "sed"
  "sort"
  "sysctl"
  "tail"
  "uname"
)

BBR_COMMANDS=(
  "lsmod"
  "modinfo"
  "modprobe"
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

usage() {
  cat <<'EOF'
用法:
  bash enable_bbr.sh [--dry-run]
  bash enable_bbr.sh --restore

选项:
  --dry-run   只预览将执行的操作，不修改系统配置，不安装依赖
  --restore   从最近的备份恢复 /etc/sysctl.d/99-z-bbr-proxy.conf
  -h, --help  显示帮助
EOF
}

log() {
  printf '%s\n' "$*"
}

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

cleanup_tmp_files() {
  local file

  for file in "${TMP_FILES[@]}"; do
    if [[ -n "$file" && -e "$file" ]]; then
      rm -f "$file"
    fi
  done

  return 0
}
trap cleanup_tmp_files EXIT

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "请用 root 运行：sudo bash $0"
  fi
}

parse_args() {
  local arg

  for arg in "$@"; do
    case "$arg" in
      --dry-run)
        DRY_RUN=1
        ;;
      --restore)
        RESTORE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "未知参数: $arg"
        ;;
    esac
  done

  if [[ "$DRY_RUN" -eq 1 && "$RESTORE" -eq 1 ]]; then
    die "--dry-run 和 --restore 不能同时使用"
  fi
}

run_cmd() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi

  "$@"
}

new_tmp_file() {
  local var_name="$1"
  local generated_tmp_file

  generated_tmp_file="$(mktemp)"
  TMP_FILES+=("$generated_tmp_file")
  printf -v "$var_name" '%s' "$generated_tmp_file"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_package_manager() {
  if command_exists apt-get; then
    printf '%s\n' "apt"
  elif command_exists dnf; then
    printf '%s\n' "dnf"
  elif command_exists yum; then
    printf '%s\n' "yum"
  elif command_exists apk; then
    printf '%s\n' "apk"
  else
    return 1
  fi
}

package_for_command() {
  local command_name="$1"
  local package_manager="$2"

  case "$command_name" in
    awk)
      [[ "$package_manager" == "apk" ]] && printf '%s\n' "gawk" || printf '%s\n' "gawk"
      ;;
    grep|sed)
      [[ "$package_manager" == "apk" ]] && printf '%s\n' "$command_name" || printf '%s\n' "grep sed"
      ;;
    cat|install|cp|date|rm|sort|tail|uname)
      [[ "$package_manager" == "apk" ]] && printf '%s\n' "coreutils" || printf '%s\n' "coreutils"
      ;;
    lsmod|modinfo|modprobe)
      [[ "$package_manager" == "apk" ]] && printf '%s\n' "kmod" || printf '%s\n' "kmod"
      ;;
    paste)
      [[ "$package_manager" == "apk" ]] && printf '%s\n' "coreutils" || printf '%s\n' "coreutils"
      ;;
    mktemp)
      [[ "$package_manager" == "apk" ]] && printf '%s\n' "coreutils" || printf '%s\n' "coreutils"
      ;;
    sysctl)
      case "$package_manager" in
        apt|apk)
          printf '%s\n' "procps"
          ;;
        dnf|yum)
          printf '%s\n' "procps-ng"
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

install_packages() {
  local package_manager="$1"
  shift

  [[ "$#" -gt 0 ]] || return 0

  case "$package_manager" in
    apt)
      run_cmd apt-get update
      run_cmd apt-get install -y "$@"
      ;;
    dnf)
      run_cmd dnf install -y "$@"
      ;;
    yum)
      run_cmd yum install -y "$@"
      ;;
    apk)
      run_cmd apk add --no-cache "$@"
      ;;
    *)
      die "不支持的包管理器: $package_manager"
      ;;
  esac
}

ensure_dependencies() {
  local missing_commands=()
  local packages=()
  local package_names=()
  local required_commands=("${REQUIRED_COMMANDS[@]}")
  local package_manager
  local command_name
  local existing_package
  local package
  local package_name
  local exists

  if [[ "$RESTORE" -eq 0 ]]; then
    required_commands+=("${BBR_COMMANDS[@]}")
  fi

  for command_name in "${required_commands[@]}"; do
    if ! command_exists "$command_name"; then
      missing_commands+=("$command_name")
    fi
  done

  [[ "${#missing_commands[@]}" -gt 0 ]] || return 0

  log "发现缺失依赖命令: ${missing_commands[*]}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    die "--dry-run 不会自动安装依赖，请先安装后再预览"
  fi

  package_manager="$(detect_package_manager)" || die "找不到 apt-get/dnf/yum/apk，无法自动安装依赖"

  for command_name in "${missing_commands[@]}"; do
    package="$(package_for_command "$command_name" "$package_manager")" || die "不知道如何安装命令: $command_name"
    read -r -a package_names <<< "$package"

    for package_name in "${package_names[@]}"; do
      exists=0
      for existing_package in "${packages[@]}"; do
        if [[ "$existing_package" == "$package_name" ]]; then
          exists=1
          break
        fi
      done

      [[ "$exists" -eq 1 ]] || packages+=("$package_name")
    done
  done

  log "自动安装依赖包: ${packages[*]}"
  install_packages "$package_manager" "${packages[@]}"

  for command_name in "${missing_commands[@]}"; do
    command_exists "$command_name" || die "依赖安装后仍找不到命令: $command_name"
  done
}

normalize_value() {
  printf '%s\n' "$1" | awk '{$1=$1; print}'
}

proc_path_for_key() {
  local key="$1"
  printf '/proc/sys/%s\n' "${key//./\/}"
}

build_key_pattern() {
  printf '%s\n' "${SYSCTL_KEYS[@]}" \
    | sed 's/[.[\*^$()+?{}|\\]/\\&/g' \
    | paste -sd '|' -
}

sysctl_supports_key() {
  local key="$1"
  local proc_path

  proc_path="$(proc_path_for_key "$key")"
  [[ -e "$proc_path" ]]
}

bbr_available() {
  sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw "bbr"
}

ensure_bbr_available() {
  log
  log "[2/8] 检查 BBR 支持"

  if bbr_available; then
    log "BBR 已可用"
    return 0
  fi

  if ! modinfo tcp_bbr >/dev/null 2>&1; then
    die "当前内核未包含 tcp_bbr 模块，且拥塞控制列表中没有 bbr"
  fi

  log "BBR 未加载 -> 正在加载"
  run_cmd modprobe tcp_bbr

  if [[ "$DRY_RUN" -eq 0 ]] && ! bbr_available; then
    die "tcp_bbr 已尝试加载，但拥塞控制列表中仍没有 bbr"
  fi
}

write_modules_load_config() {
  log "设置开机自动加载"

  if ! modinfo tcp_bbr >/dev/null 2>&1; then
    log "BBR 可能已内建到内核，跳过开机模块加载配置"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] 写入 $MODULES_FILE: tcp_bbr"
    return 0
  fi

  local tmp_file

  new_tmp_file tmp_file
  printf '%s\n' "tcp_bbr" > "$tmp_file"
  install -m 0644 "$tmp_file" "$MODULES_FILE"
  rm -f "$tmp_file"
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

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] 将清理重复项: $file"
    grep -En "^[[:space:]]*(${key_pattern})[[:space:]]*=" "$file" || true
    return 0
  fi

  cp -a "$file" "${file}${BACKUP_SUFFIX}"
  new_tmp_file tmp_file

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

  install -m 0644 "$tmp_file" "$file"
  rm -f "$tmp_file"
  log "已清理重复项: $file"
  log "备份文件: ${file}${BACKUP_SUFFIX}"
}

report_unmanaged_duplicates() {
  local file="$1"
  local key_pattern="$2"

  [[ -f "$file" ]] || return 0
  [[ "$file" != "$CONF_FILE" ]] || return 0

  if grep -Eq "^[[:space:]]*(${key_pattern})[[:space:]]*=" "$file"; then
    log "提示: 系统默认目录中存在同名项，sysctl --system 会先显示它，随后由 $CONF_FILE 覆盖: $file"
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

      if [[ "$DRY_RUN" -eq 1 ]]; then
        log "[dry-run] 将删除空旧配置: $file"
        log "[dry-run] 删除前备份: $backup_file"
        continue
      fi

      cp -a "$file" "$backup_file"
      rm -f "$file"
      log "已删除空旧配置: $file"
      log "删除前备份: $backup_file"
    fi
  done
}

cleanup_duplicate_configs() {
  local key_pattern
  local file
  local sysctl_files
  local readonly_sysctl_files

  log
  log "[4/8] 清理重复 sysctl 配置"

  key_pattern="$(build_key_pattern)"
  shopt -s nullglob
  sysctl_files=(/etc/sysctl.conf /etc/sysctl.d/*.conf)
  readonly_sysctl_files=(/run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf /usr/lib/sysctl.d/*.conf /lib/sysctl.d/*.conf)
  shopt -u nullglob

  for file in "${sysctl_files[@]}"; do
    cleanup_sysctl_duplicates "$file" "$key_pattern"
  done

  remove_obsolete_empty_files

  for file in "${readonly_sysctl_files[@]}"; do
    report_unmanaged_duplicates "$file" "$key_pattern"
  done
}

backup_current_config() {
  log
  log "[5/8] 备份当前独立配置"

  if [[ ! -f "$CONF_FILE" ]]; then
    log "未发现旧配置，跳过备份"
    return 0
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] 将备份: $CONF_FILE -> ${CONF_FILE}${BACKUP_SUFFIX}"
    return 0
  fi

  cp -a "$CONF_FILE" "${CONF_FILE}${BACKUP_SUFFIX}"
  log "旧配置已备份: ${CONF_FILE}${BACKUP_SUFFIX}"
}

write_target_config() {
  local tmp_file
  local key
  local value
  local setting

  log
  log "[6/8] 写入唯一生效配置 -> $CONF_FILE"

  new_tmp_file tmp_file
  printf '%s\n' "# ===== BBR High Throughput Network Tuning =====" > "$tmp_file"

  for setting in "${SYSCTL_SETTINGS[@]}"; do
    key="${setting%%=*}"
    value="${setting#*=}"

    if sysctl_supports_key "$key"; then
      printf '%s = %s\n' "$key" "$value" >> "$tmp_file"
    else
      log "跳过不支持参数: $key"
    fi
  done

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] 将写入以下内容:"
    cat "$tmp_file"
    return 0
  fi

  install -m 0644 "$tmp_file" "$CONF_FILE"
  rm -f "$tmp_file"
}

apply_config() {
  log
  log "[7/8] 应用配置"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] 将执行: sysctl --system"
    return 0
  fi

  if ! sysctl --system; then
    log "警告: sysctl --system 返回失败，继续单独应用本脚本配置"
    sysctl -p "$CONF_FILE"
  fi
}

verify_config() {
  local failed=0
  local key
  local value
  local setting
  local expected
  local actual

  log
  log "[8/8] 验证结果"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "[dry-run] 跳过运行时验证"
    return 0
  fi

  for setting in "${SYSCTL_SETTINGS[@]}"; do
    key="${setting%%=*}"
    value="${setting#*=}"

    if ! sysctl_supports_key "$key"; then
      continue
    fi

    expected="$(normalize_value "$value")"
    actual="$(normalize_value "$(sysctl -n "$key")")"

    if [[ "$actual" == "$expected" ]]; then
      log "OK: $key = $actual"
    else
      log "FAIL: $key 期望 '$expected'，实际 '$actual'"
      failed=1
    fi
  done

  sysctl net.ipv4.tcp_available_congestion_control
  lsmod | grep '^tcp_bbr' || true

  [[ "$failed" -eq 0 ]] || die "部分 sysctl 参数未达到期望值"
}

restore_latest_backup() {
  local latest_backup
  local backups=()
  local pre_restore_backup

  log "======================================"
  log " BBR + Provider Sysctl (恢复配置)"
  log "======================================"

  shopt -s nullglob
  backups=("${CONF_FILE}".bak.*)
  shopt -u nullglob

  [[ "${#backups[@]}" -gt 0 ]] || die "没有找到可恢复备份: ${CONF_FILE}.bak.*"
  latest_backup="$(printf '%s\n' "${backups[@]}" | sort | tail -n 1)"
  [[ -n "$latest_backup" ]] || die "没有找到可恢复备份: ${CONF_FILE}.bak.*"

  if [[ -f "$CONF_FILE" ]]; then
    pre_restore_backup="${CONF_FILE}.pre-restore${BACKUP_SUFFIX}"
    log "恢复前备份当前配置: $pre_restore_backup"
    cp -a "$CONF_FILE" "$pre_restore_backup"
  fi

  log "恢复备份: $latest_backup -> $CONF_FILE"
  run_cmd install -m 0644 "$latest_backup" "$CONF_FILE"

  sysctl -p "$CONF_FILE"

  log "恢复完成"
}

main() {
  parse_args "$@"
  require_root
  ensure_dependencies

  if [[ "$RESTORE" -eq 1 ]]; then
    restore_latest_backup
    return 0
  fi

  log "======================================"
  log " BBR + Provider Sysctl (高速去重版)"
  log "======================================"

  log "[1/8] 当前内核"
  uname -r

  ensure_bbr_available
  write_modules_load_config

  log
  log "[3/8] 检查拥塞控制支持"
  sysctl -n net.ipv4.tcp_available_congestion_control || true

  cleanup_duplicate_configs
  backup_current_config
  write_target_config
  apply_config
  verify_config

  log
  log "完成"
  log "配置文件: $CONF_FILE"
}

main "$@"
