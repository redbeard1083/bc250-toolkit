#!/usr/bin/env bash
# ==============================================================================
#  CachyOS BC250 Toolkit
#  Main setup and configuration menu
# ==============================================================================

set -euo pipefail

# ==============================================================================
# SERVICE MODE — must run before interactive code, sudo check, or UI setup
# Invoked by the systemd boot service as: bc250-toolkit --yes apply-service
# ==============================================================================
if [[ "${1:-}" == "apply-service" ]] || [[ "${2:-}" == "apply-service" ]]; then
    # Minimal color codes needed for cu_info/cu_warn output to journal
    BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; CYAN=""; WHITE=""

    CU_ASIC="${UMR_ASIC:-cyan_skillfish.gfx1013}"
    CU_REG_CC="mmCC_GC_SHADER_ARRAY_CONFIG"
    CU_REG_SPI="mmSPI_PG_ENABLE_STATIC_WGP_MASK"
    CU_REG_RLC="mmRLC_PG_ALWAYS_ON_WGP_MASK"
    CU_SERVICE_CONF="/etc/bc250-cu-live-manager.conf"
    CU_WGP_FULL_MASK=0x1f
    CU_UMR="${UMR:-}"
    CU_UMR_INSTANCE="${UMR_INSTANCE:-}"
    CU_UMR_INSTANCE_ARGS=()
    CU_LAST_REG_PATH=""
    CU_DRY_RUN=0
    CU_DISCLAIMER_ACCEPTED=1

    cu_info() { echo "  ✔  $*"; }
    cu_warn() { echo "  ⚠  $*" >&2; }
    cu_err()  { echo "  ✘  $*" >&2; }
    cu_die()  { cu_err "$@"; exit 1; }

    cu_parse_hex() {
        awk '{for(i=NF;i>=1;i--){if($i~/^0x[0-9a-fA-F]+$/){print $i;exit}}}'
    }
    cu_umr_output_failed() {
        printf '%s\n' "$1" | grep -Eqi '(\[ERROR\]|error|failed|invalid|unknown|cannot|no such)'
    }
    cu_reg_candidates() { printf '%s\n' "$1"; }
    cu_hex_mask()   { printf '0x%02x' "$(( $1 & 31 ))"; }
    cu_hex_to_dec() { printf '%d' "$(( $1 ))"; }
    cu_row_coords() {
        case "$1" in 0) printf '0 0';; 1) printf '0 1';; 2) printf '1 0';; 3) printf '1 1';; esac
    }
    cu_wgp_mask_cu_count() {
        local mask="$1" wgp count=0
        for wgp in 0 1 2 3 4; do
            if [ $((mask & (1 << wgp))) -ne 0 ]; then count=$((count + 2)); fi
        done
        printf '%s\n' "$count"
    }

    # Find umr — prefer conf value, then search standard paths
    _umr=""
    [ -n "$CU_UMR" ] && [ -x "$CU_UMR" ] && _umr="$CU_UMR"
    if [ -z "$_umr" ]; then
        for _p in /usr/bin/umr /usr/local/bin/umr /opt/umr/build/src/app/umr; do
            [ -x "$_p" ] && { _umr="$_p"; break; }
        done
    fi
    [ -n "$_umr" ] || cu_die "umr not installed — cannot apply boot profile"
    CU_UMR="$_umr"

    # Set instance args
    if [ -n "$CU_UMR_INSTANCE" ]; then
        CU_UMR_INSTANCE_ARGS=(-i "$CU_UMR_INSTANCE")
    fi

    # Load saved masks from conf
    _csv=""
    [ -f "$CU_SERVICE_CONF" ] || cu_die "no boot profile found at $CU_SERVICE_CONF"
    while IFS= read -r _line; do
        case "$_line" in BC250_WGP_MASKS=*) _csv="${_line#BC250_WGP_MASKS=}"; break;; esac
    done <"$CU_SERVICE_CONF"
    [ -n "$_csv" ] || cu_die "BC250_WGP_MASKS not found in $CU_SERVICE_CONF"

    IFS=',' read -ra _items <<<"$_csv"
    [ "${#_items[@]}" -eq 4 ] || cu_die "invalid mask count in $CU_SERVICE_CONF"
    declare -a service_masks=()
    for _i in 0 1 2 3; do
        _v=$(( ${_items[$_i]} ))
        [ "$_v" -ge 0 ] && [ "$_v" -le 31 ] || cu_die "mask out of range: ${_items[$_i]}"
        service_masks[$_i]="$_v"
    done

    # Verify ASIC is reachable — retry with a bounded backoff. The DRM render
    # node (checked by ExecStartPre) can exist before the GPU is actually
    # ready to service umr register reads, causing a single-shot check to
    # fail intermittently at boot. See GitHub issue #9.
    _cu_max_attempts="${BC250_CU_RETRY_ATTEMPTS:-60}"
    _cu_retry_delay="${BC250_CU_RETRY_DELAY:-1}"
    _val=""
    for (( _attempt = 1; _attempt <= _cu_max_attempts; _attempt++ )); do
        _out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -r "$CU_ASIC.$CU_REG_SPI" 2>&1 || true)"
        _val="$(printf '%s\n' "$_out" | cu_parse_hex)"
        if [ -n "$_val" ]; then
            cu_info "GPU register access ready on attempt ${_attempt}/${_cu_max_attempts}"
            break
        fi
        if [ "$_attempt" -eq "$_cu_max_attempts" ]; then
            cu_die "umr could not read $CU_ASIC.$CU_REG_SPI after ${_cu_max_attempts} attempts — GPU not ready"
        fi
        cu_warn "GPU not ready, retrying in ${_cu_retry_delay}s (${_attempt}/${_cu_max_attempts})"
        sleep "$_cu_retry_delay"
    done

    # Apply masks
    declare -a target_masks=("${service_masks[@]}")

    cu_try_write_reg_global() {
        local reg="$1" value="$2" candidate out
        while IFS= read -r candidate; do
            CU_LAST_REG_PATH="$CU_ASIC.$candidate"
            out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -w "$CU_LAST_REG_PATH" "$value" 2>&1 || true)"
            cu_umr_output_failed "$out" || return 0
        done < <(cu_reg_candidates "$reg")
        return 1
    }
    cu_write_reg_bank() {
        local reg="$1" value="$2" se="$3" sh="$4" candidate out
        while IFS= read -r candidate; do
            CU_LAST_REG_PATH="$CU_ASIC.$candidate"
            out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -w "$CU_LAST_REG_PATH" "$value" -b "$se" "$sh" 0xffffffff 2>&1 || true)"
            cu_umr_output_failed "$out" || return 0
        done < <(cu_reg_candidates "$reg")
        cu_die "failed to write $reg=$value for SE$se SH$sh"
    }

    cu_try_write_reg_global "$CU_REG_CC" "0x0" || cu_warn "could not write global $CU_REG_CC"
    _union=0
    for _idx in 0 1 2 3; do
        read -r _se _sh <<<"$(cu_row_coords "$_idx")"
        cu_write_reg_bank "$CU_REG_CC" 0x0 "$_se" "$_sh"
        cu_write_reg_bank "$CU_REG_SPI" "$(cu_hex_mask "${target_masks[$_idx]}")" "$_se" "$_sh"
        _union=$((_union | target_masks[_idx]))
    done
    cu_try_write_reg_global "$CU_REG_RLC" "$(cu_hex_mask "$_union")" || \
        cu_warn "could not write $CU_REG_RLC"

    _total=0
    for _idx in 0 1 2 3; do
        _total=$((_total + $(cu_wgp_mask_cu_count "${target_masks[$_idx]}")))
    done
    cu_info "BC-250 boot profile applied: ${_total}/40 CUs active"
    exit 0
fi

# From here on we're in the interactive menu. Functions throughout this
# script deliberately use 'return 1' to signal a recoverable error (print a
# message, let the menu loop continue) — that's incompatible with 'set -e',
# which would otherwise kill the entire script the moment any case-statement
# action returns non-zero, before the user ever sees a chance to continue.
# 'set -u' and pipefail stay on; only errexit is dropped here.
set +e

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

# AUR helper — detects yay or paru in that order
aur_helper() {
    if command -v yay >/dev/null 2>&1; then printf "yay"
    elif command -v paru >/dev/null 2>&1; then printf "paru"
    else return 1
    fi
}

# Installs yay automatically if no AUR helper is present. Tries pacman
# first (CachyOS ships yay directly in its own repos), falling back to
# building it from the AUR as the real user if pacman doesn't have it.
ensure_aur_helper() {
    aur_helper >/dev/null 2>&1 && return 0

    print_info "No AUR helper found — installing yay..."

    if command -v pacman >/dev/null 2>&1 && pacman -Si yay >/dev/null 2>&1; then
        if pacman -S --needed --noconfirm yay; then
            aur_helper >/dev/null 2>&1 && return 0
        fi
        print_error "pacman could not install yay — check the output above."
        return 1
    fi

    print_info "yay is not available via pacman — building it from the AUR..."
    local user_home build_dir
    user_home="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    build_dir="$user_home/.cache/bc250-toolkit/yay"

    sudo -u "$REAL_USER" mkdir -p "$(dirname "$build_dir")"
    if [[ -d "$build_dir" ]]; then
        sudo -u "$REAL_USER" git -C "$build_dir" pull || { print_error "Failed to pull the yay repository."; return 1; }
    else
        sudo -u "$REAL_USER" git clone https://aur.archlinux.org/yay.git "$build_dir" || { print_error "Failed to clone the yay repository."; return 1; }
    fi

    if ! sudo -u "$REAL_USER" bash -c "cd '$build_dir' && makepkg -si --noconfirm"; then
        print_error "Failed to build/install yay from source."
        return 1
    fi

    if aur_helper >/dev/null 2>&1; then
        return 0
    fi
    print_error "yay installation reported success but the binary could not be found afterward."
    return 1
}

aur_install() {
    local package="$1"
    if ! ensure_aur_helper; then
        print_error "No AUR helper available and automatic installation of yay failed."
        return 1
    fi
    local helper
    helper="$(aur_helper)"
    print_info "Installing $package via $helper..."
    case "$helper" in
        yay)  sudo -u "$REAL_USER" yay -S --noconfirm "$package" ;;
        paru) sudo -u "$REAL_USER" paru -S --noconfirm "$package" ;;
    esac
}

aur_remove() {
    local package="$1"
    if ! ensure_aur_helper; then
        print_error "No AUR helper available and automatic installation of yay failed."
        return 1
    fi
    local helper
    helper="$(aur_helper)"
    print_info "Removing $package via $helper..."
    case "$helper" in
        yay)  sudo -u "$REAL_USER" yay -Rns --noconfirm "$package" 2>/dev/null || true ;;
        paru) sudo -u "$REAL_USER" paru -Rns --noconfirm "$package" 2>/dev/null || true ;;
    esac
}

# Bootloader detection
detect_bootloader() {
    if [[ -f /etc/default/limine ]]; then echo "limine"
    elif [[ -f /etc/default/grub ]]; then echo "grub"
    else echo "unknown"
    fi
}

bootloader_conf() {
    case "$(detect_bootloader)" in
        limine) echo "/etc/default/limine" ;;
        grub)   echo "/etc/default/grub" ;;
        *)      echo "" ;;
    esac
}

bootloader_update() {
    case "$(detect_bootloader)" in
        limine)
            print_info "Regenerating Limine boot config..."
            limine-update
            ;;
        grub)
            print_info "Regenerating GRUB boot config..."
            grub-mkconfig -o /boot/grub/grub.cfg
            ;;
        *)
            print_error "Unknown bootloader — please update your boot config manually."
            return 1
            ;;
    esac
}

bootloader_cmdline_var() {
    case "$(detect_bootloader)" in
        limine) echo "KERNEL_CMDLINE[default]" ;;
        grub)   echo "GRUB_CMDLINE_LINUX_DEFAULT" ;;
        *)      echo "" ;;
    esac
}

# Returns the cmdline var with regex special chars escaped for use in sed
bootloader_cmdline_var_escaped() {
    bootloader_cmdline_var | sed 's/\[/\\[/g; s/\]/\\]/g'
}

# Initramfs detection
detect_initramfs() {
    if command -v mkinitcpio &>/dev/null; then echo "mkinitcpio"
    elif command -v dracut &>/dev/null;   then echo "dracut"
    else echo "unknown"
    fi
}

initramfs_add_module() {
    local module="$1"
    case "$(detect_initramfs)" in
        mkinitcpio)
            local MKINITCPIO="/etc/mkinitcpio.conf"
            if grep -q "$module" "$MKINITCPIO"; then
                print_info "$module already present in $MKINITCPIO — skipping."
            else
                print_info "Adding $module to initramfs modules..."
                sed -i "s/^MODULES=(\(.*\))/MODULES=(\1 $module)/" "$MKINITCPIO"
            fi
            ;;
        dracut)
            local DRACUT_CONF="/etc/dracut.conf.d/bc250-modules.conf"
            print_info "Adding $module to dracut config..."
            echo "add_drivers+=\" $module \"" >> "$DRACUT_CONF"
            ;;
        *)
            print_error "Unknown initramfs tool — add $module manually."
            return 1
            ;;
    esac
}

initramfs_remove_module() {
    local module="$1"
    case "$(detect_initramfs)" in
        mkinitcpio)
            local MKINITCPIO="/etc/mkinitcpio.conf"
            if grep -q "$module" "$MKINITCPIO"; then
                print_info "Removing $module from initramfs modules..."
                sed -i "s/ ${module}//g" "$MKINITCPIO"
            else
                print_info "$module not found in $MKINITCPIO — skipping."
            fi
            ;;
        dracut)
            local DRACUT_CONF="/etc/dracut.conf.d/bc250-modules.conf"
            if [[ -f "$DRACUT_CONF" ]]; then
                print_info "Removing $module from dracut config..."
                sed -i "/ $module /d" "$DRACUT_CONF"
            fi
            ;;
        *)
            print_error "Unknown initramfs tool — remove $module manually."
            return 1
            ;;
    esac
}

initramfs_rebuild() {
    case "$(detect_initramfs)" in
        mkinitcpio)
            if [[ "$(detect_bootloader)" == "limine" ]] && command -v limine-mkinitcpio &>/dev/null; then
                # CachyOS + Limine systems often have no mkinitcpio presets
                # configured — plain `mkinitcpio -P` finds nothing to build
                # and prompts interactively to use this tool instead, which
                # hangs a non-interactive script. limine-mkinitcpio also
                # correctly updates Limine's boot entries in the process.
                # GRUB systems don't have this quirk and use the normal
                # preset-based rebuild below.
                print_info "Rebuilding initramfs with limine-mkinitcpio..."
                limine-mkinitcpio
            else
                print_info "Rebuilding initramfs with mkinitcpio..."
                mkinitcpio -P
            fi
            ;;
        dracut)
            print_info "Rebuilding initramfs with dracut..."
            dracut --force
            ;;
        *)
            print_error "Unknown initramfs tool — rebuild manually."
            return 1
            ;;
    esac
}

print_banner() {
    clear
    echo -e "${BOLD}${CYAN}"
    echo "  ╔═════════════════════════════════════════════════════════════════════╗"
    echo "  ║                                                                     ║"
    echo "  ║                        CachyOS BC250 Toolkit                        ║"
    echo "  ║                    System Setup & Configuration                     ║"
    echo "  ║                                                                     ║"
    echo "  ╚═════════════════════════════════════════════════════════════════════╝"
    echo -e "${RESET}"
}

print_section() {
    echo -e "  ${BOLD}${YELLOW}$1${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
}

