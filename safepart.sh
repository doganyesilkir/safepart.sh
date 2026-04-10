#!/usr/bin/env bash
set -u
set -o pipefail

###############################################################################
# Disk Operations Tool
# v8.0.0
#
# Desteklenen işlemler:
# - Araç kontrolü
# - Gerekli araç kurulumu
# - Disk / partition / LVM / mount / fstab özetleri
# - Partition table yedeği alma / geri yükleme / reread
# - Yeni partition oluşturma
#   * Bağımsız partition + filesystem + mount + fstab
#   * LVM (PV + VG + LV + filesystem + mount + fstab)
# - Bağımsız son partition büyütme + filesystem grow
# - LVM tam zincir büyütme
#   * PV partition grow -> pvresize -> lvextend -> filesystem grow
# - Mount kaldırma
# - fstab kaydı silme
# - Mount kaldır + fstab temizleme
#
# Desteklenen filesystem:
# - ext4
# - xfs
#
# Bilinçli sınırlar:
# - Otomatik partition create/grow yalnızca diskin sonundaki boş alanla çalışır
# - LVM zincir büyütmede PV bir partition olmalıdır
# - RAID / mdadm / multipath / btrfs / zfs / karmaşık crypt topolojileri desteklenmez
###############################################################################

SCRIPT_NAME="$(basename "$0")"
VERSION="8.0.0"

DRY_RUN=0
ASSUME_YES=0

LOG_DIR="/var/log"
LOG_FILE="${LOG_DIR}/safepart.log"
BACKUP_DIR="/var/backups/disk-ops"
FSTAB_BACKUP_DIR="/var/backups/disk-ops/fstab"
LVM_BACKUP_DIR="/var/backups/disk-ops/lvm"

RET_MENU=10
REPLY_VALUE=""

# CLI automation vars
CLI_ACTION=""
CLI_DISK=""
CLI_TARGET=""
CLI_SIZE_GB=""
CLI_FS=""
CLI_MOUNTPOINT=""
CLI_STRUCTURE=""
CLI_VG_NAME=""
CLI_LV_NAME=""
CLI_BACKUP_FILE=""

VALIDATION_PLAN=()

###############################################################################
# CLI
###############################################################################

usage() {
  cat <<EOF
Kullanım:
  sudo ./${SCRIPT_NAME} [--dry-run] [--yes] [--help]
  sudo ./${SCRIPT_NAME} --action <action> [opsiyonlar]

Global parametreler:
  --dry-run
  --yes
  --help

Non-interactive action parametreleri:
  --action create|grow-part|grow-lvm|backup-pt|restore-pt|reread-pt|unmount|remove-fstab|unmount-clean|health-disk|health-part|selftest
  --disk /dev/sdX
  --target /dev/sdXN | /dev/mapper/vg-lv | /mountpoint
  --size-gb 100
  --fs ext4|xfs
  --mountpoint /data
  --structure normal|lvm
  --vg-name vg_data
  --lv-name lv_data
  --backup-file /var/backups/disk-ops/sda_20260101_120000.sfdisk

Örnek:
  sudo ./${SCRIPT_NAME} --action create --disk /dev/sdb --size-gb 100 --fs ext4 --mountpoint /data --structure normal --yes
  sudo ./${SCRIPT_NAME} --action grow-lvm --target /dev/mapper/ubuntu--vg-ubuntu--lv --size-gb 150 --yes
  sudo ./${SCRIPT_NAME} --action health-disk
  sudo ./${SCRIPT_NAME} --action health-part
  sudo ./${SCRIPT_NAME} --action selftest
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes) ASSUME_YES=1 ;;
    --help|-h)
      usage
      exit 0
      ;;
    --action) CLI_ACTION="${2:-}"; shift ;;
    --disk) CLI_DISK="${2:-}"; shift ;;
    --target) CLI_TARGET="${2:-}"; shift ;;
    --size-gb) CLI_SIZE_GB="${2:-}"; shift ;;
    --fs) CLI_FS="${2:-}"; shift ;;
    --mountpoint) CLI_MOUNTPOINT="${2:-}"; shift ;;
    --structure) CLI_STRUCTURE="${2:-}"; shift ;;
    --vg-name) CLI_VG_NAME="${2:-}"; shift ;;
    --lv-name) CLI_LV_NAME="${2:-}"; shift ;;
    --backup-file) CLI_BACKUP_FILE="${2:-}"; shift ;;
    *)
      echo "Bilinmeyen parametre: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

###############################################################################
# Colors / UI
###############################################################################

if [ -t 1 ]; then
  C_RESET="$(printf '\033[0m')"
  C_RED="$(printf '\033[31m')"
  C_GREEN="$(printf '\033[32m')"
  C_YELLOW="$(printf '\033[33m')"
  C_BLUE="$(printf '\033[34m')"
  C_MAGENTA="$(printf '\033[35m')"
  C_CYAN="$(printf '\033[36m')"
  C_BOLD="$(printf '\033[1m')"
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_MAGENTA=""
  C_CYAN=""
  C_BOLD=""
fi

divider() {
  printf '%s\n' "-------------------------------------------------------------------------------"
}

title() {
  echo
  echo "${C_BOLD}${C_MAGENTA}=== $* ===${C_RESET}"
}

subtitle() {
  echo "${C_BOLD}${C_CYAN}--- $* ---${C_RESET}"
}

###############################################################################
# Logging / audit
###############################################################################

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  local level="$1"
  shift
  local msg="$*"
  printf '%s [%s] %s\n' "$(timestamp)" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null || true
}

audit() {
  printf '%s [AUDIT] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

info() {
  echo "${C_BLUE}INFO${C_RESET}: $*"
  log INFO "$*"
}

ok() {
  echo "${C_GREEN}OK${C_RESET}: $*"
  log OK "$*"
}

warn() {
  echo "${C_YELLOW}UYARI${C_RESET}: $*"
  log WARN "$*"
}

fatal() {
  echo "${C_RED}HATA${C_RESET}: $*" >&2
  log ERROR "$*"
  exit 1
}

quit_now() {
  info "Çıkılıyor."
  exit 0
}

run_cmd() {
  local cmd_string
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] $*"
    log DRYRUN "$*"
    return 0
  fi

  cmd_string="$(printf '%q ' "$@")"
  cmd_string="${cmd_string% }"
  echo "[VERIFY] $cmd_string"
  log VERIFY "$cmd_string"

  if ! verify_command_step "$@"; then
    warn "Doğrulama adımı başarısız oldu: $cmd_string"
    return 1
  fi

  log CMD "$cmd_string"
  "$@"
}

require_root() {
  [ "$(id -u)" -eq 0 ] || fatal "Bu script root olarak çalıştırılmalı."
}

ensure_dirs() {
  mkdir -p "$BACKUP_DIR" 2>/dev/null || true
  mkdir -p "$FSTAB_BACKUP_DIR" 2>/dev/null || true
  mkdir -p "$LVM_BACKUP_DIR" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || fatal "Log dosyası oluşturulamadı: $LOG_FILE"
}

cmd_exists() {
  command -v "$1" >/dev/null 2>&1
}

validation_plan_reset() {
  VALIDATION_PLAN=()
}

validation_plan_add() {
  local status="$1"
  local step="$2"
  VALIDATION_PLAN+=("${status}|${step}")
}

validation_plan_print() {
  local entry status step marker
  [ "${#VALIDATION_PLAN[@]}" -gt 0 ] || return 0

  echo "  Adım planı:"
  for entry in "${VALIDATION_PLAN[@]}"; do
    status="${entry%%|*}"
    step="${entry#*|}"
    case "$status" in
      ok) marker="${C_GREEN}+${C_RESET}" ;;
      warn) marker="${C_YELLOW}!${C_RESET}" ;;
      fail) marker="${C_RED}-${C_RESET}" ;;
      *) marker="*" ;;
    esac
    echo "    $marker $step"
  done
  echo
}

verify_command_step() {
  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    mount)
      mount -f "$@" >/dev/null 2>&1
      ;;
    umount)
      mountpoint -q "${1:-}" 2>/dev/null
      ;;
    mkfs.ext4)
      mkfs.ext4 -n "$@" >/dev/null 2>&1
      ;;
    mkfs.xfs)
      mkfs.xfs "$@" -N >/dev/null 2>&1
      ;;
    xfs_growfs)
      xfs_growfs -n "$@" >/dev/null 2>&1
      ;;
    lvextend|lvcreate|vgcreate|pvcreate|pvresize)
      "$cmd" -t "$@" >/dev/null 2>&1
      ;;
    resize2fs)
      [ -b "${1:-}" ]
      ;;
    mkdir)
      return 0
      ;;
    partx)
      [ "${1:-}" = "-u" ] && [ -b "${2:-}" ]
      ;;
    apt-get|dnf|yum|zypper)
      return 0
      ;;
    *)
      return 0
      ;;
  esac
}

run_sfdisk_input() {
  local input="$1"
  shift
  local args=("$@")
  local cmd_string

  cmd_string="printf '%s\n' \"$input\" | sfdisk $(printf '%q ' "${args[@]}")"
  cmd_string="${cmd_string% }"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] $cmd_string"
    log DRYRUN "$cmd_string"
    return 0
  fi

  echo "[VERIFY] $cmd_string"
  log VERIFY "$cmd_string"
  printf '%s\n' "$input" | sfdisk --no-act "${args[@]}" >/dev/null 2>&1 || return 1

  log CMD "$cmd_string"
  printf '%s\n' "$input" | sfdisk "${args[@]}"
}

run_sfdisk_from_file() {
  local disk="$1"
  local backup_file="$2"
  local cmd_string

  cmd_string="sfdisk $(printf '%q ' "$disk") < $(printf '%q' "$backup_file")"
  cmd_string="${cmd_string% }"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] $cmd_string"
    log DRYRUN "$cmd_string"
    return 0
  fi

  echo "[VERIFY] sfdisk --no-act $(printf '%q ' "$disk")< $(printf '%q' "$backup_file")"
  log VERIFY "$cmd_string"
  sfdisk --no-act "$disk" < "$backup_file" >/dev/null 2>&1 || return 1

  log CMD "$cmd_string"
  sfdisk "$disk" < "$backup_file"
}

validate_partition_table_create_plan() {
  local disk="$1"
  local pttype="$2"

  validation_plan_reset
  validation_plan_add ok "label create plan prepared: $pttype on $disk"

  printf 'label: %s\n' "$pttype" | sfdisk --no-act "$disk" >/dev/null 2>&1 || {
    validation_plan_add fail "sfdisk --no-act label validation rejected"
    warn "Dry-run doğrulaması başarısız: partition table oluşturma planı sfdisk tarafından reddedildi."
    return 1
  }
  validation_plan_add ok "sfdisk --no-act label validation passed"

  verify_command_step partx -u "$disk" || {
    validation_plan_add fail "partx reread pre-check failed"
    warn "Dry-run doğrulaması başarısız: kernel reread ön-koşul kontrolü geçmedi."
    return 1
  }
  validation_plan_add ok "kernel reread pre-check passed"

  return 0
}

build_sfdisk_partition_spec() {
  local disk="$1"
  local size_bytes="$2"
  local type_code="$3"
  local sector_size size_sectors

  sector_size="$(blockdev --getss "$disk" 2>/dev/null)" || return 1
  size_sectors=$((size_bytes / sector_size))
  [ "$size_sectors" -gt 0 ] || return 1

  printf 'size=%s, type=%s\n' "$size_sectors" "$type_code"
}

validate_partition_create_plan() {
  local disk="$1"
  local size_bytes="$2"
  local usage="$3"
  local pttype type_code disk_free_bytes old_last predicted_part part_spec

  validation_plan_reset

  pttype="$(get_pttype "$disk")"
  [ -n "$pttype" ] || return 1

  get_partition_type_code "$pttype" "$usage" || return 1
  type_code="$REPLY_VALUE"

  get_disk_tail_free_bytes "$disk" || return 1
  disk_free_bytes="$REPLY_VALUE"
  [ "$disk_free_bytes" -gt 0 ] || return 1

  if [ "$size_bytes" -gt "$disk_free_bytes" ]; then
    size_bytes="$disk_free_bytes"
  fi

  old_last="$(get_last_partition_path_on_disk "$disk" || true)"
  part_spec="$(build_sfdisk_partition_spec "$disk" "$size_bytes" "$type_code")" || return 1

  printf '%s\n' "$part_spec" | sfdisk --no-act --append "$disk" >/dev/null 2>&1 || {
    validation_plan_add fail "partition append no-act rejected by sfdisk"
    warn "Dry-run doğrulaması başarısız: yeni partition create planı sfdisk tarafından reddedildi."
    return 1
  }
  validation_plan_add ok "partition append no-act accepted by sfdisk"

  verify_command_step partx -u "$disk" || {
    validation_plan_add fail "partx reread pre-check failed"
    warn "Dry-run doğrulaması başarısız: kernel reread ön-koşul kontrolü geçmedi."
    return 1
  }
  validation_plan_add ok "kernel reread pre-check passed"

  predicted_part="$(predict_next_partition_path "$disk" "$old_last")" || return 1
  validation_plan_add ok "predicted new partition path: $predicted_part"
  REPLY_VALUE="$predicted_part"
  return 0
}

validate_mount_persist_plan() {
  local dev="$1"
  local mountpoint="$2"
  local fstype="$3"
  local uuid options dump passno new_entry tmp_mountpoint real_mountpoint

  validation_plan_reset
  real_mountpoint="$mountpoint"

  uuid="$(get_uuid_of_device "$dev")"
  [ -n "$uuid" ] || {
    validation_plan_add fail "device UUID could not be read"
    warn "Dry-run doğrulaması başarısız: device UUID okunamadı."
    return 1
  }
  validation_plan_add ok "device UUID read successfully"

  case "$fstype" in
    ext4)
      options="defaults"; dump="0"; passno="2"
      ;;
    xfs)
      options="defaults"; dump="0"; passno="0"
      ;;
    *)
      return 1
      ;;
  esac

  if [ -d "$mountpoint" ] && mountpoint -q "$mountpoint" 2>/dev/null; then
    validation_plan_add fail "mountpoint already active: $mountpoint"
    warn "Dry-run doğrulaması başarısız: mountpoint zaten kullanımda: $mountpoint"
    return 1
  fi

  if [ ! -d "$mountpoint" ]; then
    echo "[VERIFY] mkdir -p $real_mountpoint"
    validation_plan_add ok "mountpoint will be created: $real_mountpoint"
    tmp_mountpoint="$(mktemp -d /tmp/safepart-mountcheck.XXXXXX)" || {
      validation_plan_add fail "temporary mountpoint check directory could not be created"
      warn "Dry-run doğrulaması başarısız: geçici mountpoint dizini oluşturulamadı."
      return 1
    }
    mountpoint="$tmp_mountpoint"
  fi

  verify_command_step mount "$dev" "$mountpoint" || {
    [ -n "${tmp_mountpoint:-}" ] && rmdir "$tmp_mountpoint" >/dev/null 2>&1 || true
    validation_plan_add fail "test mount pre-check failed"
    warn "Dry-run doğrulaması başarısız: test mount kontrolü başarısız oldu."
    return 1
  }
  [ -n "${tmp_mountpoint:-}" ] && rmdir "$tmp_mountpoint" >/dev/null 2>&1 || true
  validation_plan_add ok "test mount pre-check passed"

  new_entry="UUID=$uuid $real_mountpoint $fstype $options $dump $passno"
  verify_fstab_entry "$new_entry" || {
    validation_plan_add fail "fstab validation failed for planned entry"
    warn "Dry-run doğrulaması başarısız: fstab eklenecek satır doğrulanamadı."
    return 1
  }
  validation_plan_add ok "fstab validation passed for planned entry"

  return 0
}

validate_filesystem_create_plan() {
  local dev="$1"
  local fstype="$2"

  validation_plan_reset

  case "$fstype" in
    ext4)
      verify_command_step mkfs.ext4 -F "$dev" || {
        validation_plan_add fail "mkfs.ext4 dry-run validation failed"
        warn "Dry-run doğrulaması başarısız: mkfs.ext4 planı doğrulanamadı."
        return 1
      }
      validation_plan_add ok "mkfs.ext4 dry-run validation passed"
      ;;
    xfs)
      verify_command_step mkfs.xfs -f "$dev" || {
        validation_plan_add fail "mkfs.xfs dry-run validation failed"
        warn "Dry-run doğrulaması başarısız: mkfs.xfs planı doğrulanamadı."
        return 1
      }
      validation_plan_add ok "mkfs.xfs dry-run validation passed"
      ;;
    *)
      validation_plan_add fail "unsupported filesystem requested: $fstype"
      warn "Dry-run doğrulaması başarısız: desteklenmeyen filesystem tipi: $fstype"
      return 1
      ;;
  esac

  return 0
}

