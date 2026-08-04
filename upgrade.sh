#!/bin/ash
# Alpine Linux x86_64 Upgrade Script (Diskless & Auto-Update)

# Fail immediately if any command exits with a non-zero status
set -e

INSTALL_CRON=0
CRON_MODE=0
FLAVOR=""

# Parse command line flags
while getopts "acf:" opt; do
    case ${opt} in
        a ) INSTALL_CRON=1 ;;
        c ) CRON_MODE=1 ;;
        f ) FLAVOR="${OPTARG}" ;;
        \? ) echo "Usage: $0 [-a] [-c] [-f flavor (standard|virt|extended|xen)]" >&2; exit 1 ;;
    esac
done

ARCH="x86_64"
CURRENT_ARCH=$(uname -m)

echo "Detecting system architecture..."
if [ "$CURRENT_ARCH" != "x86_64" ] && [ "$CURRENT_ARCH" != "amd64" ]; then
    echo "Warning: Running architecture '$CURRENT_ARCH' differs from target 'x86_64'."
fi

# Detect Alpine flavor if not specified via -f
if [ -z "$FLAVOR" ]; then
    KERNEL_RELEASE=$(uname -r 2>/dev/null || echo "")
    case "$KERNEL_RELEASE" in
        *"virt"*)
            FLAVOR="virt"
            ;;
        *"extended"*)
            FLAVOR="extended"
            ;;
        *"xen"*)
            FLAVOR="xen"
            ;;
        *)
            FLAVOR="standard"
            ;;
    esac
fi

echo "Target Architecture: $ARCH"
echo "Target Release Flavor: alpine-$FLAVOR"

echo "Detecting boot partition..."
BOOT_PART=""

