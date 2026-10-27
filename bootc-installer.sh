#!/bin/bash

# Installing bootc images using gum

echo "
==============================================================
WARNING!!
In the directory where this script is being executed, 
a log file named 'bootc-installer.log' will be created 
containing all execution details of the script.
==============================================================
"
read -p "Press Enter to continue or Ctrl+C to cancel..." -r 
clear

# Check if user is root
if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root."
    exit 1
fi

# Function to align status messages
status() {
    local message="$1"
    local result="$2"
    local width=73
    local dots=$((width - ${#message} - 1))

    ((dots < 1)) && dots=1

    printf "%s " "$message"
    printf '%*s' "$dots" '' | tr ' ' '.'
    printf " [\e[0m%b\e[0m]\n" "$result"
}

# Check if gum is installed
if ! command -v gum &> /dev/null; then
    read -p "Do you want to install gum now? (required for the selection interface) [y/n]: " -n 1 -r
    echo
    if [[ $REPLY =~ ^[YySs]$ ]]; then
        dnf install gum -y &>> bootc-installer.log
    else
        echo "gum is not installed. Please install gum before continuing."
        exit 1
    fi
fi

# Check if sgdisk is installed
if ! command -v sgdisk &> /dev/null; then
    if gum confirm "Do you want to install sgdisk now? (required to partition disks)"; then
        dnf install gdisk -y &>> bootc-installer.log
    else
        echo "sgdisk is not installed. Please install sgdisk before continuing."
        exit 1
    fi
fi

# Check if skopeo is installed
if ! command -v skopeo &> /dev/null; then
    if gum confirm "Do you want to install skopeo now? (required to verify bootc images)"; then
        dnf install skopeo -y &>> bootc-installer.log
    else
        echo "skopeo is not installed. Please install skopeo before continuing."
        exit 1
    fi
fi

# Check if podman is installed
if ! command -v podman &> /dev/null; then
    if gum confirm "Do you want to install podman now? (required to install bootc images)"; then
        dnf install podman -y &>> bootc-installer.log
    else
        echo "podman is not installed. Please install podman before continuing."
        exit 1
    fi
fi

# Check if bootc is installed
if ! command -v bootc &> /dev/null; then
    if gum confirm "Do you want to install bootc now? (required to install bootc images)"; then
        dnf install bootc -y &>> bootc-installer.log
    else
        echo "bootc is not installed. Please install bootc before continuing."
        exit 1
    fi
fi

# Get available disks (filtering physical disks only, ignoring loops and cd-roms)
disk=$(lsblk -d -o NAME,TYPE --noheadings | awk '$2=="disk"{print $1}' | grep -v zram)

# Check if there are no available disks
if [ -z "$disk" ]; then
    echo "No disks available for installation."
    exit 1
fi

# Select the desired disk
disk_select=$(echo "$disk" | gum choose --header="Select the desired disk:")
if gum confirm "⚠️  Are you sure you want to partition and format the disk [$disk_select]?"; then
    echo "Starting partitioning and formatting of disk [$disk_select]..."

    # Clear existing partition table (optional, but recommended)
    if sgdisk --zap-all "/dev/$disk_select" &>> bootc-installer.log; then
        status "Existing partition table cleared" '\e[32mOK\e[0m'
    else
        status "Failed to clear existing partition table" '\e[31mERROR\e[0m'
        exit 1
    fi

    # 1. Create partition layout (All in a single command for efficiency)
    if sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" \
              -n 2:0:+2G -t 2:8300 -c 2:"BOOT" \
              -n 3:0:0 -t 3:8300 -c 3:"FEDORA" \
              "/dev/$disk_select" &>> bootc-installer.log; then
        status "Partitions created" '\e[32mOK\e[0m'
    else
        status "Failed to create partitions" '\e[31mERROR\e[0m'
        exit 1
    fi

    # Force the kernel to reread the partition table and wait for udev
    partprobe "/dev/$disk_select" &>> bootc-installer.log
    sleep 2

    # 2. Format partitions
    # EFI (FAT32)
    if mkfs.vfat -F 32 -n "EFI" "/dev/${disk_select}1" &>> bootc-installer.log; then
        status "EFI partition formatted with FAT" '\e[32mOK\e[0m'
    else
        status "Failed to format EFI partition" '\e[31mERROR\e[0m'
        exit 1
    fi

    # BOOT (EXT4)
    if mkfs.ext4 -F -L "BOOT" "/dev/${disk_select}2" &>> bootc-installer.log; then
        status "BOOT partition formatted with EXT4" '\e[32mOK\e[0m'
    else
        status "Failed to format BOOT partition" '\e[31mERROR\e[0m'
        exit 1
    fi

    # FEDORA (BTRFS)
    if mkfs.btrfs -f -L "FEDORA" "/dev/${disk_select}3" &>> bootc-installer.log; then
        status "FEDORA partition formatted with BTRFS" '\e[32mOK\e[0m'
    else
        status "Failed to format FEDORA partition" '\e[31mERROR\e[0m'
        exit 1
    fi

    # 3. Mount and create BTRFS subvolumes
    # Mount the btrfs partition temporarily at top-level to create subvolumes
    mount "/dev/${disk_select}3" /mnt

    if btrfs subvolume create /mnt/root &>> bootc-installer.log; then
        status "Subvolume 'root' created" '\e[32mOK\e[0m'
    else
        status "Failed to create subvolume 'root'" '\e[31mERROR\e[0m'
        umount /mnt
        exit 1
    fi

    # Create the 'home' subvolume (will not be mounted now, just created on disk)
    if btrfs subvolume create /mnt/home &>> bootc-installer.log; then
        status "Subvolume 'home' created" '\e[32mOK\e[0m'
    else
        status "Failed to create subvolume 'home'" '\e[31mERROR\e[0m'
        umount /mnt
        exit 1
    fi

    umount /mnt

    # Mount root subvolume at /mnt with compression
    if mount "/dev/${disk_select}3" -o subvol=root,compress=zstd:1 /mnt &>> bootc-installer.log; then
        status "FEDORA partition (root subvol) mounted" '\e[32mOK\e[0m'
    else
        status "Failed to mount FEDORA partition" '\e[31mERROR\e[0m'
        exit 1
    fi

    # Mount boot partition at /mnt/boot
    if mount "/dev/${disk_select}2" --mkdir /mnt/boot &>> bootc-installer.log; then
        status "BOOT partition mounted" '\e[32mOK\e[0m'
    else
        status "Failed to mount BOOT partition" '\e[31mERROR\e[0m'
        exit 1
    fi

    # Mount EFI partition at /mnt/boot/efi
    if mount "/dev/${disk_select}1" --mkdir /mnt/boot/efi &>> bootc-installer.log; then
        status "EFI partition mounted" '\e[32mOK\e[0m'
    else
        status "Failed to mount EFI partition" '\e[31mERROR\e[0m'
        exit 1
    fi
else
    echo -e "Operation cancelled by user."
    exit 1
fi

# Get the UUID of the BOOT labeled partition
boot_uuid=$(blkid -s UUID -o value "/dev/${disk_select}2")
if [ -z "$boot_uuid" ]; then
    status "Failed to get UUID of BOOT partition" '\e[31mERROR\e[0m'
    exit 1
fi

# Ask user for the bootc image link to install
bootc_image=$(gum input --placeholder "Bootc image link to install:")
if [ -z "$bootc_image" ]; then
    status "No link provided. Exiting." '\e[31mERROR\e[0m'
    exit 1
fi

# Check if it is a valid bootc image
if skopeo inspect "docker://${bootc_image}" | grep 'containers.bootc": "1"' &>> bootc-installer.log; then
    status "Valid bootc image" '\e[32mOK\e[0m'
else
    status "Invalid bootc image" '\e[31mERROR\e[0m'
    exit 1
fi

# Install the bootc image on the disk
if podman run --rm --privileged --pid=host \
  -v /dev:/dev \
  -v /var/lib/containers:/var/lib/containers \
  -v /mnt:/target:rw,z \
  --security-opt label=type:unconfined_t \
  "$bootc_image" \
  bootc install to-filesystem \
  --boot-mount-spec=UUID="$boot_uuid" \
  /target/ &>> bootc-installer.log; then
    status "Bootc image installed" '\e[32mOK\e[0m'
else
    status "Failed to install bootc image" '\e[31mERROR\e[0m'
    exit 1
fi