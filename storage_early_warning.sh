#!/usr/bin/env bash
# storage_early_warning.sh
# Read-only storage early-warning checks for Linux (Debian-focused).
#
# Copyright (c) 2026, Mnheia <mnheia@gmail.com>
#
# This module is free software; you can redistribute it and/or modify it
# under the terms of GNU general public license (gpl) version 3.
# See the LICENSE file for details.
# Detects: disk space/inodes, SMART/NVMe health, mdadm RAID, ZFS, BTRFS, LVM, kernel storage errors.
#
# Exit codes:
#   0 = OK
#   1 = WARN (action recommended)
#   2 = CRIT (action required)
#   3 = UNKNOWN (missing tools / partial checks)
#
# Optional env:
#   WARN_DISK_PCT=80        CRIT_DISK_PCT=90
#   WARN_INODE_PCT=80       CRIT_INODE_PCT=90
#   SMART_WARN_TEMP=55      SMART_CRIT_TEMP=65
#   REPORT_JSON=1           # prints JSON-ish summary at end (lightweight)
#
# Notes:
# - Requires root for fullest SMART/NVMe coverage.
# - Uses best-effort: if a tool is missing, continues and marks UNKNOWN.

set -Eeuo pipefail

WARN_DISK_PCT="${WARN_DISK_PCT:-80}"
CRIT_DISK_PCT="${CRIT_DISK_PCT:-90}"
WARN_INODE_PCT="${WARN_INODE_PCT:-80}"
CRIT_INODE_PCT="${CRIT_INODE_PCT:-90}"
SMART_WARN_TEMP="${SMART_WARN_TEMP:-55}"
SMART_CRIT_TEMP="${SMART_CRIT_TEMP:-65}"
REPORT_JSON="${REPORT_JSON:-0}"

STATUS=0 # 0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN

info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; [[ $STATUS -lt 1 ]] && STATUS=1; }
crit() { echo "CRIT: $*"; STATUS=2; }
unk()  { echo "UNKN: $*"; [[ $STATUS -lt 3 ]] && STATUS=3; }

have() { command -v "$1" >/dev/null 2>&1; }

# --- helpers ---
pct_from_df_line() {
  # expects "Use%" field like "85%"
  local p="$1"
  p="${p%\%}"
  [[ "$p" =~ ^[0-9]+$ ]] && echo "$p" || echo ""
}

check_df_space() {
  echo "== Filesystem usage (space) =="
  # df -PTh columns:
  # 1 Filesystem, 2 Type, 3 Size, 4 Used, 5 Avail, 6 Use%, 7 Mounted on
  local line fs usep mp p
  while IFS= read -r line; do
    fs=$(awk '{print $1}' <<<"$line")
    usep=$(awk '{print $6}' <<<"$line")
    mp=$(awk '{print $7}' <<<"$line")
    p=$(pct_from_df_line "$usep") || p=""
    [[ -z "${p:-}" ]] && continue

    if (( p >= CRIT_DISK_PCT )); then
      crit "Disk usage ${p}% on ${mp} (${fs})"
    elif (( p >= WARN_DISK_PCT )); then
      warn "Disk usage ${p}% on ${mp} (${fs})"
    else
      echo "OK:  Disk usage ${p}% on ${mp} (${fs})"
    fi
  done < <(df -PTh \
    -x tmpfs -x devtmpfs -x squashfs -x overlay -x aufs -x ramfs -x nsfs -x fusectl -x tracefs 2>/dev/null | tail -n +2)
}