for dir in /media/* /boot; do
    if [ -d "$dir" ] && { [ -f "$dir/.alpine-release" ] || [ -f "$dir/syslinux.cfg" ] || [ -d "$dir/boot/syslinux" ] || [ -d "$dir/EFI/boot" ] || [ -d "$dir/efi/boot" ] || [ -f "$dir/boot/vmlinuz-lts" ] || [ -f "$dir/boot/vmlinuz-virt" ] || [ -d "$dir/apks" ]; }; then
        BOOT_PART="$dir"
        break
    fi
done

if [ -z "$BOOT_PART" ]; then
    echo "Error: Could not dynamically locate the Alpine Linux boot partition."
    exit 1
fi

echo "Boot partition identified at: $BOOT_PART"

# Inject the dynamically detected ARCH into the URL
YAML_URL="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/${ARCH}/latest-releases.yaml"
BASE_URL="${YAML_URL%/*}"

echo "Fetching latest release info..."
FILENAME=$(wget -qO- "$YAML_URL" | awk -v flavor="alpine-${FLAVOR}" '$0 ~ flavor && /file:.*\.iso/ {print $2; exit}')

if [ -z "$FILENAME" ]; then
    # Fallback search for any ISO matching flavor or standard x86_64 ISO
    FILENAME=$(wget -qO- "$YAML_URL" | awk '/file:.*alpine-standard.*\.iso/ {print $2; exit}')
fi

if [ -z "$FILENAME" ]; then
    echo "Error: Could not determine the latest ISO filename for architecture $ARCH. The CDN might be unreachable."
    exit 1
fi

DOWNLOAD_LINK="${BASE_URL}/${FILENAME}"

# Version check for automated runs
CURRENT_VER=$(cat /etc/alpine-release 2>/dev/null || echo "0.0.0")

if echo "$FILENAME" | grep -q "$CURRENT_VER"; then
    if [ "$CRON_MODE" = 1 ]; then
        echo "System is already running the latest version ($CURRENT_VER). Cron job exiting cleanly."
        exit 0
    else
        echo "System is already at version $CURRENT_VER. Proceeding anyway due to manual execution..."
    fi
else
    echo "New version detected or forced run. Current: $CURRENT_VER, Latest Target: $FILENAME"
fi

echo "Remounting boot partition as read-write to prepare staging area..."
mount -o remount,rw "$BOOT_PART"

STAGING_DIR="${BOOT_PART}/upgrade_staging"
mkdir -p "$STAGING_DIR"
ISO_FILE="${STAGING_DIR}/image.iso"
EXTRACT_DIR="${STAGING_DIR}/extracted"
ISO_MOUNT="${STAGING_DIR}/iso_mnt"
mkdir -p "$EXTRACT_DIR"

echo "Downloading ${FILENAME} directly to boot media..."
if [ "$CRON_MODE" = 1 ]; then
    wget -qO "$ISO_FILE" "$DOWNLOAD_LINK"
else
    wget --show-progress -O "$ISO_FILE" "$DOWNLOAD_LINK" 2>/dev/null || wget -O "$ISO_FILE" "$DOWNLOAD_LINK"
fi

echo "Extracting ISO image on boot media..."
EXTRACTED=0
mkdir -p "$ISO_MOUNT"

# Try loading loop kernel module first
modprobe loop 2>/dev/null || true

# 1. Attempt loop mount
if mount -o loop "$ISO_FILE" "$ISO_MOUNT" 2>/dev/null; then
    (cd "$ISO_MOUNT" && tar -cf - .) | (cd "$EXTRACT_DIR" && tar -xf -) 2>/dev/null || true
    umount "$ISO_MOUNT" 2>/dev/null || true
    EXTRACTED=1
fi

# 2. Try pre-installed extraction utilities (7z / 7zz / bsdtar / xorriso)
if [ "$EXTRACTED" -eq 0 ]; then
    if command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1; then
        SEVENZ=$(command -v 7z 2>/dev/null || command -v 7zz 2>/dev/null)
        "$SEVENZ" x -o"$EXTRACT_DIR" "$ISO_FILE" >/dev/null && EXTRACTED=1
    elif command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$ISO_FILE" -C "$EXTRACT_DIR" && EXTRACTED=1
    elif command -v xorriso >/dev/null 2>&1; then
        xorriso -osirrox on -indev "$ISO_FILE" -extract / "$EXTRACT_DIR" >/dev/null 2>&1 && EXTRACTED=1
    fi
fi

# 3. If loop mount & existing tools fail, automatically install extraction tool via apk
if [ "$EXTRACTED" -eq 0 ]; then
    echo "Loop mount failed and no extraction tool found. Auto-installing extraction tool..."
    if apk add --no-cache 7zip >/dev/null 2>&1 || apk add --no-cache p7zip >/dev/null 2>&1 || apk add --no-cache xorriso >/dev/null 2>&1; then
        if command -v 7z >/dev/null 2>&1 || command -v 7zz >/dev/null 2>&1; then
            SEVENZ=$(command -v 7z 2>/dev/null || command -v 7zz 2>/dev/null)
            "$SEVENZ" x -o"$EXTRACT_DIR" "$ISO_FILE" >/dev/null && EXTRACTED=1
        elif command -v xorriso >/dev/null 2>&1; then
            xorriso -osirrox on -indev "$ISO_FILE" -extract / "$EXTRACT_DIR" >/dev/null 2>&1 && EXTRACTED=1
        fi
    fi
fi

rm -rf "$ISO_MOUNT"
rm -f "$ISO_FILE"

if [ "$EXTRACTED" -eq 0 ]; then
    echo "Error: Failed to extract ISO image. Neither loop mount nor extraction tools could be used."
    rm -rf "$STAGING_DIR"
    exit 1
fi

echo "Preserving existing bootloader configurations if present..."
[ -f "$BOOT_PART/syslinux.cfg" ] && cp -f "$BOOT_PART/syslinux.cfg" "$STAGING_DIR/syslinux.cfg.bak"
[ -f "$BOOT_PART/boot/syslinux/syslinux.cfg" ] && cp -f "$BOOT_PART/boot/syslinux/syslinux.cfg" "$STAGING_DIR/syslinux_boot.cfg.bak"

# Helper function to find existing directory matching target_name case-insensitively on VFAT/FAT32
find_dir_case() {
    parent="$1"
    target_name="$2"
    existing=""
    target_lower=$(echo "$target_name" | tr '[:upper:]' '[:lower:]')
    
    for item in "$parent"/* "$parent"/.*; do
        if [ -d "$item" ]; then
            base=$(basename "$item")
            base_lower=$(echo "$base" | tr '[:upper:]' '[:lower:]')
            if [ "$base_lower" = "$target_lower" ]; then
                existing="$item"
                break
            fi
        fi
    done
    
    if [ -n "$existing" ]; then
        echo "$existing"
    else
        echo "$parent/$target_name"
    fi
}

# Helper function to safely copy directory trees into existing destination directories using tar with progress indicator
safe_copy_dir() {
    src="$1"
    parent="$2"
    target_name="$3"
    if [ -d "$src" ]; then
        dst=$(find_dir_case "$parent" "$target_name")
        [ -d "$dst" ] || mkdir -p "$dst"
        if [ "$CRON_MODE" = 1 ]; then
            (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xf -)
        else
            ( (cd "$src" && tar -cf - .) | (cd "$dst" && tar -xvf -) ) 2>&1 | awk -v name="$target_name" 'NR % 10 == 0 { printf "\r  -> Copying %s: %d files transferred...", name, NR } END { printf "\r  -> Copying %s: %d files completed.    \n", name, NR }'
        fi
    fi
}

echo "Updating boot package cache (apks)..."
safe_copy_dir "$EXTRACT_DIR/apks" "$BOOT_PART" "apks"

echo "Updating boot kernel and initramfs files..."
safe_copy_dir "$EXTRACT_DIR/boot" "$BOOT_PART" "boot"

echo "Updating EFI boot files..."
if [ -d "$EXTRACT_DIR/EFI" ]; then
    safe_copy_dir "$EXTRACT_DIR/EFI" "$BOOT_PART" "EFI"
elif [ -d "$EXTRACT_DIR/efi" ]; then
    safe_copy_dir "$EXTRACT_DIR/efi" "$BOOT_PART" "EFI"
fi

# Copy any additional directories from extracted ISO safely
for dir in "$EXTRACT_DIR"/*/; do
    [ -d "$dir" ] || continue
    dname=$(basename "$dir")
    case "$dname" in
        apks|boot|EFI|efi|upgrade_staging|iso_mnt|extracted)
            continue
            ;;
        *)
            safe_copy_dir "$dir" "$BOOT_PART" "$dname"
            ;;
    esac
