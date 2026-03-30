#!/usr/bin/env bash
# ==============================================================================
#  CachyOS BC250 Toolkit
#  Main setup and configuration menu
# ==============================================================================

set -euo pipefail

# Re-launch with sudo if not already root
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

# Capture the real user who invoked sudo (for AUR helpers that refuse to run as root)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"

# Set to 1 by run_all to defer limine-update until all tasks complete
SKIP_LIMINE_UPDATE=0

# ==============================================================================
# COLORS & FORMATTING
# ==============================================================================

RESET="\e[0m"
BOLD="\e[1m"
DIM="\e[2m"

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CYAN="\e[36m"
WHITE="\e[97m"
BLUE="\e[34m"
MAGENTA="\e[35m"

BG_HEADER="\e[48;5;235m"

# ==============================================================================
# HELPERS
# ==============================================================================

print_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                              ║"
    echo "  ║              CachyOS BC250 Toolkit                           ║"
    echo "  ║           System Setup & Configuration                       ║"
    echo "  ║                                                              ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_section() {
    echo -e "  ${BOLD}${YELLOW}$1${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
}

print_item() {
    local num="$1"
    local label="$2"
    local desc="$3"
    printf "  ${BOLD}${WHITE}[${CYAN}%2s${WHITE}]${RESET}  %-19s ${DIM}%s${RESET}\n" "$num" "$label" "$desc"
}

print_success() {
    echo -e "\n  ${BOLD}${GREEN}✔  $1${RESET}\n"
}

print_error() {
    echo -e "\n  ${BOLD}${RED}✘  $1${RESET}\n"
}

print_info() {
    echo -e "  ${CYAN}→${RESET}  $1"
}

print_step() {
    echo -e "\n  ${BOLD}${MAGENTA}[$1]${RESET}  $2"
}

press_enter() {
    echo -e "\n  ${DIM}Press Enter to return to the menu...${RESET}"
    read -r
}