print_item() {
    local num="$1"
    local label="$2"
    local desc="$3"
    # Calculate visual width by stripping multi-byte chars and measuring byte difference
    local label_bytes=${#label}
    local label_visual=$(echo -n "$label" | wc -m)
    local extra=$(( label_bytes - label_visual ))
    local width=$(( 26 + extra ))
    printf "  ${BOLD}${WHITE}[${CYAN}%2s${WHITE}]${RESET}  %-${width}s ${DIM}%s${RESET}\n" "$num" "$label" "$desc"
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

    local user_home
    user_home="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    local user_bin="$user_home/.local/bin"
    local build_dir="$user_home/.cache/bc250-toolkit/bc250_smu_oc"

    if systemctl is-enabled bc250-smu-oc.service &>/dev/null || \
       [[ -x "$user_bin/bc250-detect" ]]; then
        print_info "CPU governor already installed — skipping."
        return 0
    fi

    print_info "Installing dependencies: python-pipx, stress"
    pacman -Syu python-pipx stress --noconfirm || { print_error "Failed to install dependencies."; return 1; }

    print_info "Cloning bc250_smu_oc repository as $REAL_USER..."
    sudo -u "$REAL_USER" mkdir -p "$(dirname "$build_dir")"
    if [[ -d "$build_dir" ]]; then
        print_info "Directory already exists — pulling latest changes..."
        sudo -u "$REAL_USER" git -C "$build_dir" pull || { print_error "Failed to pull repository."; return 1; }
    else
        sudo -u "$REAL_USER" git clone https://github.com/bc250-collective/bc250_smu_oc.git "$build_dir" || { print_error "Failed to clone repository."; return 1; }
    fi

    # Install and run as the real user, not root — bc250_smu_oc installs into
    # the invoking user's pipx bin dir and elevates itself internally when it
    # needs SMU access. Installing as root instead puts the binaries in
    # /root/.local/bin, where the user's own shell can never find them.
    print_info "Installing via pipx as $REAL_USER..."
    sudo -u "$REAL_USER" bash -c "cd '$build_dir' && pipx install . && pipx ensurepath" \
        || { print_error "Failed to install via pipx."; return 1; }

    print_info "Running bc250-detect as $REAL_USER (it will elevate privileges itself if needed)..."
    sudo -u "$REAL_USER" env PATH="$user_bin:$PATH" bash -c "cd '$build_dir' && bc250-detect --frequency 3500 --vid 1000 --keep" \
        || { print_error "bc250-detect failed."; return 1; }

    print_info "Applying overclock config..."
    sudo -u "$REAL_USER" env PATH="$user_bin:$PATH" bash -c "cd '$build_dir' && bc250-apply --install overclock.conf" \
        || { print_error "bc250-apply failed."; return 1; }

    print_info "Enabling systemd service..."
    systemctl enable bc250-smu-oc || { print_error "Failed to enable service."; return 1; }

    print_success "CPU Governor installed successfully!"
    echo -e "  ${DIM}bc250-detect / bc250-apply are on ${REAL_USER}'s PATH at ${user_bin}${RESET}\n"
}

run_gpu_governor() {
    print_step "03" "Installing GPU Governor"

    if systemctl is-enabled cyan-skillfish-governor-smu.service &>/dev/null || \
       pacman -Qq cyan-skillfish-governor-smu &>/dev/null; then
        print_info "GPU governor already installed — skipping."
        return 0
    fi

    print_info "Installing cyan-skillfish-governor-smu via AUR helper..."
    if ! aur_install cyan-skillfish-governor-smu; then
        print_error "Failed to install cyan-skillfish-governor-smu — check the output above."
        return 1
    fi
    if ! pacman -Qq cyan-skillfish-governor-smu &>/dev/null; then
        print_error "The install command reported success, but cyan-skillfish-governor-smu is not actually installed — check the output above."
        return 1
    fi

    print_info "Enabling and starting systemd service..."
    if ! systemctl enable --now cyan-skillfish-governor-smu.service; then
        print_error "Failed to enable/start the service — check: journalctl -u cyan-skillfish-governor-smu.service"
        return 1
    fi
    print_success "GPU Governor installed and started successfully!"
}

run_enable_swap() {
    print_step "04" "Configuring Swap"

    # Prompt for swap size
    echo ""
    read -rp "$(echo -e "  ${BOLD}${WHITE}Swap size in GB (default: 16):${RESET} ")" swap_size_input
    if [[ -z "$swap_size_input" ]]; then
        swap_size="16"
    elif [[ "$swap_size_input" =~ ^[0-9]+$ ]] && (( swap_size_input > 0 )); then
        swap_size="$swap_size_input"
    else
        print_error "Invalid size '$swap_size_input' — must be a positive integer. Using default 16G."
        swap_size="16"
    fi

    # Prompt for swappiness
    read -rp "$(echo -e "  ${BOLD}${WHITE}Swappiness value (default: 60):${RESET} ")" swappiness_input
    if [[ -z "$swappiness_input" ]]; then
        swappiness="60"
    elif [[ "$swappiness_input" =~ ^[0-9]+$ ]]; then
        swappiness="$swappiness_input"
    else
        print_error "Invalid swappiness '$swappiness_input' — must be a number. Using default 60."
        swappiness="60"
    fi

    echo ""
    print_info "Disabling and removing existing swapfile..."
    swapoff /var/swap/swapfile 2>/dev/null || true
    rm -f /var/swap/swapfile 2>/dev/null || true

    # Detect filesystem type
    local fs_type
    fs_type=$(stat -f -c "%T" / 2>/dev/null || echo "unknown")

    if [[ "$fs_type" == "btrfs" ]]; then
        print_info "Btrfs detected — creating Btrfs subvolume and swapfile..."
        btrfs subvolume delete /var/swap 2>/dev/null || true
        btrfs subvolume create /var/swap
        btrfs filesystem mkswapfile --size "${swap_size}G" /var/swap/swapfile
    else
        print_info "Non-Btrfs filesystem detected ($fs_type) — creating standard swapfile..."
        mkdir -p /var/swap
        dd if=/dev/zero of=/var/swap/swapfile bs=1M count=$(( swap_size * 1024 )) status=progress
        chmod 600 /var/swap/swapfile
        mkswap /var/swap/swapfile
    fi

    print_info "Updating /etc/fstab..."
    sed -i '/\/var\/swap\/swapfile/d' /etc/fstab
    echo '/var/swap/swapfile none swap defaults,nofail 0 0' | tee -a /etc/fstab > /dev/null

    print_info "Setting swappiness to ${swappiness}..."
    echo "vm.swappiness = ${swappiness}" | tee /etc/sysctl.d/99-swappiness.conf > /dev/null
    sysctl vm.swappiness="${swappiness}" > /dev/null

    print_info "Enabling swapfile..."
    swapon /var/swap/swapfile

    print_success "Swap configured! Current swap:"
    echo ""
    swapon --show | sed 's/^/    /'
    echo ""
}

run_set_loglevel() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "06" "Hiding RDSEED Warning — Setting loglevel=0"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
        return 1
    fi
    print_info "Detected bootloader: $BOOTLOADER ($CONF)"

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists — preserving original."
    fi

    local cmdline_var
    cmdline_var="$(bootloader_cmdline_var)"
    local cmdline_var_esc
    cmdline_var_esc="$(bootloader_cmdline_var_escaped)"

    if grep -q 'loglevel=' "$CONF"; then
        print_info "loglevel= found. Updating value to 0..."
        sed -i 's/loglevel=[0-9]*/loglevel=0/g' "$CONF"
    else
        print_info "loglevel= not found. Adding to $cmdline_var..."
        sed -i "/^${cmdline_var_esc}/ s/\"$/ loglevel=0\"/" "$CONF"
    fi

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        bootloader_update
    fi
    print_success "loglevel set to 0. Reboot to apply."
}

run_disable_zram_enable_zswap() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "05" "Disabling ZRAM & Enabling ZSWAP"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
        return 1
    fi
    print_info "Detected bootloader: $BOOTLOADER ($CONF)"

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    local cmdline_var
    cmdline_var="$(bootloader_cmdline_var)"
    local cmdline_var_esc
    cmdline_var_esc="$(bootloader_cmdline_var_escaped)"

    # --- Disable ZRAM ---
    if grep -q 'systemd\.zram=0' "$CONF"; then
        print_info "ZRAM already disabled in $CONF — skipping."
    else
        print_info "Disabling ZRAM..."
        sed -i "/^${cmdline_var_esc}/s/\"$/ systemd.zram=0\"/" "$CONF"
        print_info "systemd.zram=0 added."
    fi

    # --- Enable ZSWAP ---
    if grep -q 'zswap\.enabled=1' "$CONF"; then
        print_info "ZSWAP already enabled in $CONF — skipping."
    else
        print_info "Enabling zswap (lz4, 25% pool)..."
        sed -i "/^${cmdline_var_esc}/s/\"$/ zswap.enabled=1 zswap.max_pool_percent=25 zswap.compressor=lz4\"/" "$CONF"
        print_info "ZSWAP kernel parameters added."
    fi

    # --- Add lz4 modules to initramfs ---
    initramfs_add_module lz4 || true
    initramfs_add_module lz4_compress || true
    initramfs_rebuild

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        bootloader_update
    fi
    print_success "ZRAM disabled && ZSWAP enabled! Reboot to apply."
    echo -e "  ${DIM}After reboot, verify with: cat /sys/module/zswap/parameters/enabled${RESET}\n"
}

run_toggle_boot_mode() {
    print_step "12" "Toggle Boot Mode"

    local CONF_DIR="/etc/plasmalogin.conf.d"
    local OVERRIDE_FILE="$CONF_DIR/zzz-bc250-boot.conf"
    local USER_NAME="$REAL_USER"

    # --- DETECTION ---
    local current_session="gamescope"
    local current_relogin="true"
    if [[ -f "$OVERRIDE_FILE" ]]; then
        grep -q "plasma.desktop" "$OVERRIDE_FILE" && current_session="plasma"
        grep -q "Relogin=false"  "$OVERRIDE_FILE" && current_relogin="false"
    fi

    local current_mode
    if [[ "$current_session" == "gamescope" && "$current_relogin" == "true" ]]; then
        current_mode="${BOLD}${GREEN}Game Mode — no password${RESET}"
    elif [[ "$current_session" == "gamescope" && "$current_relogin" == "false" ]]; then
        current_mode="${BOLD}${GREEN}Game Mode — password required${RESET}"
    elif [[ "$current_session" == "plasma" && "$current_relogin" == "false" ]]; then
        current_mode="${BOLD}${CYAN}Desktop Mode — password required${RESET}"
    else
        current_mode="${BOLD}${CYAN}Desktop Mode — no password${RESET}"
    fi

    echo -e "  ${CYAN}→${RESET}  Current: $current_mode"
    echo ""
    print_item "1" "Game Mode"         "Auto-login to Steam UI"
    print_item "2" "Game Mode"         "Password required for desktop mode"
    print_item "3" "Desktop Mode"      "Password required on boot"
    print_item "4" "Desktop Mode"      "No password — autologin to Plasma"
    echo ""
    print_item "0" "Back"              "Return to menu"
    echo ""

    read -rp "$(echo -e "  ${BOLD}${WHITE}Select choice:${RESET} ")" mode_choice

    case "$mode_choice" in
        1)
            print_info "Switching to Game Mode (no password)..."
            rm -f "$OVERRIDE_FILE"
            print_success "Done. Reboot to apply."
            ;;
        2)
            print_info "Switching to Game Mode (password required)..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
Relogin=false
Session=gamescope-session.desktop
User=$USER_NAME
EOF
            print_success "Done. Reboot to apply."
            ;;
        3)
            print_info "Switching to Desktop Mode (password required)..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
User=
Session=plasma.desktop
EOF
            print_success "Done. Reboot to apply."
            ;;
        4)
            print_info "Switching to Desktop Mode (no password)..."
            cat <<EOF > "$OVERRIDE_FILE"
[Autologin]
Relogin=true
Session=plasma.desktop
User=$USER_NAME
EOF
            print_success "Done. Reboot to apply."
            ;;
        0|*)
            print_info "No changes made."
            return 0
            ;;
    esac
}

run_switch_to_default_kernel() {
    print_step "01" "Installing Default CachyOS Kernel"

    # Check if already installed
    if pacman -Qq linux-cachyos &>/dev/null; then
        print_info "Standard CachyOS kernel is already installed."
        if ! pacman -Qq linux-cachyos-deckify &>/dev/null; then
            print_success "System is already running the default kernel. Nothing to do."
            return 0
        fi
        print_info "Deckify kernel found alongside standard — you can remove it via 'Remove Deckify Kernel'."
        return 0
    fi

    # Check if Deckify is present
    if ! pacman -Qq linux-cachyos-deckify &>/dev/null; then
        print_error "linux-cachyos-deckify not found. Migration is not applicable."
        return 1
    fi

    if ! confirm "This will install linux-cachyos and linux-cachyos-headers. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    # Install the default kernel
    print_info "Installing linux-cachyos and headers..."
    if ! pacman -S --noconfirm linux-cachyos linux-cachyos-headers; then
        print_error "Failed to install the default CachyOS kernel."
        return 1
    fi

    # Update bootloader
    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        if ! bootloader_update; then
            print_error "Boot config update failed — do not remove Deckify kernel until this is resolved."
            return 1
        fi
    fi

    print_success "linux-cachyos installed successfully."
    echo ""
    echo -e "  ${BOLD}${YELLOW}Next steps:${RESET}"
    echo -e "  ${WHITE}1. Reboot your system${RESET}"
    echo -e "  ${WHITE}2. At the Limine boot menu, select 'linux-cachyos'${RESET}"
    echo -e "  ${WHITE}3. Verify the system boots correctly${RESET}"
    echo -e "  ${WHITE}4. Return here and run 'Remove Deckify Kernel' to complete the migration${RESET}"
    echo ""
}

run_remove_deckify_kernel() {
    print_step "09" "Remove Deckify Kernel"

    if ! pacman -Qq linux-cachyos-deckify &>/dev/null; then
        print_info "linux-cachyos-deckify is not installed — nothing to remove."
        return 0
    fi

    if ! pacman -Qq linux-cachyos &>/dev/null; then
        print_error "linux-cachyos is not installed. Install and verify it boots before removing Deckify."
        return 1
    fi

    echo ""
    echo -e "  ${BOLD}${RED}⚠  Only proceed if you have already rebooted into linux-cachyos and confirmed it works.${RESET}"
    echo ""
    if ! confirm "Remove linux-cachyos-deckify and its headers?"; then
        print_info "Cancelled."
        return 0
    fi

    print_info "Removing linux-cachyos-deckify..."
    if ! pacman -Rs --noconfirm linux-cachyos-deckify linux-cachyos-deckify-headers; then
        print_error "Failed to remove Deckify kernel. Check pacman output above."
        return 1
    fi

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        if ! bootloader_update; then
            print_error "Boot config update failed — boot menu may need manual attention."
            return 1
        fi
    fi

    print_success "Deckify kernel removed successfully."
}

# ==============================================================================
# CPU CORES UNLOCK — EFI Boot Entry method (Hexxeh/bc250-efi-core-unlock)
# ==============================================================================

CPU_UNLOCK_EFI_REPO_URL="https://github.com/Hexxeh/bc250-efi-core-unlock"
CPU_UNLOCK_EFI_YOPPEH_URL="https://github.com/yoppeh/efi"
CPU_UNLOCK_EFI_LABEL="CoreUnlock"
CPU_UNLOCK_EFI_BIN_NAME="COREUNLOCK.EFI"

cpu_unlock_efi_installed() {
    efibootmgr 2>/dev/null | grep -q "$CPU_UNLOCK_EFI_LABEL"
}

# Finds the EFI System Partition's mount point by checking common locations
cpu_unlock_efi_find_esp() {
    local mnt
    for mnt in /boot/efi /efi /boot; do
        if mountpoint -q "$mnt" 2>/dev/null && [[ -d "$mnt/EFI" ]]; then
            printf '%s' "$mnt"
            return 0
        fi
    done
    return 1
}

# Prints "<disk> <partition-number>" for the ESP, e.g. "/dev/nvme0n1 1"
cpu_unlock_efi_find_disk_part() {
    local esp_mount="$1" esp_dev pkname partnum
    esp_dev="$(findmnt -n -o SOURCE "$esp_mount" 2>/dev/null)"
    [[ -n "$esp_dev" ]] || return 1
    pkname="$(lsblk -rno PKNAME "$esp_dev" 2>/dev/null)"
    partnum="$(lsblk -rno PARTN "$esp_dev" 2>/dev/null)"
    [[ -n "$pkname" && -n "$partnum" ]] || return 1
    printf '/dev/%s %s' "$pkname" "$partnum"
}

cpu_unlock_efi_warn() {
    echo ""
    echo -e "  ${BOLD}${RED}⚠  WARNING: CPU CORES UNLOCK — EFI BOOT ENTRY METHOD${RESET}"
    echo ""
    echo -e "  ${WHITE}This is an alternative to the SMU mailbox service: instead of a boot-time"
    echo -e "  systemd service, it builds a standalone EFI executable and registers it as"
    echo -e "  a NEW UEFI FIRMWARE BOOT ENTRY (via efibootmgr), typically placed FIRST in"
    echo -e "  your boot order. It runs before your OS bootloader, unlocks the cores, then"
    echo -e "  chain-loads into your normal boot process."
    echo ""
    echo -e "  This modifies UEFI NVRAM boot entries directly, not just OS-level files."
    echo -e "  Only proceed if you understand that.${RESET}"
    echo ""
    echo -e "  ${DIM}Type ${RESET}${BOLD}${YELLOW}unlock${RESET}${DIM} to accept and proceed, or press Enter to cancel.${RESET}"
    echo ""
    read -rp "  → " cpu_unlock_efi_ack
    [[ "$cpu_unlock_efi_ack" == "unlock" ]]
}

