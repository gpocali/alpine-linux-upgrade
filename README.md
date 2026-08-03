# Alpine Linux x86_64 Upgrade

A robust, automated script to upgrade an Alpine Linux "diskless" installation on x86_64 machines to the latest stable release.

## Overview

This repository provides a highly optimized `upgrade.sh` script designed to handle the complexities of upgrading a diskless Alpine Linux environment on x86_64 hardware. It automatically targets the `x86_64` architecture, detects the active release flavor (`standard`, `virt`, `extended`, `xen`), locates your boot media, safely extracts updates directly on the boot media without exhausting system memory, preserves custom bootloader configurations (`syslinux.cfg`, `grub.cfg`), intelligently updates repository URLs, ensures network connectivity upon reboot, reinstalls your configured packages, and can even install itself as a monthly automated cron job.

## Features

* **x86_64 Architecture & Flavor Support:** Specifically targets `x86_64` systems. Automatically detects the active kernel release flavor (e.g. `virt` vs `standard`/`extended`/`xen`) or allows explicit selection using the `-f` flag (`-f virt`, `-f standard`, etc.).
* **Low-Memory Optimization:** Bypasses RAM (`tmpfs`) limitations entirely by downloading and extracting the official Alpine ISO image within a staging directory directly on the physical boot media. This prevents Out-Of-Memory (OOM) crashes on resource-constrained systems during extraction.
* **Bootloader Preservation:** Automatically backs up and restores existing `syslinux.cfg` and `grub.cfg` files on the boot partition, ensuring custom boot args, console parameters, and timeout settings are preserved across kernel upgrades.
* **Dynamic Media Detection:** Automatically scans `/media/*` and `/boot` to identify the correct Alpine boot partition (USB drive, SSD, or NVMe) by verifying the presence of essential boot files (`.alpine-release`, `syslinux.cfg`, `boot/syslinux`, `EFI/boot`, `vmlinuz-*`).
* **Smart Repository Updates:** Parses `/etc/apk/repositories` to upgrade all `http://` links to `https://`, and seamlessly updates specific version tags (like `v3.18`) to `latest-stable` while safely leaving `edge` repositories intact.
* **Network Resilience:** The post-upgrade script includes a robust network health check. If connectivity fails, it automatically attempts to restart the networking service and dynamically identifies the default network interface (e.g. `eth0`, `enp0s3`, `eno1`) to force a DHCP renewal.
* **Stateful Package Reinstallation:** Reads your explicitly installed package list (`/etc/apk/world`) and forces a clean reinstallation. This ensures all custom binaries are perfectly matched to the newly installed kernel and libraries.
* **Automated Package Sync:** Leverages OpenRC's `/etc/local.d/` facility to create a run-once script (`99-finish-upgrade.start`). On the first boot, it synchronizes the cache, cleans old packages, and seals the final state with `lbu commit`.
* **Auto-Update Cron Job:** Run the installer with an optional `-a` flag to deploy a monthly cron job. The cron job will automatically pull the latest script from GitHub, check the Alpine CDN for a newer version, and seamlessly upgrade your system if an update is found.

## Quick Start

You can execute this script directly from the repository using `wget` piped into `sh`. 

**Note:** This script must be run as `root`.

### 1. Manual Upgrade (One-Time)
Run the script manually without installing any scheduled tasks:

```sh
wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-upgrade/main/upgrade.sh | sh
```

### 2. Manual Upgrade with Specific Flavor
Override automatic flavor detection (e.g. targeting the `virt` kernel for virtual machines):
```sh
wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-upgrade/main/upgrade.sh | sh -s -- -f virt
```

### 3. Upgrade + Install Monthly Auto-Update Cron Job
Pass the `-a` flag to perform an immediate upgrade (if applicable) and schedule a monthly check:
```sh
wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-upgrade/main/upgrade.sh | sh -s -- -a
```

## What the Script Does

1. Verifies the `x86_64` target architecture and auto-detects system flavor (`standard`, `virt`, `extended`, `xen`).
2. Locates the active Alpine Linux boot partition.
3. Checks the Alpine CDN (`latest-releases.yaml`) for the latest targeted x86_64 ISO image. (If run via cron, it compares versions and exits cleanly if up to date).
4. Remounts the boot partition as read-write and creates a staging directory directly on the disk.
5. Downloads and extracts the ISO image using loop mount (or extraction utilities fallback) directly on boot media.
6. Preserves existing bootloader configuration (`syslinux.cfg` / `grub.cfg`) while updating kernel (`vmlinuz-*`), initramfs (`initramfs-*`), modloop (`modloop-*`), package cache (`apks/`), and release files (`.alpine-release`).
7. Intelligently updates `/etc/apk/repositories` to `https://` and `latest-stable`.
8. Generates the post-upgrade OpenRC script and enables the `local` service.
9. Installs the cron job if the `-a` flag was provided.
10. Commits the current state using `lbu commit -d` and reboots.
11. **On Next Boot:** Verifies network health (auto-recovering on active interface if needed), upgrades base packages, reinstalls all `world` packages, cleans the cache, commits the final state, and reboots one last time into the finalized environment.

## Prerequisites

* An x86_64 machine running Alpine Linux in "diskless" mode.
* An active internet connection.
* Root privileges.

## Disclaimer

Always ensure you have a backup of your boot partition and `.apkovl` files before performing major version upgrades. Use at your own risk.