confirm() {
    local prompt="${1:-Are you sure?}"
    echo -e "\n  ${YELLOW}${prompt}${RESET} ${DIM}[y/N]${RESET} "
    read -rp "  → " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ==============================================================================
# SCRIPT FUNCTIONS
# ==============================================================================

run_cpu_governor() {
    print_step "02" "Installing CPU Governor"
    print_info "Installing dependencies: python-pipx, stress"
    pacman -Syu python-pipx stress --noconfirm || { print_error "Failed to install dependencies."; return 1; }
    print_info "Cloning bc250_smu_oc repository..."
    if [[ -d "bc250_smu_oc" ]]; then
        print_info "Directory already exists — pulling latest changes..."
        git -C bc250_smu_oc pull || { print_error "Failed to pull repository."; return 1; }
    else
        git clone https://github.com/bc250-collective/bc250_smu_oc.git || { print_error "Failed to clone repository."; return 1; }
    fi
    cd bc250_smu_oc
    print_info "Installing via pipx..."
    pipx install . || { print_error "Failed to install via pipx."; cd ..; return 1; }
    pipx ensurepath || true
    export PATH="$PATH:/root/.local/bin"
    print_info "Running bc250-detect..."
    bc250-detect --frequency 3500 --vid 1000 --keep || { print_error "bc250-detect failed."; cd ..; return 1; }
    print_info "Applying overclock config..."
    bc250-apply --install overclock.conf || { print_error "bc250-apply failed."; cd ..; return 1; }
    print_info "Enabling systemd service..."
    systemctl enable bc250-smu-oc || { print_error "Failed to enable service."; cd ..; return 1; }
    cd ..
    print_success "CPU Governor installed successfully!"
}

run_gpu_governor() {
    print_step "03" "Installing GPU Governor"
    print_info "Installing cyan-skillfish-governor-smu via paru (as $REAL_USER)..."
    sudo -u "$REAL_USER" paru -S cyan-skillfish-governor-smu --noconfirm
    print_info "Enabling and starting systemd service..."
    systemctl enable --now cyan-skillfish-governor-smu.service
    print_success "GPU Governor installed and started successfully!"
}

run_enable_swap() {
    print_step "04" "Configuring Swap"
    print_info "Disabling and removing existing swapfile..."
    sudo swapoff /var/swap/swapfile 2>/dev/null || true
    sudo rm -f /var/swap/swapfile 2>/dev/null || true

    print_info "Recreating Btrfs subvolume..."
    sudo btrfs subvolume delete /var/swap 2>/dev/null || true
    sudo btrfs subvolume create /var/swap

    print_info "Creating 16G swapfile..."
    sudo btrfs filesystem mkswapfile --size 16G /var/swap/swapfile

    print_info "Updating /etc/fstab..."
    sudo sed -i '/\/var\/swap\/swapfile/d' /etc/fstab
    echo '/var/swap/swapfile none swap defaults,nofail 0 0' | sudo tee -a /etc/fstab > /dev/null

    print_info "Setting swappiness to 180..."
    echo 'vm.swappiness = 180' | sudo tee /etc/sysctl.d/99-swappiness.conf > /dev/null
    sudo sysctl vm.swappiness=180 > /dev/null

    print_info "Enabling swapfile..."
    sudo swapon /var/swap/swapfile

    print_success "Swap configured! Current swap:"
    echo ""
    swapon --show | sed 's/^/    /'
    echo ""
}

run_set_loglevel() {
    local CONF="/etc/default/limine"
    print_step "05" "Hiding RDSEED Warning — Setting loglevel=0 in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    # Create backup before any modifications
    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists — preserving original."
    fi

    # 1. If loglevel= exists anywhere in the file, update it to 0
    if grep -q 'loglevel=' "$CONF"; then
        print_info "loglevel= found. Updating value to 0..."
        sed -i 's/loglevel=[0-9]*/loglevel=0/g' "$CONF"

    # 2. If loglevel= is missing, append it inside the KERNEL_CMDLINE[default] quotes
    else
        print_info "loglevel= not found. Adding to KERNEL_CMDLINE[default]..."
        # This matches the KERNEL_CMDLINE[default]+="... line and inserts loglevel=0 before the closing quote
        sed -i '/^KERNEL_CMDLINE\[default\]/ s/\"$/ loglevel=0\"/' "$CONF"
    fi

    # Regenerate Limine config
    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating /boot/limine.conf..."
        limine-update
    fi

    print_success "loglevel set to 0. Reboot to apply."
}

run_disable_zram_enable_zswap() {
    local CONF="/etc/default/limine"
    print_step "06" "Disabling ZRAM & Enabling ZSWAP"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    # --- Disable ZRAM ---
    if grep -q 'systemd\.zram=0' "$CONF"; then
        print_info "ZRAM already disabled in $CONF — skipping."
    else
        print_info "Disabling ZRAM..."
        sed -i '/^KERNEL_CMDLINE/s/"$/ systemd.zram=0"/' "$CONF"
        print_info "systemd.zram=0 added."
    fi

    # --- Enable ZSWAP ---
    if grep -q 'zswap\.enabled=1' "$CONF"; then
        print_info "ZSWAP already enabled in $CONF — skipping."
    else
        print_info "Enabling zswap (lz4, 25% pool)..."
        sed -i '/^KERNEL_CMDLINE/s/"$/ zswap.enabled=1 zswap.max_pool_percent=25 zswap.compressor=lz4"/' "$CONF"
        print_info "ZSWAP kernel parameters added."
    fi

    # --- Add lz4 modules to initramfs ---
    local MKINITCPIO="/etc/mkinitcpio.conf"
    if grep -q 'lz4' "$MKINITCPIO"; then
        print_info "lz4 modules already present in $MKINITCPIO — skipping."
    else
        print_info "Adding lz4 and lz4_compress modules to initramfs..."
        sed -i 's/^MODULES=(\(.*\))/MODULES=(\1 lz4 lz4_compress)/' "$MKINITCPIO"
        print_info "Rebuilding initramfs (this may take a moment)..."
        mkinitcpio -P
        print_info "Initramfs rebuilt."
    fi

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating /boot/limine.conf..."
        limine-update
    fi
    print_success "ZRAM disabled && ZSWAP enabled! Reboot to apply."
    echo -e "  ${DIM}After reboot, verify with: cat /sys/module/zswap/parameters/enabled${RESET}\n"
}

run_toggle_boot_mode() {
    print_step "11" "Toggle Boot Mode (Safety Restore)"

    local CONF_DIR="/etc/plasmalogin.conf.d"
    local BACKUP_DIR="$CONF_DIR/original_backups"
    local OVERRIDE_FILE="$CONF_DIR/zzz-bc250-boot.conf"
    local USER_NAME="$REAL_USER"

    # --- 1. ONE-TIME BACKUP & CLEANUP ---
    if [[ ! -d "$BACKUP_DIR" ]]; then
        print_info "First run: Archiving CachyOS handheld configs..."
        mkdir -p "$BACKUP_DIR"
        chattr -i "$CONF_DIR"/* 2>/dev/null

        for file in "$CONF_DIR"/*.conf; do
            filename=$(basename "$file")
            if [[ -f "$file" && "$filename" != "cachyos.conf" && "$filename" != "zzz-bc250-boot.conf" ]]; then
                mv "$file" "$BACKUP_DIR/"
            fi
        done
    fi

    # --- 2. DETECTION ---
    local current_mode="${BOLD}${CYAN}Desktop Mode${RESET}"
    if [[ -f "$OVERRIDE_FILE" ]] && grep -q "gamescope" "$OVERRIDE_FILE"; then
        current_mode="${BOLD}${GREEN}Game Mode${RESET}"
    fi

    print_info "Current Boot Mode: $current_mode"
    echo ""
    print_item "1" "Game Mode" "Boot to Steam UI (Autologin $USER_NAME)"
    print_item "2" "Desktop Mode" "Boot to Plasma (Manual Login)"
    print_item "0" "Cancel & Restore" "Return to System Defaults"
    echo ""

    read -rp "$(echo -e "  ${BOLD}${WHITE}Select choice:${RESET} ")" mode_choice

    case "$mode_choice" in
        1)
            print_info "Applying Game Mode..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
Relogin=false
Session=gamescope-session.desktop
User=$USER_NAME
EOF
            print_success "Game Mode active."
            ;;
        2)
            print_info "Applying Desktop Mode..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
Relogin=false
Session=plasma.desktop
User=
EOF
            print_success "Desktop Mode active."
            ;;
        *)
            print_info "Cancelling and restoring original CachyOS configs..."
            # 1. Remove our override
            rm -f "$OVERRIDE_FILE"

            # 2. Move original files back if they exist
            if [[ -d "$BACKUP_DIR" ]]; then
                mv "$BACKUP_DIR"/* "$CONF_DIR/" 2>/dev/null
                rmdir "$BACKUP_DIR" 2>/dev/null
                print_success "Original configs restored. Backup directory removed."
            else
                print_info "No backup found to restore."
            fi
            return 0
            ;;
    esac
}

run_switch_to_default_kernel() {
    print_step "12" "Migrating to Default CachyOS Kernel"

    # 1. Check if we are already on the standard kernel
    if pacman -Qq linux-cachyos &>/dev/null; then
        print_info "Standard CachyOS kernel is already installed."

        # If deckify is also there, we should still clean it up
        if pacman -Qq linux-cachyos-deckify &>/dev/null; then
            print_info "Deckify kernel found alongside standard. Proceeding to cleanup..."
        else
            print_success "System is already running the default kernel. Nothing to do."
            return 0
        fi
    fi

    # 2. Check if Deckify is actually here to be replaced
    if ! pacman -Qq linux-cachyos-deckify &>/dev/null; then
        print_error "linux-cachyos-deckify not found. Migration is not applicable."
        return 1
    fi

    # 3. Install the default kernel
    print_info "Installing linux-cachyos and headers..."
    if ! sudo pacman -S --noconfirm linux-cachyos linux-cachyos-headers; then
        print_error "Failed to install the default CachyOS kernel."
        return 1
    fi

    # 4. Remove the deckify kernel
    print_info "Removing linux-cachyos-deckify..."
    sudo pacman -Rs --noconfirm linux-cachyos-deckify linux-cachyos-deckify-headers 2>/dev/null

    # 5. Update Limine
    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating Limine boot menu..."
        sudo limine-update
    fi

    print_success "System successfully migrated to default kernel."
    print_info "Please reboot to apply changes."
}

run_install_acpi_fix() {
    print_step "13" "Installing BC250 ACPI Fix (Independent Module)"

    local CPIO_NAME="bc250_acpi.cpio"
    local CPIO_DEST="/boot/$CPIO_NAME"
    local LIMINE_CONFIG="/boot/limine.conf"

    # 1. Dependency & Lock Check
    while [ -f /var/lib/pacman/db.lck ]; do sleep 2; done
    if ! command -v git &>/dev/null || ! command -v cpio &>/dev/null; then
        sudo pacman -S --noconfirm git cpio
    fi

    # 2. Build the CPIO
    local BUILD_DIR="/tmp/bc250-acpi-build"
    rm -rf "$BUILD_DIR"
    git clone "https://github.com/bc250-collective/bc250-acpi-fix.git" "$BUILD_DIR"
    mkdir -p "$BUILD_DIR/kernel/firmware/acpi"
    cp "$BUILD_DIR"/*.aml "$BUILD_DIR/kernel/firmware/acpi/"
    ( cd "$BUILD_DIR" && find kernel | cpio -o -H newc > "$CPIO_DEST" 2>/dev/null )
    print_success "ACPI archive created at $CPIO_DEST"

    # 3. Insert as a SEPARATE module line
    if [[ -f "$LIMINE_CONFIG" ]]; then
        if grep -q "$CPIO_NAME" "$LIMINE_CONFIG"; then
            print_info "ACPI module already exists in $LIMINE_CONFIG."
        else
            print_info "Adding independent ACPI module entry..."
            # This finds the existing module_path line and inserts a NEW line above it
            # The extra spaces match the indentation in your file
            sudo sed -i "/module_path:/i \  module_path: boot():/$CPIO_NAME" "$LIMINE_CONFIG"
            print_success "Inserted separate ACPI module line."
        fi
    else
        print_error "Could not find $LIMINE_CONFIG"
        return 1
    fi

    print_success "Fix installed. Reboot and check 'journalctl -k | grep ACPI'."
}
# ==============================================================================
# OVERCLOCK MENU (embedded from 07-overclock_menu.sh)
# ==============================================================================

CPU_DEST="/etc/bc250-smu-oc.conf"
GPU_DEST="/etc/cyan-skillfish-governor-smu/config.toml"
CPU_SERVICE="bc250-smu-oc.service"
GPU_SERVICE="cyan-skillfish-governor-smu.service"

CPU_TMPFILE="$(mktemp /tmp/cpu_profile.XXXXXX)"
GPU_TMPFILE="$(mktemp /tmp/gpu_profile.XXXXXX)"
trap 'rm -f "$CPU_TMPFILE" "$GPU_TMPFILE"' EXIT

write_cpu_undervolt_3_5ghz() { cat > "$CPU_TMPFILE" <<'EOF'
[overclock]
frequency = 3500
scale = -22
max_temperature = 80
EOF
}

write_cpu_overclock_3_85ghz() { cat > "$CPU_TMPFILE" <<'EOF'
[overclock]
frequency = 3850
scale = -30
max_temperature = 90
EOF
}

write_cpu_overclock_4ghz() { cat > "$CPU_TMPFILE" <<'EOF'
[overclock]
frequency = 4000
scale = -37
max_temperature = 90
EOF
}

write_gpu_overclock_1500mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 500
adjust = 200_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.60
lower = 0.40
[temperature]
throttling = 80
throttling_recovery = 75
[[safe-points]]
frequency = 350
voltage = 700
[[safe-points]]
frequency = 500
voltage = 700
[[safe-points]]
frequency = 1000
voltage = 800
[[safe-points]]
frequency = 1175
voltage = 850
[[safe-points]]
frequency = 1500
voltage = 900
EOF
}

write_gpu_overclock_2000mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 500
adjust = 200_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.60
lower = 0.40
[temperature]
throttling = 80
throttling_recovery = 75
[[safe-points]]
frequency = 350
voltage = 700
[[safe-points]]
frequency = 500
voltage = 700
[[safe-points]]
frequency = 1000
voltage = 800
[[safe-points]]
frequency = 1175
voltage = 850
[[safe-points]]
frequency = 1500
voltage = 900
[[safe-points]]
frequency = 1600
voltage = 910
[[safe-points]]
frequency = 1700
voltage = 920
[[safe-points]]
frequency = 1850
voltage = 930
[[safe-points]]
frequency = 2000
voltage = 960
EOF
}

write_gpu_overclock_2100mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 500
adjust = 200_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.60
lower = 0.40
[temperature]
throttling = 80
throttling_recovery = 75
[[safe-points]]
frequency = 350
voltage = 700
[[safe-points]]
frequency = 500
voltage = 700
[[safe-points]]
frequency = 1000
voltage = 800
[[safe-points]]
frequency = 1175
voltage = 850
[[safe-points]]
frequency = 1500
voltage = 900
[[safe-points]]
frequency = 1600
voltage = 910
[[safe-points]]
frequency = 1700
voltage = 920
[[safe-points]]
frequency = 1850
voltage = 930
[[safe-points]]
frequency = 2000
voltage = 960
[[safe-points]]
frequency = 2050
voltage = 980
[[safe-points]]
frequency = 2100
voltage = 1000
EOF
}

write_gpu_overclock_2300mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 500
adjust = 200_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.60
lower = 0.40
[temperature]
throttling = 90
throttling_recovery = 85
[[safe-points]]
frequency = 350
voltage = 700
[[safe-points]]
frequency = 500
voltage = 700
[[safe-points]]
frequency = 1000
voltage = 800
[[safe-points]]
frequency = 1175
voltage = 850
[[safe-points]]
frequency = 1500
voltage = 900
[[safe-points]]
frequency = 1600
voltage = 910
[[safe-points]]
frequency = 1700
voltage = 920
[[safe-points]]
frequency = 1850
voltage = 930
[[safe-points]]
frequency = 2000
voltage = 960
[[safe-points]]
frequency = 2050
voltage = 980
[[safe-points]]
frequency = 2100
voltage = 1000
[[safe-points]]
frequency = 2125
voltage = 1020
[[safe-points]]
frequency = 2150
voltage = 1035
[[safe-points]]
frequency = 2200
voltage = 1050
[[safe-points]]
frequency = 2250
voltage = 1050
[[safe-points]]
frequency = 2300
voltage = 1075
EOF
}

write_gpu_overclock_2350mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 500
adjust = 200_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.60
lower = 0.40
[temperature]
throttling = 90
throttling_recovery = 85
[[safe-points]]
frequency = 350
voltage = 700
[[safe-points]]
frequency = 500
voltage = 700
[[safe-points]]
frequency = 1000
voltage = 800
[[safe-points]]
frequency = 1175
voltage = 850
[[safe-points]]
frequency = 1500
voltage = 900
[[safe-points]]
frequency = 1600
voltage = 910
[[safe-points]]
frequency = 1700
voltage = 920
[[safe-points]]
frequency = 1850
voltage = 930
[[safe-points]]
frequency = 2000
voltage = 960
[[safe-points]]
frequency = 2050
voltage = 980
[[safe-points]]
frequency = 2100
voltage = 1000
[[safe-points]]
frequency = 2125
voltage = 1020
[[safe-points]]
frequency = 2150
voltage = 1035
[[safe-points]]
frequency = 2200
voltage = 1050
[[safe-points]]
frequency = 2250
voltage = 1050
[[safe-points]]
frequency = 2300
voltage = 1075
[[safe-points]]
frequency = 2350
voltage = 1100
EOF
}

install_cpu() {
    cp "$CPU_TMPFILE" "$CPU_DEST"
    systemctl daemon-reload
    systemctl restart "$CPU_SERVICE"
    if systemctl is-active --quiet "$CPU_SERVICE"; then
        print_info "CPU service is running."
    else
        print_error "CPU service failed to start! Check: journalctl -u $CPU_SERVICE"
    fi
}

install_gpu() {
    # Check if a new temporary config was actually provided (for presets)
    if [[ -f "${1:-}" ]]; then
        cp "$1" "$GPU_DEST"
    fi

    # Restart the service to load whatever is currently in $GPU_DEST
    systemctl restart "$GPU_SERVICE"

    if systemctl is-active --quiet "$GPU_SERVICE"; then
        print_info "GPU service is running with current config."
    else
        print_error "GPU service failed to start! Check: journalctl -u $GPU_SERVICE"
    fi
}

oc_edit_gpu_config_kate() {
    print_step "07-E" "Opening GPU Config in Kate"

    if [[ ! -f "$GPU_DEST" ]]; then
        print_error "Configuration file not found at $GPU_DEST"
        return 1
    fi

    print_info "Launching Kate as $REAL_USER..."
    # Launching as the real user prevents permission issues and root-execution blocks
    sudo -u "$REAL_USER" kate "$GPU_DEST" &>/dev/null &

    print_success "Kate opened. Make your changes and save the file."

    if confirm "Would you like to restart the GPU service to apply manual changes?"; then
        install_gpu
    fi
}

# Read the active profile and match against presets
oc_active_profile() {
    local cpu_freq="" gpu_freq="" cpu_temp="" label=""

    if [[ -f "$CPU_DEST" ]]; then
        cpu_freq=$(awk -F'= ' '/^frequency/{print $2}' "$CPU_DEST" 2>/dev/null | tr -d ' ')
        cpu_temp=$(awk -F'= ' '/^max_temperature/{print $2}' "$CPU_DEST" 2>/dev/null | tr -d ' ')
    fi
    if [[ -f "$GPU_DEST" ]]; then
        gpu_freq=$(awk -F'= ' '/^frequency/{print $2}' "$GPU_DEST" 2>/dev/null | tr -d ' ' | tail -1)
    fi

    if [[ -n "$cpu_freq" && -n "$gpu_freq" ]]; then
        label="CPU ${cpu_freq}MHz / GPU ${gpu_freq}MHz"
        [[ -n "$cpu_temp" ]] && label+=" / max ${cpu_temp}°C"
        echo "$label"
    else
        echo "Unknown (configs not found)"
    fi
}

# Match current config against preset table — returns preset name or "Custom"
oc_match_preset() {
    local cpu_freq gpu_freq
    [[ ! -f "$CPU_DEST" || ! -f "$GPU_DEST" ]] && echo "Unknown" && return

    cpu_freq=$(awk -F'= ' '/^frequency/{print $2}' "$CPU_DEST" 2>/dev/null | tr -d ' ')
    gpu_freq=$(awk -F'= ' '/^frequency/{print $2}' "$GPU_DEST" 2>/dev/null | tr -d ' ' | tail -1)

    # Preset CPU MHz values matching PRESET_CPU_WRITERS order
    local preset_cpu_freqs=(4000 3850 3500 3500 3500)
    local preset_gpu_freqs=(2350 2100 2100 2000 1500)

    for i in "${!PRESET_NAMES[@]}"; do
        if [[ "$cpu_freq" == "${preset_cpu_freqs[$i]}" && "$gpu_freq" == "${preset_gpu_freqs[$i]}" ]]; then
            echo "${PRESET_NAMES[$i]}"
            return
        fi
    done
    echo "Custom"
}

PRESET_NAMES=("High" "Medium-High" "Medium-Low" "Low" "Stock - Failsafe")
PRESET_DESCS=(
    "CPU 4GHz, GPU 2350MHz — 90°C"
    "CPU 3.85GHz, GPU 2100MHz — 90°C"
    "CPU 3.5GHz, GPU 2100MHz — 80°C"
    "CPU 3.5GHz, GPU 2000MHz — 80°C"
    "CPU 3.5GHz, GPU 1500MHz — 80°C"
)
PRESET_CPU_WRITERS=(write_cpu_overclock_4ghz write_cpu_overclock_3_85ghz write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz)
PRESET_GPU_WRITERS=(write_gpu_overclock_2350mhz write_gpu_overclock_2100mhz write_gpu_overclock_2100mhz write_gpu_overclock_2000mhz write_gpu_overclock_1500mhz)

CPU_NAMES=("Undervolt 3.5 GHz (stock)" "Overclock 3.85 GHz" "Overclock 4 GHz")
CPU_DESCS=("3500 MHz, scale -22, max 80°C" "3850 MHz, scale -30, max 90°C" "4000 MHz, scale -37, max 90°C")
CPU_WRITERS=(write_cpu_undervolt_3_5ghz write_cpu_overclock_3_85ghz write_cpu_overclock_4ghz)

GPU_NAMES=("Overclock 1500 MHz" "Overclock 2000 MHz" "Overclock 2100 MHz" "Overclock 2300 MHz" "Overclock 2350 MHz")
GPU_DESCS=(
    "throttle 80°C — conservative"
    "throttle 80°C — moderate"
    "throttle 80°C — moderate-high"
    "throttle 90°C — high"
    "throttle 90°C — aggressive"
)
GPU_WRITERS=(write_gpu_overclock_1500mhz write_gpu_overclock_2000mhz write_gpu_overclock_2100mhz write_gpu_overclock_2300mhz write_gpu_overclock_2350mhz)

oc_print_summary() {
    local cpu_name="$1" cpu_desc="$2" gpu_name="$3" gpu_desc="$4"
    local custom_temp="${5:-}"
    echo ""
    echo -e "  ${BOLD}${WHITE}Summary:${RESET}"
    echo -e "  ${CYAN}CPU${RESET}  ${cpu_name} — ${cpu_desc}"
    echo -e "  ${CYAN}GPU${RESET}  ${gpu_name} — ${gpu_desc}"
    [[ -n "$custom_temp" ]] && echo -e "  ${CYAN}TMP${RESET}  Temperature override: ${custom_temp}°C (CPU max & GPU throttle)"
    echo ""
}

oc_apply_preset() {
    local idx=$(( $1 - 1 ))
    local name="${PRESET_NAMES[$idx]}"
    local desc="${PRESET_DESCS[$idx]}"

    echo ""
    echo -e "  ${BOLD}${WHITE}Selected:${RESET} ${name} — ${desc}"
    echo ""
    if ! confirm "Apply this preset?"; then
        print_info "Cancelled."
        return 0
    fi

    echo ""
    print_info "Writing and installing CPU config..."
    "${PRESET_CPU_WRITERS[$idx]}"
    install_cpu

    print_info "Writing and installing GPU config..."
    "${PRESET_GPU_WRITERS[$idx]}"
    install_gpu "$GPU_TMPFILE"

    echo ""
    print_success "Preset '${name}' applied!"
    echo -e "  ${CYAN}CPU${RESET}  $(awk -F'= ' '/^frequency/{print $2}' "$CPU_DEST" | tr -d ' ')MHz"
    echo -e "  ${CYAN}GPU${RESET}  $(awk -F'= ' '/^frequency/{print $2}' "$GPU_DEST" | tr -d ' ' | tail -1)MHz"
    echo -e "  ${CYAN}TMP${RESET}  $(awk -F'= ' '/^max_temperature/{print $2}' "$CPU_DEST" | tr -d ' ')°C"
    echo ""
}

oc_prompt_temperature() {
    local default="$1"
    while true; do
        read -rp "$(echo -e "  ${WHITE}Max temperature °C (60-100, default ${default}, 0=cancel):${RESET} ")" t
        [[ "$t" =~ ^[0-9]+$ ]] || { echo "  Invalid input."; continue; }
        [[ "$t" -eq 0 ]] && return 1
        (( t >= 60 && t <= 100 )) || { echo "  Out of range (60-100)."; continue; }
        TEMP_RESULT="$t"
        return 0
    done
}

oc_apply_custom() {
    echo ""
    print_section "CPU Profiles"
    for i in "${!CPU_NAMES[@]}"; do
        print_item "$((i+1))" "${CPU_NAMES[$i]}" "${CPU_DESCS[$i]}"
    done
    echo ""
    read -rp "$(echo -e "  ${BOLD}${WHITE}Select CPU profile (0=cancel):${RESET} ")" cpu_choice
    [[ "$cpu_choice" =~ ^[0-9]+$ ]] || { print_error "Invalid input."; return 1; }
    [[ "$cpu_choice" -eq 0 ]] && { print_info "Cancelled."; return 0; }
    (( cpu_choice >= 1 && cpu_choice <= ${#CPU_NAMES[@]} )) || { print_error "Invalid selection."; return 1; }

    echo ""
    print_section "GPU Profiles"
    for i in "${!GPU_NAMES[@]}"; do
        print_item "$((i+1))" "${GPU_NAMES[$i]}" "${GPU_DESCS[$i]}"
    done
    echo ""
    read -rp "$(echo -e "  ${BOLD}${WHITE}Select GPU profile (0=cancel):${RESET} ")" gpu_choice
    [[ "$gpu_choice" =~ ^[0-9]+$ ]] || { print_error "Invalid input."; return 1; }
    [[ "$gpu_choice" -eq 0 ]] && { print_info "Cancelled."; return 0; }
    (( gpu_choice >= 1 && gpu_choice <= ${#GPU_NAMES[@]} )) || { print_error "Invalid selection."; return 1; }

    local cpu_idx=$(( cpu_choice - 1 )) gpu_idx=$(( gpu_choice - 1 ))
    local custom_temp=""

    # Single temperature prompt — applies to both CPU max and GPU throttle
    echo ""
    read -rp "$(echo -e "  ${WHITE}Override temperature limit? [y/N]:${RESET} ")" yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        local default_temp=80
        (( gpu_idx >= 2 )) && default_temp=90
        oc_prompt_temperature "$default_temp" || { print_info "Cancelled."; return 0; }
        custom_temp="$TEMP_RESULT"
    fi

    oc_print_summary \
        "${CPU_NAMES[$cpu_idx]}" "${CPU_DESCS[$cpu_idx]}" \
        "${GPU_NAMES[$gpu_idx]}" "${GPU_DESCS[$gpu_idx]}" \
        "$custom_temp"

    if ! confirm "Apply this custom profile?"; then
        print_info "Cancelled."
        return 0
    fi

    echo ""
    print_info "Writing and installing CPU config..."
    "${CPU_WRITERS[$cpu_idx]}"
    [[ -n "$custom_temp" ]] && sed -i "s/^max_temperature = .*/max_temperature = ${custom_temp}/" "$CPU_TMPFILE"
    install_cpu

    print_info "Writing and installing GPU config..."
    "${GPU_WRITERS[$gpu_idx]}"
    if [[ -n "$custom_temp" ]]; then
        local recovery=$(( custom_temp - 5 ))
        sed -i "s/^throttling = .*/throttling = ${custom_temp}/" "$GPU_TMPFILE"
        sed -i "s/^throttling_recovery = .*/throttling_recovery = ${recovery}/" "$GPU_TMPFILE"
    fi
    install_gpu "$GPU_TMPFILE"

    echo ""
    print_success "Custom profile applied!"
    echo -e "  ${CYAN}CPU${RESET}  $(awk -F'= ' '/^frequency/{print $2}' "$CPU_DEST" | tr -d ' ')MHz  /  max $(awk -F'= ' '/^max_temperature/{print $2}' "$CPU_DEST" | tr -d ' ')°C"
    echo -e "  ${CYAN}GPU${RESET}  $(awk -F'= ' '/^frequency/{print $2}' "$GPU_DEST" | tr -d ' ' | tail -1)MHz  /  throttle $(awk -F'= ' '/^throttling /{print $2}' "$GPU_DEST" | tr -d ' ')°C"
    echo ""
}

run_overclock_menu() {
    while true; do
        print_banner
        print_section "Performance Profile Menu"
        echo -e "  ${DIM}Active: $(oc_match_preset) — $(oc_active_profile)${RESET}"
        echo ""
        for i in "${!PRESET_NAMES[@]}"; do
            print_item "$((i+1))" "${PRESET_NAMES[$i]}" "${PRESET_DESCS[$i]}"
        done
        echo ""
        print_item "C" "Custom"           "Mix & match CPU and GPU profiles"
        print_item "E" "Edit with Kate"  "Manually edit GPU overclock"
        print_item "0" "Back to Main Menu" ""
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" oc_choice

        case "${oc_choice^^}" in
            C) oc_apply_custom;      press_enter ;;
            E) oc_edit_gpu_config_kate; press_enter ;;
            0) return 0 ;;
            *)
                if [[ "$oc_choice" =~ ^[0-9]+$ ]] && (( oc_choice >= 1 && oc_choice <= ${#PRESET_NAMES[@]} )); then
                    oc_apply_preset "$oc_choice"
                    press_enter
                else
                    print_error "Invalid selection: '$oc_choice'"
                    sleep 1
                fi
                ;;
        esac
    done
}


run_revert_zswap() {
    local CONF="/etc/default/limine"
    print_step "08" "Revert ZSWAP — Re-enabling ZRAM"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if ! confirm "This will remove zswap params and re-enable ZRAM in $CONF. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    # --- Remove zswap params ---
    if grep -q 'zswap\.enabled=1' "$CONF"; then
        print_info "Removing zswap parameters..."
        sed -i 's/ zswap\.enabled=1//g;s/ zswap\.max_pool_percent=[0-9]*//g;s/ zswap\.compressor=[a-z0-9]*//g' "$CONF"
        print_info "ZSWAP parameters removed."
    else
        print_info "No zswap parameters found — skipping."
    fi

    # --- Re-enable ZRAM ---
    if grep -q 'systemd\.zram=0' "$CONF"; then
        print_info "Re-enabling ZRAM..."
        sed -i 's/ systemd\.zram=0//g' "$CONF"
        print_info "ZRAM re-enabled."
    else
        print_info "systemd.zram=0 not found — ZRAM already enabled."
    fi

    # --- Remove lz4 from mkinitcpio ---
    local MKINITCPIO="/etc/mkinitcpio.conf"
    if grep -q 'lz4' "$MKINITCPIO"; then
        print_info "Removing lz4 modules from initramfs..."
        sed -i 's/ lz4_compress//g;s/ lz4//g' "$MKINITCPIO"
        print_info "Rebuilding initramfs..."
        mkinitcpio -P
        print_info "Initramfs rebuilt."
    else
        print_info "lz4 not found in $MKINITCPIO — skipping."
    fi

    print_info "Regenerating /boot/limine.conf..."
    limine-update
    print_success "Revert complete! Reboot to restore ZRAM and disable ZSWAP."
    echo -e "  ${DIM}After reboot, verify with: systemctl is-active systemd-zram-setup@zram0.service${RESET}\n"
}


run_disable_mitigations() {
    local CONF="/etc/default/limine"
    print_step "07" "Disabling CPU Mitigations in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    if grep -q 'mitigations=off' "$CONF"; then
        print_info "mitigations=off already present in $CONF — skipping."
        return 0
    fi

    print_info "Adding mitigations=off..."
    sed -i '/^KERNEL_CMDLINE/s/"$/ mitigations=off"/' "$CONF"
    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        print_info "Regenerating /boot/limine.conf..."
        limine-update
    fi
    print_success "mitigations=off added. Reboot to apply."
    echo -e "  ${DIM}Note: this disables Spectre/Meltdown mitigations for a performance gain.${RESET}\n"
}

run_status() {
    print_banner
    print_section "System Status"

    local LIMINE_CONF="/etc/default/limine"
    local CPU_CONF="/etc/bc250-smu-oc.conf"
    local GPU_CONF="/etc/cyan-skillfish-governor-smu/config.toml"
    local MKINITCPIO="/etc/mkinitcpio.conf"

    # --- System ---
    echo -e "  ${BOLD}${YELLOW}System${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

    local OVERRIDE_FILE="/etc/plasmalogin.conf.d/zzz-bc250-boot.conf"
    local CONF_DIR="/etc/plasmalogin.conf.d"
    local boot_mode="${BOLD}${GREEN}Game Mode${RESET}"
    if [[ -f "$OVERRIDE_FILE" ]]; then
        grep -q "plasma.desktop" "$OVERRIDE_FILE" && boot_mode="${BOLD}${CYAN}Desktop Mode${RESET}"
    else
        grep -rq "plasma.desktop" "$CONF_DIR"/*.conf 2>/dev/null && boot_mode="${BOLD}${CYAN}Desktop Mode${RESET}"
    fi
    echo -e "  ${CYAN}Boot Mode${RESET}         ${boot_mode}"
    echo -e "  ${CYAN}Kernel${RESET}            $(uname -r)"
    echo ""

    # --- Overclock Profile ---
    echo -e "  ${BOLD}${YELLOW}Overclock${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"
    if [[ -f "$CPU_CONF" ]]; then
        local cpu_freq cpu_scale cpu_temp cpu_preset
        cpu_freq=$(awk -F'= ' '/^frequency/{print $2}' "$CPU_CONF" | tr -d ' ')
        cpu_scale=$(awk -F'= ' '/^scale/{print $2}' "$CPU_CONF" | tr -d ' ')
        cpu_temp=$(awk -F'= ' '/^max_temperature/{print $2}' "$CPU_CONF" | tr -d ' ')
        cpu_preset=$(oc_match_preset)
        echo -e "  ${CYAN}Preset${RESET}            ${BOLD}${WHITE}${cpu_preset}${RESET}"
        echo -e "  ${CYAN}CPU Profile${RESET}       ${cpu_freq}MHz  scale ${cpu_scale}  max ${cpu_temp}°C"
    else
        echo -e "  ${CYAN}CPU Profile${RESET}       ${DIM}config not found${RESET}"
    fi

    if [[ -f "$GPU_CONF" ]]; then
        local gpu_freq gpu_throttle
        gpu_freq=$(awk -F'= ' '/^frequency/{print $2}' "$GPU_CONF" | tr -d ' ' | tail -1)
        gpu_throttle=$(awk -F'= ' '/^throttling /{print $2}' "$GPU_CONF" | tr -d ' ')
        echo -e "  ${CYAN}GPU Profile${RESET}       ${gpu_freq}MHz  throttle ${gpu_throttle}°C"
    else
        echo -e "  ${CYAN}GPU Profile${RESET}       ${DIM}config not found${RESET}"
    fi

    local cpu_svc_enabled cpu_svc_result gpu_svc_state
    cpu_svc_enabled=$(systemctl is-enabled bc250-smu-oc.service 2>/dev/null || echo "disabled")
    cpu_svc_result=$(systemctl show bc250-smu-oc.service --property=ExecMainStatus --value 2>/dev/null || echo "unknown")
    gpu_svc_state=$(systemctl is-active cyan-skillfish-governor-smu.service 2>/dev/null || echo "unknown")

    local cpu_color gpu_color cpu_label
    if [[ "$cpu_svc_enabled" == "enabled" && "$cpu_svc_result" == "0" ]]; then
        cpu_color="$GREEN"; cpu_label="enabled (applied successfully)"
    elif [[ "$cpu_svc_enabled" == "enabled" ]]; then
        cpu_color="$YELLOW"; cpu_label="enabled (exit code: ${cpu_svc_result})"
    else
        cpu_color="$RED"; cpu_label="disabled"
    fi
    [[ "$gpu_svc_state" == "active" ]] && gpu_color="$GREEN" || gpu_color="$RED"
    echo -e "  ${CYAN}CPU Service${RESET}       ${cpu_color}${cpu_label}${RESET}"
    echo -e "  ${CYAN}GPU Service${RESET}       ${gpu_color}${gpu_svc_state}${RESET}"
    echo ""

    # --- Memory / Swap ---
    echo -e "  ${BOLD}${YELLOW}Memory & Swap${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

    # ZSWAP Detection
    local zswap_enabled zswap_compressor zswap_pool
    zswap_enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
    zswap_compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo "N/A")
    zswap_pool=$(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo "N/A")
    local zswap_color
    [[ "$zswap_enabled" == "Y" ]] && zswap_color="$GREEN" || zswap_color="$RED"
    echo -e "  ${CYAN}ZSWAP${RESET}              ${zswap_color}${zswap_enabled}${RESET}  compressor=${zswap_compressor}  pool=${zswap_pool}%"

    # ZRAM Detection (Checks kernel device instead of just one specific service)
    local zram_state="inactive"
    if [[ -d /sys/block/zram0 ]]; then
        zram_state="active"
    fi
    local zram_color
    [[ "$zram_state" == "active" ]] && zram_color="$GREEN" || zram_color="$DIM"
    echo -e "  ${CYAN}ZRAM${RESET}               ${zram_color}${zram_state}${RESET}"

    # Swappiness
    local swappiness
    swappiness=$(cat /proc/sys/vm/swappiness 2>/dev/null || echo "N/A")
    echo -e "  ${CYAN}Swappiness${RESET}         ${swappiness}"

    # Swap Devices (Filtered to avoid empty/inactive lines)
    echo -e "  ${CYAN}Swap Devices${RESET}"
    local swap_output
    swap_output=$(swapon --show --noheadings 2>/dev/null)
    if [[ -z "$swap_output" ]]; then
        echo -e "    ${DIM}(No active swap devices found)${RESET}"
    else
        echo "$swap_output" | while read -r name type size used prio; do
            echo -e "    ${DIM}${name}  ${type}  size=${size}  used=${used}  prio=${prio}${RESET}"
        done
    fi
    echo ""

    # --- Kernel Parameters ---
    echo -e "  ${BOLD}${YELLOW}Kernel Parameters${RESET}  ${DIM}(source: $LIMINE_CONF)${RESET}"
    echo -e "  ${DIM}──────────────────────────────────────────────────────────────${RESET}"

    if [[ -f "$LIMINE_CONF" ]]; then
        local loglevel mitigations_off zram_disabled zswap_conf lz4_initrd
        loglevel=$(grep -o 'loglevel=[0-9]*' "$LIMINE_CONF" | head -1 || echo "not set")
        grep -q 'mitigations=off' "$LIMINE_CONF" && mitigations_off="off ${RED}(vulnerable)${RESET}" || mitigations_off="${GREEN}on (default)${RESET}"
        grep -q 'systemd\.zram=0' "$LIMINE_CONF" && zram_disabled="${RED}disabled${RESET}" || zram_disabled="${GREEN}enabled (default)${RESET}"
        grep -q 'zswap\.enabled=1' "$LIMINE_CONF" && zswap_conf="${GREEN}enabled${RESET}" || zswap_conf="${DIM}not set${RESET}"
        grep -q 'lz4' "$MKINITCPIO" 2>/dev/null && lz4_initrd="${GREEN}yes${RESET}" || lz4_initrd="${DIM}no${RESET}"

        echo -e "  ${CYAN}loglevel${RESET}          ${loglevel}"
        echo -e "  ${CYAN}Mitigations${RESET}       ${mitigations_off}"
        echo -e "  ${CYAN}ZRAM (cmdline)${RESET}    ${zram_disabled}"
        echo -e "  ${CYAN}ZSWAP (cmdline)${RESET}   ${zswap_conf}"
        echo -e "  ${CYAN}lz4 in initramfs${RESET}  ${lz4_initrd}"
    else
        echo -e "  ${RED}$LIMINE_CONF not found${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

run_revert_loglevel() {
    local CONF="/etc/default/limine"
    print_step "10" "Revert loglevel — Restoring default"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if ! grep -q 'loglevel=' "$CONF"; then
        print_info "No loglevel parameter found — nothing to revert."
        return 0
    fi

    if grep -q 'loglevel=3' "$CONF"; then
        print_info "loglevel is already at default (3) — nothing to do."
        return 0
    fi

    if ! confirm "This will restore loglevel to 3 in $CONF. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    sed -i 's/loglevel=[0-9]*/loglevel=3/g' "$CONF"
    print_info "Regenerating /boot/limine.conf..."
    limine-update
    print_success "loglevel restored to 3. Reboot to apply."
}

run_revert_mitigations() {
    local CONF="/etc/default/limine"
    print_step "09" "Revert Mitigations — Re-enabling in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    if ! confirm "This will remove mitigations=off from $CONF. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    if ! grep -q 'mitigations=off' "$CONF"; then
        print_info "mitigations=off not found — nothing to revert."
        return 0
    fi

    print_info "Removing mitigations=off..."
    sed -i 's/ mitigations=off//g' "$CONF"
    print_info "Regenerating /boot/limine.conf..."
    limine-update
    print_success "mitigations=off removed. Reboot to re-enable CPU security mitigations."
}

run_all() {
    print_step "★" "Running All Setup Tasks (2–7)"
    echo -e "  ${DIM}This will run: CPU Governor, GPU Governor, Enable Swap,"
    echo -e "  Hide RDSEED Warning, Disable ZRAM / Enable ZSWAP, and Disable Mitigations.${RESET}"

    if ! confirm "Proceed with all tasks?"; then
        print_info "Cancelled."
        return 0
    fi

    local failed=0
    SKIP_LIMINE_UPDATE=1

    # Define the list of tasks to run
    local tasks=(
        run_cpu_governor
        run_gpu_governor
        run_enable_swap
        run_set_loglevel
        run_disable_zram_enable_zswap
        run_disable_mitigations
    )

    for task in "${tasks[@]}"; do
        # --- NEW: PACMAN LOCK GUARD ---
        # Checks if pacman is busy BEFORE starting the next task
        while [ -f /var/lib/pacman/db.lck ]; do
            print_info "Waiting for system locks to release before: ${task//_/ }..."
            sleep 2
        done

        echo ""
        echo -e "  ${BG_HEADER}${BOLD}${WHITE}  Running: ${task//_/ }  ${RESET}"

        if $task; then
            # Optional: Short sleep to let system services settle after a success
            sleep 1
        else
            print_error "Task failed: $task — continuing with remaining tasks."
            (( failed++ )) || true
        fi
        echo ""
    done

    # Re-enable and run the bootloader update once at the end
    SKIP_LIMINE_UPDATE=0
    print_info "Regenerating /boot/limine.conf..."
    if ! limine-update; then
        print_error "Failed to update Limine. Please run manually."
        (( failed++ ))
    fi

    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
    if [[ "$failed" -eq 0 ]]; then
        print_success "All tasks completed successfully!"
    else
        print_error "$failed task(s) encountered errors. Review output above."
    fi
}
# ==============================================================================
# MAIN MENU LOOP
# ==============================================================================

show_menu() {
    print_banner
    print_section "Performance"
    print_item  "1"  "Overclock Menu"      "CPU & GPU performance profiles"
    echo ""
    print_section "Setup Tasks"
    print_item  "A"  "Run All (2-7)"       "Run all setup tasks in sequence"
    echo ""
    print_item  "2"  "CPU Governor"        "bc250-smu-oc CPU overclock service"
    print_item  "3"  "GPU Governor"        "cyan-skillfish GPU governor service"
    print_item  "4"  "Enable Swap"         "16G Btrfs swapfile, swappiness=180"
    print_item  "5"  "Hide RDSEED Warning" "Set loglevel=0 in /boot/limine.conf"
    print_item  "6"  "ZRAM -> ZSWAP"       "Disable ZRAM, enable ZSWAP w/ lz4"
    print_item  "7"  "Disable Mitigations" "Add mitigations=off to limine.conf"
    echo ""
    print_section "Extras"
    print_item  "8"  "Revert ZSWAP"        "Remove zswap, re-enable ZRAM"
    print_item  "9"  "Revert Mitigations"  "Re-enable CPU security mitigations"
    print_item  "10" "Revert loglevel"     "Restore loglevel to default (3)"
    print_item  "11" "Toggle Boot Mode"    "Switch between Game Mode & Desktop"
    print_item "12" "CachyOS Kernel"       "Replaces Deckify kernel with standard CachyOS"
    print_item "13" "Install ACPI Fix"     "Enable CPU C-States (800MHz-3.2GHz)"
    echo ""
    print_item  "S"  "Status"              "Summary of current system settings"
    echo ""
    print_item  "0"  "Exit"                ""
    echo ""
    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

while true; do
    show_menu
    read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" choice

    case "${choice^^}" in
        1) run_overclock_menu ;;
        2) run_cpu_governor;              press_enter ;;
        3) run_gpu_governor;              press_enter ;;
        4) run_enable_swap;               press_enter ;;
        5) run_set_loglevel;              press_enter ;;
        6) run_disable_zram_enable_zswap; press_enter ;;
        7) run_disable_mitigations;       press_enter ;;
        8) run_revert_zswap;              press_enter ;;
        9) run_revert_mitigations;        press_enter ;;
        10) run_revert_loglevel;          press_enter ;;
        11) run_toggle_boot_mode;         press_enter ;;
        12) run_switch_to_default_kernel  press_enter ;;
        13) run_install_acpi_fix;         press_enter ;;
        S) run_status;                    press_enter ;;
        A) run_all;                       press_enter ;;
        0)
            echo -e "\n  ${DIM}Goodbye.${RESET}\n"
            exit 0
            ;;
        *)
            print_error "Invalid selection: '$choice'"
            sleep 1
            ;;
    esac
done