run_cpu_cores_unlock_efi() {
    print_step "08b" "Installing CPU Cores Unlock — EFI Boot Entry Method"

    if cpu_unlock_efi_installed; then
        print_info "A '$CPU_UNLOCK_EFI_LABEL' EFI boot entry already exists — skipping."
        return 0
    fi

    cpu_unlock_efi_warn || { print_info "Cancelled."; return 0; }

    if ! command -v clang &>/dev/null; then
        print_error "clang is not installed. Install it (e.g. 'pacman -S clang') and try again."
        return 1
    fi

    print_info "Locating the EFI System Partition..."
    local esp_mount
    if ! esp_mount="$(cpu_unlock_efi_find_esp)"; then
        print_error "Could not automatically locate the EFI System Partition (checked /boot/efi, /efi, /boot)."
        return 1
    fi
    print_info "Found ESP at $esp_mount"

    local disk_part disk part
    if ! disk_part="$(cpu_unlock_efi_find_disk_part "$esp_mount")"; then
        print_error "Could not determine the underlying disk/partition for the ESP at $esp_mount."
        print_error "Run manually: efibootmgr --create --disk <disk> --part <N> --label \"$CPU_UNLOCK_EFI_LABEL\" --loader \"\\EFI\\BOOT\\$CPU_UNLOCK_EFI_BIN_NAME\""
        return 1
    fi
    read -r disk part <<<"$disk_part"
    print_info "ESP is on $disk, partition $part"

    print_info "Installing gnu-efi..."
    if command -v pacman >/dev/null 2>&1 && pacman -Si gnu-efi >/dev/null 2>&1; then
        pacman -S --needed --noconfirm gnu-efi || { print_error "Failed to install gnu-efi via pacman."; return 1; }
    else
        aur_install gnu-efi || { print_error "Failed to install gnu-efi."; return 1; }
    fi

    local user_home
    user_home="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    local build_dir="$user_home/.cache/bc250-toolkit/bc250-efi-core-unlock"

    print_info "Cloning bc250-efi-core-unlock as $REAL_USER..."
    sudo -u "$REAL_USER" mkdir -p "$(dirname "$build_dir")"
    if [[ -d "$build_dir" ]]; then
        print_info "Directory already exists — pulling latest changes..."
        sudo -u "$REAL_USER" git -C "$build_dir" pull || { print_error "Failed to pull repository."; return 1; }
    else
        sudo -u "$REAL_USER" git clone "$CPU_UNLOCK_EFI_REPO_URL" "$build_dir" || { print_error "Failed to clone repository."; return 1; }
    fi

    print_info "Cloning yoppeh/efi dependency..."
    if [[ -d "$build_dir/efi" ]]; then
        sudo -u "$REAL_USER" git -C "$build_dir/efi" pull || { print_error "Failed to pull efi dependency."; return 1; }
    else
        sudo -u "$REAL_USER" git clone "$CPU_UNLOCK_EFI_YOPPEH_URL" "$build_dir/efi" || { print_error "Failed to clone efi dependency."; return 1; }
    fi

    print_info "Patching Makefile..."
    sudo -u "$REAL_USER" sed -i 's/yoppeh-efi/efi/g' "$build_dir/Makefile"

    print_info "Building with clang..."
    if ! sudo -u "$REAL_USER" bash -c "cd '$build_dir' && make clang"; then
        print_error "Build failed."
        return 1
    fi
    if [[ ! -f "$build_dir/bc250-unlock.efi" ]]; then
        print_error "Build did not produce bc250-unlock.efi."
        return 1
    fi

    print_info "Installing to $esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME..."
    mkdir -p "$esp_mount/EFI/BOOT"
    cp "$build_dir/bc250-unlock.efi" "$esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME"

    if ! confirm "Create a UEFI boot entry '$CPU_UNLOCK_EFI_LABEL' on $disk (partition $part)? This will typically become your default boot entry."; then
        print_info "Cancelled before creating the boot entry."
        print_info "The .efi file remains installed at $esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME if you want to register it manually later."
        return 0
    fi

    print_info "Creating EFI boot entry via efibootmgr..."
    if ! efibootmgr --create --disk "$disk" --part "$part" --label "$CPU_UNLOCK_EFI_LABEL" --loader "\\EFI\\BOOT\\$CPU_UNLOCK_EFI_BIN_NAME"; then
        print_error "efibootmgr failed to create the boot entry."
        return 1
    fi

    print_success "CPU Cores Unlock (EFI method) installed successfully!"
    echo -e "  ${DIM}EFI binary:  $esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME${RESET}"
    echo -e "  ${DIM}Boot entry:  $CPU_UNLOCK_EFI_LABEL${RESET}"
    echo -e "  ${BOLD}${YELLOW}A reboot is required to apply.${RESET}\n"
}

run_revert_cpu_cores_unlock_efi() {
    print_step "R-9" "Revert CPU Cores Unlock"

    if ! cpu_unlock_efi_installed; then
        print_info "No '$CPU_UNLOCK_EFI_LABEL' EFI boot entry found — nothing to revert."
        return 0
    fi

    if ! confirm "This will remove the '$CPU_UNLOCK_EFI_LABEL' UEFI boot entry and its .efi file. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    local bootnum
    bootnum="$(efibootmgr | awk -v label="$CPU_UNLOCK_EFI_LABEL" '$0 ~ label {gsub(/[^0-9]/,"",$1); print $1; exit}')"
    if [[ -n "$bootnum" ]]; then
        print_info "Removing boot entry Boot$bootnum ($CPU_UNLOCK_EFI_LABEL)..."
        efibootmgr -b "$bootnum" -B || print_error "Failed to remove boot entry Boot$bootnum — check manually with 'efibootmgr'."
    else
        print_error "Could not determine the boot entry number for '$CPU_UNLOCK_EFI_LABEL' — remove manually with 'efibootmgr'."
    fi

    local esp_mount
    if esp_mount="$(cpu_unlock_efi_find_esp)" && [[ -f "$esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME" ]]; then
        print_info "Removing $esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME..."
        rm -f "$esp_mount/EFI/BOOT/$CPU_UNLOCK_EFI_BIN_NAME"
    fi

    local user_home
    user_home="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    local build_dir="$user_home/.cache/bc250-toolkit/bc250-efi-core-unlock"
    if [[ -d "$build_dir" ]]; then
        print_info "Removing build directory..."
        rm -rf "$build_dir"
    fi

    print_success "CPU Cores Unlock (EFI method) removed."
    echo -e "  ${BOLD}${YELLOW}You must fully power off the system to complete the uninstall —"
    echo -e "  a reboot is not enough. The unlock only clears itself on a genuine"
    echo -e "  cold boot, so a warm reboot may still show unlocked cores until you"
    echo -e "  power the system down completely and turn it back on.${RESET}\n"
}

# ---- CPU Cores Unlock submenu (both methods) ----

# ==============================================================================
# ACPI FIX (mendesrr/bc250-acpi-fix-updated-8c) + CPU GOVERNOR
# ==============================================================================

ACPI_OVERRIDE_DIR="/etc/initcpio/acpi_override"
ACPI_CST_URL="https://github.com/mendesrr/bc250-acpi-fix-updated-8c/raw/refs/heads/main/SSDT-CST.aml"
ACPI_PST_URL="https://github.com/mendesrr/bc250-acpi-fix-updated-8c/raw/refs/heads/main/SSDT-PST.aml"
MKINITCPIO_CONF="/etc/mkinitcpio.conf"
CPUPOWER_CONF="/etc/default/cpupower-service.conf"
CPUPOWER_SERVICE="cpupower.service"

acpi_fix_installed() {
    [[ -f "$ACPI_OVERRIDE_DIR/SSDT-CST.aml" && -f "$ACPI_OVERRIDE_DIR/SSDT-PST.aml" ]] && \
        grep -qE '^HOOKS=.*\bacpi_override\b' "$MKINITCPIO_CONF" 2>/dev/null
}

# Prints the live scaling_governor if all CPUs agree, "mixed" if they don't,
# or nothing if it couldn't be read at all.
cpupower_current_governor() {
    local govs govcount
    govs="$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | sort -u)"
    [[ -n "$govs" ]] || return 1
    govcount="$(printf '%s\n' "$govs" | wc -l)"
    if [[ "$govcount" -eq 1 ]]; then
        printf '%s' "$govs"
    else
        printf 'mixed'
    fi
}

run_install_acpi_fix() {
    print_step "AS-1" "Installing ACPI Fix"

    if acpi_fix_installed; then
        print_info "ACPI Fix already installed — skipping."
        return 0
    fi

    print_info "Creating $ACPI_OVERRIDE_DIR..."
    mkdir -p "$ACPI_OVERRIDE_DIR"

    print_info "Downloading SSDT-CST.aml and SSDT-PST.aml..."
    if ! wget -nc -P "$ACPI_OVERRIDE_DIR" "$ACPI_CST_URL" "$ACPI_PST_URL"; then
        print_error "Failed to download one or both ACPI override files."
        return 1
    fi
    if [[ ! -f "$ACPI_OVERRIDE_DIR/SSDT-CST.aml" || ! -f "$ACPI_OVERRIDE_DIR/SSDT-PST.aml" ]]; then
        print_error "Expected ACPI override files not found after download."
        return 1
    fi

    if grep -qE '^HOOKS=.*\bacpi_override\b' "$MKINITCPIO_CONF"; then
        print_info "acpi_override hook already present in $MKINITCPIO_CONF — skipping hook edit."
    else
        print_info "Adding acpi_override hook to $MKINITCPIO_CONF..."
        sed -i '/^HOOKS=/ { /acpi_override/q; s/microcode/& acpi_override/; q }' "$MKINITCPIO_CONF"
        if ! grep -qE '^HOOKS=.*\bacpi_override\b' "$MKINITCPIO_CONF"; then
            print_error "Could not add the acpi_override hook automatically — no 'microcode' hook found to anchor next to."
            print_error "Add 'acpi_override' to the HOOKS= line in $MKINITCPIO_CONF manually, then rebuild initramfs."
            return 1
        fi
    fi

    if ! initramfs_rebuild; then
        print_error "Initramfs rebuild failed — check the output above."
        return 1
    fi

    print_success "ACPI Fix installed successfully!"
    echo -e "  ${BOLD}${YELLOW}A reboot is required to apply the ACPI override.${RESET}\n"
}

run_acpi_show_power_info() {
    print_step "AS-2" "CPU Power Info"

    if ! command -v cpupower &>/dev/null; then
        print_error "cpupower is not installed."
        return 1
    fi

    echo ""
    print_section "cpupower idle-info"
    cpupower idle-info || print_error "cpupower idle-info failed."
    echo ""
    print_section "cpupower frequency-info"
    cpupower frequency-info || print_error "cpupower frequency-info failed."
}

run_set_cpu_governor() {
    print_step "AS-3" "Set CPU Governor"

    local current
    if current="$(cpupower_current_governor)"; then
        print_info "Current live governor: ${current}"
    else
        print_info "Could not read the current governor from sysfs."
    fi

    echo ""
    print_item "1" "schedutil"   "Dynamic, kernel-driven scaling (default)"
    print_item "2" "performance" "Locks CPUs at max frequency"
    echo ""
    print_item "0" "Cancel" ""
    echo ""
    read -rp "$(echo -e "  ${BOLD}${WHITE}Select governor:${RESET} ")" gov_choice

    local target_gov
    case "$gov_choice" in
        1) target_gov="schedutil" ;;
        2) target_gov="performance" ;;
        0) print_info "Cancelled."; return 0 ;;
        *) print_error "Invalid selection."; return 1 ;;
    esac

    if ! confirm "Set CPU governor to '${target_gov}'?"; then
        print_info "Cancelled."
        return 0
    fi

    if [[ ! -f "$CPUPOWER_CONF" ]]; then
        print_error "$CPUPOWER_CONF not found — is the 'cpupower' package/service installed?"
        return 1
    fi

    print_info "Updating $CPUPOWER_CONF..."
    if grep -qE '^GOVERNOR=' "$CPUPOWER_CONF"; then
        sed -i "s/^GOVERNOR=.*/GOVERNOR='${target_gov}'/" "$CPUPOWER_CONF"
    elif grep -qE '^#\s*GOVERNOR=' "$CPUPOWER_CONF"; then
        sed -i "s/^#\s*GOVERNOR=.*/GOVERNOR='${target_gov}'/" "$CPUPOWER_CONF"
    else
        echo "GOVERNOR='${target_gov}'" >> "$CPUPOWER_CONF"
    fi

    if systemctl list-unit-files "$CPUPOWER_SERVICE" &>/dev/null; then
        print_info "Restarting ${CPUPOWER_SERVICE}..."
        systemctl enable "$CPUPOWER_SERVICE" &>/dev/null || true
        if ! systemctl restart "$CPUPOWER_SERVICE"; then
            print_error "Failed to restart $CPUPOWER_SERVICE — check: journalctl -u $CPUPOWER_SERVICE"
            return 1
        fi
    else
        print_error "$CPUPOWER_SERVICE not found — config was updated but not applied. Install/enable the cpupower service to apply it."
        return 1
    fi

    print_success "CPU governor set to '${target_gov}'."
    local new_current
    if new_current="$(cpupower_current_governor)"; then
        echo -e "  ${DIM}Live governor now reports: ${new_current}${RESET}\n"
    fi
}

show_acpi_menu() {
    print_banner
    print_section "ACPI Fix"
    echo -e "  ${DIM}SSDT idle/frequency table override (mendesrr/bc250-acpi-fix-updated-8c) plus CPU governor control.${RESET}\n"
    local status_label
    if acpi_fix_installed; then
        status_label="${GREEN}installed${RESET}  ${DIM}($ACPI_OVERRIDE_DIR)${RESET}"
    else
        status_label="${DIM}not installed${RESET}"
    fi
    echo -e "  ${CYAN}Status${RESET}    ${status_label}"
    local gov
    if gov="$(cpupower_current_governor)"; then
        echo -e "  ${CYAN}Governor${RESET}  ${BOLD}${WHITE}${gov}${RESET}"
    else
        echo -e "  ${CYAN}Governor${RESET}  ${DIM}unknown${RESET}"
    fi
    echo ""
    print_item "1" "Install ACPI Fix"    "Downloads SSDT overrides, rebuilds initramfs"
    print_item "2" "Show CPU Power Info" "cpupower idle-info / frequency-info"
    print_item "3" "Set CPU Governor"    "Switch between schedutil and performance"
    echo ""
    print_item "0" "Back" ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_acpi_menu() {
    while true; do
        show_acpi_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" acpi_choice

        case "${acpi_choice^^}" in
            1) run_install_acpi_fix;     press_enter ;;
            2) run_acpi_show_power_info; press_enter ;;
            3) run_set_cpu_governor;     press_enter ;;
            0) return 0 ;;
            *)
                print_error "Invalid selection: '$acpi_choice'"
                sleep 1
                ;;
        esac
    done
}

run_revert_acpi_fix() {
    print_step "R-8" "Revert ACPI Fix"

    if ! acpi_fix_installed && [[ ! -d "$ACPI_OVERRIDE_DIR" ]] && \
       ! grep -qE '^HOOKS=.*\bacpi_override\b' "$MKINITCPIO_CONF" 2>/dev/null; then
        print_info "ACPI Fix does not appear to be installed — nothing to revert."
        return 0
    fi

    if ! confirm "This will remove the acpi_override hook, delete the SSDT override files, and rebuild initramfs. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    if grep -qE '^HOOKS=.*\bacpi_override\b' "$MKINITCPIO_CONF" 2>/dev/null; then
        print_info "Removing acpi_override hook from $MKINITCPIO_CONF..."
        sed -i 's/ acpi_override//g' "$MKINITCPIO_CONF"
    else
        print_info "acpi_override hook not found in $MKINITCPIO_CONF — skipping."
    fi

    if [[ -d "$ACPI_OVERRIDE_DIR" ]]; then
        print_info "Removing $ACPI_OVERRIDE_DIR..."
        rm -rf "$ACPI_OVERRIDE_DIR"
    fi

    initramfs_rebuild || print_error "Initramfs rebuild failed — check the output above."

    print_success "ACPI Fix removed."
    echo -e "  ${BOLD}${YELLOW}A reboot is required to fully revert.${RESET}\n"
    echo -e "  ${DIM}Note: this does not change your CPU governor setting — use 'Set CPU"
    echo -e "  Governor' from the ACPI Fix menu if you also want to reset that.${RESET}\n"
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
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 1500
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 80
throttling_recovery = 75
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

write_gpu_overclock_1600mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 1600
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 80
throttling_recovery = 75
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
EOF
}

write_gpu_overclock_1750mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 1750
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 80
throttling_recovery = 75
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
frequency = 1750
voltage = 925
EOF
}

write_gpu_overclock_1850mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 1850
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 80
throttling_recovery = 75
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
EOF
}

