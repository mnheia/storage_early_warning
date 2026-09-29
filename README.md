Copyright (c) 2026, Mnheia <mnheia@gmail.com>

# storage_early_warning
A read-only Linux storage health and early-warning script.

It performs best-effort checks for filesystem capacity, inode usage, SMART and NVMe health, software RAID, ZFS, BTRFS, LVM and common storage-related kernel errors.

# Usage
Run it directly:

```bash
sudo ./storage_early_warning.sh
```

Thresholds can be adjusted with environment variables:

```bash
sudo env WARN_DISK_PCT=80 CRIT_DISK_PCT=90 \
  WARN_INODE_PCT=80 CRIT_INODE_PCT=90 \
  SMART_WARN_TEMP=55 SMART_CRIT_TEMP=65 \
  ./storage_early_warning.sh
```

A lightweight JSON-style summary can be enabled with:

```bash
sudo env REPORT_JSON=1 ./storage_early_warning.sh
```

# Checks
- filesystem space usage
- inode usage
- SMART health and common early-failure attributes
- NVMe health information
- mdadm software RAID state
- ZFS pool health
- BTRFS device error counters
- LVM PV/VG state
- storage-related kernel log errors

# Exit Codes
- `0` OK
- `1` WARN
- `2` CRIT
- `3` UNKNOWN / partial checks

# Requirements
The script is Bash-based and Debian-focused, but should work on many Linux distributions.

Core tools used when available include `df`, `awk`, `grep`, `sed`, `lsblk`, `findmnt`, `journalctl` and `dmesg`.

Optional tools provide additional coverage:
- `smartctl` from smartmontools
- `nvme` from nvme-cli
- `mdadm`
- `zpool`
- `btrfs`
- LVM tools (`pvs`, `vgs`)

Run as root for the fullest SMART and NVMe coverage.

# Bugs
Please report any bugs or feature requests through the web interface at https://github.com/mnheia/storage_early_warning/issues