check_df_inodes() {
  echo "== Filesystem usage (inodes) =="
  # df -PiPT columns:
  # 1 Filesystem, 2 Type, 3 Inodes, 4 IUsed, 5 IFree, 6 IUse%, 7 Mounted on
  local line fs usep mp p
  while IFS= read -r line; do
    fs=$(awk '{print $1}' <<<"$line")
    usep=$(awk '{print $6}' <<<"$line")
    mp=$(awk '{print $7}' <<<"$line")
    p=$(pct_from_df_line "$usep") || p=""
    [[ -z "${p:-}" ]] && continue

    if (( p >= CRIT_INODE_PCT )); then
      crit "Inode usage ${p}% on ${mp} (${fs})"
    elif (( p >= WARN_INODE_PCT )); then
      warn "Inode usage ${p}% on ${mp} (${fs})"
    else
      echo "OK:  Inode usage ${p}% on ${mp} (${fs})"
    fi
  done < <(df -PiPT \
    -x tmpfs -x devtmpfs -x squashfs -x overlay -x aufs -x ramfs -x nsfs -x fusectl -x tracefs 2>/dev/null | tail -n +2)
}

check_kernel_storage_errors() {
  echo "== Kernel storage error hints (last boot) =="

  local patterns=(
    "I/O error"
    "blk_update_request"
    "Buffer I/O error"
    "EXT4-fs error"
    "XFS.*corrupt"
    "BTRFS.*error"
    "zfs.*checksum"
    "md.*degrad"
    "ata[0-9].*failed"
    "nvme.*reset"
    "SCSI error"
    "Medium Error"
    "Unrecovered read error"
  )

  local combined_pattern
  combined_pattern="$(IFS="|"; echo "${patterns[*]}")"

  if have journalctl; then
    local kernel_log
    kernel_log="$(journalctl -k -b --no-pager 2>/dev/null || true)"

    if grep -Eiq "$combined_pattern" <<<"$kernel_log"; then
      warn "Kernel log contains storage-related error patterns. Review: journalctl -k -b"
    else
      echo "OK:  No common storage error patterns detected in kernel journal current boot."
    fi
  elif have dmesg; then
    local dmesg_log
    dmesg_log="$(dmesg 2>/dev/null || true)"

    if grep -Eiq "$combined_pattern" <<<"$dmesg_log"; then
      warn "dmesg contains storage-related error patterns. Review: dmesg"
    else
      echo "OK:  No common storage error patterns detected in dmesg."
    fi
  else
    unk "Neither journalctl nor dmesg found; cannot check kernel storage errors."
  fi
}

list_block_devices() {
  # Returns "KNAME TYPE TRAN" for disk-ish devices
  # Prefer lsblk, fallback to /sys
  if have lsblk; then
    # KNAME like sda/nvme0n1, TYPE disk
    lsblk -dn -o KNAME,TYPE,TRAN 2>/dev/null | awk '$2=="disk"{print $1" "$2" "$3}'
  else
    unk "lsblk not found; SMART/NVMe coverage will be limited."
    return 1
  fi
}