write_gpu_overclock_2000mhz() { cat > "$GPU_TMPFILE" <<'EOF'
[timing.intervals]
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 2000
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 80
throttling_recovery = 75
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
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 2100
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 80
throttling_recovery = 75
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
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 2300
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 90
throttling_recovery = 85
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
sample = 250
adjust = 100_000
[gpu-usage]
fix-metrics = true
method = "busy-flag" # "busy-flag" or "process"
flush-every = 10
[gpu]
set-method = "smu"  # "smu" or "kernel"

[dbus]
enabled = true

[frequency-range]
min = 500
max = 2350
[timing.ramp-rates]
normal = 1
burst = 50
[timing]
burst-samples = 60
down-events = 5
[frequency-thresholds]
adjust = 10
[load-target]
upper = 0.65
lower = 0.50
[temperature]
throttling = 90
throttling_recovery = 85
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

oc_edit_cpu_config_nano() {
    print_step "07-E" "Opening CPU Config in nano"

    if [[ ! -f "$CPU_DEST" ]]; then
        print_error "Configuration file not found at $CPU_DEST"
        return 1
    fi

    nano "$CPU_DEST" || true

    if confirm "Would you like to restart the CPU service to apply changes?"; then
        systemctl daemon-reload
        systemctl restart "$CPU_SERVICE"
        if systemctl is-active --quiet "$CPU_SERVICE"; then
            print_success "CPU service restarted successfully."
        else
            print_error "CPU service failed to start! Check: journalctl -u $CPU_SERVICE"
        fi
    fi
}

oc_edit_gpu_config_nano() {
    print_step "07-E" "Opening GPU Config in nano"

    if [[ ! -f "$GPU_DEST" ]]; then
        print_error "Configuration file not found at $GPU_DEST"
        return 1
    fi

    nano "$GPU_DEST" || true

    if confirm "Would you like to restart the GPU service to apply changes?"; then
        systemctl restart "$GPU_SERVICE"
        if systemctl is-active --quiet "$GPU_SERVICE"; then
            print_success "GPU service restarted successfully."
        else
            print_error "GPU service failed to start! Check: journalctl -u $GPU_SERVICE"
        fi
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

    # Preset CPU MHz values matching PRESET_CPU_WRITERS order (slowest to fastest)
    local preset_cpu_freqs=(3500 3500 3500 3500 3500 3500 3850 4000)
    local preset_gpu_freqs=(1500 1600 1750 1850 2000 2100 2100 2350)

    for i in "${!PRESET_NAMES[@]}"; do
        if [[ "$cpu_freq" == "${preset_cpu_freqs[$i]}" && "$gpu_freq" == "${preset_gpu_freqs[$i]}" ]]; then
            echo "${PRESET_NAMES[$i]}"
            return
        fi
    done
    echo "Custom"
}

PRESET_NAMES=("Stock" "Mild" "Moderate" "Strong" "Aggressive" "Extreme I ⚠" "Extreme II ⚠" "Extreme III ⚠")
PRESET_DESCS=(
    "CPU 3.5GHz, GPU 1500MHz — 80°C"
    "CPU 3.5GHz, GPU 1600MHz — 80°C"
    "CPU 3.5GHz, GPU 1750MHz — 80°C"
    "CPU 3.5GHz, GPU 1850MHz — 80°C"
    "CPU 3.5GHz, GPU 2000MHz — 80°C"
    "CPU 3.5GHz, GPU 2100MHz — 80°C"
    "CPU 3.85GHz, GPU 2100MHz — 80°C"
    "CPU 4GHz, GPU 2350MHz — 90°C"
)
PRESET_CPU_WRITERS=(write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz write_cpu_undervolt_3_5ghz write_cpu_overclock_3_85ghz write_cpu_overclock_4ghz)
PRESET_GPU_WRITERS=(write_gpu_overclock_1500mhz write_gpu_overclock_1600mhz write_gpu_overclock_1750mhz write_gpu_overclock_1850mhz write_gpu_overclock_2000mhz write_gpu_overclock_2100mhz write_gpu_overclock_2100mhz write_gpu_overclock_2350mhz)
# Presets 6-8 (index 5-7) are high-risk and require OC acknowledgement
PRESET_HIGH_RISK_THRESHOLD=5

CPU_NAMES=("Undervolt 3.5 GHz (stock)" "Overclock 3.85 GHz" "Overclock 4 GHz")
CPU_DESCS=("3500 MHz, scale -22, max 80°C" "3850 MHz, scale -30, max 90°C" "4000 MHz, scale -37, max 90°C")
CPU_WRITERS=(write_cpu_undervolt_3_5ghz write_cpu_overclock_3_85ghz write_cpu_overclock_4ghz)

GPU_NAMES=("1500 MHz" "1600 MHz" "1750 MHz" "1850 MHz" "2000 MHz" "2100 MHz ⚠" "2300 MHz ⚠" "2350 MHz ⚠")
GPU_DESCS=(
    "throttle 80°C — conservative"
    "throttle 80°C — moderate-low"
    "throttle 80°C — moderate"
    "throttle 80°C — moderate-high"
    "throttle 80°C — standard ceiling"
    "throttle 80°C — HIGH RISK"
    "throttle 90°C — HIGH RISK"
    "throttle 90°C — HIGH RISK"
)
GPU_WRITERS=(write_gpu_overclock_1500mhz write_gpu_overclock_1600mhz write_gpu_overclock_1750mhz write_gpu_overclock_1850mhz write_gpu_overclock_2000mhz write_gpu_overclock_2100mhz write_gpu_overclock_2300mhz write_gpu_overclock_2350mhz)
# GPU profiles at index 5+ (2100 MHz and above) require OC acknowledgement
GPU_HIGH_RISK_THRESHOLD=5

# Display high-risk warning and require "OC" acknowledgement
# Returns 0 if acknowledged, 1 if cancelled
oc_warn_high_risk() {
    echo ""
    echo -e "  ${BOLD}${RED}⚠  WARNING: HIGH-RISK OVERCLOCK PROFILE${RESET}"
    echo ""
    echo -e "  ${WHITE}Unlocking additional compute units (38-40 CU) significantly increases"
    echo -e "  power draw. Combined with high GPU frequencies, this can exceed the"
    echo -e "  safe capacity of your power delivery hardware. The 8-pin connector"
    echo -e "  and its wiring are particularly vulnerable — overloading them can"
    echo -e "  cause the connector to melt or the wires to overheat, resulting in"
    echo -e "  permanent damage or fire risk."
    echo ""
    echo -e "  Only proceed if you have verified your PSU, cabling, and cooling"
    echo -e "  can handle the increased load of your CU configuration.${RESET}"
    echo ""
    echo -e "  ${DIM}Type ${RESET}${BOLD}${YELLOW}OC${RESET}${DIM} to accept full responsibility and proceed, or press Enter to cancel.${RESET}"
    echo ""
    read -rp "  → " ack
    if [[ "$ack" == "OC" ]]; then
        return 0
    else
        print_info "Cancelled."
        return 1
    fi
}

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

    # Gate high-risk presets (index 5-7, i.e. presets 6-8)
    if (( idx >= PRESET_HIGH_RISK_THRESHOLD )); then
        oc_warn_high_risk || return 0
    fi

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

    # Gate high-risk GPU profiles (index 5+, i.e. 2100 MHz and above)
    if (( gpu_idx >= GPU_HIGH_RISK_THRESHOLD )); then
        oc_warn_high_risk || return 0
    fi

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
        print_section "Standard Profiles"
        for i in "${!PRESET_NAMES[@]}"; do
            if (( i >= PRESET_HIGH_RISK_THRESHOLD )); then
                continue
            fi
            print_item "$((i+1))" "${PRESET_NAMES[$i]}" "${PRESET_DESCS[$i]}"
        done
        echo ""
        print_section "High-Risk Profiles  ⚠  Requires OC acknowledgement"
        for i in "${!PRESET_NAMES[@]}"; do
            if (( i < PRESET_HIGH_RISK_THRESHOLD )); then
                continue
            fi
            print_item "$((i+1))" "${PRESET_NAMES[$i]}" "${PRESET_DESCS[$i]}"
        done
        echo ""
        print_section "Advanced"
        print_item "C" "Custom"          "Mix & match CPU and GPU profiles"
        print_item "E" "Edit GPU Config" "Manually edit GPU config with nano"
        print_item "F" "Edit CPU Config" "Manually edit CPU config with nano"
        print_item "0" "Back"            ""
        echo ""
        echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" oc_choice

        case "${oc_choice^^}" in
            C) oc_apply_custom;         press_enter ;;
            E) oc_edit_gpu_config_nano; press_enter ;;
            F) oc_edit_cpu_config_nano; press_enter ;;
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
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "R-3" "Revert ZSWAP — Re-enabling ZRAM, removing swapfile"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
        return 1
    fi

    if ! confirm "This will remove zswap params, re-enable ZRAM, remove the swapfile and reset swappiness to default. Proceed?"; then
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

    # --- Remove lz4 from initramfs ---
    initramfs_remove_module lz4_compress || true
    initramfs_remove_module lz4 || true
    initramfs_rebuild

    # --- Disable and remove swapfile ---
    if swapon --show | grep -q '/var/swap/swapfile'; then
        print_info "Disabling swapfile..."
        swapoff /var/swap/swapfile || { print_error "Failed to disable swapfile."; return 1; }
        print_info "Swapfile disabled."
    else
        print_info "Swapfile not active — skipping swapoff."
    fi

    if [[ -f "/var/swap/swapfile" ]]; then
        print_info "Removing swapfile..."
        rm -f /var/swap/swapfile
        print_info "Swapfile removed."
    else
        print_info "Swapfile not found — skipping."
    fi

    # --- Remove Btrfs subvolume ---
    if btrfs subvolume show /var/swap &>/dev/null; then
        print_info "Deleting Btrfs subvolume /var/swap..."
        btrfs subvolume delete /var/swap || { print_error "Failed to delete subvolume."; return 1; }
        print_info "Subvolume deleted."
    else
        print_info "/var/swap subvolume not found — skipping."
    fi

    # --- Remove fstab entry ---
    if grep -q '/var/swap/swapfile' /etc/fstab; then
        print_info "Removing swapfile entry from /etc/fstab..."
        sed -i '/\/var\/swap\/swapfile/d' /etc/fstab
        print_info "fstab entry removed."
    else
        print_info "No swapfile entry in /etc/fstab — skipping."
    fi

    # --- Reset swappiness ---
    if [[ -f "/etc/sysctl.d/99-swappiness.conf" ]]; then
        print_info "Removing swappiness config..."
        rm -f /etc/sysctl.d/99-swappiness.conf
        sysctl vm.swappiness=60 > /dev/null
        print_info "Swappiness reset to default (60)."
    else
        print_info "No swappiness config found — skipping."
    fi

    print_info "Updating boot config..."
    bootloader_update
    print_success "Revert complete! Reboot to restore ZRAM and disable ZSWAP."
    print_info "Note: ZRAM will not be active until after reboot."
    echo -e "  ${DIM}After reboot, verify with: systemctl is-active systemd-zram-setup@zram0.service${RESET}\n"
}


run_disable_mitigations() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "07" "Disabling CPU Mitigations"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
        return 1
    fi
    print_info "Detected bootloader: $BOOTLOADER ($CONF)"

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    if grep -q 'mitigations=off' "$CONF"; then
        print_info "mitigations=off already present — skipping."
        return 0
    fi

    local cmdline_var
    cmdline_var="$(bootloader_cmdline_var)"
    local cmdline_var_esc
    cmdline_var_esc="$(bootloader_cmdline_var_escaped)"
    print_info "Adding mitigations=off..."
    sed -i "/^${cmdline_var_esc}/s/\"$/ mitigations=off\"/" "$CONF"

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        bootloader_update
    fi
    print_success "mitigations=off added. Reboot to apply."
    echo -e "  ${DIM}Note: this disables Spectre/Meltdown mitigations for a performance gain.${RESET}\n"
}

run_status() {
    print_banner
    print_section "System Status"

    local LIMINE_CONF
    LIMINE_CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    local CPU_CONF="/etc/bc250-smu-oc.conf"
    local GPU_CONF="/etc/cyan-skillfish-governor-smu/config.toml"
    local MKINITCPIO="/etc/mkinitcpio.conf"

    # --- System ---
    echo -e "  ${BOLD}${YELLOW}System${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"

    local OVERRIDE_FILE="/etc/plasmalogin.conf.d/zzz-bc250-boot.conf"
    local boot_session="gamescope"
    local boot_relogin="true"
    if [[ -f "$OVERRIDE_FILE" ]]; then
        grep -q "plasma.desktop" "$OVERRIDE_FILE" && boot_session="plasma"
        grep -q "User=$" "$OVERRIDE_FILE"  && boot_relogin="false"
    fi

    local boot_mode boot_login
    if [[ "$boot_session" == "gamescope" ]]; then
        boot_mode="${BOLD}${GREEN}Game Mode${RESET}"
    else
        boot_mode="${BOLD}${CYAN}Desktop Mode${RESET}"
    fi
    if [[ "$boot_relogin" == "false" ]]; then
        boot_login="${DIM}password required${RESET}"
    else
        boot_login="${DIM}no password${RESET}"
    fi

    echo -e "  ${CYAN}Boot Mode${RESET}         ${boot_mode}  ${boot_login}"
    echo -e "  ${CYAN}Kernel${RESET}            $(uname -r)"
    echo ""

    # --- Overclock Profile ---
    echo -e "  ${BOLD}${YELLOW}Overclock${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
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

    # --- Hardware Unlocks (CPU Cores / Compute Units) ---
    echo -e "  ${BOLD}${YELLOW}Hardware Unlocks${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
    local cpu_core_count cpu_core_color
    cpu_core_count=$(nproc --all 2>/dev/null || echo "?")
    if [[ "$cpu_core_count" == "16" ]]; then
        cpu_core_color="$GREEN"
    elif [[ "$cpu_core_count" == "12" ]]; then
        cpu_core_color="$DIM"
    else
        cpu_core_color="$YELLOW"
    fi
    local unlock_method_tag=""
    if cpu_unlock_efi_installed; then
        unlock_method_tag=" ${DIM}[EFI entry]${RESET}"
    fi
    echo -e "  ${CYAN}CPU Cores${RESET}         ${cpu_core_color}${BOLD}${cpu_core_count}${RESET}  ${DIM}(12 stock, 16 unlocked)${RESET}${unlock_method_tag}"
    if cu_find_umr; then
        cu_select_umr_instance
        local cu_total=0 cu_idx cu_se cu_sh cu_spi_hex cu_spi_val cu_wgp cu_bit
        local -a cu_masks
        if cu_select_asic 2>/dev/null; then
            for cu_idx in 0 1 2 3; do
                read -r cu_se cu_sh <<<"$(cu_row_coords "$cu_idx")"
                cu_spi_hex="$(cu_read_reg_bank "$CU_REG_SPI" "$cu_se" "$cu_sh" 2>/dev/null || echo "0x0")"
                cu_spi_val=$(( $(cu_hex_to_dec "$cu_spi_hex") & 31 ))
                cu_masks[$cu_idx]=$cu_spi_val
                for cu_wgp in 0 1 2 3 4; do
                    cu_bit=$((1 << cu_wgp))
                    if [ $((cu_spi_val & cu_bit)) -ne 0 ]; then
                        cu_total=$((cu_total + 2))
                    fi
                done
            done
            local cu_color
            if [ "$cu_total" -gt 24 ]; then
                cu_color="$YELLOW"
            else
                cu_color="$GREEN"
            fi
            echo -e "  ${CYAN}Active CUs${RESET}        ${cu_color}${BOLD}${cu_total}/40${RESET}  ${DIM}(default 24, max 40)${RESET}"
            if [ "$cu_total" -gt 24 ]; then
                echo -e "  ${YELLOW}⚠  CUs unlocked — verify power and cooling${RESET}"
            fi
        else
            echo -e "  ${CYAN}Active CUs${RESET}        ${DIM}unavailable (umr could not read registers)${RESET}"
        fi
    else
        echo -e "  ${CYAN}Active CUs${RESET}        ${DIM}umr not installed${RESET}"
    fi
    echo ""

    # --- ACPI Fix / CPU Governor ---
    echo -e "  ${BOLD}${YELLOW}ACPI Fix${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
    if acpi_fix_installed; then
        echo -e "  ${CYAN}Status${RESET}            ${GREEN}installed${RESET}  ${DIM}($ACPI_OVERRIDE_DIR)${RESET}"
    else
        echo -e "  ${CYAN}Status${RESET}            ${DIM}not installed${RESET}"
    fi
    local status_gov
    if status_gov="$(cpupower_current_governor)"; then
        echo -e "  ${CYAN}CPU Governor${RESET}      ${BOLD}${WHITE}${status_gov}${RESET}"
    else
        echo -e "  ${CYAN}CPU Governor${RESET}      ${DIM}unknown${RESET}"
    fi
    echo ""

    # --- BC-250 Memory Config (bc250_memcfg) ---
    echo -e "  ${BOLD}${YELLOW}Memory Config (bc250_memcfg)${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
    if memcfg_installed; then
        echo -e "  ${CYAN}Tool${RESET}              ${GREEN}installed${RESET}  ${DIM}($MEMCFG_BIN)${RESET}"
        local status_vram_size
        status_vram_size="$(memcfg_current_uma_size)"
        if [[ -n "$status_vram_size" ]]; then
            echo -e "  ${CYAN}VRAM Size${RESET}         ${BOLD}${WHITE}${status_vram_size}MB${RESET}  ${DIM}(UMA_SIZE, current CMOS setting)${RESET}"
        else
            echo -e "  ${CYAN}VRAM Size${RESET}         ${DIM}unknown — see Initial Setup > BC-250 Memory Config${RESET}"
        fi
    else
        echo -e "  ${CYAN}Tool${RESET}              ${DIM}not installed${RESET}"
    fi
    echo ""

    # --- Memory / Swap ---
    echo -e "  ${BOLD}${YELLOW}Memory & Swap${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"

    # ZSWAP Detection
    local zswap_enabled zswap_compressor zswap_pool
    zswap_enabled=$(cat /sys/module/zswap/parameters/enabled 2>/dev/null || echo "N")
    zswap_compressor=$(cat /sys/module/zswap/parameters/compressor 2>/dev/null || echo "N/A")
    zswap_pool=$(cat /sys/module/zswap/parameters/max_pool_percent 2>/dev/null || echo "N/A")
    local zswap_color
    [[ "$zswap_enabled" == "Y" ]] && zswap_color="$GREEN" || zswap_color="$RED"
    echo -e "  ${CYAN}ZSWAP${RESET}              ${zswap_color}${zswap_enabled}${RESET}  ${DIM}${zswap_compressor} / pool ${zswap_pool}%${RESET}"

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

    # Swapfile
    local swapfile_color swapfile_status
    if [[ -f "/var/swap/swapfile" ]]; then
        swapfile_status="${GREEN}present${RESET}"
    else
        swapfile_status="${DIM}not found${RESET}"
    fi
    echo -e "  ${CYAN}Swapfile${RESET}           ${swapfile_status}"

    # Swap Devices (Filtered to avoid empty/inactive lines)
    echo -e "  ${CYAN}Swap Devices${RESET}"
    local swap_output
    swap_output=$(swapon --show --noheadings 2>/dev/null)
    if [[ -z "$swap_output" ]]; then
        echo -e "    ${DIM}(No active swap devices found)${RESET}"
    else
        echo "$swap_output" | while read -r name type size used prio; do
            echo -e "    ${DIM}${name} (${size})${RESET}"
        done
    fi
    echo ""

    # --- Disk Space ---
    echo -e "  ${BOLD}${YELLOW}Disk Space${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
    local df_root df_boot
    df_root=$(df -h / | awk 'NR==2 {printf "%s/%s (%s free)", $3, $2, $4}')
    df_boot=$(df -h /boot | awk 'NR==2 {printf "%s/%s (%s free)", $3, $2, $4}')
    echo -e "  ${CYAN}/${RESET}                 ${df_root}"
    echo -e "  ${CYAN}/boot${RESET}             ${df_boot}"
    echo ""

    # --- Kernel Parameters ---
    echo -e "  ${BOLD}${YELLOW}Kernel Parameters${RESET}"
    echo -e "  ${DIM}bootloader: $BOOTLOADER — source: $LIMINE_CONF${RESET}"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"

    if [[ -f "$LIMINE_CONF" ]]; then
        local loglevel mitigations_off zram_disabled zswap_conf lz4_initrd ttm_ceiling
        loglevel=$(grep -o 'loglevel=[0-9]*' "$LIMINE_CONF" | head -1 || echo "not set")
        grep -q 'mitigations=off' "$LIMINE_CONF" && mitigations_off="off ${RED}(vulnerable)${RESET}" || mitigations_off="${GREEN}on (default)${RESET}"
        grep -q 'systemd\.zram=0' "$LIMINE_CONF" && zram_disabled="${RED}disabled${RESET}" || zram_disabled="${GREEN}enabled (default)${RESET}"
        grep -q 'zswap\.enabled=1' "$LIMINE_CONF" && zswap_conf="${GREEN}enabled${RESET}" || zswap_conf="${DIM}not set${RESET}"
        local ttm_value
        ttm_value="$(ttm_configured_pages_limit || true)"
        if [[ -n "$ttm_value" ]]; then
            ttm_ceiling="${GREEN}~$(ttm_pages_to_gb "$ttm_value")GB${RESET}  ${DIM}(ttm.pages_limit=${ttm_value})${RESET}"
        else
            ttm_ceiling="${DIM}not set (driver default, ~8.25GB w/ 512MB split)${RESET}"
        fi
        local initramfs_tool
        initramfs_tool="$(detect_initramfs)"
        case "$initramfs_tool" in
            mkinitcpio)
                local MKINITCPIO="/etc/mkinitcpio.conf"
                grep -q 'lz4' "$MKINITCPIO" 2>/dev/null && lz4_initrd="${GREEN}yes${RESET}" || lz4_initrd="${DIM}no${RESET}"
                ;;
            dracut)
                grep -rq 'lz4' /etc/dracut.conf.d/ 2>/dev/null && lz4_initrd="${GREEN}yes${RESET}" || lz4_initrd="${DIM}no${RESET}"
                ;;
            *)
                lz4_initrd="${DIM}unknown${RESET}"
                ;;
        esac

        echo -e "  ${CYAN}loglevel${RESET}          ${loglevel}"
        echo -e "  ${CYAN}Mitigations${RESET}       ${mitigations_off}"
        echo -e "  ${CYAN}ZRAM (cmdline)${RESET}    ${zram_disabled}"
        echo -e "  ${CYAN}ZSWAP (cmdline)${RESET}   ${zswap_conf}"
        echo -e "  ${CYAN}lz4 in initramfs${RESET}  ${lz4_initrd}"
        echo -e "  ${CYAN}VRAM Ceiling${RESET}      ${ttm_ceiling}"
    else
        echo -e "  ${RED}$LIMINE_CONF not found${RESET}"
    fi
    echo ""

    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_revert_loglevel() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "R-4" "Revert loglevel — Restoring default"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
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
    bootloader_update
    print_success "loglevel restored to 3. Reboot to apply."
}