validate_lvm_create_plan() {
  local pv="$1"
  local vg_name="$2"
  local lv_name="$3"

  validation_plan_reset

  verify_command_step pvcreate "$pv" || {
    validation_plan_add fail "pvcreate test mode failed"
    warn "Dry-run doğrulaması başarısız: pvcreate test modu başarısız oldu."
    return 1
  }
  validation_plan_add ok "pvcreate test mode passed"
  verify_command_step vgcreate "$vg_name" "$pv" || {
    validation_plan_add fail "vgcreate test mode failed"
    warn "Dry-run doğrulaması başarısız: vgcreate test modu başarısız oldu."
    return 1
  }
  validation_plan_add ok "vgcreate test mode passed"
  verify_command_step lvcreate -l 100%FREE -n "$lv_name" "$vg_name" || {
    validation_plan_add fail "lvcreate test mode failed"
    warn "Dry-run doğrulaması başarısız: lvcreate test modu başarısız oldu."
    return 1
  }
  validation_plan_add ok "lvcreate test mode passed"
  return 0
}

validate_restore_partition_table_plan() {
  local disk="$1"
  local backup_file="$2"

  validation_plan_reset

  sfdisk --no-act "$disk" < "$backup_file" >/dev/null 2>&1 || {
    validation_plan_add fail "restore no-act rejected by sfdisk"
    warn "Dry-run doğrulaması başarısız: yedek geri yükleme planı sfdisk tarafından reddedildi."
    return 1
  }
  validation_plan_add ok "restore no-act accepted by sfdisk"

  verify_command_step partx -u "$disk" || {
    validation_plan_add fail "partx reread pre-check failed"
    warn "Dry-run doğrulaması başarısız: kernel reread ön-koşul kontrolü geçmedi."
    return 1
  }
  validation_plan_add ok "kernel reread pre-check passed"

  return 0
}

bytes_to_gb() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}

gb_to_bytes() {
  awk -v g="$1" 'BEGIN { printf "%.0f", g*1024*1024*1024 }'
}

bytes_to_human() {
  awk -v b="$1" '
    BEGIN {
      split("B KB MB GB TB PB", u, " ");
      i=1;
      while (b >= 1024 && i < 6) { b /= 1024; i++ }
      printf "%.2f %s", b, u[i]
    }'
}

structure_label() {
  case "${1:-}" in
    normal) printf '%s\n' "Bağımsız partition" ;;
    lvm) printf '%s\n' "LVM yapısı" ;;
    *) printf '%s\n' "${1:-bilinmiyor}" ;;
  esac
}

pause_enter() {
  echo
  read -r -p "Devam etmek için Enter'a basın..." _
}

show_input_help() {
  echo "Not: Ana menüye dönmek için 'm', çıkmak için 'q' yazabilirsiniz."
}

print_banner() {
  divider
  echo "${C_BOLD}${C_MAGENTA}Disk Operations Tool v${VERSION}${C_RESET}"
  divider
  echo "${C_CYAN}Host${C_RESET}       : $(hostname 2>/dev/null || echo unknown)"
  echo "${C_CYAN}Kernel${C_RESET}     : $(uname -r 2>/dev/null || echo unknown)"
  echo "${C_CYAN}Dry-run${C_RESET}    : $( [ "$DRY_RUN" -eq 1 ] && echo yes || echo no )"
  echo "${C_CYAN}Auto-yes${C_RESET}   : $( [ "$ASSUME_YES" -eq 1 ] && echo yes || echo no )"
  echo "${C_CYAN}Log file${C_RESET}   : $LOG_FILE"
  echo "${C_CYAN}Backup dir${C_RESET} : $BACKUP_DIR"
  echo
  show_input_help
  echo
}

###############################################################################
# Input helpers
###############################################################################

ask_nonempty() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt (m: ana menü, q: çıkış): " value
    case "$value" in
      q|Q) quit_now ;;
      m|M) return "$RET_MENU" ;;
      "")
        warn "Boş değer girildi. Lütfen geçerli bir değer girin."
        ;;
      *)
        REPLY_VALUE="$value"
        return 0
        ;;
    esac
  done
}

ask_numeric_gb() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt (m: ana menü, q: çıkış): " value
    case "$value" in
      q|Q) quit_now ;;
      m|M) return "$RET_MENU" ;;
      "")
        warn "Boş değer girildi. Lütfen GB cinsinden bir değer girin."
        ;;
      *)
        if echo "$value" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
          REPLY_VALUE="$value"
          return 0
        else
          warn "Hatalı değer girildi. Örnek geçerli değerler: 20, 120, 250.5"
        fi
        ;;
    esac
  done
}

ask_identifier() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt (m: ana menü, q: çıkış): " value
    case "$value" in
      q|Q) quit_now ;;
      m|M) return "$RET_MENU" ;;
      "")
        warn "Boş değer girildi. Lütfen geçerli bir isim girin."
        ;;
      *)
        if echo "$value" | grep -Eq '^[A-Za-z0-9._+-]+$'; then
          REPLY_VALUE="$value"
          return 0
        else
          warn "Hatalı isim. Yalnızca harf, rakam, nokta, alt çizgi, tire ve artı kullanılabilir."
        fi
        ;;
    esac
  done
}

ask_mountpoint() {
  local prompt="$1"
  local value
  while true; do
    read -r -p "$prompt (örn: /data, m: ana menü, q: çıkış): " value
    case "$value" in
      q|Q) quit_now ;;
      m|M) return "$RET_MENU" ;;
      "")
        warn "Boş değer girildi. Lütfen geçerli bir mountpoint girin."
        ;;
      *)
        if echo "$value" | grep -Eq '^/[A-Za-z0-9._/+:-]*$'; then
          REPLY_VALUE="$value"
          return 0
        else
          warn "Hatalı mountpoint. / ile başlamalı ve geçerli karakterler içermeli."
        fi
        ;;
    esac
  done
}

ask_menu_choice() {
  local prompt="$1"
  local min="$2"
  local max="$3"
  local value
  while true; do
    read -r -p "$prompt (q: çıkış): " value
    case "$value" in
      q|Q) quit_now ;;
      "")
        warn "Boş değer girildi. Lütfen ${min}-${max} arasında seçim yapın."
        ;;
      *)
        if echo "$value" | grep -Eq '^[0-9]+$'; then
          if [ "$value" -ge "$min" ] && [ "$value" -le "$max" ]; then
            REPLY_VALUE="$value"
            return 0
          else
            warn "Hatalı seçim. Lütfen ${min}-${max} arasında bir sayı girin."
          fi
        else
          warn "Hatalı değer girildi. Lütfen sayı girin."
        fi
        ;;
    esac
  done
}

confirm() {
  local prompt="$1"
  local ans

  if [ "$ASSUME_YES" -eq 1 ]; then
    echo "$prompt [y/n]: y"
    return 0
  fi

  while true; do
    read -r -p "$prompt [y/n] (m: ana menü, q: çıkış): " ans
    case "$ans" in
      q|Q) quit_now ;;
      m|M) return "$RET_MENU" ;;
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      "")
        warn "Boş değer girildi. Lütfen y, n, m veya q girin."
        ;;
      *)
        warn "Hatalı değer girildi. Lütfen y, n, m veya q girin."
        ;;
    esac
  done
}

critical_mount_extra_confirm() {
  local mountpoint="$1"
  case "$mountpoint" in
    /|/boot|/boot/efi|/var|/usr|/home|/opt)
      warn "Kritik mountpoint seçildi: $mountpoint"
      confirm "EKSTRA ONAY: $mountpoint üzerinde değişiklik yapılacak. Devam edilsin mi?"
      return $?
      ;;
    *)
      return 0
      ;;
  esac
}

###############################################################################
# Package manager / install
###############################################################################

detect_pkg_manager() {
  if cmd_exists apt-get; then
    REPLY_VALUE="apt"
    return 0
  elif cmd_exists dnf; then
    REPLY_VALUE="dnf"
    return 0
  elif cmd_exists yum; then
    REPLY_VALUE="yum"
    return 0
  elif cmd_exists zypper; then
    REPLY_VALUE="zypper"
    return 0
  fi
  return 1
}

get_required_packages() {
  local mgr="$1"
  case "$mgr" in
    apt)
      REPLY_VALUE="util-linux e2fsprogs xfsprogs lvm2 gawk grep sed coreutils procps mount psmisc smartmontools"
      ;;
    dnf|yum)
      REPLY_VALUE="util-linux e2fsprogs xfsprogs lvm2 gawk grep sed coreutils procps-ng psmisc lsof smartmontools"
      ;;
    zypper)
      REPLY_VALUE="util-linux e2fsprogs xfsprogs lvm2 gawk grep sed coreutils procps psmisc lsof smartmontools"
      ;;
    *)
      return 1
      ;;
  esac
  return 0
}

install_required_tools() {
  local skip_confirm="${1:-0}"
  local mgr pkgs rc

  title "Gerekli araçları kur"
  echo "Açıklama: Script için gereken paketleri dağıtıma uygun paket yöneticisi ile kurar."
  echo

  detect_pkg_manager || {
    warn "Desteklenen paket yöneticisi bulunamadı. apt/dnf/yum/zypper destekleniyor."
    return 1
  }
  mgr="$REPLY_VALUE"

  get_required_packages "$mgr" || {
    warn "Kurulacak paket listesi oluşturulamadı."
    return 1
  }
  pkgs="$REPLY_VALUE"

  echo "${C_CYAN}Paket yöneticisi${C_RESET} : $mgr"
  echo "${C_CYAN}Kurulacak paketler${C_RESET}:"
  echo "  $pkgs"
  echo

  if [ "$skip_confirm" -ne 1 ]; then
    confirm "Gerekli araçlar kurulsun mu?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && {
      warn "Kurulum iptal edildi."
      return 1
    }
  fi

  case "$mgr" in
    apt)
      run_cmd apt-get update || fatal "apt-get update başarısız oldu."
      run_cmd apt-get install -y $pkgs || fatal "Paket kurulumu başarısız oldu."
      ;;
    dnf)
      run_cmd dnf install -y $pkgs || fatal "Paket kurulumu başarısız oldu."
      ;;
    yum)
      run_cmd yum install -y $pkgs || fatal "Paket kurulumu başarısız oldu."
      ;;
    zypper)
      run_cmd zypper --non-interactive install $pkgs || fatal "Paket kurulumu başarısız oldu."
      ;;
  esac

  ok "Kurulum tamamlandı."
}

###############################################################################
# Tool checks
###############################################################################

CORE_TOOLS=(
  bash lsblk blockdev sfdisk partx findmnt df awk sed grep cat date hostname uname
  blkid mount umount mountpoint mkdir cp mktemp losetup truncate rm sync dd
)

FS_TOOLS=(
  resize2fs xfs_growfs mkfs.ext4 mkfs.xfs
)

LVM_TOOLS=(
  pvs vgs lvs lvdisplay lvextend lvcreate vgcreate pvdisplay pvresize pvcreate vgcfgbackup
)

OPTIONAL_TOOLS=(
  fuser lsof lslocks pgrep smartctl e2fsck xfs_repair
)

get_missing_critical_tools() {
  local missing_tools=()
  local t

  for t in "${CORE_TOOLS[@]}"; do
    cmd_exists "$t" || missing_tools+=("$t")
  done

  for t in "${FS_TOOLS[@]}"; do
    cmd_exists "$t" || missing_tools+=("$t")
  done

  for t in "${LVM_TOOLS[@]}"; do
    cmd_exists "$t" || missing_tools+=("$t")
  done

  if [ "${#missing_tools[@]}" -eq 0 ]; then
    REPLY_VALUE=""
    return 1
  fi

  REPLY_VALUE="${missing_tools[*]}"
  return 0
}

startup_tool_check() {
  local missing_tools rc

  if ! get_missing_critical_tools; then
    ok "Başlangıç araç kontrolü: tüm kritik araçlar mevcut."
    return 0
  fi
  missing_tools="$REPLY_VALUE"

  warn "Başlangıç araç kontrolünde eksik kritik araçlar bulundu."
  echo "Eksik araçlar: $missing_tools"
  echo

  confirm "Eksik kritik araçlar şimdi kurulsun mu?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && {
    warn "Araç kurulumu atlandı. Normal akışa devam ediliyor."
    return 0
  }
  [ "$rc" -ne 0 ] && {
    warn "Araç kurulumu kullanıcı tarafından atlandı. Normal akışa devam ediliyor."
    return 0
  }

  install_required_tools 1 || {
    warn "Araç kurulumu tamamlanamadı. Normal akışa devam ediliyor."
    return 0
  }

  ok "Eksik kritik araçların kurulumu tamamlandı."
  return 0
}

show_tool_check() {
  local missing=0
  local t

  title "Araç kontrolü"
  echo "Açıklama: Temel disk, filesystem ve LVM işlemleri için gereken araçları kontrol eder."
  echo

  subtitle "Temel araçlar"
  for t in "${CORE_TOOLS[@]}"; do
    if cmd_exists "$t"; then
      echo "  ${C_GREEN}+${C_RESET} $t"
    else
      echo "  ${C_RED}-${C_RESET} $t"
      missing=1
    fi
  done

  echo
  subtitle "Filesystem araçları"
  for t in "${FS_TOOLS[@]}"; do
    if cmd_exists "$t"; then
      echo "  ${C_GREEN}+${C_RESET} $t"
    else
      echo "  ${C_RED}-${C_RESET} $t"
      missing=1
    fi
  done

  echo
  subtitle "LVM araçları"
  for t in "${LVM_TOOLS[@]}"; do
    if cmd_exists "$t"; then
      echo "  ${C_GREEN}+${C_RESET} $t"
    else
      echo "  ${C_RED}-${C_RESET} $t"
      missing=1
    fi
  done

  echo
  subtitle "Opsiyonel ama faydalı araçlar"
  for t in "${OPTIONAL_TOOLS[@]}"; do
    if cmd_exists "$t"; then
      echo "  ${C_GREEN}+${C_RESET} $t"
    else
      echo "  ${C_YELLOW}-${C_RESET} $t"
    fi
  done

  echo
  if [ "$missing" -ne 0 ]; then
    warn "Eksik kritik araçlar var. İstersen menüden kurulum sekmesini kullanabilirsin."
    return 1
  fi

  ok "Tüm kritik araçlar mevcut."
  return 0
}

###############################################################################
# Startup health check
###############################################################################

check_fsck_processes() {
  cmd_exists pgrep || return 1
  pgrep -af 'fsck|e2fsck|xfs_repair|xfs_check' 2>/dev/null | sed -n '1,10p'
}

check_fsck_lock_files() {
  local dir

  cmd_exists find || return 1

  for dir in /run/fsck /var/run/fsck; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 1 -type f \( -name '*.lock' -o -name '*.pid' \) -print 2>/dev/null
  done | sed -n '1,10p'
}

check_sensitive_file_locks() {
  cmd_exists lslocks || return 1
  lslocks -n -o PID,COMMAND,PATH 2>/dev/null | awk '
    $3 ~ /^\/dev\// || $3 ~ /^\/run\/fsck\// || $3 ~ /^\/var\/run\/fsck\// || $3 == "/etc/fstab" { print }
  ' | sed -n '1,10p'
}

get_meminfo_kb() {
  local key="$1"
  awk -v target="${key}:" '$1 == target { print $2; exit }' /proc/meminfo 2>/dev/null
}

get_vmstat_value() {
  local key="$1"
  awk -v target="$key" '$1 == target { print $2; exit }' /proc/vmstat 2>/dev/null
}

check_dirty_cache_state() {
  local dirty_kb writeback_kb dirty_pages writeback_pages

  dirty_kb="$(get_meminfo_kb Dirty)"
  writeback_kb="$(get_meminfo_kb Writeback)"
  dirty_pages="$(get_vmstat_value nr_dirty)"
  writeback_pages="$(get_vmstat_value nr_writeback)"

  [ -n "$dirty_kb" ] || dirty_kb=0
  [ -n "$writeback_kb" ] || writeback_kb=0
  [ -n "$dirty_pages" ] || dirty_pages=0
  [ -n "$writeback_pages" ] || writeback_pages=0

  if [ "$dirty_kb" -gt 0 ] || [ "$writeback_kb" -gt 0 ] || [ "$dirty_pages" -gt 0 ] || [ "$writeback_pages" -gt 0 ]; then
    printf 'Dirty=%s KB | Writeback=%s KB | nr_dirty=%s | nr_writeback=%s\n' \
      "$dirty_kb" "$writeback_kb" "$dirty_pages" "$writeback_pages"
    return 0
  fi

  return 1
}

