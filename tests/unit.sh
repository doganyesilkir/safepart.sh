#!/usr/bin/env bash
set -u
set -o pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../safepart.sh
source "$ROOT_DIR/safepart.sh"

pass=0
fail=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok - %s\n' "$label"
    pass=$((pass + 1))
  else
    printf 'not ok - %s (expected=%s actual=%s)\n' "$label" "$expected" "$actual" >&2
    fail=$((fail + 1))
  fi
}

test_gpt_growth_uses_device_capacity() {
  sfdisk() {
    printf '%s\n' 'label: gpt' 'last-lba: 2047' '/dev/test1 : start=2048, size=1024, type=8300'
  }
  blockdev() {
    case "$1" in
      --getss) printf '%s\n' 512 ;;
      --getsize64) printf '%s\n' 10485760 ;;
      *) return 1 ;;
    esac
  }

  get_partitionable_end_sector_limit /dev/test
  assert_eq 20447 "$REPLY_VALUE" "GPT growth ignores stale last-lba"
  unset -f sfdisk blockdev
}

test_mbr_growth_is_lba_limited() {
  sfdisk() { printf '%s\n' 'label: dos'; }
  blockdev() {
    case "$1" in
      --getss) printf '%s\n' 512 ;;
      --getsize64) printf '%s\n' 4398046511104 ;;
      *) return 1 ;;
    esac
  }

  get_partitionable_end_sector_limit /dev/test
  assert_eq 4294967296 "$REPLY_VALUE" "MBR growth respects 32-bit LBA limit"
  unset -f sfdisk blockdev
}

test_whole_disk_pv_selection() {
  get_vg_pv_list() { printf '%s\n' '/dev/test|10g|0'; }
  get_pv_vg_name() { printf '%s\n' vg_test; }
  lsblk() { printf '%s\n' disk; }

  resolve_vg_pv_selection vg_test 1
  assert_eq /dev/test "$REPLY_VALUE" "whole-disk PV is selectable"
  unset -f get_vg_pv_list get_pv_vg_name lsblk
}

test_unclaimed_pv_space() {
  get_pv_size_bytes() { printf '%s\n' 10737418240; }
  blockdev() { printf '%s\n' 21474836480; }

  get_pv_unclaimed_bytes /dev/test
  assert_eq 10737418240 "$REPLY_VALUE" "expanded block device exposes unclaimed PV bytes"
  unset -f get_pv_size_bytes blockdev
}

test_gpt_growth_uses_device_capacity
test_mbr_growth_is_lba_limited
test_whole_disk_pv_selection
test_unclaimed_pv_space

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