run_revert_mitigations() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "R-5" "Revert Mitigations — Re-enabling"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
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
    bootloader_update
    print_success "mitigations=off removed. Reboot to re-enable CPU security mitigations."
}

run_revert_ttm_pages_limit() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "R-8" "Revert Dynamic VRAM Ceiling — Removing ttm.pages_limit"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
        return 1
    fi

    if ! grep -q 'ttm\.pages_limit=' "$CONF"; then
        print_info "ttm.pages_limit not found — nothing to revert."
        return 0
    fi

    if ! confirm "This will remove ttm.pages_limit from $CONF. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    print_info "Removing ttm.pages_limit..."
    sed -i 's/ ttm\.pages_limit=[0-9]*//g' "$CONF"
    bootloader_update
    print_success "ttm.pages_limit removed. Reboot to restore the driver default dynamic VRAM ceiling."
}

run_all() {
    print_step "★" "Running All Setup Tasks (1–7)"
    echo -e "  ${DIM}This will run: CachyOS Kernel, CPU Governor, GPU Governor, Enable Swap,"
    echo -e "  Disable ZRAM / Enable ZSWAP, Hide RDSEED Warning, and Disable Mitigations.${RESET}"

    if ! confirm "Proceed with all tasks?"; then
        print_info "Cancelled."
        return 0
    fi

    local failed=0
    SKIP_LIMINE_UPDATE=1

    # Define the list of tasks to run
    local tasks=(
        run_switch_to_default_kernel
        run_cpu_governor
        run_gpu_governor
        run_enable_swap
        run_disable_zram_enable_zswap
        run_set_loglevel
        run_disable_mitigations
    )

    for task in "${tasks[@]}"; do
        # Wait for pacman lock before starting next task
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
    if ! bootloader_update; then
        print_error "Failed to update boot config. Please run manually."
        (( failed++ ))
    fi

    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
    if [[ "$failed" -eq 0 ]]; then
        print_success "All tasks completed successfully!"
    else
        print_error "$failed task(s) encountered errors. Review output above."
    fi
}
# ==============================================================================
# EXPERIMENTAL / DANGER ZONE — CU LIVE MANAGER
# ==============================================================================
#
# Integrates bc250-cu-live-manager functionality with toolkit formatting.
# Terminology mapping:
#   WGP (Work Group Processor) → Compute Pair  (always 2 CUs)
#   SE/SH rows                 → Row           (SE0.SH0 etc.)
#   SPI dispatch                → Routing
#   D+ / S+ / D!                → Default / Enabled / Blocked
#   stock-dispatch              → Reset to Driver Default
#   write-service-table         → Save Boot Profile
#   apply-service                → Apply Saved Boot Profile
# ==============================================================================

CU_BC250_PCI_ID="13fe"
CU_ASIC="${UMR_ASIC:-cyan_skillfish.gfx1013}"
CU_REG_CC="mmCC_GC_SHADER_ARRAY_CONFIG"
CU_REG_SPI="mmSPI_PG_ENABLE_STATIC_WGP_MASK"
CU_REG_RLC="mmRLC_PG_ALWAYS_ON_WGP_MASK"
CU_SERVICE_NAME="bc250-cu-live-manager.service"
CU_SERVICE_PATH="/etc/systemd/system/$CU_SERVICE_NAME"
CU_SERVICE_BIN="/usr/local/bin/bc250-cu-live-manager"
CU_SERVICE_CONF="/etc/bc250-cu-live-manager.conf"
CU_OLD_UDEV_RULE="/etc/udev/rules.d/99-bc250-cu-live-manager.rules"
CU_LAST_REG_PATH=""
CU_WGP_FULL_MASK=0x1f
CU_UMR="${UMR:-}"
CU_UMR_INSTANCE="${UMR_INSTANCE:-}"
CU_UMR_INSTANCE_SOURCE="${UMR_INSTANCE:+env}"
CU_DRY_RUN=0
CU_FORCE=0
CU_SERVICE_TABLE_PENDING=0
CU_DISCLAIMER_ACCEPTED=0
CU_UMR_INSTALL_OFFERED=0
CU_UMR_INSTANCE_ARGS=()

cu_info() { echo -e "  ${BOLD}${GREEN}✔${RESET}  $*"; }
cu_warn() { echo -e "  ${BOLD}${YELLOW}⚠${RESET}  $*"; }
cu_err()  { echo -e "  ${BOLD}${RED}✘${RESET}  $*" >&2; }
cu_die()  { cu_err "$@"; return 1; }

cu_hr() {
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

cu_find_umr() {
    local p
    if [ -n "$CU_UMR" ] && [ -x "$CU_UMR" ]; then return 0; fi
    for p in /usr/bin/umr /usr/local/bin/umr /opt/umr/build/src/app/umr; do
        if [ -x "$p" ]; then CU_UMR="$p"; return 0; fi
    done
    if p="$(command -v umr 2>/dev/null)" && [ -x "$p" ]; then
        CU_UMR="$p"
        return 0
    fi
    return 1
}

cu_need_umr() {
    cu_find_umr || cu_die "umr not found. Use 'Install umr' from this menu." || return 1
    cu_select_umr_instance
}

cu_validate_umr_instance() { [[ "$1" =~ ^[0-9]+$ ]]; }

cu_init_umr_instance_args() {
    CU_UMR_INSTANCE_ARGS=()
    if [ -n "$CU_UMR_INSTANCE" ]; then
        CU_UMR_INSTANCE_ARGS=(-i "$CU_UMR_INSTANCE")
    fi
}

cu_detect_umr_instance() {
    local debug_root="/sys/kernel/debug/dri" line bdf dir inst
    local -a seen=()
    [ -d "$debug_root" ] || return 1
    while IFS= read -r line; do
        bdf="${line%% *}"
        [ -n "$bdf" ] || continue
        for dir in "$debug_root"/[0-9]*; do
            [ -e "$dir/name" ] || continue
            inst="${dir##*/}"
            [[ "$inst" =~ ^[0-9]+$ ]] || continue
            [ "$inst" -lt 128 ] || continue
            if grep -Fqi "$bdf" "$dir/name" 2>/dev/null; then
                printf '%s\n' "$inst"; return 0
            fi
        done
    done < <(lspci -Dnn 2>/dev/null | grep -i '\[1002:13fe\]' || true)
    for dir in "$debug_root"/[0-9]*; do
        [ -e "$dir/name" ] || continue
        inst="${dir##*/}"
        [[ "$inst" =~ ^[0-9]+$ ]] || continue
        [ "$inst" -lt 128 ] || continue
        seen+=("$inst")
    done
    [ "${#seen[@]}" -eq 1 ] || return 1
    printf '%s\n' "${seen[0]}"
}

cu_select_umr_instance() {
    local detected
    if [ -n "$CU_UMR_INSTANCE" ]; then
        cu_validate_umr_instance "$CU_UMR_INSTANCE" || { cu_die "invalid UMR instance '$CU_UMR_INSTANCE'"; return 1; }
        CU_UMR_INSTANCE_SOURCE="${CU_UMR_INSTANCE_SOURCE:-env}"
        cu_init_umr_instance_args; return 0
    fi
    detected="$(cu_detect_umr_instance || true)"
    if [ -n "$detected" ]; then
        CU_UMR_INSTANCE="$detected"; CU_UMR_INSTANCE_SOURCE="auto"
    else
        CU_UMR_INSTANCE_SOURCE="default"
    fi
    cu_init_umr_instance_args
}

cu_umr_cmd_string() {
    printf '%s' "$CU_UMR"
    if [ -n "$CU_UMR_INSTANCE" ]; then printf ' -i %s' "$CU_UMR_INSTANCE"; fi
}

cu_check_bc250() {
    if command -v lspci >/dev/null 2>&1 && lspci -nn 2>/dev/null | grep -qi "$CU_BC250_PCI_ID"; then
        return 0
    fi
    cu_warn "BC-250 PCI ID 13fe was not detected by lspci."
    return 1
}

cu_require_bc250_for_write() {
    cu_check_bc250 && return 0
    [ "$CU_FORCE" -eq 1 ] || { cu_die "refusing register writes on unknown hardware"; return 1; }
    cu_warn "forcing register writes despite failed BC-250 PCI detection"
}

cu_parse_hex() {
    awk '{for(i=NF;i>=1;i--){if($i~/^0x[0-9a-fA-F]+$/){print $i;exit}}}'
}

cu_umr_output_failed() {
    printf '%s\n' "$1" | grep -Eqi '(\[ERROR\]|error|failed|invalid|unknown|cannot|no such)'
}

cu_reg_candidates() { printf '%s\n' "$1"; }

cu_try_read_reg_bank() {
    local reg="$1" se="$2" sh="$3" candidate out value
    CU_LAST_REG_PATH=""
    while IFS= read -r candidate; do
        out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -r "$CU_ASIC.$candidate" -b "$se" "$sh" 0xffffffff 2>&1 || true)"
        value="$(printf '%s\n' "$out" | cu_parse_hex)"
        if [ -z "$value" ]; then
            out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -r "$CU_ASIC.$candidate" -b "$se" "$sh" 2>&1 || true)"
            value="$(printf '%s\n' "$out" | cu_parse_hex)"
        fi
        if [ -n "$value" ]; then
            CU_LAST_REG_PATH="$CU_ASIC.$candidate"; printf '%s\n' "$value"; return 0
        fi
    done < <(cu_reg_candidates "$reg")
    return 1
}

cu_read_reg_bank() {
    local reg="$1" se="$2" sh="$3" value
    if value="$(cu_try_read_reg_bank "$reg" "$se" "$sh")"; then
        printf '%s\n' "$value"; return 0
    fi
    cu_die "failed to read $reg for SE$se SH$sh with umr"; return 1
}

cu_try_write_reg_global() {
    local reg="$1" value="$2" candidate out
    CU_LAST_REG_PATH=""
    while IFS= read -r candidate; do
        CU_LAST_REG_PATH="$CU_ASIC.$candidate"
        if [ "$CU_DRY_RUN" -eq 1 ]; then
            printf 'dry-run: %s -w %s %s\n' "$(cu_umr_cmd_string)" "$CU_LAST_REG_PATH" "$value"; return 0
        fi
        out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -w "$CU_LAST_REG_PATH" "$value" 2>&1 || true)"
        cu_umr_output_failed "$out" || return 0
    done < <(cu_reg_candidates "$reg")
    return 1
}

cu_write_reg_bank() {
    local reg="$1" value="$2" se="$3" sh="$4" candidate out
    CU_LAST_REG_PATH=""
    while IFS= read -r candidate; do
        CU_LAST_REG_PATH="$CU_ASIC.$candidate"
        if [ "$CU_DRY_RUN" -eq 1 ]; then
            printf 'dry-run: %s -w %s %s -b %s %s 0xffffffff\n' \
                "$(cu_umr_cmd_string)" "$CU_LAST_REG_PATH" "$value" "$se" "$sh"
            return 0
        fi
        out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -w "$CU_LAST_REG_PATH" "$value" -b "$se" "$sh" 0xffffffff 2>&1 || true)"
        cu_umr_output_failed "$out" || return 0
    done < <(cu_reg_candidates "$reg")
    cu_die "failed to write $reg=$value for SE$se SH$sh"; return 1
}

cu_hex_mask()       { printf '0x%02x' "$(( $1 & 31 ))"; }
cu_hex_to_dec()     { printf '%d' "$(( $1 ))"; }

cu_wgp_mask_cu_count() {
    local mask="$1" wgp count=0
    for wgp in 0 1 2 3 4; do
        if [ $((mask & (1 << wgp))) -ne 0 ]; then count=$((count + 2)); fi
    done
    printf '%s\n' "$count"
}

cu_row_label() {
    case "$1" in 0) printf 'SE0.SH0';; 1) printf 'SE0.SH1';; 2) printf 'SE1.SH0';; 3) printf 'SE1.SH1';; esac
}

cu_row_coords() {
    case "$1" in 0) printf '0 0';; 1) printf '0 1';; 2) printf '1 0';; 3) printf '1 1';; esac
}

cu_read_spi_masks() {
    local idx se sh spi_hex
    for idx in 0 1 2 3; do
        read -r se sh <<<"$(cu_row_coords "$idx")"
        spi_hex="$(cu_read_reg_bank "$CU_REG_SPI" "$se" "$sh")"
        masks[$idx]=$(( $(cu_hex_to_dec "$spi_hex") & 31 ))
    done
}

cu_read_current_masks() {
    local -a masks
    cu_read_spi_masks
    current_masks=("${masks[@]}")
}

cu_mask_csv() {
    local -n ref="$1"
    printf '%s,%s,%s,%s\n' \
        "$(cu_hex_mask "${ref[0]}")" "$(cu_hex_mask "${ref[1]}")" \
        "$(cu_hex_mask "${ref[2]}")" "$(cu_hex_mask "${ref[3]}")"
}

cu_mask_summary() {
    local -n ref="$1"
    printf '%s=%s %s=%s %s=%s %s=%s\n' \
        "$(cu_row_label 0)" "$(cu_hex_mask "${ref[0]}")" \
        "$(cu_row_label 1)" "$(cu_hex_mask "${ref[1]}")" \
        "$(cu_row_label 2)" "$(cu_hex_mask "${ref[2]}")" \
        "$(cu_row_label 3)" "$(cu_hex_mask "${ref[3]}")"
}

cu_mask_tokens() {
    local mask="$1" driver_mask="${2:-0}" wgp bit token out=""
    for wgp in 0 1 2 3 4; do
        bit=$((1 << wgp))
        if   [ $((driver_mask & bit)) -ne 0 ] && [ $((mask & bit)) -ne 0 ]; then token="Default"
        elif [ $((driver_mask & bit)) -ne 0 ];                               then token="Blocked"
        elif [ $((mask & bit)) -ne 0 ];                                      then token="Enabled"
        else                                                                       token="Disabled"
        fi
        out="${out}${out:+ }$token"
    done
    printf '%s\n' "$out"
}