startup_health_check() {
  local issues=0
  local out

  title "Başlangıç Kontrolleri"
  echo "Açıklama: İşleme başlamadan önce filesystem tarafında sorun çıkarabilecek temel durumlar kontrol edilir."
  echo

  if mount -a -fn >/dev/null 2>&1; then
    echo "  ${C_GREEN}+${C_RESET} /etc/fstab doğrulaması başarılı"
  else
    echo "  ${C_YELLOW}!${C_RESET} /etc/fstab doğrulaması başarısız"
    warn "mount -a -fn doğrulaması başarısız. Hatalı bir fstab kaydı olabilir."
    issues=$((issues + 1))
  fi

  out="$(check_fsck_processes || true)"
  if [ -n "$out" ]; then
    echo "  ${C_YELLOW}!${C_RESET} Aktif fsck/repair süreci bulundu"
    warn "Aşağıdaki fsck/recovery süreçleri şu anda çalışıyor:"
    echo "$out" | sed 's/^/    /'
    issues=$((issues + 1))
  else
    echo "  ${C_GREEN}+${C_RESET} Aktif fsck/recovery süreci görünmüyor"
  fi

  out="$(check_fsck_lock_files || true)"
  if [ -n "$out" ]; then
    echo "  ${C_YELLOW}!${C_RESET} fsck lock/pid dosyası bulundu"
    warn "Aşağıdaki fsck lock/pid dosyaları tespit edildi:"
    echo "$out" | sed 's/^/    /'
    issues=$((issues + 1))
  else
    echo "  ${C_GREEN}+${C_RESET} fsck lock/pid dosyası görünmüyor"
  fi

  out="$(check_sensitive_file_locks || true)"
  if [ -n "$out" ]; then
    echo "  ${C_YELLOW}!${C_RESET} Kritik path üzerinde aktif lock tespit edildi"
    warn "Aşağıdaki lock kayıtları disk işlemlerini etkileyebilir:"
    echo "$out" | sed 's/^/    /'
    issues=$((issues + 1))
  else
    echo "  ${C_GREEN}+${C_RESET} Kritik path üzerinde dikkat çeken lock görünmüyor"
  fi

  out="$(check_dirty_cache_state || true)"
  if [ -n "$out" ]; then
    echo "  ${C_YELLOW}!${C_RESET} Henüz filesystem'e yazılmamış cache/writeback verisi var"
    warn "Kernel write cache içinde henüz diske flush edilmemiş veri görünüyor:"
    echo "$out" | sed 's/^/    /'
    issues=$((issues + 1))
  else
    echo "  ${C_GREEN}+${C_RESET} Dirty/writeback cache sinyali görünmüyor"
  fi

  echo
  if [ "$issues" -gt 0 ]; then
    warn "Başlangıç kontrolünde ${issues} adet uyarı bulundu. Devam etmeden önce bu durumları gözden geçirmen önerilir."
  else
    ok "Başlangıç kontrolünde işlem engelleyebilecek bir sorun görünmedi."
  fi
  echo
}

###############################################################################
# Listing
###############################################################################

list_disks_and_partitions() {
  title "Disk ve partition listesi"
  echo "Açıklama: Sistemde görülen diskleri, partitionları, filesystem tiplerini ve mount noktalarını gösterir."
  echo
  lsblk -o PATH,SIZE,TYPE,FSTYPE,FSAVAIL,FSUSE%,MOUNTPOINT
  echo
}



show_disk_usage() {
  title "Filesystem kullanım özeti"
  echo "Açıklama: Mount edilmiş filesystem'lerin boyut, doluluk ve mount bilgilerini gösterir."
  echo
  df -hT
  echo
}

show_block_details() {
  title "Detaylı block device özeti"
  echo "Açıklama: Disk topolojisini parent-child ilişkileriyle gösterir."
  echo
  lsblk -e7 -o NAME,KNAME,PATH,PKNAME,TYPE,SIZE,FSTYPE,MOUNTPOINT,MODEL
  echo
}

show_mount_table() {
  title "Mevcut mount ve fstab özeti"
  echo "Açıklama: Sistemde mount edilmiş filesystem'leri ve /etc/fstab kayıtlarını gösterir."
  echo
  subtitle "Mount edilmiş filesystem'ler"
  findmnt -rno TARGET,SOURCE,FSTYPE,OPTIONS
  echo
  subtitle "/etc/fstab"
  sed -n '1,200p' /etc/fstab
  echo
}

show_disk_health() {
  local path size model disk_name ro rota state device_state health_output attr_output
  local ok_count=0 warn_count=0 fail_count=0

  title "Disk sağlık özeti"
  echo "Açıklama: Disklerin temel sağlık bilgisini gösterir. 'smartctl' varsa SMART verisi de özetlenir."
  echo

  while IFS='|' read -r path size model; do
    [ -n "$path" ] || continue
    state="ok"
    disk_name="$(basename "$path")"
    ro="$(cat "/sys/block/${disk_name}/ro" 2>/dev/null || echo "?")"
    rota="$(cat "/sys/block/${disk_name}/queue/rotational" 2>/dev/null || echo "?")"
    device_state="$(cat "/sys/block/${disk_name}/device/state" 2>/dev/null || echo "unknown")"

    subtitle "$path"
    echo "  Boyut        : ${size:--}"
    echo "  Model        : ${model:--}"
    echo "  Read-only    : $( [ "$ro" = "1" ] && echo yes || echo no )"
    echo "  Medya tipi   : $( [ "$rota" = "1" ] && echo rotational || echo solid-state )"
    echo "  Device state : $device_state"

    if cmd_exists smartctl; then
      echo
      echo "  SMART sağlık özeti:"
      health_output="$(smartctl -H "$path" 2>/dev/null || true)"
      echo "$health_output" | sed -n '1,12p' | sed 's/^/    /'
      if echo "$health_output" | grep -Eq 'PASSED|OK'; then
        state="ok"
      elif echo "$health_output" | grep -Eiq 'unsupported|unavailable|unknown usb bridge|permission denied|device lacks SMART'; then
        state="warning"
      else
        state="fail"
      fi
      echo
      echo "  Kritik SMART satırları:"
      attr_output="$(smartctl -A "$path" 2>/dev/null | awk '
        /Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable|Media_Wearout_Indicator|Percentage Used|Critical Warning|Available Spare|Temperature_Celsius/ { print }
      ')"
      echo "$attr_output" | sed -n '1,12p' | sed 's/^/    /'
      if echo "$attr_output" | awk '
        /Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable/ && $NF ~ /^[1-9][0-9]*$/ { found=1 }
        END { exit(found ? 0 : 1) }'
      then
        [ "$state" = "ok" ] && state="warning"
      fi
    else
      echo "  SMART        : smartctl bulunamadı. Ayrıntılı sağlık için smartmontools kurulmalı."
      state="warning"
    fi
    echo "  Durum        : $state"
    echo

    case "$state" in
      ok) ok_count=$((ok_count + 1)) ;;
      warning) warn_count=$((warn_count + 1)) ;;
      fail) fail_count=$((fail_count + 1)) ;;
    esac
  done < <(get_disk_list)

  subtitle "Özet"
  echo "  OK      : $ok_count"
  echo "  Warning : $warn_count"
  echo "  Fail    : $fail_count"
  echo
}

show_partition_health() {
  local path size fstype mnt opts state fsck_rc kernel_lines
  local ok_count=0 warn_count=0 fail_count=0

  title "Partition sağlık özeti"
  echo "Açıklama: Partition bazında filesystem durumu, mount bilgisi ve read-only sağlık kontrollerini gösterir."
  echo

  while IFS='|' read -r path size fstype mnt; do
    [ -n "$path" ] || continue
    opts="$(findmnt -rno OPTIONS -S "$path" 2>/dev/null | head -n1)"
    state="ok"

    subtitle "$path"
    echo "  Boyut        : ${size:--}"
    echo "  Filesystem   : ${fstype:--}"
    echo "  Mountpoint   : ${mnt:--}"
    echo "  Mount opts   : ${opts:--}"

    if echo "${opts:-}" | grep -qw ro; then
      warn "Partition read-only mount edilmiş görünüyor."
      state="warning"
    fi

    if [ -n "$mnt" ]; then
      echo "  Kullanım     :"
      df -hT "$mnt" 2>/dev/null | sed -n '1,2p' | sed 's/^/    /'
      echo "  Inode durumu :"
      df -i "$mnt" 2>/dev/null | sed -n '1,2p' | sed 's/^/    /'
    fi

    case "$fstype" in
      ext4)
        if cmd_exists e2fsck; then
          if [ -n "$mnt" ]; then
            echo "  Fsck dry-run : Atlandi (mount edilmis ext4 icin offline e2fsck kontrolu uygulanmiyor)"
          else
            echo "  Fsck dry-run : e2fsck -n"
            e2fsck -n "$path" 2>/dev/null | sed -n '1,12p' | sed 's/^/    /'
            fsck_rc=${PIPESTATUS[0]}
            if [ "$fsck_rc" -gt 1 ]; then
              state="fail"
            elif [ "$fsck_rc" -ne 0 ]; then
              state="warning"
            fi
          fi
        else
          echo "  Fsck dry-run : e2fsck bulunamadı"
          state="warning"
        fi
        ;;
      xfs)
        if cmd_exists xfs_repair; then
          if [ -n "$mnt" ]; then
            echo "  Fsck dry-run : Atlandi (mount edilmis XFS icin offline xfs_repair kontrolu uygulanmiyor)"
          else
            echo "  Fsck dry-run : xfs_repair -n"
            xfs_repair -n "$path" 2>/dev/null | sed -n '1,12p' | sed 's/^/    /'
            fsck_rc=${PIPESTATUS[0]}
            if [ "$fsck_rc" -ne 0 ]; then
              state="fail"
            fi
          fi
        else
          echo "  Fsck dry-run : xfs_repair bulunamadı"
          state="warning"
        fi
        ;;
      "")
        warn "Filesystem tipi okunamadı."
        state="warning"
        ;;
      *)
        echo "  Fsck dry-run : Bu filesystem için özel kontrol tanımlı değil"
        ;;
    esac

    if cmd_exists dmesg; then
      echo "  Kernel sinyali:"
      kernel_lines="$(dmesg 2>/dev/null | grep -i "$path" | grep -Ei 'error|warn|fail|i/o|filesystem' | tail -n 5 || true)"
      if [ -n "$kernel_lines" ]; then
        echo "$kernel_lines" | sed 's/^/    /'
        [ "$state" = "ok" ] && state="warning"
      else
        echo "    (son hata sinyali bulunamadı)"
      fi
    fi

    echo "  Durum        : $state"
    echo

    case "$state" in
      ok) ok_count=$((ok_count + 1)) ;;
      warning) warn_count=$((warn_count + 1)) ;;
      fail) fail_count=$((fail_count + 1)) ;;
    esac
  done < <(get_partition_list)

  subtitle "Özet"
  echo "  OK      : $ok_count"
  echo "  Warning : $warn_count"
  echo "  Fail    : $fail_count"
  echo
}

run_loopback_test_lab() {
  local workdir image loopdev target_dev mount_dir
  local sfdisk_err lab_part_spec
  cleanup_loopback_lab() {
    mountpoint -q "$mount_dir" 2>/dev/null && umount "$mount_dir" >/dev/null 2>&1 || true
    [ -n "$loopdev" ] && losetup -d "$loopdev" >/dev/null 2>&1 || true
    [ -n "${old_exit_trap:-}" ] && trap -- "$old_exit_trap" EXIT || trap - EXIT
    rm -rf "$workdir" >/dev/null 2>&1 || true
  }

  local old_exit_trap
  old_exit_trap="$(trap -p EXIT | sed -n "s/^trap -- '\\(.*\\)' EXIT$/\1/p")"

  title "Güvenli loopback test laboratuvarı"
  echo "Açıklama: Gerçek diskleri etkilemeden geçici bir loop device üzerinde create/grow akışlarını test eder."
  echo

  local selftest_tools=(losetup sfdisk mkfs.ext4 mount umount mountpoint dd)
  local missing_tools=() tool
  for tool in "${selftest_tools[@]}"; do
    cmd_exists "$tool" || missing_tools+=("$tool")
  done
  if [ "${#missing_tools[@]}" -gt 0 ]; then
    fatal "Loopback lab için eksik araçlar var: ${missing_tools[*]}"
  fi

  workdir="$(mktemp -d /tmp/safepart-lab.XXXXXX)" || fatal "Geçici test dizini oluşturulamadı."
  image="${workdir}/lab.img"
  mount_dir="${workdir}/mnt"
  loopdev=""
  target_dev=""
  trap cleanup_loopback_lab EXIT

  validation_plan_reset
  validation_plan_add ok "temporary lab directory created: $workdir"

  if ! truncate -s 512M "$image"; then
    cleanup_loopback_lab
    fatal "Loopback test dosyası oluşturulamadı."
  fi
  validation_plan_add ok "sparse image created: $image"

  loopdev="$(losetup --find --show "$image" 2>/dev/null)" || {
    cleanup_loopback_lab
    fatal "Loop device atanamadı."
  }
  validation_plan_add ok "loop device attached: $loopdev"

  lab_part_spec="$(build_sfdisk_partition_spec "$loopdev" $((128 * 1024 * 1024)) 8300)" || {
    cleanup_loopback_lab
    fatal "Loopback test partition spec oluşturulamadı."
  }

  if sfdisk_err="$(printf 'label: gpt\n%s\n' "$lab_part_spec" | sfdisk --no-act "$loopdev" 2>&1 >/dev/null)"; then
    validation_plan_add ok "partition table create syntax validated on loop device"
  else
    sfdisk_err="$(printf '%s\n' "$sfdisk_err" | sed -n '1,3p' | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g; s/[[:space:]]$//')"
    validation_plan_add warn "partition table validation skipped details: ${sfdisk_err:-unknown sfdisk issue}"
  fi

  target_dev="$loopdev"
  validation_plan_add warn "portability mode active: filesystem test runs on raw loop device"

  if ! mkfs.ext4 -F "$target_dev" >/dev/null 2>&1; then
    cleanup_loopback_lab
    fatal "Loop device üzerinde ext4 oluşturulamadı."
  fi
  validation_plan_add ok "ext4 filesystem created on loop device"

  if ! mkdir -p "$mount_dir"; then
    cleanup_loopback_lab
    fatal "Test mountpoint oluşturulamadı."
  fi
  if ! mount "$target_dev" "$mount_dir"; then
    cleanup_loopback_lab
    fatal "Loop device mount edilemedi."
  fi
  validation_plan_add ok "loop device mounted: $mount_dir"

  if ! dd if=/dev/zero of="${mount_dir}/probe.bin" bs=1M count=8 status=none; then
    cleanup_loopback_lab
    fatal "Test yazımı başarısız oldu."
  fi
  sync
  validation_plan_add ok "basic write/read path completed"

  validation_plan_print
  ok "Loopback test laboratuvarı başarılı tamamlandı."
  cleanup_loopback_lab
}

get_partition_list() {
  lsblk -rno PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT | awk '$3=="part" {print $1 "|" $2 "|" $4 "|" $5}'
}

get_disk_list() {
  lsblk -d -rno PATH,SIZE,MODEL | awk '{
    path=$1; size=$2; $1=""; $2="";
    sub(/^  */, "", $0);
    print path "|" size "|" $0
  }'
}

get_lvm_lv_list() {
  lsblk -rno PATH,SIZE,TYPE,FSTYPE,MOUNTPOINT | awk '$3=="lvm" {print $1 "|" $2 "|" $4 "|" $5}'
}

get_vg_pv_list() {
  local vg="$1"
  pvs --noheadings --separator '|' -o pv_name,vg_name,pv_size,pv_free 2>/dev/null |
  awk -F'|' -v target_vg="$vg" '
    {
      for (i=1; i<=NF; i++) gsub(/^[ \t]+|[ \t]+$/, "", $i)
      if ($2 == target_vg) print $1 "|" $3 "|" $4
    }'
}

get_lv_vg_name() {
  lvs --noheadings -o vg_name "$1" 2>/dev/null | awk '{$1=$1;print}'
}

get_lv_name() {
  lvs --noheadings -o lv_name "$1" 2>/dev/null | awk '{$1=$1;print}'
}

get_vg_free_bytes() {
  vgs --noheadings --units B --nosuffix -o vg_free "$1" 2>/dev/null | awk '{$1=$1; printf "%.0f", $1}'
}

get_lv_size_bytes() {
  lvs --noheadings --units B --nosuffix -o lv_size "$1" 2>/dev/null | awk '{$1=$1; printf "%.0f", $1}'
}

get_pv_size_bytes() {
  pvs --noheadings --units B --nosuffix -o pv_size "$1" 2>/dev/null | awk '{$1=$1; printf "%.0f", $1}'
}

get_pv_free_bytes() {
  pvs --noheadings --units B --nosuffix -o pv_free "$1" 2>/dev/null | awk '{$1=$1; printf "%.0f", $1}'
}

list_only_partitions_with_sizes() {
  title "Seçilebilir partitionlar"
  echo "Açıklama: Bağımsız partition işlemleri için kullanılabilecek partitionları gösterir."
  echo
  local i=1
  while IFS='|' read -r path size fstype mnt; do
    [ -n "$path" ] || continue
    printf "  ${C_CYAN}%2d)${C_RESET} %-22s %-10s %-8s %s\n" "$i" "$path" "$size" "${fstype:--}" "${mnt:--}"
    i=$((i + 1))
  done < <(get_partition_list)
  echo
}

list_only_disks_with_sizes() {
  title "Seçilebilir diskler"
  echo "Açıklama: Disk bazlı işlemler için kullanılabilecek diskleri gösterir."
  echo
  local i=1
  while IFS='|' read -r path size model; do
    [ -n "$path" ] || continue
    printf "  ${C_CYAN}%2d)${C_RESET} %-16s %-10s %s\n" "$i" "$path" "$size" "${model:--}"
    i=$((i + 1))
  done < <(get_disk_list)
  echo
}