smart_check_one() {
  local dev="/dev/$1"
  # smartctl -H gives overall health, -A gives attributes
  local out health temp

  if ! have smartctl; then
    unk "smartctl not found; install smartmontools for SMART checks."
    return 1
  fi

  # Some devices (e.g., behind certain USB bridges) may need -d sat/usbjmicron etc.
  # We keep it conservative: try default; if it fails, warn.
  if ! out=$(smartctl -H -A "$dev" 2>/dev/null); then
    warn "SMART query failed for ${dev} (possibly needs smartctl -d <type> or insufficient permissions)."
    return 0
  fi

  if grep -Eiq "SMART overall-health self-assessment test result:\s*FAILED|SMART Health Status:\s*FAIL" <<<"$out"; then
    crit "SMART overall health FAILED on ${dev}"
  elif grep -Eiq "SMART overall-health self-assessment test result:\s*PASSED|SMART Health Status:\s*OK" <<<"$out"; then
    echo "OK:  SMART overall health OK on ${dev}"
  else
    # Some NVMe show different wording; treat as unknown
    warn "SMART overall health not clearly reported on ${dev}"
  fi

  # Temperature (best-effort)
  # ATA SMART attribute lines often start with an ID, for example:
  # 194 Temperature_Celsius ... 39
  # The first number is the attribute ID, not the temperature.
  temp=$(awk '
    /^194[[:space:]]+Temperature_Celsius|^190[[:space:]]+Airflow_Temperature_Cel/ {
      for(i=NF;i>=1;i--){
        if($i ~ /^[0-9]+$/){ print $i; exit }
      }
    }
    /Current Drive Temperature:/ {
      for(i=1;i<=NF;i++){
        if($i ~ /^[0-9]+$/){ print $i; exit }
      }
    }
    /^Temperature:/ {
      for(i=1;i<=NF;i++){
        if($i ~ /^[0-9]+$/){ print $i; exit }
      }
    }
  ' <<<"$out" | head -n1)

  if [[ -n "${temp:-}" ]]; then
    if (( temp >= SMART_CRIT_TEMP )); then
      crit "High disk temperature ${temp}C on ${dev}"
    elif (( temp >= SMART_WARN_TEMP )); then
      warn "Elevated disk temperature ${temp}C on ${dev}"
    else
      echo "OK:  Disk temperature ${temp}C on ${dev}"
    fi
  fi

  # Classic early-failure attributes (best-effort parse; not all disks expose same names)
  # We flag non-zero RAW values where meaningful.
  local realloc pend offline_unc crc
  realloc=$(awk '$2 ~ /Reallocated_Sector_Ct|Reallocated_Event_Count/ {print $10}' <<<"$out" | head -n1)
  pend=$(awk '$2 ~ /Current_Pending_Sector/ {print $10}' <<<"$out" | head -n1)
  offline_unc=$(awk '$2 ~ /Offline_Uncorrectable/ {print $10}' <<<"$out" | head -n1)
  crc=$(awk '$2 ~ /UDMA_CRC_Error_Count/ {print $10}' <<<"$out" | head -n1)

  # helper numeric compare
  is_num() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
  if is_num "$realloc" && (( realloc > 0 )); then warn "SMART: Reallocated sectors=${realloc} on ${dev}"; fi
  if is_num "$pend" && (( pend > 0 )); then crit "SMART: Pending sectors=${pend} on ${dev}"; fi
  if is_num "$offline_unc" && (( offline_unc > 0 )); then crit "SMART: Offline uncorrectable=${offline_unc} on ${dev}"; fi
  if is_num "$crc" && (( crc > 0 )); then warn "SMART: UDMA CRC errors=${crc} on ${dev} (cabling/controller noise)"; fi
}

nvme_check_all() {
  if ! have nvme; then
    # NVMe can still be queried via smartctl; nvme-cli is a bonus
    return 0
  fi

  echo "== NVMe health (nvme-cli) =="
  local dev
  for dev in /dev/nvme*n?; do
    [[ -e "$dev" ]] || continue
    local out
    if ! out=$(nvme smart-log "$dev" 2>/dev/null); then
      warn "nvme smart-log failed for ${dev}"
      continue
    fi

    # “critical_warning” non-zero is bad
    local cw
    cw=$(awk '/critical_warning/ {print $3}' <<<"$out" | head -n1)
    if [[ -n "${cw:-}" && "$cw" != "0x00" && "$cw" != "0" ]]; then
      crit "NVMe critical_warning=${cw} on ${dev}"
    else
      echo "OK:  NVMe critical_warning OK on ${dev}"
    fi

    # media_errors, num_err_log_entries
    local me el
    me=$(awk '/media_errors/ {print $3}' <<<"$out" | head -n1)
    el=$(awk '/num_err_log_entries/ {print $3}' <<<"$out" | head -n1)
    [[ "${me:-0}" =~ ^[0-9]+$ ]] && (( me > 0 )) && crit "NVMe media_errors=${me} on ${dev}"
    [[ "${el:-0}" =~ ^[0-9]+$ ]] && (( el > 0 )) && warn "NVMe error_log_entries=${el} on ${dev}"
  done
}

mdadm_check() {
  echo "== MD RAID (mdadm) =="
  if [[ -f /proc/mdstat ]]; then
    # If any array shows "_" (missing) or "degraded" indicators, warn/crit.
    local mdstat
    mdstat=$(cat /proc/mdstat 2>/dev/null || true)
    if grep -Eq '(_|\[.*U_.*\]|\[.*_U.*\])' <<<"$mdstat"; then
      crit "MD RAID appears degraded (/proc/mdstat shows missing member)."
    elif grep -Eq '^md[0-9]+' <<<"$mdstat"; then
      echo "OK:  MD arrays present and appear healthy in /proc/mdstat."
    else
      echo "OK:  No MD arrays detected."
    fi

    if have mdadm; then
      # Further detail if arrays exist
      local arrays
      arrays=$(awk '/^md[0-9]+/ {print "/dev/"$1}' /proc/mdstat 2>/dev/null || true)
      if [[ -n "${arrays:-}" ]]; then
        while IFS= read -r a; do
          [[ -z "$a" ]] && continue
          local detail
          detail=$(mdadm --detail "$a" 2>/dev/null || true)
          if grep -Eiq 'State :.*degraded|State :.*faulty' <<<"$detail"; then
            crit "MD RAID degraded/faulty: ${a}"
          fi
        done <<<"$arrays"
      fi
    else
      unk "mdadm not installed; limited MD RAID detail."
    fi
  else
    echo "OK:  /proc/mdstat not present; MD RAID not detected."
  fi
}

zfs_check() {
  echo "== ZFS health =="
  if have zpool; then
    local st
    st=$(zpool status -x 2>/dev/null || true)
    # "all pools are healthy" => OK, anything else => warn/crit
    if grep -Eiq 'all pools are healthy' <<<"$st"; then
      echo "OK:  ZFS pools healthy."
    elif grep -Eiq 'no pools available' <<<"$st"; then
      echo "OK:  No ZFS pools detected."
    elif [[ -n "$st" ]]; then
      crit "ZFS reports issues: $(head -n1 <<<"$st")"
      echo "$st" | sed 's/^/  /'
    else
      warn "ZFS tools present but could not query pool status."
    fi
  else
    echo "OK:  ZFS not detected (zpool missing)."
  fi
}

btrfs_check() {
  echo "== BTRFS health =="
  if have btrfs; then
    # Find BTRFS mount points
    local mps
    mps=$(findmnt -rn -t btrfs -o TARGET 2>/dev/null || true)
    if [[ -z "${mps:-}" ]]; then
      echo "OK:  No BTRFS mounts detected."
      return 0
    fi

    while IFS= read -r mp; do
      [[ -z "$mp" ]] && continue
      local devs errs
      devs=$(btrfs filesystem show "$mp" 2>/dev/null || true)
      errs=$(btrfs device stats "$mp" 2>/dev/null || true)

      # Basic red flags: non-zero error counters
      if awk '$2 ~ /(write_io_errs|read_io_errs|flush_io_errs|corruption_errs|generation_errs)/ && $3+0>0 {exit 1}' <<<"$errs"; then
        echo "OK:  BTRFS device stats OK on ${mp}"
      else
        crit "BTRFS reports device errors on ${mp}"
        echo "$errs" | sed 's/^/  /'
      fi

      # Degraded mode: "devid ... missing" etc.
      if grep -Eiq 'missing' <<<"$devs"; then
        crit "BTRFS appears to have missing device(s) on ${mp}"
      fi
    done <<<"$mps"
  else
    echo "OK:  BTRFS not detected (btrfs tool missing)."
  fi
}

lvm_check() {
  echo "== LVM PV/VG health =="
  if have pvs && have vgs; then
    # PV missing is critical; VG partial is warning/critical depending.
    local p
    p=$(pvs --noheadings -o pv_name,pv_attr 2>/dev/null | tr -s ' ' || true)
    if [[ -n "${p:-}" ]]; then
      # pv_attr contains 'm' for missing
      if grep -Eq ' m' <<<"$p"; then
        crit "LVM reports missing PV(s)."
      else
        echo "OK:  LVM PVs look OK."
      fi
    else
      echo "OK:  No LVM PVs detected."
    fi

    local vg
    vg=$(vgs --noheadings -o vg_name,vg_attr 2>/dev/null | tr -s ' ' || true)
    if [[ -n "${vg:-}" ]]; then
      # vg_attr 'p' partial
      if grep -Eq ' p' <<<"$vg"; then
        warn "LVM VG partial state detected."
      else
        echo "OK:  LVM VGs look OK."
      fi
    fi
  else
    echo "OK:  LVM tools not present or not in use."
  fi
}

smart_check_all_disks() {
  echo "== SMART health (smartctl) =="
  if ! have smartctl; then
    unk "smartmontools not installed; skipping SMART checks."
    return 0
  fi
  if ! have lsblk; then
    unk "lsblk missing; cannot enumerate disks for SMART checks."
    return 0
  fi

  # Enumerate disks, skip obvious virtual devices
  # TRAN may be empty; include all disks and let smartctl decide.
  local devs
  devs=$(lsblk -dn -o KNAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' || true)
  if [[ -z "${devs:-}" ]]; then
    warn "No block disks found via lsblk."
    return 0
  fi

  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    # Avoid common RAM/loop devices even though TYPE disk normally excludes them
    [[ "$d" =~ ^loop ]] && continue
    [[ "$d" =~ ^zram ]] && continue
    [[ "$d" =~ ^ram ]] && continue

    # Raspberry Pi SD/eMMC devices normally do not expose standard SMART via smartctl.
    if [[ "$d" =~ ^mmcblk ]]; then
      echo "INFO: Skipping /dev/${d}; MMC/SD storage usually has no standard SMART support."
      continue
    fi

    smart_check_one "$d" || true
  done <<<"$devs"
}

print_tooling_hint() {
  # If running non-root, be explicit.
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    warn "Not running as root; SMART/NVMe checks may be incomplete. Run with sudo for full coverage."
  fi

  # Missing optional tools should not make the whole result UNKNOWN.
  # Many hosts do not use NVMe, mdadm, BTRFS, or ZFS.
  local missing=()

  have smartctl || missing+=("smartmontools")
  have nvme || missing+=("nvme-cli")
  have mdadm || missing+=("mdadm")
  have btrfs || missing+=("btrfs-progs")

  if (( ${#missing[@]} > 0 )); then
    info "Optional tooling not found: ${missing[*]}."
    info "Install only what matches this host's storage stack."
  fi
}

main() {
  echo "### Storage Early-Warning Report $(date -Is) ###"
  echo "Host: $(hostname -f 2>/dev/null || hostname)"
  echo

  print_tooling_hint
  echo

  check_df_space
  echo
  check_df_inodes
  echo
  mdadm_check
  echo
  zfs_check
  echo
  btrfs_check
  echo
  lvm_check
  echo
  smart_check_all_disks
  echo
  nvme_check_all
  echo
  check_kernel_storage_errors
  echo

  if [[ "$REPORT_JSON" == "1" ]]; then
    echo "== Summary (JSON-ish) =="
    echo "{"
    echo "  \"status\": ${STATUS},"
    echo "  \"status_text\": \"$(case "$STATUS" in 0) echo OK;; 1) echo WARN;; 2) echo CRIT;; 3) echo UNKNOWN;; esac)\","
    echo "  \"thresholds\": {"
    echo "    \"warn_disk_pct\": ${WARN_DISK_PCT},"
    echo "    \"crit_disk_pct\": ${CRIT_DISK_PCT},"
    echo "    \"warn_inode_pct\": ${WARN_INODE_PCT},"
    echo "    \"crit_inode_pct\": ${CRIT_INODE_PCT},"
    echo "    \"smart_warn_temp\": ${SMART_WARN_TEMP},"
    echo "    \"smart_crit_temp\": ${SMART_CRIT_TEMP}"
    echo "  }"
    echo "}"
    echo
  fi

  case "$STATUS" in
    0) echo "RESULT: OK";;
    1) echo "RESULT: WARN";;
    2) echo "RESULT: CRIT";;
    3) echo "RESULT: UNKNOWN (partial checks)";;
  esac

  exit "$STATUS"
}

main "$@"