cu_mask_change_label() {
    local old="$1" new="$2" wgp bit out=""
    for wgp in 0 1 2 3 4; do
        bit=$((1 << wgp))
        if   [ $((old & bit)) -eq 0 ] && [ $((new & bit)) -ne 0 ]; then out="${out}${out:+,}P${wgp}+"
        elif [ $((old & bit)) -ne 0 ] && [ $((new & bit)) -eq 0 ]; then out="${out}${out:+,}P${wgp}-"
        fi
    done
    printf '%s\n' "${out:-none}"
}

cu_dispatch_total() {
    local idx total=0
    for idx in 0 1 2 3; do
        total=$((total + $(cu_wgp_mask_cu_count "${target_masks[$idx]}")))
    done
    printf '%s\n' "$total"
}

cu_load_service_masks() {
    local line csv item idx value
    local -a _items
    service_masks=()
    [ -f "$CU_SERVICE_CONF" ] || return 1
    while IFS= read -r line; do
        case "$line" in BC250_WGP_MASKS=*) csv="${line#BC250_WGP_MASKS=}"; break;; esac
    done <"$CU_SERVICE_CONF"
    [ -n "${csv:-}" ] || return 1
    IFS=',' read -ra _items <<<"$csv"
    [ "${#_items[@]}" -eq 4 ] || return 1
    for idx in 0 1 2 3; do
        item="${_items[$idx]}"
        [[ "$item" =~ ^(0x[0-9a-fA-F]+|[0-9]+)$ ]] || return 1
        value=$((item))
        [ "$value" -ge 0 ] && [ "$value" -le 31 ] || return 1
        service_masks[$idx]="$value"
    done
    return 0
}

cu_service_masks_match_current() {
    local idx
    [ "${#service_masks[@]}" -eq 4 ] || return 1
    [ "${#current_masks[@]}" -eq 4 ] || return 1
    for idx in 0 1 2 3; do
        [ "$((service_masks[idx] & 31))" -eq "$((current_masks[idx] & 31))" ] || return 1
    done
    return 0
}

cu_read_driver_wgp_masks() {
    local line idx mask
    local -a out=()
    while IFS= read -r line; do out+=("$line"); done < <(python3 <<'PYEOF'
import ctypes, os, struct, sys
def open_render_node():
    candidates = ["/dev/dri/renderD128"]
    dri = "/dev/dri"
    if os.path.isdir(dri):
        for name in sorted(os.listdir(dri)):
            if name.startswith("renderD"):
                path = os.path.join(dri, name)
                if path not in candidates:
                    candidates.append(path)
    last = None
    for path in candidates:
        try: return os.open(path, os.O_RDWR)
        except OSError as exc: last = exc
    raise RuntimeError(f"no DRM render node could be opened: {last}")
try:
    libdrm = ctypes.CDLL("libdrm_amdgpu.so.1")
    fd = open_render_node()
    dev = ctypes.c_void_p()
    maj, min_ = ctypes.c_uint32(), ctypes.c_uint32()
    rc = libdrm.amdgpu_device_initialize(fd, ctypes.byref(maj), ctypes.byref(min_), ctypes.byref(dev))
    if rc != 0: raise RuntimeError(f"amdgpu_device_initialize failed: {rc}")
    buf = (ctypes.c_uint8 * 1024)()
    rc = libdrm.amdgpu_query_info(dev, 0x16, 1024, ctypes.byref(buf))
    if rc != 0: raise RuntimeError(f"amdgpu_query_info(CU_INFO) failed: {rc}")
    raw = bytes(buf)
    num_se = struct.unpack_from("<I", raw, 20)[0]
    num_sh = struct.unpack_from("<I", raw, 24)[0]
    rows = []
    for se in range(min(num_se, 2)):
        for sh in range(min(num_sh, 2)):
            bm = struct.unpack_from("<I", raw, 56 + (se * 4 + sh) * 4)[0]
            wgp_mask = 0
            for wgp in range(5):
                if bm & (0x3 << (wgp * 2)): wgp_mask |= 1 << wgp
            rows.append((se * 2 + sh, wgp_mask))
    for idx, mask in rows: print(f"{idx} {mask}")
except Exception: sys.exit(1)
finally:
    try:
        if 'dev' in locals() and dev: libdrm.amdgpu_device_deinitialize(dev)
    except Exception: pass
    try:
        if 'fd' in locals() and fd >= 0: os.close(fd)
    except Exception: pass
PYEOF
    )
    [ "${#out[@]}" -gt 0 ] || return 1
    for idx in 0 1 2 3; do driver_masks[$idx]=0; done
    for line in "${out[@]}"; do
        read -r idx mask <<<"$line"
        [[ "$idx" =~ ^[0-3]$ ]] || continue
        driver_masks[$idx]="$mask"
    done
    return 0
}

cu_select_asic() {
    local out value
    out="$("$CU_UMR" "${CU_UMR_INSTANCE_ARGS[@]}" -r "$CU_ASIC.$CU_REG_SPI" 2>&1 || true)"
    value="$(printf '%s\n' "$out" | cu_parse_hex)"
    [ -n "$value" ] || { cu_die "failed to read $CU_ASIC.$CU_REG_SPI with umr"; return 1; }
}

cu_apply_target_masks() {
    local idx se sh union=0
    if ! cu_try_write_reg_global "$CU_REG_CC" "0x0"; then
        cu_warn "could not write global $CU_REG_CC; trying per-row CC clears"
    fi
    for idx in 0 1 2 3; do
        read -r se sh <<<"$(cu_row_coords "$idx")"
        cu_write_reg_bank "$CU_REG_CC" 0x0 "$se" "$sh"
        cu_write_reg_bank "$CU_REG_SPI" "$(cu_hex_mask "${target_masks[$idx]}")" "$se" "$sh"
        union=$((union | target_masks[idx]))
    done
    if ! cu_try_write_reg_global "$CU_REG_RLC" "$(cu_hex_mask "$union")"; then
        cu_warn "could not write $CU_REG_RLC; continuing with routing masks applied"
    fi
    cu_info "Compute pair routing updated ($(cu_dispatch_total)/40 CUs active)"
}

cu_confirm_dispatch_plan() {
    local title="$1" idx ans current target driver
    [ "$CU_DISCLAIMER_ACCEPTED" -eq 1 ] || return 1
    echo ""
    print_section "$title"
    echo -e "  ${DIM}Legend: Default = driver default CUs, Enabled = additionally unlocked, Disabled = not active, Blocked = driver conflict${RESET}\n"
    printf "  %-9s %-30s %-30s %-20s\n" "Row" "Current" "Target" "Change"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────────────────────────${RESET}"
    for idx in 0 1 2 3; do
        current="${current_masks[$idx]}"
        target="${target_masks[$idx]}"
        driver="${driver_masks[$idx]:-0}"
        printf "  %-9s %-30s %-30s %-20s\n" \
            "$(cu_row_label "$idx")" \
            "$(cu_mask_tokens "$current" "$driver")" \
            "$(cu_mask_tokens "$target" "$driver")" \
            "$(cu_mask_change_label "$current" "$target")"
    done
    echo ""
    echo -e "  ${BOLD}${WHITE}Target total: $(cu_dispatch_total)/40 CUs${RESET}"
    echo ""
    if ! confirm "Apply these changes?"; then
        print_info "Cancelled."; return 1
    fi
}

cu_module_status() {
    local mode enum
    mode="$(cat /sys/module/amdgpu/parameters/bc250_cc_write_mode 2>/dev/null || true)"
    enum="$(dmesg 2>/dev/null | grep -o 'active_cu_number [0-9]*' | tail -1 | awk '{print $2}' || true)"
    printf "  %-14s: bc250_cc_write_mode=%s, active_cu_number=%s\n" \
        "amdgpu" "${mode:-not exposed}" "${enum:-unknown}"
}

cu_live_table_header() {
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────────────────────────${RESET}"
    printf "  %-9s %-8s %-8s %-8s %-8s %-8s %-8s %-12s %-8s\n" \
        "Row" "Pair0" "Pair1" "Pair2" "Pair3" "Pair4" "Routing" "CC Reg" "CUs"
    printf "  %-9s %-8s %-8s %-8s %-8s %-8s\n" \
        "" "CU0-1" "CU2-3" "CU4-5" "CU6-7" "CU8-9"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────────────────────────${RESET}"
}

cu_live_cell() {
    local spi_on="$1" driver_on="${2:-0}"
    if   [ "$driver_on" -ne 0 ] && [ "$spi_on" -ne 0 ]; then printf "${GREEN}${BOLD}Default  ${RESET}"
    elif [ "$driver_on" -ne 0 ];                          then printf "${RED}${BOLD}Blocked  ${RESET}"
    elif [ "$spi_on" -ne 0 ];                             then printf "${CYAN}Enabled  ${RESET}"
    else                                                       printf "${DIM}Disabled ${RESET}"
    fi
}

cu_register_status() {
    cu_need_umr || return 1
    cu_select_asic || return 1
    cu_check_bc250 || true
    local total=0 driver_total=0 blocked_total=0 se sh spi cc_hex count idx wgp bit driver_mask spi_on driver_on
    local -a driver_masks current_masks service_masks
    local driver_ok=0 service_has_config=0
    CU_SERVICE_TABLE_PENDING=0
    if cu_read_driver_wgp_masks; then driver_ok=1; fi
    cu_read_current_masks
    if cu_load_service_masks; then
        service_has_config=1
        cu_service_masks_match_current || CU_SERVICE_TABLE_PENDING=1
    elif [ -f "$CU_SERVICE_PATH" ]; then
        CU_SERVICE_TABLE_PENDING=1
    fi
    echo ""
    print_section "CU Live Status"
    printf "  %-14s: %s\n" "umr" "$CU_UMR"
    if [ -n "$CU_UMR_INSTANCE" ]; then
        printf "  %-14s: %s (%s)\n" "UMR instance" "$CU_UMR_INSTANCE" "$CU_UMR_INSTANCE_SOURCE"
    else
        printf "  %-14s: default (0)\n" "UMR instance"
    fi
    printf "  %-14s: %s\n" "ASIC" "$CU_ASIC"
    cu_module_status
    if command -v systemctl >/dev/null 2>&1 && [ -f "$CU_SERVICE_PATH" ]; then
        printf "  %-14s: %s\n" "Boot service" "$(systemctl is-enabled "$CU_SERVICE_NAME" 2>/dev/null || printf 'installed')"
        if [ "$CU_SERVICE_TABLE_PENDING" -eq 1 ]; then
            echo -e "  ${BOLD}${YELLOW}⚠  Boot profile pending — use 'Save Boot Profile' to sync${RESET}"
        elif [ "$service_has_config" -eq 1 ]; then
            printf "  %-14s: current table saved\n" "Boot profile"
        else
            echo -e "  ${BOLD}${YELLOW}⚠  No boot profile saved yet — use 'Save Boot Profile'${RESET}"
        fi
    fi
    echo ""
    if [ "$driver_ok" -eq 1 ]; then
        echo -e "  ${GREEN}${BOLD}Default${RESET}  = driver default CUs   ${CYAN}Enabled${RESET}  = additionally unlocked CUs   ${DIM}Disabled${RESET}  = not active   ${RED}${BOLD}Blocked${RESET} = driver conflict"
    else
        echo -e "  ${CYAN}Enabled${RESET}  = routing active   ${DIM}Disabled${RESET}  = not active   ${YELLOW}(driver lock state unavailable)${RESET}"
    fi
    echo ""
    cu_live_table_header
    for se in 0 1; do
        for sh in 0 1; do
            idx=$((se * 2 + sh))
            cc_hex="$(cu_read_reg_bank "$CU_REG_CC" "$se" "$sh")"
            spi="${current_masks[$idx]}"
            driver_mask="${driver_masks[$idx]:-0}"
            count=0
            printf "  %-9s " "SE${se}.SH${sh}"
            for wgp in 0 1 2 3 4; do
                bit=$((1 << wgp))
                spi_on=0; driver_on=0
                if [ $((spi & bit)) -ne 0 ]; then spi_on=1; count=$((count + 2)); fi
                if [ "$driver_ok" -eq 1 ] && [ $((driver_mask & bit)) -ne 0 ]; then
                    driver_on=1; driver_total=$((driver_total + 2))
                fi
                if [ "$driver_on" -ne 0 ] && [ "$spi_on" -eq 0 ]; then blocked_total=$((blocked_total + 2)); fi
                cu_live_cell "$spi_on" "$driver_on"
            done
            total=$((total + count))
            printf "${DIM}%s${RESET}  %s  %3s/10 CUs\n" "$(cu_hex_mask "$spi")" "$cc_hex" "$count"
        done
    done
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────────────────────────${RESET}"
    echo ""
    echo -e "  ${BOLD}${WHITE}Routing total : ${total}/40 CUs${RESET}"
    [ "$service_has_config" -eq 1 ] && printf "  %-14s: %s\n" "Boot profile" "$(cu_mask_summary service_masks)"
    if [ "$driver_ok" -eq 1 ]; then
        echo -e "  ${BOLD}Driver lock   : ${driver_total}/40 CUs active — default pairs cannot be disabled live${RESET}"
        if [ "$blocked_total" -gt 0 ]; then
            cu_warn "${blocked_total} driver-active CUs are not routed (shown as Blocked)"
        fi
    else
        cu_warn "driver lock state unavailable — disabling routing will be refused"
    fi
}

cu_draw_table_editor() {
    local cursor_row="$1" cursor_wgp="$2" idx wgp bit cell style endstyle driver_on
    clear
    print_banner
    print_section "Edit Compute Pair Routing"
    echo -e "  ${DIM}Arrows/hjkl${RESET} move   ${DIM}Space${RESET} toggle   ${DIM}Enter/a${RESET} apply   ${DIM}q${RESET} cancel\n"
    echo -e "  ${GREEN}${BOLD}Default${RESET} = driver default CUs (locked)   ${CYAN}Enabled${RESET} = additionally unlocked   ${DIM}Disabled${RESET} = not active\n"
    printf "  %-9s %-8s %-8s %-8s %-8s %-8s\n" "Row" "Pair0" "Pair1" "Pair2" "Pair3" "Pair4"
    printf "  %-9s %-8s %-8s %-8s %-8s %-8s\n" "" "CU0-1" "CU2-3" "CU4-5" "CU6-7" "CU8-9"
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
    for idx in 0 1 2 3; do
        printf "  %-9s" "$(cu_row_label "$idx")"
        for wgp in 0 1 2 3 4; do
            bit=$((1 << wgp))
            driver_on=0
            if [ "${driver_lock_ok:-0}" -eq 1 ] && [ $((driver_masks[idx] & bit)) -ne 0 ]; then driver_on=1; fi
            if [ $((masks[idx] & bit)) -ne 0 ]; then
                if [ "$driver_on" -eq 1 ]; then cell="Default  "; style="${GREEN}${BOLD}"
                else                            cell="Enabled  "; style="${CYAN}"
                fi
            else
                cell="Disabled "; style="${DIM}"
            fi
            endstyle="${RESET}"
            if [ "$idx" -eq "$cursor_row" ] && [ "$wgp" -eq "$cursor_wgp" ]; then
                style="${BOLD}${YELLOW}"; cell="[${cell:0:6}]"
                endstyle="${RESET}"
            fi
            printf "${style}%-8s${endstyle}" "${cell:0:8}"
        done
        printf "\n"
    done
    echo -e "  ${DIM}─────────────────────────────────────────────────────────────────────${RESET}"
}

cu_table_editor() {
    cu_need_umr || return 1
    cu_select_asic || return 1
    local -a masks driver_masks
    local driver_lock_ok=0
    local row=0 wgp=0 key rest bit
    cu_read_spi_masks
    cu_read_driver_wgp_masks && driver_lock_ok=1
    while true; do
        cu_draw_table_editor "$row" "$wgp"
        IFS= read -rsn1 key || return 0
        case "$key" in
            $'\x1b')
                IFS= read -rsn2 -t 0.1 rest || rest=""
                case "$rest" in
                    '[A') row=$((row > 0 ? row - 1 : 3)) ;;
                    '[B') row=$((row < 3 ? row + 1 : 0)) ;;
                    '[C') wgp=$((wgp < 4 ? wgp + 1 : 0)) ;;
                    '[D') wgp=$((wgp > 0 ? wgp - 1 : 4)) ;;
                esac ;;
            h|H) wgp=$((wgp > 0 ? wgp - 1 : 4)) ;;
            l|L) wgp=$((wgp < 4 ? wgp + 1 : 0)) ;;
            k|K) row=$((row > 0 ? row - 1 : 3)) ;;
            j|J) row=$((row < 3 ? row + 1 : 0)) ;;
            ' ')
                bit=$((1 << wgp))
                if [ "$driver_lock_ok" -ne 1 ]; then
                    cu_warn "driver topology unavailable — toggles are locked"; sleep 1
                elif [ $((driver_masks[row] & bit)) -ne 0 ] && [ $((masks[row] & bit)) -ne 0 ]; then
                    cu_warn "$(cu_row_label "$row") Pair${wgp} is a Default (driver-locked) CU and cannot be disabled live"; sleep 1
                else
                    masks[$row]=$((masks[row] ^ bit))
                fi ;;
            ''|$'\n'|$'\r'|a|A)
                local -a target_masks current_masks driver_masks_confirm
                cu_read_current_masks
                target_masks=("${masks[@]}")
                cu_read_driver_wgp_masks && driver_masks_confirm=("${driver_masks[@]}") || driver_masks_confirm=(0 0 0 0)
                driver_masks=("${driver_masks_confirm[@]}")
                cu_apply_target_masks
                press_enter; return 0 ;;
            q|Q) return 0 ;;
        esac
    done
}