list_lvm_lvs() {
  title "Seçilebilir LVM logical volume'lar"
  echo "Açıklama: LVM büyütme işlemleri için kullanılabilecek LV'leri gösterir."
  echo
  local i=1
  while IFS='|' read -r path size fstype mnt; do
    [ -n "$path" ] || continue
    printf "  ${C_CYAN}%2d)${C_RESET} %-30s %-10s %-8s %s\n" "$i" "$path" "$size" "${fstype:--}" "${mnt:--}"
    i=$((i + 1))
  done < <(get_lvm_lv_list)
  echo
}

list_vg_pvs() {
  local vg="$1"
  title "VG içindeki Physical Volume'lar"
  echo "Açıklama: Seçilen VG'ye bağlı PV'leri ve boş alanlarını gösterir."
  echo "VG: $vg"
  echo
  local i=1
  while IFS='|' read -r pv size free; do
    [ -n "$pv" ] || continue
    printf "  ${C_CYAN}%2d)${C_RESET} %-22s %-12s free=%s\n" "$i" "$pv" "${size:--}" "${free:--}"
    i=$((i + 1))
  done < <(get_vg_pv_list "$vg")
  echo
}

get_mounted_targets_list() {
  findmnt -rno TARGET,SOURCE,FSTYPE | awk '{print $1 "|" $2 "|" $3}'
}

list_mounted_targets() {
  title "Unmount edilebilir mountpoint'ler"
  echo "Açıklama: Şu anda mount edilmiş hedefleri gösterir."
  echo
  local i=1
  while IFS='|' read -r target source fstype; do
    [ -n "$target" ] || continue
    printf "  ${C_CYAN}%2d)${C_RESET} %-25s %-30s %s\n" "$i" "$target" "$source" "$fstype"
    i=$((i + 1))
  done < <(get_mounted_targets_list)
  echo
}

get_fstab_entries_list() {
  awk '
    $0 !~ /^[[:space:]]*#/ && NF >= 4 {
      print $1 "|" $2 "|" $3 "|" $4
    }' /etc/fstab
}

list_fstab_entries() {
  title "/etc/fstab içindeki kayıtlar"
  echo "Açıklama: Yorum satırı olmayan fstab kayıtlarını gösterir."
  echo
  local i=1
  while IFS='|' read -r spec mountpoint fstype opts; do
    [ -n "$spec" ] || continue
    printf "  ${C_CYAN}%2d)${C_RESET} %-26s %-22s %-8s %s\n" "$i" "$spec" "$mountpoint" "$fstype" "$opts"
    i=$((i + 1))
  done < <(get_fstab_entries_list)
  echo
}

###############################################################################
# Device / topology info
###############################################################################

get_parent_disk() {
  local part="$1"
  local parent
  parent="$(lsblk -no PKNAME "$part" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  [ -n "$parent" ] || return 1
  echo "/dev/$parent"
}

get_partnum() {
  lsblk -no PARTN "$1" 2>/dev/null | head -n1 | awk '{$1=$1;print}'
}

get_fstype() {
  lsblk -no FSTYPE "$1" 2>/dev/null | head -n1 | awk '{$1=$1;print}'
}

get_mountpoint() {
  lsblk -no MOUNTPOINT "$1" 2>/dev/null | head -n1 | awk '{$1=$1;print}'
}

get_pttype() {
  lsblk -no PTTYPE "$1" 2>/dev/null | head -n1 | awk '{$1=$1;print}'
}

get_disk_basename() {
  basename "$1"
}

get_sfdisk_line() {
  local disk="$1"
  local part="$2"
  sfdisk -d "$disk" 2>/dev/null | awk -v p="$part" '$1==p {print}'
}

get_start_sector_from_line() {
  echo "$1" | sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

get_size_sector_from_line() {
  echo "$1" | sed -n 's/.*size=[[:space:]]*\([0-9][0-9]*\).*/\1/p'
}

get_last_partition_path_on_disk() {
  local disk="$1"
  local disk_base
  disk_base="$(get_disk_basename "$disk")"

  lsblk -rno PATH,PKNAME,PARTN,TYPE 2>/dev/null | awk -v d="$disk_base" '
    $2 == d && $4 == "part" {
      if ($3 > maxn) { maxn = $3; path = $1 }
    }
    END {
      if (path != "") print path
    }'
}

predict_next_partition_path() {
  local disk="$1"
  local last_part="$2"
  local next_num

  if [ -n "$last_part" ]; then
    next_num="$(get_partnum "$last_part")"
    [ -n "$next_num" ] || return 1
    next_num=$((next_num + 1))
  else
    next_num=1
  fi

  case "$disk" in
    *[0-9]) printf '%sp%s\n' "$disk" "$next_num" ;;
    *)      printf '%s%s\n' "$disk" "$next_num" ;;
  esac
}

