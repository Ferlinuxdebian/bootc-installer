# Bootc Disk Installer (`bootc-installer.sh`)

A robust, interactive terminal script designed to automate the partitioning, formatting, and deployment of OCI-based OS images directly onto a physical disk using **`bootc install to-filesystem`**. 

Built specifically for Fedora/RHEL-based containerized operating systems (bootc), this tool leverages modern CLI utilities like `gum` for an intuitive TUI experience, `sgdisk` for precise disk partitioning, `btrfs` with subvolumes and compression, and `podman` / `bootc` for the final image installation.

---

## ✨ Features

* **Interactive TUI:** Powered by Charmbracelet's `gum` for clean prompts, checks, and disk selection.
* **Smart Disk Filtering:** Automatically detects physical drives while ignoring loops, CD-ROMs, and `zram` devices.
* **Modern Partition Layout:** 
  * **EFI System Partition (ESP):** Formatted with FAT32 (`+1G`).
  * **Boot Partition (`/boot`):** Formatted with EXT4 (`+2G`).
  * **Root Partition (`/FEDORA`):** Formatted with BTRFS, featuring structured subvolumes (`root`, `home`) and `zstd` compression (`compress=zstd:1`).
* **Image Verification:** Validates the target OCI image via `skopeo` to ensure it contains a valid bootc configuration (`containers.bootc: "1"`).
* **Safe Execution:** Runs the `bootc install to-filesystem` routine securely inside a privileged Podman container instance targeting the mounted filesystem.
* **Comprehensive Logging:** Automatically logs all installation steps and command outputs to `bootc-installer.log` in the working directory.

---

## 📋 Prerequisites

The script requires root privileges and will automatically offer to check for or install missing dependencies via `dnf`:
* **`gum`** (Interactive UI components)
* **`gdisk` / `sgdisk`** (GPT partitioning tool)
* **`skopeo`** (Container image inspection)
* **`podman`** (Container runtime)
* **`bootc`** (Bootable container installer utility)

---

## 🚀 Usage

1. Clone or download the script to your environment.
2. Make the script executable:
   ```bash
   chmod +x bootc-installer.sh
   ```
3. Execute the script with **root privileges**:
   ```bash
   sudo ./bootc-installer.sh
   ```
4. Follow the interactive prompts on screen:
   * Acknowledge the warning and log file creation.
   * Select the target installation disk from the list.
   * Confirm the partitioning and formatting action.
   * Provide the container image reference (e.g., `ghcr.io/your-username/your-bootc-image:latest`).

---

## 📂 Partition Structure Created

| Partition | Mount Point | Filesystem | Size / Notes |
| :--- | :--- | :--- | :--- |
| **Partition 1** | `/mnt/boot/efi` | FAT32 | `1 GB` (EFI System Partition) |
| **Partition 2** | `/mnt/boot` | EXT4 | `2 GB` (Dedicated Boot Partition) |
| **Partition 3** | `/mnt` (`subvol=root`) | BTRFS | Remaining space (`zstd` compressed root subvolume) |
| **Partition 3** | (Created on disk) | BTRFS | `/home` subvolume (ready for mounting) |

---

## 📝 Logging

All stdout and stderr outputs during execution are captured and appended to `bootc-installer.log` in the directory where the script is invoked. Check this file for troubleshooting details if any step fails.