cu_enable_all() {
    cu_need_umr || return 1
    cu_select_asic || return 1
    cu_require_bc250_for_write || return 1
    local -a current_masks target_masks driver_masks
    cu_read_current_masks
    cu_read_driver_wgp_masks || true
    target_masks=("$CU_WGP_FULL_MASK" "$CU_WGP_FULL_MASK" "$CU_WGP_FULL_MASK" "$CU_WGP_FULL_MASK")
    cu_confirm_dispatch_plan "Enable All Compute Pairs" || return 0
    cu_apply_target_masks
}

cu_stock_dispatch() {
    cu_need_umr || return 1
    cu_select_asic || return 1
    cu_require_bc250_for_write || return 1
    local -a current_masks target_masks driver_masks
    cu_read_driver_wgp_masks || { cu_die "driver topology unavailable; cannot restore driver default"; return 1; }
    cu_read_current_masks
    target_masks=("${driver_masks[@]}")
    cu_confirm_dispatch_plan "Reset to Driver Default" || return 0
    cu_apply_target_masks
}

cu_write_service_table() {
    cu_need_umr || return 1
    cu_select_asic || return 1
    cu_require_bc250_for_write || return 1
    local -a current_masks
    cu_read_current_masks
    if ! confirm "Save current compute pair routing as the boot profile?"; then
        print_info "Cancelled."; return 0
    fi
    cat > "$CU_SERVICE_CONF" <<EOF
# BC-250 live manager boot profile.
# Generated by bc250-toolkit on $(date -Iseconds).
# Format: SE0.SH0,SE0.SH1,SE1.SH0,SE1.SH1 SPI routing masks.
BC250_WGP_MASKS=$(cu_mask_csv current_masks)
UMR_ASIC=$CU_ASIC
UMR_INSTANCE=$CU_UMR_INSTANCE
UMR=$CU_UMR
EOF
    chmod 0644 "$CU_SERVICE_CONF"
    cu_info "Boot profile saved: $(cu_mask_summary current_masks)"
}

cu_install_service() {
    cu_need_umr || return 1
    if ! confirm "Install/update the boot service to apply saved routing on startup?"; then
        print_info "Cancelled."; return 0
    fi
    local source_path
    source_path="$(readlink -f "$0")"
    if ! install -m 0755 "$source_path" "$CU_SERVICE_BIN"; then
        if [ -d /var/usrlocal/bin ]; then
            CU_SERVICE_BIN="/var/usrlocal/bin/bc250-cu-live-manager"
            install -m 0755 "$source_path" "$CU_SERVICE_BIN"
        else
            cu_die "failed to install service binary at $CU_SERVICE_BIN"; return 1
        fi
    fi
    cat > "$CU_SERVICE_PATH" <<EOF
[Unit]
Description=BC-250 CU saved enumeration and dispatch
After=systemd-udev-settle.service cyan-skillfish-governor-smu.service
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
Environment="BC250_CU_RETRY_ATTEMPTS=60"
Environment="BC250_CU_RETRY_DELAY=1"
EnvironmentFile=-$CU_SERVICE_CONF
TimeoutStartSec=150s
ExecStartPre=/usr/bin/bash -c 'for _ in {1..30}; do compgen -G "/dev/dri/renderD*" >/dev/null && exit 0; sleep 1; done; exit 1'
ExecStart=$CU_SERVICE_BIN --yes apply-service
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    rm -f "$CU_OLD_UDEV_RULE"
    systemctl daemon-reload
    systemctl enable "$CU_SERVICE_NAME"
    if [ -f "$CU_SERVICE_CONF" ]; then
        cu_info "Boot service installed and enabled"
        cu_info "Saved boot profile will be applied on next boot"
    else
        cu_info "Boot service installed and enabled"
        cu_warn "No boot profile saved yet — use 'Save Boot Profile' before rebooting"
    fi
}

cu_uninstall_service() {
    if ! confirm "Remove the boot service and all saved profiles?"; then
        print_info "Cancelled."; return 0
    fi
    systemctl disable --now "$CU_SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$CU_SERVICE_PATH" "$CU_SERVICE_BIN" "/var/usrlocal/bin/bc250-cu-live-manager" \
          "$CU_SERVICE_CONF" "$CU_OLD_UDEV_RULE"
    systemctl daemon-reload
    cu_info "Boot service removed"
}

cu_install_umr() {
    if command -v pacman >/dev/null 2>&1 && pacman -Qi umr >/dev/null 2>&1; then
        cu_info "umr is already installed."
        cu_find_umr && cu_info "Found at: $CU_UMR"
        return 0
    fi

    local installed=0

    if command -v pacman >/dev/null 2>&1 && pacman -Si umr >/dev/null 2>&1; then
        cu_info "Installing umr with pacman..."
        if pacman -S --needed --noconfirm umr; then
            installed=1
        else
            cu_die "pacman could not install umr — check the output above"
            return 1
        fi
    elif ensure_aur_helper; then
        cu_info "Installing umr via AUR helper..."
        if aur_install umr; then
            installed=1
        else
            cu_die "AUR install of umr failed — check the build output above"
            return 1
        fi
    elif command -v rpm-ostree >/dev/null 2>&1; then
        cu_warn "rpm-ostree layering is host-level and may affect immutable system upgrades."
        cu_info "Installing umr with rpm-ostree (reboot required)..."
        if rpm-ostree install umr; then
            cu_info "umr staged. Reboot then return here — it can't be verified until then."
            return 0
        else
            cu_die "rpm-ostree could not install umr"
            return 1
        fi
    elif command -v dnf >/dev/null 2>&1; then
        cu_info "Installing umr with dnf..."
        if dnf install -y umr; then
            installed=1
        else
            cu_die "dnf could not install umr"
            return 1
        fi
    else
        cu_die "could not install umr automatically — no pacman, AUR helper, rpm-ostree, or dnf available"
        return 1
    fi

    if [ "$installed" -eq 1 ]; then
        CU_UMR=""   # clear any stale cached path so this re-searches fresh
        if cu_find_umr; then
            cu_info "umr installed successfully — found at: $CU_UMR"
            return 0
        else
            cu_warn "The install command reported success, but umr could not be found"
            cu_warn "afterward (checked /usr/bin/umr, /usr/local/bin/umr,"
            cu_warn "/opt/umr/build/src/app/umr, and PATH). It may have installed to a"
            cu_warn "non-standard location — check the install output above."
            return 1
        fi
    fi
}

dz_warn() {
    echo ""
    echo -e "  ${BOLD}${RED}⚠  EXPERIMENTAL / DANGER ZONE${RESET}"
    echo ""
    echo -e "  ${WHITE}This section gives direct access to low-level GPU hardware registers."
    echo -e "  Writing incorrect values can freeze the GPU, crash the system, or"
    echo -e "  force a hard reboot — causing loss of unsaved work."
    echo ""
    echo -e "  Enabling additional compute units significantly increases power draw."
    echo -e "  Ensure your PSU, cabling, and cooling can handle the load before"
    echo -e "  making changes. The 8-pin connector and wiring are particularly"
    echo -e "  vulnerable to overload damage."
    echo ""
    echo -e "  You are fully responsible for any outcomes.${RESET}"
    echo ""
    echo -e "  ${DIM}Type ${RESET}${BOLD}${YELLOW}unlock${RESET}${DIM} to acknowledge and enter, or press Enter to go back.${RESET}"
    echo ""
    read -rp "  → " dz_ack
    if [[ "${dz_ack,,}" == "unlock" ]]; then
        CU_DISCLAIMER_ACCEPTED=1
        return 0
    else
        print_info "Returning to main menu."
        return 1
    fi
}

show_danger_zone_menu() {
    print_banner
    print_section "⚠  Experimental/Danger Zone — Compute Units Unlock"
    echo -e "  ${DIM}Direct hardware register access. Read the status dashboard before making changes.${RESET}\n"
    print_section "Prerequisites"
    print_item  "1"  "Install umr"              ""
    echo ""
    print_section "Compute Unit Management"
    print_item  "2"  "CU Status Dashboard"       ""
    print_item  "3"  "Edit Compute Pairs"        ""
    print_item  "4"  "Enable All Compute Pairs"  ""
    print_item  "5"  "Reset to Driver Default"   ""
    echo ""
    print_section "Boot Persistence"
    print_item  "6"  "Install Boot Service"      ""
    print_item  "7"  "Save Boot Profile"         ""
    print_item  "8"  "Uninstall Boot Service"    ""
    echo ""
    print_item  "0"  "Back"                      ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_danger_zone_menu() {
    dz_warn || return 0
    while true; do
        show_danger_zone_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" dz_choice

        case "${dz_choice^^}" in
            1) cu_install_umr;          press_enter ;;
            2) cu_register_status;      press_enter ;;
            3) cu_table_editor ;;
            4) cu_enable_all;           press_enter ;;
            5) cu_stock_dispatch;       press_enter ;;
            6) cu_install_service;      press_enter ;;
            7) cu_write_service_table;  press_enter ;;
            8) cu_uninstall_service;    press_enter ;;
            0) return 0 ;;
            *)
                print_error "Invalid selection: '$dz_choice'"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# BC-250 MEMORY CONFIG (bc250_memcfg — https://github.com/fanoush/bc250_memcfg)
# ==============================================================================

MEMCFG_REPO_URL="https://github.com/fanoush/bc250_memcfg.git"
MEMCFG_BUILD_DIR="/tmp/bc250_memcfg_build"
MEMCFG_BIN="/usr/local/bin/bc250memcfg"
MEMCFG_VERSION_FILE="/usr/local/share/bc250-memcfg.commit"

memcfg_installed() {
    [[ -x "$MEMCFG_BIN" ]]
}

# Prints the remote HEAD commit hash, or empty string if it couldn't be reached
memcfg_remote_commit() {
    git ls-remote "$MEMCFG_REPO_URL" HEAD 2>/dev/null | awk '{print $1}'
}

memcfg_installed_commit() {
    [[ -f "$MEMCFG_VERSION_FILE" ]] && cat "$MEMCFG_VERSION_FILE"
}

run_install_memcfg() {
    print_step "AT-6" "Installing bc250_memcfg"

    print_info "Checking for the latest version..."
    local remote_commit
    remote_commit="$(memcfg_remote_commit)"

    if memcfg_installed; then
        local installed_commit
        installed_commit="$(memcfg_installed_commit)"
        if [[ -z "$remote_commit" ]]; then
            print_info "Could not reach GitHub to check for updates — keeping existing install at $MEMCFG_BIN."
            return 0
        elif [[ -n "$installed_commit" && "$installed_commit" == "$remote_commit" ]]; then
            print_info "bc250_memcfg is already up to date ($MEMCFG_BIN)."
            return 0
        else
            print_info "bc250_memcfg is installed at $MEMCFG_BIN, but a newer version is available upstream."
            if ! confirm "Rebuild and reinstall the latest version?"; then
                print_info "Keeping current install."
                return 0
            fi
        fi
    fi

    print_info "Installing build dependencies: base-devel"
    pacman -S --needed --noconfirm base-devel || { print_error "Failed to install build dependencies."; return 1; }

    print_info "Cloning bc250_memcfg repository..."
    rm -rf "$MEMCFG_BUILD_DIR"
    if ! git clone "$MEMCFG_REPO_URL" "$MEMCFG_BUILD_DIR"; then
        print_error "Failed to clone repository."
        return 1
    fi

    print_info "Building bc250memcfg..."
    if ! make -C "$MEMCFG_BUILD_DIR"; then
        print_error "Build failed."
        return 1
    fi

    # The Makefile's output binary name — fall back to searching the build dir
    local built_bin="$MEMCFG_BUILD_DIR/bc250memcfg"
    if [[ ! -x "$built_bin" ]]; then
        built_bin="$(find "$MEMCFG_BUILD_DIR" -maxdepth 1 -type f -executable | head -1)"
    fi
    if [[ -z "$built_bin" || ! -x "$built_bin" ]]; then
        print_error "Build did not produce an executable."
        return 1
    fi

    print_info "Installing binary to $MEMCFG_BIN..."
    install -m 0755 "$built_bin" "$MEMCFG_BIN"

    # Record the commit we just built so future runs can detect updates
    local built_commit
    built_commit="$(git -C "$MEMCFG_BUILD_DIR" rev-parse HEAD 2>/dev/null || printf '%s' "$remote_commit")"
    if [[ -n "$built_commit" ]]; then
        mkdir -p "$(dirname "$MEMCFG_VERSION_FILE")"
        echo "$built_commit" > "$MEMCFG_VERSION_FILE"
    fi

    rm -rf "$MEMCFG_BUILD_DIR"

    print_success "bc250_memcfg installed successfully!"
}

memcfg_warn() {
    echo ""
    echo -e "  ${BOLD}${RED}⚠  WARNING: Direct BIOS CMOS Memory Configuration${RESET}"
    echo ""
    echo -e "  ${WHITE}This tool writes directly to the battery-backed CMOS RAM the BIOS"
    echo -e "  uses for memory configuration (VRAM size, memory timings). Incorrect"
    echo -e "  values can cause instability or a failure to boot."
    echo ""
    echo -e "  Changes only take effect after a reboot. To revert to defaults you"
    echo -e "  must clear CMOS via the board jumper, or by removing the battery —"
    echo -e "  this tool cannot undo its own changes.${RESET}"
    echo ""
    echo -e "  ${DIM}Type ${RESET}${BOLD}${YELLOW}yes${RESET}${DIM} to continue, or press Enter to cancel.${RESET}"
    echo ""
    read -rp "  → " mc_ack
    [[ "${mc_ack,,}" == "yes" ]]
}

run_memcfg_show() {
    print_step "AT-6" "Current Memory Configuration"
    if ! memcfg_installed; then
        print_error "bc250_memcfg is not installed. Run 'Install bc250_memcfg' first."
        return 1
    fi
    "$MEMCFG_BIN"
}

# Best-effort parse of the current UMA_SIZE (VRAM size in MB) from the tool's
# no-args output. The exact print format isn't documented upstream, so this
# grabs the first number on whatever line mentions UMA_SIZE.
memcfg_current_uma_size() {
    memcfg_installed || return 1
    "$MEMCFG_BIN" 2>/dev/null | grep -i 'UMA_SIZE' | head -1 | grep -oE '[0-9]+' | head -1
}

run_memcfg_set_uma_size() {
    print_step "AT-6" "Set VRAM Size (UMA_SIZE)"
    if ! memcfg_installed; then
        print_error "bc250_memcfg is not installed. Run 'Install bc250_memcfg' first."
        return 1
    fi

    memcfg_warn || { print_info "Cancelled."; return 0; }

    echo ""
    read -rp "$(echo -e "  ${BOLD}${WHITE}VRAM size in MB, >=256, aligned to 16MB steps (default: 512):${RESET} ")" uma_input
    local uma_size
    if [[ -z "$uma_input" ]]; then
        uma_size="512"
    elif [[ "$uma_input" =~ ^[0-9]+$ ]] && (( uma_input >= 256 )); then
        uma_size="$uma_input"
    else
        print_error "Invalid size '$uma_input' — must be an integer >= 256."
        return 1
    fi

    if ! confirm "Set UMA_SIZE to ${uma_size}MB? A reboot is required to apply."; then
        print_info "Cancelled."
        return 0
    fi

    "$MEMCFG_BIN" UMA_SIZE "$uma_size"
    print_success "UMA_SIZE written. Reboot to apply."
}

# Reads the currently configured ttm.pages_limit value from the bootloader
# cmdline config, if set. Prints nothing if not set or config unreadable.
ttm_configured_pages_limit() {
    local conf
    conf="$(bootloader_conf)"
    [[ -n "$conf" && -f "$conf" ]] || return 1
    grep -o 'ttm\.pages_limit=[0-9]*' "$conf" | head -1 | cut -d= -f2
}

# Converts a ttm.pages_limit value (4KiB pages) to an approximate GB figure
ttm_pages_to_gb() {
    awk -v pages="$1" 'BEGIN{printf "%.1f", pages * 4 / 1024 / 1024}'
}