done

echo "Updating root release files..."
for file in "$EXTRACT_DIR"/* "$EXTRACT_DIR"/.*; do
    [ -f "$file" ] || continue
    fname=$(basename "$file")
    [ "$fname" = "." ] || [ "$fname" = ".." ] && continue
    cp -f "$file" "$BOOT_PART/"
done

echo "Restoring preserved bootloader configurations..."
[ -f "$STAGING_DIR/syslinux.cfg.bak" ] && cp -f "$STAGING_DIR/syslinux.cfg.bak" "$BOOT_PART/syslinux.cfg"
[ -f "$STAGING_DIR/syslinux_boot.cfg.bak" ] && cp -f "$STAGING_DIR/syslinux_boot.cfg.bak" "$BOOT_PART/boot/syslinux/syslinux.cfg"

echo "Cleaning up staging directory..."
rm -rf "$STAGING_DIR"

echo "Remounting boot partition as read-only..."
sync
mount -o remount,ro "$BOOT_PART" || true

echo "Updating repositories to HTTPS and latest-stable..."
sed -i 's|http://|https://|g' /etc/apk/repositories
sed -i -E 's|/v[0-9]+\.[0-9]+/|/latest-stable/|g' /etc/apk/repositories

# Force the package manager to recognize the new architecture immediately on the next boot
echo "$ARCH" > /etc/apk/arch

if [ "$INSTALL_CRON" = 1 ]; then
    echo "Installing monthly cron job for automatic updates..."
    mkdir -p /etc/periodic/monthly
    
    cat << 'CRONEOF' > /etc/periodic/monthly/alpine-upgrade
#!/bin/ash
# Automated monthly Alpine upgrade
exec > /var/log/alpine-cron-upgrade.log 2>&1
wget -qO- https://raw.githubusercontent.com/gpocali/alpine-linux-upgrade/main/upgrade.sh | sh -s -- -c
CRONEOF
    
    chmod +x /etc/periodic/monthly/alpine-upgrade
    
    rc-update add crond default
    rc-service crond start || true
fi

echo "Creating post-upgrade finish script..."
rc-update add local default

cat <<'EOF' > /etc/local.d/99-finish-upgrade.start
#!/bin/ash
exec > /var/log/alpine-upgrade.log 2>&1

echo "Starting post-upgrade sequence..."

check_network() {
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 || ping -c 1 -W 2 dl-cdn.alpinelinux.org >/dev/null 2>&1
}

echo "Waiting for network connectivity..."
NETWORK_UP=false
for i in $(seq 1 6); do
    if check_network; then
        NETWORK_UP=true
        break
    fi
    sleep 5
done

if [ "$NETWORK_UP" = false ]; then
    echo "Network check failed. Attempting to restart networking service..."
    rc-service networking restart
    sleep 5
    if ! check_network; then
        IFACE=$(ip route 2>/dev/null | awk '/default/ {print $5}' | head -n 1)
        [ -z "$IFACE" ] && IFACE="eth0"
        echo "Still no network. Forcing DHCP renewal on interface ($IFACE)..."
        udhcpc -i "$IFACE" -q || udhcpc -q
        sleep 5
        if ! check_network; then
            echo "CRITICAL: Network could not be restored. Aborting upgrade finish."
            exit 1
        fi
    fi
fi

echo "Network is up. Performing base system upgrade..."
apk update
apk upgrade --available

echo "Reinstalling all configured packages to ensure clean binary state..."
WORLD_PKGS=$(grep -v '^#' /etc/apk/world | tr '\n' ' ')
if [ -n "$WORLD_PKGS" ]; then
    apk add --force-reinstall $WORLD_PKGS
fi

echo "Syncing and cleaning package cache..."
apk cache sync
apk cache clean

echo "Cleaning up run-once script..."
rm -f "$0"

echo "Committing final state..."
lbu commit -d

echo "Rebooting into finalized system..."
reboot
EOF

chmod +x /etc/local.d/99-finish-upgrade.start

echo "Committing initial changes and rebooting into new kernel..."
lbu commit -d && reboot