get_disk_tail_free_bytes() {
  local disk="$1"
  local disk_bytes sector_size max_end end start size line

  disk_bytes="$(blockdev --getsize64 "$disk" 2>/dev/null)" || return 1
  sector_size="$(blockdev --getss "$disk" 2>/dev/null)" || return 1

  max_end=0
  while IFS= read -r line; do
    case "$line" in
      /dev/*)
        start="$(get_start_sector_from_line "$line")"
        size="$(get_size_sector_from_line "$line")"
        [ -n "$start" ] || continue
        [ -n "$size" ] || continue
        end=$((start + size))
        [ "$end" -gt "$max_end" ] && max_end="$end"
        ;;
    esac
  done < <(sfdisk -d "$disk" 2>/dev/null)

  REPLY_VALUE="$((disk_bytes - (max_end * sector_size)))"
  [ "$REPLY_VALUE" -lt 0 ] && REPLY_VALUE=0
  return 0
}

is_last_partition_on_disk() {
  local disk="$1"
  local part="$2"
  local max_end=0
  local sel_end=0

  while IFS= read -r line; do
    case "$line" in
      /dev/*)
        local p start size end
        p="$(echo "$line" | awk '{print $1}')"
        start="$(get_start_sector_from_line "$line")"
        size="$(get_size_sector_from_line "$line")"
        [ -n "$start" ] || continue
        [ -n "$size" ] || continue
        end=$((start + size))
        [ "$end" -gt "$max_end" ] && max_end="$end"
        [ "$p" = "$part" ] && sel_end="$end"
        ;;
    esac
  done < <(sfdisk -d "$disk" 2>/dev/null)

  [ "$sel_end" -eq "$max_end" ] && [ "$sel_end" -ne 0 ]
}

detect_unsupported_topology() {
  local dev="$1"
  local out=""
  local t fstype

  t="$(lsblk -no TYPE "$dev" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  fstype="$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"

  case "$t" in
    raid*|md|crypt|mpath)
      out="type=$t"
      ;;
  esac

  case "$fstype" in
    btrfs|zfs_member)
      out="${out} fstype=$fstype"
      ;;
  esac

  if [ -n "$out" ]; then
    REPLY_VALUE="$out"
    return 0
  fi

  return 1
}

preflight_report() {
  local action="$1"
  local target="${2:-}"
  local disk="${3:-}"
  local fs="${4:-}"
  local mountpoint="${5:-}"

  title "Pre-check / Risk Raporu"
  echo "Açıklama: İşlem başlamadan önce temel riskler ve uygulanacak adımlar özetlenir."
  echo

  echo "  Action      : $action"
  [ -n "$target" ] && echo "  Target      : $target"
  [ -n "$disk" ] && echo "  Disk        : $disk"
  [ -n "$fs" ] && echo "  Filesystem  : $fs"
  [ -n "$mountpoint" ] && echo "  Mountpoint  : $mountpoint"
  echo

  case "$action" in
    create-normal)
      echo "  Adımlar:"
      echo "    1) Partition table backup"
      echo "    2) Yeni partition create"
      echo "    3) Filesystem oluşturma"
      echo "    4) Mountpoint oluşturma"
      echo "    5) test mount + gerçek mount"
      echo "    6) fstab backup + entry append"
      ;;
    create-lvm)
      echo "  Adımlar:"
      echo "    1) Partition table backup"
      echo "    2) Yeni partition create"
      echo "    3) pvcreate"
      echo "    4) vgcreate"
      echo "    5) lvcreate"
      echo "    6) Filesystem oluşturma"
      echo "    7) Mountpoint oluşturma"
      echo "    8) test mount + gerçek mount"
      echo "    9) fstab backup + entry append"
      ;;
    grow-part)
      echo "  Adımlar:"
      echo "    1) Partition table backup"
      echo "    2) Son partition grow"
      echo "    3) Kernel reread denemesi"
      echo "    4) Filesystem grow"
      ;;
    grow-lvm)
      echo "  Adımlar:"
      echo "    1) Gerekirse partition table backup"
      echo "    2) Gerekirse PV partition grow"
      echo "    3) vgcfgbackup"
      echo "    4) pvresize"
      echo "    5) lvextend"
      echo "    6) Filesystem grow"
      ;;
    restore-pt)
      echo "  Risk:"
      echo "    - Partition table restore tam rollback değildir."
      echo "    - Filesystem ve LVM metadata otomatik eski haline dönmez."
      echo "    - Reboot gerekebilir."
      ;;
    unmount)
      echo "  Risk:"
      echo "    - Aktif süreçler mountpoint'i kullanıyor olabilir."
      ;;
  esac

  if [ -n "$mountpoint" ]; then
    case "$mountpoint" in
      /|/boot|/boot/efi|/var|/usr|/home|/opt)
        warn "Kritik mountpoint tespit edildi: $mountpoint"
        ;;
    esac
  fi

  if [ -n "$target" ] && detect_unsupported_topology "$target"; then
    warn "Desteklenmeyen veya riskli topoloji tespit edildi: $REPLY_VALUE"
  fi

  if [ -n "$disk" ] && detect_unsupported_topology "$disk"; then
    warn "Disk üzerinde riskli topoloji sinyali: $REPLY_VALUE"
  fi

  echo
}

###############################################################################
# Filesystem ops
###############################################################################

grow_filesystem() {
  local dev="$1"
  local fstype="$2"
  local mnt="$3"

  case "$fstype" in
    ext4)
      info "Filesystem büyütülüyor: ext4"
      run_cmd resize2fs "$dev" || fatal "resize2fs başarısız oldu."
      ;;
    xfs)
      [ -n "$mnt" ] || fatal "XFS için mountpoint gerekli."
      info "Filesystem büyütülüyor: xfs"
      run_cmd xfs_growfs "$mnt" || fatal "xfs_growfs başarısız oldu."
      ;;
    *)
      fatal "Desteklenmeyen filesystem: $fstype"
      ;;
  esac
}

mkfs_for_type() {
  local dev="$1"
  local fstype="$2"

  case "$fstype" in
    ext4)
      run_cmd mkfs.ext4 -F "$dev" || fatal "mkfs.ext4 başarısız oldu."
      ;;
    xfs)
      run_cmd mkfs.xfs -f "$dev" || fatal "mkfs.xfs başarısız oldu."
      ;;
    *)
      fatal "Desteklenmeyen filesystem: $fstype"
      ;;
  esac
}

###############################################################################
# Mount / fstab
###############################################################################

backup_fstab() {
  local ts file
  ts="$(date '+%Y%m%d_%H%M%S')"
  file="${FSTAB_BACKUP_DIR}/fstab_${ts}.bak"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] cp /etc/fstab $file"
    REPLY_VALUE="$file"
    return 0
  fi

  cp /etc/fstab "$file" || fatal "/etc/fstab yedeği alınamadı."
  REPLY_VALUE="$file"
  return 0
}

get_uuid_of_device() {
  local dev="$1"
  blkid -s UUID -o value "$dev" 2>/dev/null | head -n1
}

fstab_has_mountpoint() {
  local mountpoint="$1"
  awk -v mp="$mountpoint" '
    $0 !~ /^[[:space:]]*#/ && NF >= 2 && $2 == mp { found=1 }
    END { exit(found ? 0 : 1) }' /etc/fstab
}

fstab_has_uuid() {
  local uuid="$1"
  awk -v u="UUID=$uuid" '
    $0 !~ /^[[:space:]]*#/ && $1 == u { found=1 }
    END { exit(found ? 0 : 1) }' /etc/fstab
}

validate_fstab() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] mount -a -fn"
    return 0
  fi

  mount -a -fn >/dev/null 2>&1 || fatal "/etc/fstab doğrulaması başarısız oldu. Son değişikliği kontrol et."
}

verify_fstab_entry() {
  local line="$1"
  local tmp_file

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] mount -a -fn -T <temp-fstab-with-new-entry>"
    return 0
  fi

  tmp_file="$(mktemp)" || return 1
  cp /etc/fstab "$tmp_file" >/dev/null 2>&1 || {
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }

  printf '%s\n' "$line" >> "$tmp_file" || {
    rm -f "$tmp_file" >/dev/null 2>&1 || true
    return 1
  }

  mount -a -fn -T "$tmp_file" >/dev/null 2>&1
  local rc=$?
  rm -f "$tmp_file" >/dev/null 2>&1 || true
  return "$rc"
}

append_fstab_entry() {
  local dev="$1"
  local mountpoint="$2"
  local fstype="$3"
  local uuid options dump passno backup_file new_entry

  uuid="$(get_uuid_of_device "$dev")"
  [ -n "$uuid" ] || fatal "Device UUID okunamadı: $dev"

  if fstab_has_mountpoint "$mountpoint"; then
    fatal "/etc/fstab içinde bu mountpoint zaten mevcut: $mountpoint"
  fi

  if fstab_has_uuid "$uuid"; then
    fatal "/etc/fstab içinde bu UUID zaten mevcut: $uuid"
  fi

  case "$fstype" in
    ext4)
      options="defaults"
      dump="0"
      passno="2"
      ;;
    xfs)
      options="defaults"
      dump="0"
      passno="0"
      ;;
    *)
      fatal "fstab için desteklenmeyen filesystem: $fstype"
      ;;
  esac

  new_entry="UUID=$uuid $mountpoint $fstype $options $dump $passno"
  echo "[VERIFY] $new_entry -> /etc/fstab"
  verify_fstab_entry "$new_entry" || fatal "/etc/fstab eklenecek satır doğrulanamadı."

  backup_fstab
  backup_file="$REPLY_VALUE"
  ok "/etc/fstab yedeği alındı: $backup_file"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] echo '$new_entry' >> /etc/fstab"
    validate_fstab
    return 0
  fi

  printf '%s\n' "$new_entry" >> /etc/fstab \
    || fatal "/etc/fstab güncellenemedi."

  validate_fstab
}

mount_and_persist_device() {
  local dev="$1"
  local mountpoint="$2"
  local fstype="$3"

  if [ -d "$mountpoint" ]; then
    if mountpoint -q "$mountpoint" 2>/dev/null; then
      fatal "Mountpoint zaten kullanımda: $mountpoint"
    fi
  else
    run_cmd mkdir -p "$mountpoint" || fatal "Mountpoint oluşturulamadı: $mountpoint"
  fi

  run_cmd mount "$dev" "$mountpoint" || fatal "Mount başarısız oldu: $dev -> $mountpoint"
  append_fstab_entry "$dev" "$mountpoint" "$fstype"

  ok "Device mount edildi ve /etc/fstab içine eklendi."
  echo "  Device      : $dev"
  echo "  Mountpoint  : $mountpoint"
  echo "  Filesystem  : $fstype"
}

show_mount_usage() {
  local mountpoint="$1"
  subtitle "Mountpoint kullanım kontrolü: $mountpoint"

  if cmd_exists fuser; then
    echo "fuser çıktısı:"
    fuser -vm "$mountpoint" 2>/dev/null || echo "  (aktif süreç bulunamadı veya bilgi alınamadı)"
    echo
  fi

  if cmd_exists lsof; then
    echo "lsof ilk 20 satır:"
    lsof +D "$mountpoint" 2>/dev/null | sed -n '1,20p' || echo "  (aktif süreç bulunamadı veya bilgi alınamadı)"
    echo
  fi

  if ! cmd_exists fuser && ! cmd_exists lsof; then
    warn "Ne fuser ne de lsof bulundu. Kullanım kontrolü yapılamadı."
  fi
}

resolve_partition_selection() {
  local input="$1"
  local index=1
  local dtype path size fstype mnt

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    while IFS='|' read -r path size fstype mnt; do
      [ -n "$path" ] || continue
      if [ "$index" -eq "$input" ]; then
        dtype="$(lsblk -no TYPE "$path" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
        [ "$dtype" = "part" ] || return 1
        REPLY_VALUE="$path"
        return 0
      fi
      index=$((index + 1))
    done < <(get_partition_list)
    return 1
  fi

  [ -b "$input" ] || return 1
  dtype="$(lsblk -no TYPE "$input" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  [ "$dtype" = "part" ] || return 1
  REPLY_VALUE="$input"
  return 0
}

resolve_mount_selection() {
  local input="$1"
  local index=1
  local target source fstype

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    while IFS='|' read -r target source fstype; do
      [ -n "$target" ] || continue
      if [ "$index" -eq "$input" ]; then
        REPLY_VALUE="$target"
        return 0
      fi
      index=$((index + 1))
    done < <(get_mounted_targets_list)
    return 1
  fi

  if mountpoint -q "$input" 2>/dev/null; then
    REPLY_VALUE="$input"
    return 0
  fi

  return 1
}

select_mount_target() {
  local input
  while true; do
    list_mounted_targets
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan mountpoint yolunu girin."
    ask_nonempty "Unmount edilecek mountpoint seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_mount_selection "$input"; then
      return 0
    fi
    warn "Hatalı değer girildi. Geçerli bir mount numarası veya mountpoint girin."
  done
}

resolve_disk_selection() {
  local input="$1"
  local index=1
  local dtype path size model

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    while IFS='|' read -r path size model; do
      [ -n "$path" ] || continue
      if [ "$index" -eq "$input" ]; then
        dtype="$(lsblk -no TYPE "$path" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
        [ "$dtype" = "disk" ] || return 1
        REPLY_VALUE="$path"
        return 0
      fi
      index=$((index + 1))
    done < <(get_disk_list)
    return 1
  fi

  [ -b "$input" ] || return 1
  dtype="$(lsblk -no TYPE "$input" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  [ "$dtype" = "disk" ] || return 1
  REPLY_VALUE="$input"
  return 0
}

resolve_fstab_selection() {
  local input="$1"
  local index=1
  local spec mountpoint fstype opts

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    while IFS='|' read -r spec mountpoint fstype opts; do
      [ -n "$spec" ] || continue
      if [ "$index" -eq "$input" ]; then
        REPLY_VALUE="$mountpoint"
        return 0
      fi
      index=$((index + 1))
    done < <(get_fstab_entries_list)
    return 1
  fi

  awk -v target="$input" '
    $0 !~ /^[[:space:]]*#/ && NF >= 2 && ($2 == target || $1 == target) {
      print $2
      found=1
      exit
    }
    END { if (!found) exit 1 }' /etc/fstab > /tmp/safepart_fstab_match.$$ 2>/dev/null || return 1

  REPLY_VALUE="$(cat /tmp/safepart_fstab_match.$$ 2>/dev/null)"
  rm -f /tmp/safepart_fstab_match.$$ 2>/dev/null || true
  [ -n "$REPLY_VALUE" ] || return 1
  return 0
}

select_fstab_entry() {
  local input
  while true; do
    list_fstab_entries
    echo "Seçim yöntemi: listedeki numarayı, mountpoint'i veya spec değerini girin."
    ask_nonempty "Silinecek fstab kaydı seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_fstab_selection "$input"; then
      return 0
    fi
    warn "Hatalı değer girildi. Geçerli bir fstab kayıt numarası, mountpoint veya spec girin."
  done
}

remove_fstab_entry_by_mountpoint() {
  local mountpoint="$1"
  local backup_file tmp_file

  backup_fstab
  backup_file="$REPLY_VALUE"
  ok "/etc/fstab yedeği alındı: $backup_file"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] /etc/fstab içinden mountpoint '$mountpoint' kaydı silinecek"
    validate_fstab
    return 0
  fi

  tmp_file="$(mktemp)" || fatal "Geçici dosya oluşturulamadı."

  awk -v mp="$mountpoint" '
    $0 ~ /^[[:space:]]*#/ { print; next }
    NF >= 2 && $2 == mp { next }
    { print }' /etc/fstab > "$tmp_file" || {
      rm -f "$tmp_file"
      fatal "/etc/fstab yeniden yazılamadı."
    }

  cp "$tmp_file" /etc/fstab || {
    rm -f "$tmp_file"
    fatal "/etc/fstab güncellenemedi."
  }

  rm -f "$tmp_file" || true
  validate_fstab
  ok "/etc/fstab kaydı silindi: $mountpoint"
}

unmount_target_flow() {
  local mountpoint rc

  title "Mount kaldırma"
  echo "Açıklama: Seçilen mountpoint'i unmount eder."
  echo

  select_mount_target
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  mountpoint="$REPLY_VALUE"

  if [ "$mountpoint" = "/" ]; then
    fatal "Root filesystem unmount edilemez."
  fi

  critical_mount_extra_confirm "$mountpoint"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  preflight_report "unmount" "$mountpoint" "" "" "$mountpoint"
  show_mount_usage "$mountpoint"

  confirm "$mountpoint unmount edilsin mi?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  run_cmd umount "$mountpoint" || fatal "umount başarısız oldu: $mountpoint"
  ok "Unmount tamamlandı: $mountpoint"
  audit "unmount mountpoint=$mountpoint"
}

remove_fstab_entry_flow() {
  local mountpoint rc

  title "fstab kaydı silme"
  echo "Açıklama: Seçilen /etc/fstab kaydını siler."
  echo

  select_fstab_entry
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  mountpoint="$REPLY_VALUE"

  critical_mount_extra_confirm "$mountpoint"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  echo "  Silinecek mountpoint : $mountpoint"
  echo

  confirm "/etc/fstab içinden $mountpoint kaydı silinsin mi?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  remove_fstab_entry_by_mountpoint "$mountpoint"
  audit "remove-fstab mountpoint=$mountpoint"
}

unmount_and_remove_fstab_flow() {
  local mountpoint rc

  title "Unmount + fstab temizleme"
  echo "Açıklama: Seçilen mountpoint'i unmount eder ve /etc/fstab içindeki karşılık gelen kaydı siler."
  echo

  select_mount_target
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  mountpoint="$REPLY_VALUE"

  if [ "$mountpoint" = "/" ]; then
    fatal "Root filesystem için bu işlem yapılamaz."
  fi

  critical_mount_extra_confirm "$mountpoint"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  preflight_report "unmount" "$mountpoint" "" "" "$mountpoint"
  show_mount_usage "$mountpoint"

  confirm "$mountpoint unmount edilsin ve fstab kaydı silinsin mi?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  run_cmd umount "$mountpoint" || fatal "umount başarısız oldu: $mountpoint"
  ok "Unmount tamamlandı: $mountpoint"

  if fstab_has_mountpoint "$mountpoint"; then
    remove_fstab_entry_by_mountpoint "$mountpoint"
  else
    warn "/etc/fstab içinde bu mountpoint için kayıt bulunamadı: $mountpoint"
  fi

  ok "Unmount + fstab temizleme tamamlandı."
  audit "unmount-clean mountpoint=$mountpoint"
}

###############################################################################
# LVM metadata backup
###############################################################################

backup_lvm_metadata() {
  local vg="$1"
  local ts file

  ts="$(date '+%Y%m%d_%H%M%S')"
  file="${LVM_BACKUP_DIR}/${vg}_${ts}.vgcfg"

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] vgcfgbackup -f $file $vg"
    REPLY_VALUE="$file"
    return 0
  fi

  vgcfgbackup -f "$file" "$vg" >/dev/null 2>&1 || fatal "vgcfgbackup başarısız oldu: $vg"
  REPLY_VALUE="$file"
  ok "LVM metadata yedeği alındı: $file"
  return 0
}

###############################################################################
# Selection helpers
###############################################################################

select_disk_for_generic_ops() {
  local input
  while true; do
    list_only_disks_with_sizes
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan disk yolunu girin."
    ask_nonempty "İşlem yapılacak disk seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_disk_selection "$input"; then
      return 0
    fi
    warn "Hatalı değer girildi. Geçerli bir disk numarası veya disk yolu girin."
  done
}

select_partition_for_ops() {
  local input
  while true; do
    list_only_partitions_with_sizes
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan partition yolunu girin."
    ask_nonempty "İşlem yapılacak partition seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_partition_selection "$input"; then
      return 0
    fi
    warn "Hatalı değer girildi. Geçerli bir partition numarası veya partition yolu girin."
  done
}

resolve_lvm_selection() {
  local input="$1"
  local index=1
  local path size fstype mnt dtype

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    while IFS='|' read -r path size fstype mnt; do
      [ -n "$path" ] || continue
      if [ "$index" -eq "$input" ]; then
        dtype="$(lsblk -no TYPE "$path" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
        [ "$dtype" = "lvm" ] || return 1
        REPLY_VALUE="$path"
        return 0
      fi
      index=$((index + 1))
    done < <(get_lvm_lv_list)
    return 1
  fi

  [ -e "$input" ] || return 1
  dtype="$(lsblk -no TYPE "$input" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  [ "$dtype" = "lvm" ] || return 1
  REPLY_VALUE="$input"
  return 0
}

resolve_vg_pv_selection() {
  local vg="$1"
  local input="$2"
  local index=1
  local pv size free dtype

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    while IFS='|' read -r pv size free; do
      [ -n "$pv" ] || continue
      if [ "$index" -eq "$input" ]; then
        dtype="$(lsblk -no TYPE "$pv" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
        [ "$dtype" = "part" ] || return 1
        REPLY_VALUE="$pv"
        return 0
      fi
      index=$((index + 1))
    done < <(get_vg_pv_list "$vg")
    return 1
  fi

  [ -b "$input" ] || return 1
  dtype="$(lsblk -no TYPE "$input" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  [ "$dtype" = "part" ] || return 1
  REPLY_VALUE="$input"
  return 0
}

select_lvm_for_ops() {
  local input
  while true; do
    list_lvm_lvs
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan LV yolunu girin."
    ask_nonempty "İşlem yapılacak LVM logical volume seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_lvm_selection "$input"; then
      return 0
    fi
    warn "Hatalı değer girildi. Geçerli bir LVM LV numarası veya yolu girin."
  done
}

select_vg_pv_for_ops() {
  local vg="$1"
  local input
  while true; do
    list_vg_pvs "$vg"
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan PV yolunu girin."
    ask_nonempty "İşlem yapılacak PV seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_vg_pv_selection "$vg" "$input"; then
      return 0
    fi
    warn "Hatalı değer girildi. Geçerli bir PV numarası veya PV yolu girin."
  done
}

###############################################################################
# Partition table backup / restore / reread
###############################################################################

backup_partition_table() {
  local disk="$1"
  local skip_confirm="${2:-0}"
  local ts file rc

  title "Partition table yedeği"
  echo "Açıklama: Seçilen disk için mevcut partition tablosunu yedekler."
  echo "${C_CYAN}Disk${C_RESET}: $disk"

  ts="$(date '+%Y%m%d_%H%M%S')"
  file="${BACKUP_DIR}/$(basename "$disk")_${ts}.sfdisk"
  echo "${C_CYAN}Yedek${C_RESET}: $file"
  echo

  if [ "$skip_confirm" -ne 1 ]; then
    confirm "$disk için partition table yedeği alınsın mı?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return "$RET_MENU"
    [ "$rc" -ne 0 ] && {
      warn "İşlem iptal edildi."
      return 1
    }
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] sfdisk -d $disk > $file"
    REPLY_VALUE="$file"
    return 0
  fi

  sfdisk -d "$disk" > "$file" || fatal "Partition table yedeği alınamadı."
  REPLY_VALUE="$file"
  ok "Yedek alındı: $file"
  audit "backup-pt disk=$disk file=$file"
}

list_partition_table_backups() {
  title "Mevcut partition table yedekleri"
  echo "Açıklama: Daha önce alınmış sfdisk yedeklerini listeler."
  echo

  if [ ! -d "$BACKUP_DIR" ]; then
    warn "Yedek dizini bulunamadı: $BACKUP_DIR"
    return 1
  fi

  local count=0
  local i=1
  local f
  for f in "$BACKUP_DIR"/*.sfdisk; do
    [ -e "$f" ] || continue
    count=1
    printf "  ${C_CYAN}%2d)${C_RESET} %s\n" "$i" "$f"
    i=$((i + 1))
  done

  if [ "$count" -eq 0 ]; then
    warn "Hiç yedek bulunamadı."
    return 1
  fi

  echo
  return 0
}

resolve_backup_selection() {
  local input="$1"
  local index=1
  local f

  if echo "$input" | grep -Eq '^[0-9]+$'; then
    for f in "$BACKUP_DIR"/*.sfdisk; do
      [ -e "$f" ] || continue
      if [ "$index" -eq "$input" ]; then
        REPLY_VALUE="$f"
        return 0
      fi
      index=$((index + 1))
    done
    return 1
  fi

  [ -f "$input" ] || return 1
  REPLY_VALUE="$input"
  return 0
}

select_backup_file_for_restore() {
  local input

  while true; do
    list_partition_table_backups || return 1
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan yedek dosya yolunu girin."
    ask_nonempty "Geri yüklenecek yedek seçimi"
    case $? in
      "$RET_MENU") return "$RET_MENU" ;;
      0) input="$REPLY_VALUE" ;;
    esac

    if resolve_backup_selection "$input"; then
      return 0
    fi

    warn "Hatalı değer girildi. Geçerli bir yedek numarası veya yedek dosya yolu girin."
  done
}

extract_disk_from_backup() {
  local backup_file="$1"
  awk -F: '
    /^\/dev\// {
      disk=$1
      sub(/[0-9]+$/, "", disk)
      sub(/p$/, "", disk)
      print disk
      exit
    }' "$backup_file"
}

show_backup_preview() {
  local backup_file="$1"
  title "Yedek önizleme"
  echo "Dosya: $backup_file"
  echo "İlk satırlar:"
  echo
  sed -n '1,15p' "$backup_file"
  echo
}

restore_partition_table_from_backup() {
  local backup_file disk detected_disk rc

  title "Partition table yedeğinden geri dön"
  echo "Açıklama: Daha önce alınmış sfdisk yedeğini seçilen diske geri yükler."
  echo
  warn "Bu işlem yalnızca partition table'ı geri alır."
  warn "Tam rollback değildir:"
  echo "  - filesystem içerikleri geri alınmaz"
  echo "  - LVM metadata otomatik geri alınmaz"
  echo "  - reboot gerekebilir"
  echo

  if [ -n "$CLI_BACKUP_FILE" ]; then
    backup_file="$CLI_BACKUP_FILE"
    [ -f "$backup_file" ] || fatal "Yedek dosyası bulunamadı: $backup_file"
  else
    select_backup_file_for_restore
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && {
      warn "Yedek seçimi yapılamadı."
      return 1
    }
    backup_file="$REPLY_VALUE"
  fi

  show_backup_preview "$backup_file"

  detected_disk="$(extract_disk_from_backup "$backup_file")"
  if [ -n "$detected_disk" ]; then
    info "Yedekten tahmin edilen disk: $detected_disk"
  else
    warn "Yedek dosyasından disk bilgisi net çıkarılamadı."
  fi

  if [ -n "$CLI_DISK" ]; then
    disk="$CLI_DISK"
  else
    list_only_disks_with_sizes
    echo "Seçim yöntemi: listedeki numarayı veya doğrudan disk yolunu girin."
    ask_nonempty "Yedeğin geri yükleneceği disk seçimi"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    disk="$REPLY_VALUE"
  fi

  if ! resolve_disk_selection "$disk"; then
    warn "Hatalı disk seçimi."
    return 1
  fi
  disk="$REPLY_VALUE"

  if [ -n "$detected_disk" ] && [ "$disk" != "$detected_disk" ]; then
    warn "Seçilen disk ($disk), yedekten tahmin edilen diskle ($detected_disk) eşleşmiyor."
    confirm "Buna rağmen devam edilsin mi?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1
  fi

  preflight_report "restore-pt" "" "$disk"

  confirm "$disk için mevcut partition table ayrıca yeni bir güvenlik yedeği olarak alınsın mı?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  if [ "$rc" -eq 0 ]; then
    backup_partition_table "$disk" 1 || fatal "Geri dönüş öncesi güvenlik yedeği alınamadı."
  fi

  validate_restore_partition_table_plan "$disk" "$backup_file" || return 1
  show_action_validation_result "Partition table geri yükleme" "$disk" "backup=$(basename "$backup_file")" || return 1

  confirm "Dry-run başarılı. $backup_file içeriği $disk üzerine geri yüklensin mi?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] sfdisk $disk < $backup_file"
  else
    run_sfdisk_from_file "$disk" "$backup_file" || fatal "Partition table geri yükleme başarısız oldu."
  fi

  info "Kernel'e yeni partition tablosu okutulmaya çalışılıyor..."
  if run_cmd partx -u "$disk"; then
    ok "Kernel partition tablosunu yeniden okumayı denedi."
  else
    warn "Kernel yeni partition bilgisini hemen okuyamadı. Reboot gerekebilir."
  fi

  ok "Partition table geri yükleme işlemi tamamlandı."
  audit "restore-pt disk=$disk backup=$backup_file"
}

reread_partition_table() {
  local disk="$1"
  local rc

  title "Partition table yeniden okutma"
  echo "Açıklama: Kernel'e disk üzerindeki bölüm tablosunu yeniden okutmayı dener."
  echo

  verify_command_step partx -u "$disk" || return 1
  show_action_validation_result "Partition table yeniden okutma" "$disk" "partx -u" || return 1

  confirm "Dry-run başarılı. $disk için kernel partition tablosunu yeniden okusun mu?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  if run_cmd partx -u "$disk"; then
    ok "Kernel partition tablosu yeniden okutma denemesi tamamlandı."
  else
    warn "Kernel tabloyu hemen yeniden okuyamadı. Reboot gerekebilir."
  fi

  audit "reread-pt disk=$disk"
}

###############################################################################
# Partition create helpers
###############################################################################

ensure_partition_table_exists() {
  local disk="$1"
  local pttype rc choice

  pttype="$(get_pttype "$disk")"

  if [ -n "$pttype" ]; then
    REPLY_VALUE="$pttype"
    return 0
  fi

  title "Partition table bulunamadı"
  echo "Açıklama: Seçilen diskte partition table görünmüyor. Devam etmek için önce bir label oluşturulmalı."
  echo

  echo "  ${C_CYAN}1)${C_RESET} GPT"
  echo "  ${C_CYAN}2)${C_RESET} DOS/MBR"
  echo
  ask_menu_choice "Oluşturulacak partition table tipini seçin [1-2]" 1 2
  choice="$REPLY_VALUE"

  case "$choice" in
    1) pttype="gpt" ;;
    2) pttype="dos" ;;
  esac

  validate_partition_table_create_plan "$disk" "$pttype" || return 1
  show_action_validation_result "Partition table oluşturma" "$disk" "label=$pttype" || return 1

  confirm "Dry-run başarılı. $disk üzerinde ${pttype} partition table oluşturulsun mu?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return "$RET_MENU"
  [ "$rc" -ne 0 ] && return 1

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] printf 'label: %s\n' '$pttype' | sfdisk '$disk'"
  else
    run_sfdisk_input "label: $pttype" "$disk" || fatal "Partition table oluşturulamadı."
    run_cmd partx -u "$disk" || true
  fi

  REPLY_VALUE="$pttype"
  return 0
}

get_partition_type_code() {
  local pttype="$1"
  local usage="$2"

  case "$pttype:$usage" in
    gpt:normal) REPLY_VALUE="8300" ;;
    gpt:lvm)    REPLY_VALUE="8e00" ;;
    dos:normal) REPLY_VALUE="83" ;;
    dos:lvm)    REPLY_VALUE="8e" ;;
    *)
      return 1
      ;;
  esac
  return 0
}

create_partition_at_disk_end() {
  local disk="$1"
  local size_bytes="$2"
  local usage="$3"

  local pttype type_code disk_free_bytes old_last new_last part_spec

  pttype="$(get_pttype "$disk")"
  [ -n "$pttype" ] || fatal "Partition table tipi bulunamadı."

  get_partition_type_code "$pttype" "$usage" || fatal "Partition type code belirlenemedi."
  type_code="$REPLY_VALUE"

  get_disk_tail_free_bytes "$disk" || fatal "Disk boş alanı hesaplanamadı."
  disk_free_bytes="$REPLY_VALUE"

  if [ "$disk_free_bytes" -le 0 ]; then
    fatal "Diskin sonunda kullanılabilir boş alan yok."
  fi

  if [ "$size_bytes" -gt "$disk_free_bytes" ]; then
    size_bytes="$disk_free_bytes"
  fi

  old_last="$(get_last_partition_path_on_disk "$disk" || true)"
  part_spec="$(build_sfdisk_partition_spec "$disk" "$size_bytes" "$type_code")" || fatal "Yeni partition spec oluşturulamadı."

  info "Yeni partition oluşturuluyor..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] printf '%s\\n' '$part_spec' | sfdisk --append '$disk'"
    new_last="$(predict_next_partition_path "$disk" "$old_last")" || fatal "Dry-run için yeni partition yolu tahmin edilemedi."
  else
    run_sfdisk_input "$part_spec" --append "$disk" || fatal "Yeni partition oluşturulamadı."
    new_last="$(get_last_partition_path_on_disk "$disk" || true)"
    [ -n "$new_last" ] || fatal "Yeni partition yolu tespit edilemedi."
  fi

  run_cmd partx -u "$disk" || warn "Kernel yeni partition bilgisini hemen okuyamadı. Reboot gerekebilir."

  if [ -n "$old_last" ] && [ "$old_last" = "$new_last" ] && [ "$DRY_RUN" -ne 1 ]; then
    fatal "Yeni partition tespit edilemedi. Son partition değişmemiş görünüyor."
  fi

  REPLY_VALUE="$new_last"
  return 0
}

###############################################################################
# Shared: grow last partition to exact target bytes
###############################################################################

grow_partition_to_target_bytes() {
  local part="$1"
  local target_bytes="$2"

  local disk partnum sfdisk_line start_sector current_sectors sector_size disk_bytes
  local total_sectors part_end_sector free_after_sectors max_sectors max_bytes
  local final_bytes final_sectors part_spec new_spec

  disk="$(get_parent_disk "$part")" || fatal "Parent disk bulunamadı."
  partnum="$(get_partnum "$part")"
  [ -n "$partnum" ] || fatal "Partition numarası bulunamadı."

  if ! is_last_partition_on_disk "$disk" "$part"; then
    fatal "Seçilen partition diskin son partition'ı değil. Güvenli büyütme için yalnızca son partition desteklenir."
  fi

  sfdisk_line="$(get_sfdisk_line "$disk" "$part")"
  [ -n "$sfdisk_line" ] || fatal "Partition bilgisi sfdisk ile okunamadı."

  start_sector="$(get_start_sector_from_line "$sfdisk_line")"
  current_sectors="$(get_size_sector_from_line "$sfdisk_line")"
  sector_size="$(blockdev --getss "$disk")"
  disk_bytes="$(blockdev --getsize64 "$disk")"

  [ -n "$start_sector" ] || fatal "Partition başlangıç sektörü okunamadı."
  [ -n "$current_sectors" ] || fatal "Partition sektör boyutu okunamadı."

  total_sectors=$((disk_bytes / sector_size))
  part_end_sector=$((start_sector + current_sectors))
  free_after_sectors=$((total_sectors - part_end_sector))
  [ "$free_after_sectors" -lt 0 ] && free_after_sectors=0

  max_sectors=$((current_sectors + free_after_sectors))
  max_bytes=$((max_sectors * sector_size))

  if [ "$target_bytes" -gt "$max_bytes" ]; then
    final_bytes="$max_bytes"
  else
    final_bytes="$target_bytes"
  fi

  final_sectors=$((final_bytes / sector_size))
  final_bytes=$((final_sectors * sector_size))

  if [ "$final_sectors" -le "$current_sectors" ]; then
    REPLY_VALUE="$((current_sectors * sector_size))"
    return 0
  fi

  part_spec="$(echo "$sfdisk_line" | cut -d: -f2-)"
  new_spec="$(echo "$part_spec" | sed -E "s/(size=)[[:space:]]*[0-9]+/\1 ${final_sectors}/")"

  info "Partition tablosu güncelleniyor..."
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[DRY-RUN] printf '%s\n' \"$new_spec\" | sfdisk --no-reread --force -N \"$partnum\" \"$disk\""
  else
    run_sfdisk_input "$new_spec" --no-reread --force -N "$partnum" "$disk" || fatal "Partition tablosu güncellenemedi."
  fi

  info "Kernel'e yeni partition bilgisi okutuluyor..."
  run_cmd partx -u "$disk" || warn "Kernel yeni partition bilgisini hemen okuyamadı. Reboot gerekebilir."

  REPLY_VALUE="$final_bytes"
  return 0
}

validate_partition_growth_plan() {
  local part="$1"
  local target_bytes="$2"
  local fstype="$3"
  local mnt="$4"

  local disk partnum sfdisk_line start_sector current_sectors sector_size disk_bytes
  local total_sectors part_end_sector free_after_sectors max_sectors max_bytes
  local final_bytes final_sectors part_spec new_spec

  validation_plan_reset

  disk="$(get_parent_disk "$part")" || return 1
  partnum="$(get_partnum "$part")"
  [ -n "$partnum" ] || return 1

  if ! is_last_partition_on_disk "$disk" "$part"; then
    validation_plan_add fail "target partition is not the last partition on disk"
    warn "Dry-run doğrulaması başarısız: hedef partition diskin son partition'ı değil."
    return 1
  fi
  validation_plan_add ok "target partition is the last partition on disk"

  sfdisk_line="$(get_sfdisk_line "$disk" "$part")"
  [ -n "$sfdisk_line" ] || return 1

  start_sector="$(get_start_sector_from_line "$sfdisk_line")"
  current_sectors="$(get_size_sector_from_line "$sfdisk_line")"
  sector_size="$(blockdev --getss "$disk")"
  disk_bytes="$(blockdev --getsize64 "$disk")"

  [ -n "$start_sector" ] || return 1
  [ -n "$current_sectors" ] || return 1

  total_sectors=$((disk_bytes / sector_size))
  part_end_sector=$((start_sector + current_sectors))
  free_after_sectors=$((total_sectors - part_end_sector))
  [ "$free_after_sectors" -lt 0 ] && free_after_sectors=0

  max_sectors=$((current_sectors + free_after_sectors))
  max_bytes=$((max_sectors * sector_size))
  if [ "$target_bytes" -gt "$max_bytes" ]; then
    final_bytes="$max_bytes"
  else
    final_bytes="$target_bytes"
  fi

  final_sectors=$((final_bytes / sector_size))
  final_bytes=$((final_sectors * sector_size))

  if [ "$final_sectors" -le "$current_sectors" ]; then
    validation_plan_add fail "no additional sectors available for safe growth"
    warn "Dry-run doğrulaması: partition için büyütülebilir ek alan görünmüyor."
    return 1
  fi

  part_spec="$(echo "$sfdisk_line" | cut -d: -f2-)"
  new_spec="$(echo "$part_spec" | sed -E "s/(size=)[[:space:]]*[0-9]+/\1 ${final_sectors}/")"

  printf '%s\n' "$new_spec" | sfdisk --no-act --no-reread --force -N "$partnum" "$disk" >/dev/null 2>&1 || {
    validation_plan_add fail "sfdisk no-act growth validation rejected"
    warn "Dry-run doğrulaması başarısız: sfdisk hedef büyütmeyi kabul etmedi."
    return 1
  }
  validation_plan_add ok "sfdisk no-act growth validation passed"

  verify_command_step partx -u "$disk" || {
    validation_plan_add fail "kernel reread pre-check failed"
    warn "Dry-run doğrulaması başarısız: kernel reread ön-koşul kontrolü geçmedi."
    return 1
  }
  validation_plan_add ok "kernel reread pre-check passed"

  case "$fstype" in
    ext4)
      verify_command_step resize2fs "$part" || {
        validation_plan_add fail "resize2fs pre-check failed"
        warn "Dry-run doğrulaması başarısız: ext4 filesystem grow ön-kontrolü geçmedi."
        return 1
      }
      validation_plan_add ok "resize2fs pre-check passed"
      ;;
    xfs)
      verify_command_step xfs_growfs "$mnt" || {
        validation_plan_add fail "xfs_growfs -n pre-check failed"
        warn "Dry-run doğrulaması başarısız: xfs_growfs -n kontrolü geçmedi."
        return 1
      }
      validation_plan_add ok "xfs_growfs -n pre-check passed"
      ;;
  esac

  REPLY_VALUE="$final_bytes"
  return 0
}

validate_lvm_growth_plan() {
  local lv="$1"
  local target_bytes="$2"
  local fstype="$3"
  local mnt="$4"
  local pv="${5:-}"
  local desired_partition_bytes="${6:-}"
  local part_current_bytes="${7:-0}"
  local vg_free_bytes="${8:-0}"
  local current_lv_bytes="${9:-0}"

  local final_target_bytes predicted_vg_free_bytes actual_partition_bytes

  validation_plan_reset

  if [ -z "$pv" ]; then
    verify_command_step lvextend -L "${target_bytes}B" "$lv" || {
      validation_plan_add fail "lvextend test mode rejected requested size"
      warn "Dry-run doğrulaması başarısız: lvextend test modu hedefi kabul etmedi."
      return 1
    }
    validation_plan_add ok "lvextend test mode accepted requested size"
    final_target_bytes="$target_bytes"
  else
    validate_partition_growth_plan "$pv" "$desired_partition_bytes" "$fstype" "$mnt" || return 1
    actual_partition_bytes="$REPLY_VALUE"
    validation_plan_add ok "pv partition growth validation passed"

    verify_command_step pvresize "$pv" || {
      validation_plan_add fail "pvresize test mode failed"
      warn "Dry-run doğrulaması başarısız: pvresize test modu başarısız oldu."
      return 1
    }
    validation_plan_add ok "pvresize test mode passed"

    predicted_vg_free_bytes=$((vg_free_bytes + actual_partition_bytes - part_current_bytes))
    [ "$predicted_vg_free_bytes" -lt 0 ] && predicted_vg_free_bytes=0
    final_target_bytes=$((current_lv_bytes + predicted_vg_free_bytes))
    if [ "$target_bytes" -lt "$final_target_bytes" ]; then
      final_target_bytes="$target_bytes"
    fi

    verify_command_step lvextend -L "${final_target_bytes}B" "$lv" || {
      validation_plan_add fail "lvextend test mode rejected chained growth target"
      warn "Dry-run doğrulaması başarısız: lvextend test modu zincir büyütmeyi kabul etmedi."
      return 1
    }
    validation_plan_add ok "lvextend test mode accepted chained growth target"
  fi

  case "$fstype" in
    ext4)
      verify_command_step resize2fs "$lv" || {
        validation_plan_add fail "resize2fs pre-check failed"
        warn "Dry-run doğrulaması başarısız: ext4 filesystem grow ön-kontrolü geçmedi."
        return 1
      }
      validation_plan_add ok "resize2fs pre-check passed"
      ;;
    xfs)
      verify_command_step xfs_growfs "$mnt" || {
        validation_plan_add fail "xfs_growfs -n pre-check failed"
        warn "Dry-run doğrulaması başarısız: xfs_growfs -n kontrolü geçmedi."
        return 1
      }
      validation_plan_add ok "xfs_growfs -n pre-check passed"
      ;;
  esac

  REPLY_VALUE="$final_target_bytes"
  return 0
}

validate_lvm_post_pv_growth_plan() {
  local lv="$1"
  local target_bytes="$2"
  local current_lv_bytes="$3"
  local fstype="$4"
  local mnt="$5"
  local vg_name="$6"
  local final_target_bytes vg_free_bytes

  validation_plan_reset

  vg_free_bytes="$(get_vg_free_bytes "$vg_name")"
  [ -n "$vg_free_bytes" ] || return 1
  validation_plan_add ok "current VG free space read after pvresize"

  final_target_bytes=$((current_lv_bytes + vg_free_bytes))
  if [ "$target_bytes" -lt "$final_target_bytes" ]; then
    final_target_bytes="$target_bytes"
  fi

  if [ "$final_target_bytes" -le "$current_lv_bytes" ]; then
    validation_plan_add fail "no new VG free space available for LV extension"
    warn "Dry-run doğrulaması başarısız: PV büyümesinden sonra LV için kullanılabilir yeni alan görünmüyor."
    return 1
  fi

  verify_command_step lvextend -L "${final_target_bytes}B" "$lv" || {
    validation_plan_add fail "lvextend test mode rejected post-PV target"
    warn "Dry-run doğrulaması başarısız: lvextend test modu yeni VG boş alanıyla hedefi kabul etmedi."
    return 1
  }
  validation_plan_add ok "lvextend test mode accepted post-PV target"

  case "$fstype" in
    ext4)
      verify_command_step resize2fs "$lv" || {
        validation_plan_add fail "resize2fs pre-check failed"
        warn "Dry-run doğrulaması başarısız: ext4 filesystem grow ön-kontrolü geçmedi."
        return 1
      }
      validation_plan_add ok "resize2fs pre-check passed"
      ;;
    xfs)
      verify_command_step xfs_growfs "$mnt" || {
        validation_plan_add fail "xfs_growfs -n pre-check failed"
        warn "Dry-run doğrulaması başarısız: xfs_growfs -n kontrolü geçmedi."
        return 1
      }
      validation_plan_add ok "xfs_growfs -n pre-check passed"
      ;;
  esac

  REPLY_VALUE="$final_target_bytes"
  return 0
}

show_dry_run_validation_result() {
  local label="$1"
  local target_label="$2"
  local current_bytes="$3"
  local target_bytes="$4"
  local validated_bytes="$5"

  title "Dry-run Doğrulama Sonucu"
  echo "Açıklama: Gerçek değişiklik uygulanmadan önce plan test edildi."
  echo
  echo "  İşlem           : $label"
  echo "  Hedef           : $target_label"
  echo "  Mevcut boyut    : $(bytes_to_gb "$current_bytes") GB"
  echo "  İstenen boyut   : $(bytes_to_gb "$target_bytes") GB"
  echo "  Doğrulanan boyut: $(bytes_to_gb "$validated_bytes") GB"
  echo
  validation_plan_print

  if [ "$validated_bytes" -le "$current_bytes" ]; then
    warn "Dry-run sonucuna göre hedefe güvenli şekilde ilerlenemiyor."
    return 1
  fi

  if [ "$validated_bytes" -lt "$target_bytes" ]; then
    warn "Dry-run hedefi tam karşılamadı; script mümkün olan en yüksek değere çıkacak."
  else
    ok "Dry-run doğrulaması başarılı. Kritik adımlar sorun çıkarmadan ilerliyor görünüyor."
  fi
  return 0
}

show_action_validation_result() {
  local label="$1"
  local target="$2"
  local detail="${3:-}"

  title "Dry-run Doğrulama Sonucu"
  echo "Açıklama: Gerçek değişiklik uygulanmadan önce plan test edildi."
  echo
  echo "  İşlem   : $label"
  echo "  Hedef   : $target"
  [ -n "$detail" ] && echo "  Detay   : $detail"
  echo
  validation_plan_print
  ok "Dry-run doğrulaması başarılı. İşlem uygulanabilir görünüyor."
  return 0
}

###############################################################################
# New partition creation
###############################################################################

ask_filesystem_type() {
  local choice
  echo "  ${C_CYAN}1)${C_RESET} ext4"
  echo "  ${C_CYAN}2)${C_RESET} xfs"
  echo
  ask_menu_choice "Filesystem tipini seçin [1-2]" 1 2
  choice="$REPLY_VALUE"
  case "$choice" in
    1) REPLY_VALUE="ext4" ;;
    2) REPLY_VALUE="xfs" ;;
  esac
  return 0
}

ask_new_partition_structure() {
  local choice
  echo "  ${C_CYAN}1)${C_RESET} Bağımsız partition   - Doğrudan filesystem yazılan partition"
  echo "  ${C_CYAN}2)${C_RESET} LVM yapısı             - New PV + new VG + new LV + filesystem"
  echo
  ask_menu_choice "Yapı tipini seçin [1-2]" 1 2
  choice="$REPLY_VALUE"
  case "$choice" in
    1) REPLY_VALUE="normal" ;;
    2) REPLY_VALUE="lvm" ;;
  esac
  return 0
}

vg_exists() {
  vgs "$1" >/dev/null 2>&1
}

lv_exists() {
  lvs "$1" >/dev/null 2>&1
}

create_new_partition_flow() {
  local disk pttype rc structure fstype requested_gb requested_bytes
  local disk_free_bytes final_bytes final_gb new_part predicted_new_part mountpoint
  local vg_name lv_name lv_path

  title "Yeni partition oluşturma"
  echo "Açıklama: Seçilen diskin sonundaki boş alanı kullanarak yeni partition oluşturur."
  echo "Bu işlemde kullanıcıdan yapı tipi, filesystem tipi ve mountpoint seçimi alınır."
  echo "İşlem sonunda yeni yapı otomatik mount edilir ve /etc/fstab içine eklenir."
  echo

  if [ -n "$CLI_DISK" ]; then
    disk="$CLI_DISK"
    resolve_disk_selection "$disk" || fatal "Geçersiz disk: $disk"
    disk="$REPLY_VALUE"
  else
    select_disk_for_generic_ops
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    disk="$REPLY_VALUE"
  fi

  ensure_partition_table_exists "$disk"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1
  pttype="$REPLY_VALUE"

  get_disk_tail_free_bytes "$disk" || fatal "Disk boş alanı hesaplanamadı."
  disk_free_bytes="$REPLY_VALUE"

  echo "${C_CYAN}Seçilen disk${C_RESET}        : $disk"
  echo "${C_CYAN}Partition table${C_RESET}    : $pttype"
  echo "${C_CYAN}Sondaki boş alan${C_RESET}    : $(bytes_to_human "$disk_free_bytes")"
  echo

  if [ "$disk_free_bytes" -le 0 ]; then
    fatal "Diskin sonunda kullanılabilir boş alan yok."
  fi

  if [ -n "$CLI_STRUCTURE" ]; then
    structure="$CLI_STRUCTURE"
  else
    ask_new_partition_structure
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    structure="$REPLY_VALUE"
  fi

  if [ -n "$CLI_FS" ]; then
    fstype="$CLI_FS"
  else
    ask_filesystem_type
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    fstype="$REPLY_VALUE"
  fi

  if [ -n "$CLI_SIZE_GB" ]; then
    requested_gb="$CLI_SIZE_GB"
  else
    ask_numeric_gb "Yeni partition kaç GB olsun?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    requested_gb="$REPLY_VALUE"
  fi
  requested_bytes="$(gb_to_bytes "$requested_gb")"

  if [ "$requested_bytes" -gt "$disk_free_bytes" ]; then
    warn "Yeterli boş alan yok. Partition mümkün olan en büyük boyutta oluşturulacak."
    final_bytes="$disk_free_bytes"
  else
    final_bytes="$requested_bytes"
  fi
  final_gb="$(bytes_to_gb "$final_bytes")"

  if [ -n "$CLI_MOUNTPOINT" ]; then
    mountpoint="$CLI_MOUNTPOINT"
  else
    ask_mountpoint "Yeni yapının mountpoint'i ne olsun?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    mountpoint="$REPLY_VALUE"
  fi

  echo
  echo "${C_BOLD}${C_CYAN}Oluşturma özeti${C_RESET}"
  echo "  Disk             : $disk"
  echo "  Partition table  : $pttype"
  echo "  Yapı tipi        : $(structure_label "$structure")"
  echo "  Filesystem       : $fstype"
  echo "  Partition boyutu : ${final_gb} GB"
  echo "  Mountpoint       : $mountpoint"
  echo

  if [ "$structure" = "lvm" ]; then
    if [ -n "$CLI_VG_NAME" ]; then
      vg_name="$CLI_VG_NAME"
    else
      ask_identifier "Yeni VG adı ne olsun?"
      rc=$?
      [ "$rc" -eq "$RET_MENU" ] && return 0
      vg_name="$REPLY_VALUE"
    fi

    if [ -n "$CLI_LV_NAME" ]; then
      lv_name="$CLI_LV_NAME"
    else
      ask_identifier "Yeni LV adı ne olsun?"
      rc=$?
      [ "$rc" -eq "$RET_MENU" ] && return 0
      lv_name="$REPLY_VALUE"
    fi

    vg_exists "$vg_name" && fatal "VG adı zaten mevcut: $vg_name"
    lv_path="/dev/${vg_name}/${lv_name}"

    echo
    echo "${C_BOLD}${C_CYAN}LVM detayları${C_RESET}"
    echo "  VG : $vg_name"
    echo "  LV : $lv_name"
    echo "  LV path : $lv_path"
    echo
  fi

  preflight_report "create-${structure}" "" "$disk" "$fstype" "$mountpoint"

  confirm "$disk için önce partition table yedeği alınsın mı?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && fatal "Yedek alınmadan devam edilmedi."

  backup_partition_table "$disk" 1 || fatal "Partition table yedeği alınamadı."

  validate_partition_create_plan "$disk" "$final_bytes" "$structure" || return 1
  predicted_new_part="$REPLY_VALUE"
  show_action_validation_result "Yeni partition oluşturma" "$disk" "yeni partition=$predicted_new_part boyut=${final_gb}GB yapı=$(structure_label "$structure")" || return 1

  confirm "Dry-run başarılı. Yeni partition oluşturma işlemi başlatılsın mı?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  create_partition_at_disk_end "$disk" "$final_bytes" "$structure"
  new_part="$REPLY_VALUE"

  if [ "$structure" = "normal" ]; then
    validate_filesystem_create_plan "$new_part" "$fstype" || return 1
    show_action_validation_result "Filesystem oluşturma" "$new_part" "fstype=$fstype" || return 1

    confirm "Dry-run başarılı. $new_part üzerinde $fstype filesystem oluşturulsun mu?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1

    info "Filesystem oluşturuluyor..."
    mkfs_for_type "$new_part" "$fstype"

    validate_mount_persist_plan "$new_part" "$mountpoint" "$fstype" || return 1
    show_action_validation_result "Mount + fstab yapılandırma" "$new_part" "mountpoint=$mountpoint fstype=$fstype" || return 1

    confirm "Dry-run başarılı. $new_part mount edilip /etc/fstab içine eklensin mi?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1

    info "Mount ve fstab yapılandırılıyor..."
    mount_and_persist_device "$new_part" "$mountpoint" "$fstype"

    ok "Yeni bağımsız partition oluşturuldu."
    echo "  Partition   : $new_part"
    echo "  Filesystem  : $fstype"
    echo "  Boyut       : ${final_gb} GB"
    echo "  Mountpoint  : $mountpoint"
    echo
    audit "create-normal disk=$disk part=$new_part fs=$fstype mountpoint=$mountpoint size_gb=$final_gb"
    return 0
  fi

  validate_lvm_create_plan "$new_part" "$vg_name" "$lv_name" || return 1
  show_action_validation_result "LVM yapı oluşturma" "$new_part" "vg=$vg_name lv=$lv_name" || return 1

  confirm "Dry-run başarılı. pvcreate + vgcreate + lvcreate adımları uygulansın mı?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  info "LVM yapısı hazırlanıyor..."
  run_cmd pvcreate "$new_part" || fatal "pvcreate başarısız oldu."
  run_cmd vgcreate "$vg_name" "$new_part" || fatal "vgcreate başarısız oldu."
  backup_lvm_metadata "$vg_name" >/dev/null 2>&1 || true
  run_cmd lvcreate -l 100%FREE -n "$lv_name" "$vg_name" || fatal "lvcreate başarısız oldu."

  validate_filesystem_create_plan "$lv_path" "$fstype" || return 1
  show_action_validation_result "Filesystem oluşturma" "$lv_path" "fstype=$fstype" || return 1

  confirm "Dry-run başarılı. $lv_path üzerinde $fstype filesystem oluşturulsun mu?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  info "LV üzerine filesystem oluşturuluyor..."
  mkfs_for_type "$lv_path" "$fstype"

  validate_mount_persist_plan "$lv_path" "$mountpoint" "$fstype" || return 1
  show_action_validation_result "Mount + fstab yapılandırma" "$lv_path" "mountpoint=$mountpoint fstype=$fstype" || return 1

  confirm "Dry-run başarılı. $lv_path mount edilip /etc/fstab içine eklensin mi?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  info "Mount ve fstab yapılandırılıyor..."
  mount_and_persist_device "$lv_path" "$mountpoint" "$fstype"

  ok "Yeni LVM yapısı oluşturuldu."
  echo "  PV          : $new_part"
  echo "  VG          : $vg_name"
  echo "  LV          : $lv_path"
  echo "  Filesystem  : $fstype"
  echo "  Boyut       : ${final_gb} GB"
  echo "  Mountpoint  : $mountpoint"
  echo
  audit "create-lvm disk=$disk pv=$new_part vg=$vg_name lv=$lv_path fs=$fstype mountpoint=$mountpoint size_gb=$final_gb"
}

###############################################################################
# Bağımsız partition grow
###############################################################################

grow_last_partition_exact() {
  local part disk fstype mnt
  local current_bytes current_gb
  local target_gb target_bytes final_bytes final_gb validated_bytes rc

  title "Bağımsız partition büyütme"
  echo "Açıklama: Yalnızca diskin son partition'ını hedef boyuta kadar büyütür, ardından filesystem'i genişletir."
  echo

  if [ -n "$CLI_TARGET" ]; then
    part="$CLI_TARGET"
    resolve_partition_selection "$part" || fatal "Geçersiz partition: $part"
    part="$REPLY_VALUE"
  else
    select_partition_for_ops
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    part="$REPLY_VALUE"
  fi

  disk="$(get_parent_disk "$part")" || fatal "Parent disk bulunamadı."
  fstype="$(get_fstype "$part")"
  mnt="$(get_mountpoint "$part")"
  current_bytes="$(blockdev --getsize64 "$part")"
  current_gb="$(bytes_to_gb "$current_bytes")"

  [ -n "$fstype" ] || fatal "Filesystem tipi bulunamadı."
  case "$fstype" in
    ext4|xfs) ;;
    *) fatal "Bu büyütme akışında yalnızca ext4 ve xfs desteklenir." ;;
  esac

  detect_unsupported_topology "$part" && fatal "Desteklenmeyen topoloji: $REPLY_VALUE"

  echo
  echo "  Partition     : $part"
  echo "  Disk          : $disk"
  echo "  Filesystem    : $fstype"
  echo "  Mountpoint    : ${mnt:--}"
  echo "  Mevcut boyut  : ${current_gb} GB"
  echo

  preflight_report "grow-part" "$part" "$disk" "$fstype" "$mnt"

  if [ -n "$CLI_SIZE_GB" ]; then
    target_gb="$CLI_SIZE_GB"
  else
    confirm "$part için hedef boyut girme adımına geçilsin mi?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1

    ask_numeric_gb "Partition kaç GB olsun?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    target_gb="$REPLY_VALUE"
  fi

  target_bytes="$(gb_to_bytes "$target_gb")"

  if [ "$target_bytes" -lt "$current_bytes" ]; then
    fatal "Girilen hedef mevcut boyuttan küçük olamaz."
  fi

  if [ "$target_bytes" -eq "$current_bytes" ]; then
    ok "Partition zaten hedef boyutta."
    return 0
  fi

  validate_partition_growth_plan "$part" "$target_bytes" "$fstype" "$mnt" || return 1
  validated_bytes="$REPLY_VALUE"
  show_dry_run_validation_result "Bağımsız partition büyütme" "$part" "$current_bytes" "$target_bytes" "$validated_bytes" || return 1

  confirm "$disk için önce partition table yedeği alınsın mı?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && fatal "Yedek alınmadan devam edilmedi."

  backup_partition_table "$disk" 1 || fatal "Partition table yedeği alınamadı."

  confirm "Dry-run başarılı. $part büyütülsün ve ardından filesystem genişletilsin mi?"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  [ "$rc" -ne 0 ] && return 1

  grow_partition_to_target_bytes "$part" "$target_bytes"
  final_bytes="$REPLY_VALUE"
  final_gb="$(bytes_to_gb "$final_bytes")"

  if [ "$final_bytes" -le "$current_bytes" ]; then
    warn "Partition daha fazla büyütülemedi."
    return 1
  fi

  grow_filesystem "$part" "$fstype" "$mnt"

  ok "İşlem tamamlandı."
  echo "  Partition      : $part"
  echo "  Ulaşılan boyut : ${final_gb} GB"
  echo
  audit "grow-part part=$part disk=$disk old_gb=$current_gb new_gb=$final_gb fs=$fstype mountpoint=${mnt:--}"
}

###############################################################################
# LVM full grow chain
###############################################################################

grow_lvm_lv_full_chain() {
  local lv vg_name lv_name fstype mnt
  local current_lv_bytes current_lv_gb vg_free_bytes vg_free_gb max_direct_bytes
  local target_gb target_bytes
  local final_target_bytes final_target_gb
  local need_extra_bytes
  local pv pv_type pv_size_bytes pv_free_bytes
  local part_current_bytes pv_max_partition_bytes pv_possible_additional_bytes
  local desired_partition_bytes actual_partition_bytes
  local post_pvresize_vg_free_bytes achievable_lv_max_bytes
  local lv_target_for_extend_string
  local validated_target_bytes validated_partition_bytes rc

  title "LVM tam zincir büyütme"
  echo "Açıklama: Gerekirse alttaki PV partition'ını büyütür, ardından pvresize, lvextend ve filesystem grow yapar."
  echo

  if [ -n "$CLI_TARGET" ]; then
    lv="$CLI_TARGET"
    resolve_lvm_selection "$lv" || fatal "Geçersiz LVM LV: $lv"
    lv="$REPLY_VALUE"
  else
    select_lvm_for_ops
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    lv="$REPLY_VALUE"
  fi

  vg_name="$(get_lv_vg_name "$lv")"
  lv_name="$(get_lv_name "$lv")"
  fstype="$(get_fstype "$lv")"
  mnt="$(get_mountpoint "$lv")"

  [ -n "$vg_name" ] || fatal "VG adı okunamadı."
  [ -n "$lv_name" ] || fatal "LV adı okunamadı."
  [ -n "$fstype" ] || fatal "Filesystem tipi okunamadı."
  case "$fstype" in
    ext4|xfs) ;;
    *) fatal "Bu büyütme akışında yalnızca ext4 ve xfs desteklenir." ;;
  esac

  current_lv_bytes="$(get_lv_size_bytes "$lv")"
  vg_free_bytes="$(get_vg_free_bytes "$vg_name")"

  [ -n "$current_lv_bytes" ] || fatal "LV boyutu okunamadı."
  [ -n "$vg_free_bytes" ] || fatal "VG boş alanı okunamadı."

  current_lv_gb="$(bytes_to_gb "$current_lv_bytes")"
  vg_free_gb="$(bytes_to_gb "$vg_free_bytes")"
  max_direct_bytes=$((current_lv_bytes + vg_free_bytes))

  echo
  echo "  LV path             : $lv"
  echo "  VG                  : $vg_name"
  echo "  LV                  : $lv_name"
  echo "  Filesystem          : $fstype"
  echo "  Mountpoint          : ${mnt:--}"
  echo "  LV mevcut boyut     : ${current_lv_gb} GB"
  echo "  VG mevcut boş alan  : ${vg_free_gb} GB"
  echo

  if [ "$fstype" = "xfs" ] && [ -z "$mnt" ]; then
    fatal "XFS için mountpoint gerekli."
  fi

  preflight_report "grow-lvm" "$lv" "" "$fstype" "$mnt"

  if [ -n "$CLI_SIZE_GB" ]; then
    target_gb="$CLI_SIZE_GB"
  else
    confirm "$lv için hedef boyut girme adımına geçilsin mi?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1

    ask_numeric_gb "LVM logical volume kaç GB olsun?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    target_gb="$REPLY_VALUE"
  fi
  target_bytes="$(gb_to_bytes "$target_gb")"

  if [ "$target_bytes" -lt "$current_lv_bytes" ]; then
    fatal "Girilen hedef mevcut LV boyutundan küçük olamaz."
  fi

  if [ "$target_bytes" -eq "$current_lv_bytes" ]; then
    ok "LV zaten hedef boyutta."
    return 0
  fi

  backup_lvm_metadata "$vg_name" >/dev/null 2>&1 || true

  if [ "$target_bytes" -le "$max_direct_bytes" ]; then
    final_target_bytes="$target_bytes"
    final_target_gb="$(bytes_to_gb "$final_target_bytes")"

    echo
    echo "  Akış              : Doğrudan lvextend + filesystem grow"
    echo "  LV                : $lv"
    echo "  Hedef boyut       : ${final_target_gb} GB"
    echo

    validate_lvm_growth_plan "$lv" "$target_bytes" "$fstype" "$mnt" || return 1
    validated_target_bytes="$REPLY_VALUE"
    show_dry_run_validation_result "LVM doğrudan büyütme" "$lv" "$current_lv_bytes" "$target_bytes" "$validated_target_bytes" || return 1

    confirm "Dry-run başarılı. $lv doğrudan ${final_target_gb} GB boyutuna yükseltilecek. Gerçek işlem uygulansın mı?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1

    lv_target_for_extend_string="${final_target_bytes}B"
    run_cmd lvextend -L "$lv_target_for_extend_string" "$lv" || fatal "lvextend başarısız oldu."
    grow_filesystem "$lv" "$fstype" "$mnt"

    ok "LVM büyütme işlemi tamamlandı."
    echo "  LV                : $lv"
    echo "  Yeni boyut        : ${final_target_gb} GB"
    echo
    audit "grow-lvm-direct lv=$lv vg=$vg_name old_gb=$current_lv_gb new_gb=$final_target_gb fs=$fstype mountpoint=${mnt:--}"
    return 0
  fi

  need_extra_bytes=$((target_bytes - max_direct_bytes))

  echo
  warn "VG içinde doğrudan yeterli boş alan yok."
  echo "Hedefe ulaşmak için ek olarak en az $(bytes_to_human "$need_extra_bytes") alan gerekiyor."
  echo

  select_vg_pv_for_ops "$vg_name"
  rc=$?
  [ "$rc" -eq "$RET_MENU" ] && return 0
  pv="$REPLY_VALUE"

  pv_type="$(lsblk -no TYPE "$pv" 2>/dev/null | head -n1 | awk '{$1=$1;print}')"
  [ "$pv_type" = "part" ] || fatal "Seçilen PV bir partition değil. Bu script yalnızca partition tabanlı PV topolojisini otomatik büyütür."

  pv_size_bytes="$(get_pv_size_bytes "$pv")"
  pv_free_bytes="$(get_pv_free_bytes "$pv")"
  part_current_bytes="$(blockdev --getsize64 "$pv")"

  [ -n "$pv_size_bytes" ] || fatal "PV boyutu okunamadı."
  [ -n "$part_current_bytes" ] || fatal "PV partition boyutu okunamadı."

  local disk partnum sfdisk_line start_sector current_sectors sector_size disk_bytes
  local total_sectors part_end_sector free_after_sectors max_sectors

  disk="$(get_parent_disk "$pv")" || fatal "PV için parent disk bulunamadı."
  partnum="$(get_partnum "$pv")"
  [ -n "$partnum" ] || fatal "PV partition numarası bulunamadı."

  if ! is_last_partition_on_disk "$disk" "$pv"; then
    fatal "Seçilen PV partition diskin son partition'ı değil. Güvenli otomatik zincir büyütme için yalnızca son partition desteklenir."
  fi

  sfdisk_line="$(get_sfdisk_line "$disk" "$pv")"
  [ -n "$sfdisk_line" ] || fatal "PV partition bilgisi sfdisk ile okunamadı."
  start_sector="$(get_start_sector_from_line "$sfdisk_line")"
  current_sectors="$(get_size_sector_from_line "$sfdisk_line")"
  sector_size="$(blockdev --getss "$disk")"
  disk_bytes="$(blockdev --getsize64 "$disk")"

  total_sectors=$((disk_bytes / sector_size))
  part_end_sector=$((start_sector + current_sectors))
  free_after_sectors=$((total_sectors - part_end_sector))
  [ "$free_after_sectors" -lt 0 ] && free_after_sectors=0
  max_sectors=$((current_sectors + free_after_sectors))
  pv_max_partition_bytes=$((max_sectors * sector_size))
  pv_possible_additional_bytes=$((pv_max_partition_bytes - part_current_bytes))
  [ "$pv_possible_additional_bytes" -lt 0 ] && pv_possible_additional_bytes=0

  echo "Seçilen PV detayları:"
  echo "  PV                  : $pv"
  echo "  Parent disk         : $disk"
  echo "  PV mevcut boyut     : $(bytes_to_human "$pv_size_bytes")"
  echo "  Partition boyutu    : $(bytes_to_human "$part_current_bytes")"
  echo "  Partition ek büyüme : $(bytes_to_human "$pv_possible_additional_bytes")"
  echo

  if [ "$pv_possible_additional_bytes" -le 0 ]; then
    warn "Seçilen PV partition için ek büyüme alanı yok."
    achievable_lv_max_bytes="$max_direct_bytes"
  else
    desired_partition_bytes=$((part_current_bytes + need_extra_bytes))
    if [ "$desired_partition_bytes" -gt "$pv_max_partition_bytes" ]; then
      desired_partition_bytes="$pv_max_partition_bytes"
    fi

    echo "Zincir büyütme özeti:"
    echo "  1) PV partition büyütülecek"
    echo "  2) vgcfgbackup"
    echo "  3) pvresize"
    echo "  4) lvextend"
    echo "  5) filesystem büyütülecek"
    echo

    validate_partition_growth_plan "$pv" "$desired_partition_bytes" "$fstype" "$mnt" || return 1
    validated_partition_bytes="$REPLY_VALUE"
    show_dry_run_validation_result "PV partition büyütme" "$pv" "$part_current_bytes" "$desired_partition_bytes" "$validated_partition_bytes" || return 1

    confirm "$disk için önce partition table yedeği alınsın mı?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && fatal "Yedek alınmadan devam edilmedi."

    backup_partition_table "$disk" 1 || fatal "Partition table yedeği alınamadı."
    backup_lvm_metadata "$vg_name" >/dev/null 2>&1 || true

    confirm "Dry-run başarılı. Önce $pv partition'ı büyütülsün mü?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1

    grow_partition_to_target_bytes "$pv" "$desired_partition_bytes"
    actual_partition_bytes="$REPLY_VALUE"

    if [ "$actual_partition_bytes" -le "$part_current_bytes" ]; then
      warn "PV partition daha fazla büyütülemedi."
    else
      info "pvresize çalıştırılıyor..."
      run_cmd pvresize "$pv" || fatal "pvresize başarısız oldu."
    fi

    post_pvresize_vg_free_bytes="$(get_vg_free_bytes "$vg_name")"
    [ -n "$post_pvresize_vg_free_bytes" ] || fatal "pvresize sonrası VG boş alanı okunamadı."
    achievable_lv_max_bytes=$((current_lv_bytes + post_pvresize_vg_free_bytes))

    validate_lvm_post_pv_growth_plan "$lv" "$target_bytes" "$current_lv_bytes" "$fstype" "$mnt" "$vg_name" || return 1
    validated_target_bytes="$REPLY_VALUE"
    show_dry_run_validation_result "PV sonrası LVM büyütme" "$lv" "$current_lv_bytes" "$target_bytes" "$validated_target_bytes" || return 1

    confirm "Dry-run başarılı. Şimdi pvresize sonrası lvextend + filesystem grow adımları uygulansın mı?"
    rc=$?
    [ "$rc" -eq "$RET_MENU" ] && return 0
    [ "$rc" -ne 0 ] && return 1
  fi

  if [ "$target_bytes" -gt "$achievable_lv_max_bytes" ]; then
    warn "Hedefe tam ulaşılamadı. LV mümkün olan en yüksek değere çıkarılacak."
    final_target_bytes="$achievable_lv_max_bytes"
  else
    final_target_bytes="$target_bytes"
  fi

  if [ "$final_target_bytes" -le "$current_lv_bytes" ]; then
    fatal "LVM zincir büyütme sonrası LV için büyütülebilir alan kalmadı."
  fi

  final_target_gb="$(bytes_to_gb "$final_target_bytes")"
  lv_target_for_extend_string="${final_target_bytes}B"

  info "lvextend çalıştırılıyor..."
  run_cmd lvextend -L "$lv_target_for_extend_string" "$lv" || fatal "lvextend başarısız oldu."

  info "Filesystem büyütülüyor..."
  grow_filesystem "$lv" "$fstype" "$mnt"

  ok "LVM tam zincir büyütme tamamlandı."
  echo "  LV                : $lv"
  echo "  Yeni boyut        : ${final_target_gb} GB"
  echo
  audit "grow-lvm-chain lv=$lv vg=$vg_name pv=$pv old_gb=$current_lv_gb new_gb=$final_target_gb fs=$fstype mountpoint=${mnt:--}"
}

###############################################################################
# CLI action dispatcher
###############################################################################

run_cli_action() {
  case "$CLI_ACTION" in
    "")
      return 1
      ;;
    create)
      create_new_partition_flow
      ;;
    grow-part)
      grow_last_partition_exact
      ;;
    grow-lvm)
      grow_lvm_lv_full_chain
      ;;
    health-disk)
      show_disk_health
      ;;
    health-part)
      show_partition_health
      ;;
    selftest)
      run_loopback_test_lab
      ;;
    backup-pt)
      [ -n "$CLI_DISK" ] || fatal "--disk gerekli"
      resolve_disk_selection "$CLI_DISK" || fatal "Geçersiz disk: $CLI_DISK"
      backup_partition_table "$REPLY_VALUE"
      ;;
    restore-pt)
      [ -n "$CLI_BACKUP_FILE" ] || fatal "--backup-file gerekli"
      restore_partition_table_from_backup
      ;;
    reread-pt)
      [ -n "$CLI_DISK" ] || fatal "--disk gerekli"
      resolve_disk_selection "$CLI_DISK" || fatal "Geçersiz disk: $CLI_DISK"
      reread_partition_table "$REPLY_VALUE"
      ;;
    unmount)
      [ -n "$CLI_TARGET" ] || fatal "--target gerekli"
      if ! mountpoint -q "$CLI_TARGET" 2>/dev/null; then
        fatal "Geçersiz mountpoint: $CLI_TARGET"
      fi
      REPLY_VALUE="$CLI_TARGET"
      unmount_target_flow
      ;;
    remove-fstab)
      [ -n "$CLI_TARGET" ] || fatal "--target gerekli"
      REPLY_VALUE="$CLI_TARGET"
      remove_fstab_entry_flow
      ;;
    unmount-clean)
      [ -n "$CLI_TARGET" ] || fatal "--target gerekli"
      if ! mountpoint -q "$CLI_TARGET" 2>/dev/null; then
        fatal "Geçersiz mountpoint: $CLI_TARGET"
      fi
      REPLY_VALUE="$CLI_TARGET"
      unmount_and_remove_fstab_flow
      ;;
    *)
      fatal "Desteklenmeyen --action: $CLI_ACTION"
      ;;
  esac

  exit 0
}

###############################################################################
# Menu
###############################################################################

print_menu() {
  title "Yapılabilecek işlemler"
  echo "  ${C_CYAN}1)${C_RESET}  Araç kontrolü                     - Gerekli komutların sistemde olup olmadığını kontrol eder."
  echo "  ${C_CYAN}2)${C_RESET}  Gerekli araçları kur              - Eksik paketleri dağıtıma uygun paket yöneticisi ile kurar."
  echo "  ${C_CYAN}3)${C_RESET}  Disk/partition listele            - Diskleri, partitionları ve mount bilgilerini gösterir."
  echo "  ${C_CYAN}4)${C_RESET}  Filesystem kullanımını göster     - df -hT çıktısını gösterir."
  echo "  ${C_CYAN}5)${C_RESET}  Detaylı block device özeti        - lsblk ile topolojiyi detaylı gösterir."
  echo "  ${C_CYAN}6)${C_RESET}  Mount ve fstab özetini göster     - Mount edilmiş targetları ve fstab içeriğini gösterir."
  echo "  ${C_CYAN}7)${C_RESET}  Disk sağlık özetini göster        - SMART varsa disk sağlık verilerini ve temel durum sinyallerini gösterir."
  echo "  ${C_CYAN}8)${C_RESET}  Partition sağlık özetini göster   - Filesystem dry-run kontrolleri ve mount sağlık sinyallerini gösterir."
  echo "  ${C_CYAN}9)${C_RESET}  Güvenli loopback test laboratuvarı - Geçici loop device üzerinde güvenli self-test yapar."
  echo "  ${C_CYAN}10)${C_RESET} Partition table yedeği al         - Seçilen disk için sfdisk yedeği alır."
  echo "  ${C_CYAN}11)${C_RESET} Partition table geri yükle        - Daha önce alınan sfdisk yedeğini diske geri yükler."
  echo "  ${C_CYAN}12)${C_RESET} Partition table yeniden okut      - Kernel'e partition tablosunu yeniden okutmayı dener."
  echo "  ${C_CYAN}13)${C_RESET} Yeni partition oluştur            - Bağımsız partition veya LVM yapıda yeni partition oluşturur, mount eder, fstab'a ekler."
  echo "  ${C_CYAN}14)${C_RESET} Bağımsız partition büyüt         - Son partition'ı büyütür ve filesystem'i genişletir."
  echo "  ${C_CYAN}15)${C_RESET} LVM tam zincir büyüt              - PV grow + pvresize + lvextend + filesystem grow."
  echo "  ${C_CYAN}16)${C_RESET} Mount kaldır                       - Seçilen mountpoint'i unmount eder."
  echo "  ${C_CYAN}17)${C_RESET} fstab kaydı sil                    - Seçilen fstab kaydını siler."
  echo "  ${C_CYAN}18)${C_RESET} Mount kaldır + fstab temizle       - Unmount eder ve fstab kaydını siler."
  echo "  ${C_CYAN}19)${C_RESET} Çıkış                             - Script'ten çıkar."
  echo
}

main_loop() {
  local choice disk rc

  while true; do
    print_menu
    ask_menu_choice "Yapmak istediğiniz işlemi seçin [1-19]" 1 19
    choice="$REPLY_VALUE"
    echo

    case "$choice" in
      1)
        show_tool_check || true
        pause_enter
        ;;
      2)
        install_required_tools
        pause_enter
        ;;
      3)
        list_disks_and_partitions
        pause_enter
        ;;
      4)
        show_disk_usage
        pause_enter
        ;;
      5)
        show_block_details
        pause_enter
        ;;
      6)
        show_mount_table
        pause_enter
        ;;
      7)
        show_disk_health
        pause_enter
        ;;
      8)
        show_partition_health
        pause_enter
        ;;
      9)
        run_loopback_test_lab
        pause_enter
        ;;
      10)
        select_disk_for_generic_ops
        rc=$?
        [ "$rc" -eq "$RET_MENU" ] && continue
        disk="$REPLY_VALUE"
        backup_partition_table "$disk"
        rc=$?
        [ "$rc" -eq "$RET_MENU" ] && continue
        pause_enter
        ;;
      11)
        restore_partition_table_from_backup
        pause_enter
        ;;
      12)
        select_disk_for_generic_ops
        rc=$?
        [ "$rc" -eq "$RET_MENU" ] && continue
        disk="$REPLY_VALUE"
        reread_partition_table "$disk"
        pause_enter
        ;;
      13)
        create_new_partition_flow
        pause_enter
        ;;
      14)
        grow_last_partition_exact
        pause_enter
        ;;
      15)
        grow_lvm_lv_full_chain
        pause_enter
        ;;
      16)
        unmount_target_flow
        pause_enter
        ;;
      17)
        remove_fstab_entry_flow
        pause_enter
        ;;
      18)
        unmount_and_remove_fstab_flow
        pause_enter
        ;;
      19)
        quit_now
        ;;
    esac

    clear 2>/dev/null || true
    print_banner
  done
}

###############################################################################
# Main
###############################################################################

main() {
  require_root
  ensure_dirs
  print_banner
  startup_tool_check
  startup_health_check

  if [ -n "$CLI_ACTION" ]; then
    run_cli_action
    return $?
  fi

  main_loop
}

main "$@"