run_set_ttm_pages_limit() {
    local CONF
    CONF="$(bootloader_conf)"
    local BOOTLOADER
    BOOTLOADER="$(detect_bootloader)"
    print_step "AT-7" "Raising Dynamic VRAM Ceiling — ttm.pages_limit"

    if [[ -z "$CONF" ]] || [[ ! -f "$CONF" ]]; then
        print_error "Bootloader config not found. Supported: Limine, GRUB."
        return 1
    fi
    print_info "Detected bootloader: $BOOTLOADER ($CONF)"

    echo ""
    echo -e "  ${WHITE}With the 512MB VRAM split, the default dynamic VRAM ceiling is"
    echo -e "  around 8.25GB, which some games can exceed and crash against."
    echo -e "  This sets the ttm.pages_limit kernel parameter to raise that"
    echo -e "  ceiling — similar headroom to a larger fixed split, while still"
    echo -e "  returning unused VRAM to system RAM once a game closes.${RESET}"
    echo ""

    local existing
    existing="$(ttm_configured_pages_limit || true)"
    if [[ -n "$existing" ]]; then
        print_info "Currently configured: ttm.pages_limit=${existing} (~$(ttm_pages_to_gb "$existing")GB)"
    fi

    read -rp "$(echo -e "  ${BOLD}${WHITE}Desired max dynamic VRAM in GB (default: 12):${RESET} ")" vram_gb_input
    local vram_gb
    if [[ -z "$vram_gb_input" ]]; then
        vram_gb="12"
    elif [[ "$vram_gb_input" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v g="$vram_gb_input" 'BEGIN{exit !(g>0)}'; then
        vram_gb="$vram_gb_input"
    else
        print_error "Invalid value '$vram_gb_input' — must be a positive number."
        return 1
    fi

    local pages_limit
    pages_limit=$(awk -v gb="$vram_gb" 'BEGIN{printf "%.0f", gb * 1024 * 1024 / 4}')

    if ! confirm "Set ttm.pages_limit=${pages_limit} (~${vram_gb}GB dynamic VRAM ceiling)? Reboot required to apply."; then
        print_info "Cancelled."
        return 0
    fi

    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi

    local cmdline_var
    cmdline_var="$(bootloader_cmdline_var)"
    local cmdline_var_esc
    cmdline_var_esc="$(bootloader_cmdline_var_escaped)"

    if grep -q 'ttm\.pages_limit=' "$CONF"; then
        print_info "ttm.pages_limit= found. Updating value to ${pages_limit}..."
        sed -i "s/ttm\.pages_limit=[0-9]*/ttm.pages_limit=${pages_limit}/g" "$CONF"
    else
        print_info "ttm.pages_limit= not found. Adding to $cmdline_var..."
        sed -i "/^${cmdline_var_esc}/ s/\"$/ ttm.pages_limit=${pages_limit}\"/" "$CONF"
    fi

    if [[ "$SKIP_LIMINE_UPDATE" -eq 0 ]]; then
        bootloader_update
    fi
    print_success "ttm.pages_limit set to ${pages_limit} (~${vram_gb}GB). Reboot to apply."
    echo -e "  ${DIM}After reboot, verify with: cat /sys/module/ttm/parameters/pages_limit${RESET}\n"
}

show_memcfg_menu() {
    print_banner
    print_section "BC-250 Memory Config"
    echo -e "  ${DIM}Configure BIOS CMOS memory settings via bc250_memcfg (https://github.com/fanoush/bc250_memcfg).${RESET}\n"
    local status_label
    if memcfg_installed; then
        status_label="${GREEN}installed${RESET}  ${DIM}($MEMCFG_BIN)${RESET}"
    else
        status_label="${DIM}not installed${RESET}"
    fi
    echo -e "  ${CYAN}Status${RESET}      ${status_label}"
    if memcfg_installed; then
        local current_vram
        current_vram="$(memcfg_current_uma_size)"
        if [[ -n "$current_vram" ]]; then
            echo -e "  ${CYAN}VRAM Size${RESET}   ${BOLD}${WHITE}${current_vram}MB${RESET}  ${DIM}(UMA_SIZE, current CMOS setting)${RESET}"
        else
            echo -e "  ${CYAN}VRAM Size${RESET}   ${DIM}unknown — see 'Show Current Config' for raw output${RESET}"
        fi
    fi
    local ttm_current
    ttm_current="$(ttm_configured_pages_limit || true)"
    if [[ -n "$ttm_current" ]]; then
        echo -e "  ${CYAN}VRAM Ceiling${RESET} ${BOLD}${WHITE}~$(ttm_pages_to_gb "$ttm_current")GB${RESET}  ${DIM}(ttm.pages_limit=${ttm_current}, cmdline)${RESET}"
    else
        echo -e "  ${CYAN}VRAM Ceiling${RESET} ${DIM}not set (driver default, ~8.25GB with 512MB split)${RESET}"
    fi
    echo -e "  ${DIM}(Re-running Install checks GitHub and offers to rebuild if a newer version exists.)${RESET}\n"
    print_item "1" "Install bc250_memcfg"     "Build and install from source"
    print_item "2" "Show Current Config"      "Print all tunable memory parameters"
    print_item "3" "Set VRAM Size"            "Set UMA_SIZE (requires reboot)"
    print_item "4" "Set Dynamic VRAM Ceiling" "ttm.pages_limit kernel param (requires reboot)"
    echo ""
    print_item "0" "Back" ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_memcfg_menu() {
    while true; do
        show_memcfg_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" mc_choice

        case "${mc_choice^^}" in
            1) run_install_memcfg;        press_enter ;;
            2) run_memcfg_show;           press_enter ;;
            3) run_memcfg_set_uma_size;   press_enter ;;
            4) run_set_ttm_pages_limit;   press_enter ;;
            0) return 0 ;;
            *)
                print_error "Invalid selection: '$mc_choice'"
                sleep 1
                ;;
        esac
    done
}

# ==============================================================================
# ADDITIONAL TOOLS FUNCTIONS
# ==============================================================================


run_dolphinbar_udev() {
    local RULES_FILE="/etc/udev/rules.d/51-dolphinbar.rules"
    print_step "AT-2" "Installing DolphinBar udev Rules"

    print_info "Writing $RULES_FILE..."
    cat > "$RULES_FILE" << 'EOF'
#GameCube Controller Adapter
SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTRS{idVendor}=="057e", ATTRS{idProduct}=="0337", TAG+="uaccess"
#Wiimotes or DolphinBar
SUBSYSTEM=="hidraw*", ATTRS{idVendor}=="057e", ATTRS{idProduct}=="0306", TAG+="uaccess"
SUBSYSTEM=="hidraw*", ATTRS{idVendor}=="057e", ATTRS{idProduct}=="0330", TAG+="uaccess"
EOF

    print_info "Reloading udev rules..."
    udevadm control --reload-rules
    udevadm trigger

    print_success "DolphinBar udev rules installed! Reconnect your device."
}

run_revert_dolphinbar() {
    local RULES_FILE="/etc/udev/rules.d/51-dolphinbar.rules"
    print_step "R-7" "Reverting DolphinBar udev Rules"

    if [[ ! -f "$RULES_FILE" ]]; then
        print_info "Rules file not found: $RULES_FILE — nothing to remove."
        return 0
    fi

    print_info "Removing $RULES_FILE..."
    rm -f "$RULES_FILE"

    print_info "Reloading udev rules..."
    udevadm control --reload-rules
    udevadm trigger

    print_success "DolphinBar udev rules removed. Reconnect your device."
}

run_revert_cpu_governor() {
    print_step "R-1" "Revert CPU Governor — Removing bc250-smu-oc"

    local user_home
    user_home="$(getent passwd "$REAL_USER" | cut -d: -f6)"
    local user_bin="$user_home/.local/bin"

    if ! systemctl is-enabled bc250-smu-oc.service &>/dev/null && \
       [[ ! -x "$user_bin/bc250-detect" ]] && \
       ! sudo -u "$REAL_USER" pipx list 2>/dev/null | grep -q 'bc250-smu-oc' && \
       ! pipx list 2>/dev/null | grep -q 'bc250-smu-oc'; then
        print_info "CPU governor does not appear to be installed — nothing to revert."
        return 0
    fi

    if ! confirm "This will stop, disable, and remove the bc250-smu-oc service. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    print_info "Stopping and disabling bc250-smu-oc service..."
    systemctl stop bc250-smu-oc.service 2>/dev/null || true
    systemctl disable bc250-smu-oc.service 2>/dev/null || true

    print_info "Uninstalling via pipx as $REAL_USER..."
    sudo -u "$REAL_USER" pipx uninstall bc250-smu-oc 2>/dev/null || true
    # Also try root's pipx, in case an older toolkit version installed it there
    pipx uninstall bc250-smu-oc 2>/dev/null || true

    if [[ -f "$CPU_DEST" ]]; then
        print_info "Removing config file $CPU_DEST..."
        rm -f "$CPU_DEST"
    fi

    print_success "CPU governor removed successfully."
}

run_revert_gpu_governor() {
    print_step "R-2" "Revert GPU Governor — Removing cyan-skillfish-governor-smu"

    if ! systemctl is-enabled cyan-skillfish-governor-smu.service &>/dev/null && \
       ! pacman -Qq cyan-skillfish-governor-smu &>/dev/null; then
        print_info "GPU governor does not appear to be installed — nothing to revert."
        return 0
    fi

    if ! confirm "This will stop, disable, and remove the cyan-skillfish-governor-smu service. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    print_info "Stopping and disabling cyan-skillfish-governor-smu service..."
    systemctl stop cyan-skillfish-governor-smu.service 2>/dev/null || true
    systemctl disable cyan-skillfish-governor-smu.service 2>/dev/null || true

    print_info "Removing cyan-skillfish-governor-smu via AUR helper..."
    aur_remove cyan-skillfish-governor-smu

    print_success "GPU governor removed successfully."
}

show_revert_menu() {
    print_banner
    print_section "Revert / Undo"
    echo -e "  ${DIM}Undo previously applied settings and restore defaults.${RESET}\n"
    print_item  "1"  "Revert CPU Governor"     "Remove bc250-smu-oc service"
    print_item  "2"  "Revert GPU Governor"     "Remove cyan-skillfish-governor-smu"
    print_item  "3"  "Revert ZSWAP"            "Re-enable ZRAM, remove swapfile"
    print_item  "4"  "Revert loglevel"         "Restore loglevel to default (3)"
    print_item  "5"  "Revert Mitigations"      "Re-enable CPU security mitigations"
    print_item  "6"  "Revert DolphinBar"       "Remove DolphinBar udev rules"
    print_item  "7"  "Revert VRAM Ceiling"     "Remove ttm.pages_limit kernel param"
    print_item  "8"  "Revert ACPI Fix"         "Remove SSDT overrides & acpi_override hook"
    print_item  "9"  "Revert CPU Cores Unlock" "Remove UEFI boot entry & .efi file"
    echo ""
    print_item  "0"  "Back"                    ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_revert_menu() {
    while true; do
        show_revert_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" rev_choice

        case "${rev_choice^^}" in
            1) run_revert_cpu_governor;         press_enter ;;
            2) run_revert_gpu_governor;         press_enter ;;
            3) run_revert_zswap;                press_enter ;;
            4) run_revert_loglevel;             press_enter ;;
            5) run_revert_mitigations;          press_enter ;;
            6) run_revert_dolphinbar;           press_enter ;;
            7) run_revert_ttm_pages_limit;      press_enter ;;
            8) run_revert_acpi_fix;             press_enter ;;
            9) run_revert_cpu_cores_unlock_efi; press_enter ;;
            0) return ;;
            *)
                print_error "Invalid selection: '$rev_choice'"
                sleep 1
                ;;
        esac
    done
}

run_update_toolkit() {
    local target
    target="$(readlink -f "$0")"
    local base_url="https://raw.githubusercontent.com/redbeard1083/bc250-toolkit/main"

    print_section "Update Toolkit"
    echo ""
    print_item "1" "Stable"      "bc250-toolkit.sh"
    print_item "2" "Pre-Release" "Pre-release build"
    echo ""
    print_item "0" "Cancel" ""
    echo ""
    read -rp "$(echo -e "  ${BOLD}${WHITE}Select version:${RESET} ")" ver_choice

    local url
    case "$ver_choice" in
        1) url="$base_url/bc250-toolkit.sh" ;;
        2) url="$base_url/bc250-toolkit-pre.sh" ;;
        0) print_info "Cancelled."; return 0 ;;
        *) print_error "Invalid selection."; return 1 ;;
    esac

    echo ""
    print_info "Downloading from GitHub..."

    if ! curl -sSL \
        -H "Cache-Control: no-cache" \
        -H "Pragma: no-cache" \
        "$url" -o "${target}.tmp"; then
        print_error "Download failed. Check your internet connection."
        rm -f "${target}.tmp"
        return 1
    fi

    if ! head -1 "${target}.tmp" | grep -q "^#!"; then
        print_error "Downloaded file does not look like a valid script. Aborting."
        rm -f "${target}.tmp"
        return 1
    fi

    mv "${target}.tmp" "$target"
    chmod +x "$target"
    print_success "Toolkit updated successfully. Restarting..."
    sleep 1
    exec bash "$target"
}

show_initial_setup_menu() {
    print_banner
    print_section "Initial Setup"
    echo -e "  ${DIM}Run these tasks to configure your BC-250 system.${RESET}\n"
    print_item  "1"  "Install CachyOS Kernel"  "Replaces linux-cachyos-deckify"
    print_item  "2"  "CPU Governor"            "bc250-smu-oc CPU overclock service"
    print_item  "3"  "GPU Governor"            "cyan-skillfish GPU governor service"
    print_item  "4"  "Enable Swap"             "Btrfs swapfile, configurable"
    print_item  "5"  "ZRAM -> ZSWAP"           "Disable ZRAM, enable ZSWAP w/ lz4"
    print_item  "6"  "Hide RDSEED Warning"     "Set loglevel=0 in bootloader config"
    print_item  "7"  "Disable Mitigations"     "Add mitigations=off to bootloader config"
    echo ""
    print_item  "A"  "Run All (1-7)"           "Run all setup tasks in sequence"
    echo ""
    print_section "⚠  Manual Steps — not included in Run All"
    print_item  "8"  "CPU Cores Unlock"        "6 → 8 CPU cores via EFI boot entry"
    print_item  "9"  "GPU Compute Units Unlock" ""
    print_item  "10" "ACPI Fix"                "SSDT override + CPU governor control"
    print_item  "11" "BC-250 Memory Config"    "Configure VRAM size via bc250_memcfg"
    print_item  "12" "Remove Deckify Kernel"   "Verify new kernel boots first"
    echo ""
    print_item  "0"  "Back"                    ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_initial_setup_menu() {
    while true; do
        show_initial_setup_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" is_choice

        case "${is_choice^^}" in
            1) run_switch_to_default_kernel;  press_enter ;;
            2) run_cpu_governor;              press_enter ;;
            3) run_gpu_governor;              press_enter ;;
            4) run_enable_swap;               press_enter ;;
            5) run_disable_zram_enable_zswap; press_enter ;;
            6) run_set_loglevel;              press_enter ;;
            7) run_disable_mitigations;       press_enter ;;
            A) run_all;                       press_enter ;;
            8) run_cpu_cores_unlock_efi;       press_enter ;;
            9) run_danger_zone_menu ;;
            10) run_acpi_menu ;;
            11) run_memcfg_menu ;;
            12) run_remove_deckify_kernel;    press_enter ;;
            0) return 0 ;;
            *)
                print_error "Invalid selection: '$is_choice'"
                sleep 1
                ;;
        esac
    done
}

run_install_decky() {
    print_section "Install Decky"
    print_info "Downloading and running Decky installer..."
    echo ""
    rm -f /tmp/user_install_script.sh
    if curl -S -s -L -O --output-dir /tmp/ --connect-timeout 60 \
        https://github.com/SteamDeckHomebrew/decky-installer/releases/latest/download/user_install_script.sh; then
        bash /tmp/user_install_script.sh
    else
        print_error "Download failed. Check your internet connection and try again."
    fi
}

run_install_emudeck() {
    print_section "Install EmuDeck"
    print_info "Downloading and running EmuDeck installer as $REAL_USER..."
    echo ""
    sudo -u "$REAL_USER" bash -c 'curl -L https://raw.githubusercontent.com/dragoonDorise/EmuDeck/main/install.sh | bash'
}

run_install_protonup_qt() {
    print_section "Install ProtonUp-Qt"
    if aur_install protonup-qt; then
        print_success "ProtonUp-Qt installed successfully."
    else
        print_error "Installation failed — check the output above."
    fi
}

show_experimental_menu() {
    print_banner
    print_section "Additional Tools"
    echo -e "  ${DIM}Additional system utilities and hardware support.${RESET}\n"
    print_item  "1"  "Toggle Boot Mode"    "Switch between Game Mode & Desktop"
    print_item  "2"  "DolphinBar Setup"    "Wiimote support via DolphinBar"
    print_item  "3"  "Install Decky"       "Install the Decky plugin loader"
    print_item  "4"  "Install EmuDeck"     "Install the EmuDeck emulation suite"
    print_item  "5"  "Install ProtonUp-Qt" "Manage Proton and Wine versions"
    echo ""
    print_item  "0"  "Back"               ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

run_experimental_menu() {
    while true; do
        show_experimental_menu
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" exp_choice

        case "${exp_choice^^}" in
            1) run_toggle_boot_mode;      press_enter ;;
            2) run_dolphinbar_udev;       press_enter ;;
            3) run_install_decky;         press_enter ;;
            4) run_install_emudeck;       press_enter ;;
            5) run_install_protonup_qt;   press_enter ;;
            0) return 0 ;;
            *)
                print_error "Invalid selection: '$exp_choice'"
                sleep 1
                ;;
        esac
    done
}

run_reboot() {
    if confirm "Reboot the system now?"; then
        echo -e "\n  ${DIM}Rebooting...${RESET}\n"
        systemctl reboot
    else
        print_info "Cancelled."
    fi
}

show_menu() {
    print_banner
    print_section "Performance"
    print_item  "1"  "Performance Profiles"  "CPU & GPU performance profiles"
    echo ""
    print_section "Setup"
    print_item  "2"  "Initial Setup"         "System configuration tasks"
    print_item  "3"  "Additional Tools"      "Additional system utilities"
    print_item  "4"  "Revert Menu"           "Undo previously applied settings"
    echo ""
    print_section "System"
    print_item  "S"  "Status"                "Current system summary"
    print_item  "U"  "Update Toolkit"        "Download latest version from GitHub"
    print_item  "R"  "Reboot"                "Restart the system"
    print_item  "0"  "Exit"                  ""
    echo ""
    echo -e "  ${BOLD}${CYAN}═════════════════════════════════════════════════════════════════════${RESET}"
}

while true; do
    show_menu
    read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" choice

    case "${choice^^}" in
        1) run_overclock_menu ;;
        2) run_initial_setup_menu ;;
        3) run_experimental_menu ;;
        4) run_revert_menu ;;
        S) run_status;        press_enter ;;
        U) run_update_toolkit ;;
        R) run_reboot ;;
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
