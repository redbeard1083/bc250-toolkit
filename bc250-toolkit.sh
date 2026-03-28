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
    print_step "01" "Installing CPU Governor"
    print_info "Installing dependencies: python-pipx, stress"
    sudo pacman -Syu python-pipx stress --noconfirm
    print_info "Cloning bc250_smu_oc repository..."
    if [[ -d "bc250_smu_oc" ]]; then
        print_info "Directory already exists — pulling latest changes..."
        git -C bc250_smu_oc pull
    else
        git clone https://github.com/bc250-collective/bc250_smu_oc.git
    fi
    cd bc250_smu_oc
    print_info "Installing via pipx..."
    pipx install .
    pipx ensurepath
    export PATH="$PATH:/root/.local/bin"
    print_info "Running bc250-detect..."
    bc250-detect --frequency 3500 --vid 1000 --keep
    print_info "Applying overclock config..."
    bc250-apply --install overclock.conf
    print_info "Enabling systemd service..."
    sudo systemctl enable bc250-smu-oc
    cd ..
    print_success "CPU Governor installed successfully!"
}

run_gpu_governor() {
    print_step "02" "Installing GPU Governor"
    print_info "Installing cyan-skillfish-governor-smu via paru (as $REAL_USER)..."
    sudo -u "$REAL_USER" paru -S cyan-skillfish-governor-smu --noconfirm
    print_info "Enabling and starting systemd service..."
    systemctl enable --now cyan-skillfish-governor-smu.service
    print_success "GPU Governor installed and started successfully!"
}

run_enable_swap() {
    print_step "03" "Configuring Swap"
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
    local CONF="/boot/limine.conf"
    print_step "04" "Hiding RDSEED Warning — Setting loglevel=0 in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    MATCHES=$(grep -c 'loglevel=[0-9]\+' "$CONF" || true)

    if [[ "$MATCHES" -eq 0 ]]; then
        print_info "No loglevel parameter found — nothing to do."
        return 0
    fi

    print_info "Found $MATCHES cmdline line(s) with loglevel."
    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi
    sed -i 's/loglevel=[0-9]\+/loglevel=0/g' "$CONF"
    print_success "loglevel set to 0 on $MATCHES line(s)."
}

run_disable_zram() {
    local CONF="/boot/limine.conf"
    print_step "05" "Disabling ZRAM in $CONF"

    if [[ ! -f "$CONF" ]]; then
        print_error "File not found: $CONF"
        return 1
    fi

    MATCHES=$(grep -c '^\s*cmdline:' "$CONF" || true)
    ALREADY=$(grep -c '^\s*cmdline:.*systemd\.zram=0' "$CONF" || true)
    NEEDS_UPDATE=$(( MATCHES - ALREADY ))

    if [[ "$MATCHES" -eq 0 ]]; then
        print_info "No cmdline entries found — nothing to do."
        return 0
    fi

    if [[ "$NEEDS_UPDATE" -eq 0 ]]; then
        print_info "All $MATCHES cmdline line(s) already have systemd.zram=0."
        return 0
    fi

    print_info "Found $NEEDS_UPDATE cmdline line(s) that need systemd.zram=0."
    if [[ ! -f "${CONF}.bak" ]]; then
        print_info "Creating original backup at ${CONF}.bak ..."
        cp "$CONF" "${CONF}.bak"
    else
        print_info "Backup already exists at ${CONF}.bak — preserving original."
    fi
    sed -i '/^\s*cmdline:/{/systemd\.zram=0/!s/$/ systemd.zram=0/}' "$CONF"
    print_success "systemd.zram=0 added to $NEEDS_UPDATE cmdline line(s)."
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
}

install_gpu() {
    cp "$GPU_TMPFILE" "$GPU_DEST"
    systemctl restart "$GPU_SERVICE"
}

PRESET_NAMES=("High" "Medium-High" "Medium-Low" "Low" "Very Low (Stock)")
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

oc_apply_preset() {
    local idx=$(( $1 - 1 ))
    print_info "Applying preset: ${PRESET_NAMES[$idx]}"
    print_info "${PRESET_DESCS[$idx]}"
    echo ""
    print_info "Writing and installing CPU config..."
    "${PRESET_CPU_WRITERS[$idx]}"
    install_cpu
    print_info "Writing and installing GPU config..."
    "${PRESET_GPU_WRITERS[$idx]}"
    install_gpu
    print_success "Preset '${PRESET_NAMES[$idx]}' applied!"
}

oc_prompt_temperature() {
    local label="$1" default="$2"
    while true; do
        read -rp "$(echo -e "  ${WHITE}Enter $label temp °C (60–100, default ${default}, 0=cancel):${RESET} ")" t
        [[ "$t" =~ ^[0-9]+$ ]] || { echo "  Invalid input."; continue; }
        [[ "$t" -eq 0 ]] && return 1
        (( t >= 60 && t <= 100 )) || { echo "  Out of range (60–100)."; continue; }
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
    local custom_cpu_temp="" custom_gpu_throttle="" custom_gpu_recovery=""

    echo ""
    read -rp "$(echo -e "  ${WHITE}Override CPU max temperature? [y/N]:${RESET} ")" yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        oc_prompt_temperature "CPU max" 90 || { print_info "Cancelled."; return 0; }
        custom_cpu_temp="$TEMP_RESULT"
    fi

    local gpu_default_temp=80
    (( gpu_idx >= 2 )) && gpu_default_temp=90
    echo ""
    read -rp "$(echo -e "  ${WHITE}Override GPU throttling temperature? [y/N]:${RESET} ")" yn
    if [[ "$yn" =~ ^[Yy]$ ]]; then
        oc_prompt_temperature "GPU throttling" "$gpu_default_temp" || { print_info "Cancelled."; return 0; }
        custom_gpu_throttle="$TEMP_RESULT"
        local recovery_max=$(( custom_gpu_throttle - 1 ))
        local recovery_default=$(( custom_gpu_throttle - 5 ))
        while true; do
            read -rp "$(echo -e "  ${WHITE}GPU recovery temp °C (60–${recovery_max}, default ${recovery_default}, 0=cancel):${RESET} ")" t
            [[ "$t" =~ ^[0-9]+$ ]] || { echo "  Invalid input."; continue; }
            [[ "$t" -eq 0 ]] && { print_info "Cancelled."; return 0; }
            (( t >= 60 && t < custom_gpu_throttle )) || { echo "  Out of range (60–${recovery_max})."; continue; }
            custom_gpu_recovery="$t"; break
        done
    fi

    echo ""
    print_info "CPU : ${CPU_NAMES[$cpu_idx]} — ${CPU_DESCS[$cpu_idx]}"
    [[ -n "$custom_cpu_temp" ]] && print_info "      ↳ max temp overridden to ${custom_cpu_temp}°C"
    print_info "GPU : ${GPU_NAMES[$gpu_idx]} — ${GPU_DESCS[$gpu_idx]}"
    [[ -n "$custom_gpu_throttle" ]] && print_info "      ↳ throttling overridden to ${custom_gpu_throttle}°C, recovery ${custom_gpu_recovery}°C"
    echo ""

    print_info "Writing and installing CPU config..."
    "${CPU_WRITERS[$cpu_idx]}"
    [[ -n "$custom_cpu_temp" ]] && sed -i "s/^max_temperature = .*/max_temperature = ${custom_cpu_temp}/" "$CPU_TMPFILE"
    install_cpu

    print_info "Writing and installing GPU config..."
    "${GPU_WRITERS[$gpu_idx]}"
    if [[ -n "$custom_gpu_throttle" ]]; then
        sed -i "s/^throttling = .*/throttling = ${custom_gpu_throttle}/" "$GPU_TMPFILE"
        sed -i "s/^throttling_recovery = .*/throttling_recovery = ${custom_gpu_recovery}/" "$GPU_TMPFILE"
    fi
    install_gpu

    print_success "Custom profile applied!"
}

run_overclock_menu() {
    while true; do
        print_banner
        print_section "Performance Profile Menu"
        for i in "${!PRESET_NAMES[@]}"; do
            print_item "$((i+1))" "${PRESET_NAMES[$i]}" "${PRESET_DESCS[$i]}"
        done
        echo ""
        print_item "C" "Custom"           "Mix & match CPU and GPU profiles"
        print_item "0" "Back to Main Menu" ""
        echo ""
        echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
        read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" oc_choice

        case "${oc_choice^^}" in
            C) oc_apply_custom;   press_enter ;;
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

run_create_patch() {
    local PATCH_FILE="0001-drm-amd-fix-dcn-2.01-check.patch"
    print_step "06" "DP Audio Fix — Creating Patch for CachyOS Kernel Manager"

    if [[ -f "$PATCH_FILE" ]]; then
        print_info "Patch file already exists: $PATCH_FILE — skipping."
        return 0
    fi

    cat > "$PATCH_FILE" << 'EOF'
From: Andy Nguyen <theofficialflow1996@gmail.com>
Subject: [PATCH] drm/amd: fix dcn 2.01 check
The ASICREV_IS_BEIGE_GOBY_P check always took precedence, because it
includes all chip revisions upto NV_UNKNOWN.
Fixes: 54b822b3eac3 ("drm/amd/display: Use dce_version instead of chip_id")
Signed-off-by: Andy Nguyen <theofficialflow1996@gmail.com>
---
 drivers/gpu/drm/amd/display/dc/clk_mgr/clk_mgr.c | 8 ++++----
 1 file changed, 4 insertions(+), 4 deletions(-)

diff --git a/drivers/gpu/drm/amd/display/dc/clk_mgr/clk_mgr.c b/drivers/gpu/drm/amd/display/dc/clk_mgr/clk_mgr.c
index 08d0e05a313e..d237d7b41dfd 100644
--- a/drivers/gpu/drm/amd/display/dc/clk_mgr/clk_mgr.c
+++ b/drivers/gpu/drm/amd/display/dc/clk_mgr/clk_mgr.c
@@ -255,6 +255,10 @@ struct clk_mgr *dc_clk_mgr_create(struct dc_context *ctx, struct pp_smu_funcs *p
 			BREAK_TO_DEBUGGER();
 			return NULL;
 		}
+		if (ctx->dce_version == DCN_VERSION_2_01) {
+			dcn201_clk_mgr_construct(ctx, clk_mgr, pp_smu, dccg);
+			return &clk_mgr->base;
+		}
 		if (ASICREV_IS_SIENNA_CICHLID_P(asic_id.hw_internal_rev)) {
 			dcn3_clk_mgr_construct(ctx, clk_mgr, pp_smu, dccg);
 			return &clk_mgr->base;
@@ -267,10 +271,6 @@ struct clk_mgr *dc_clk_mgr_create(struct dc_context *ctx, struct pp_smu_funcs *p
 			dcn3_clk_mgr_construct(ctx, clk_mgr, pp_smu, dccg);
 			return &clk_mgr->base;
 		}
-		if (ctx->dce_version == DCN_VERSION_2_01) {
-			dcn201_clk_mgr_construct(ctx, clk_mgr, pp_smu, dccg);
-			return &clk_mgr->base;
-		}
 		dcn20_clk_mgr_construct(ctx, clk_mgr, pp_smu, dccg);
 		return &clk_mgr->base;
 	}
-- 
2.43.0
EOF

    print_success "Patch file created: $PATCH_FILE"
}

run_all() {
    print_step "★" "Running All Setup Tasks (1–5)"
    echo -e "  ${DIM}This will run: CPU Governor, GPU Governor, Enable Swap,"
    echo -e "  Hide RDSEED Warning, and Disable ZRAM.${RESET}"

    if ! confirm "Proceed with all tasks?"; then
        print_info "Cancelled."
        return 0
    fi

    local failed=0

    for task in run_cpu_governor run_gpu_governor run_enable_swap run_set_loglevel run_disable_zram; do
        echo ""
        echo -e "  ${BG_HEADER}${BOLD}${WHITE}  Running: ${task//_/ }  ${RESET}"
        if $task; then
            :
        else
            print_error "Task failed: $task — continuing with remaining tasks."
            (( failed++ )) || true
        fi
        echo ""
    done

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
    print_section "Setup Tasks"
    print_item  "1"  "CPU Governor"        "bc250-smu-oc CPU overclock service"
    print_item  "2"  "GPU Governor"        "cyan-skillfish GPU governor service"
    print_item  "3"  "Enable Swap"         "16G Btrfs swapfile, swappiness=180"
    print_item  "4"  "Hide RDSEED Warning" "Set loglevel=0 in /boot/limine.conf"
    print_item  "5"  "Disable ZRAM"        "Add systemd.zram=0 to limine.conf"
    echo ""
    print_section "Extras"
    print_item  "6"  "Overclock Menu"      "CPU & GPU performance profiles"
    print_item  "7"  "DP Audio Fix"        "Patch file for CachyOS Kernel Mgr"
    echo ""
    print_section "Quick Actions"
    print_item  "A"  "Run All (1–5)"       "Run all setup tasks in sequence"
    print_item  "0"  "Exit"                ""
    echo ""
    echo -e "  ${BOLD}${CYAN}══════════════════════════════════════════════════════════════${RESET}"
}

while true; do
    show_menu
    read -rp "$(echo -e "  ${BOLD}${WHITE}Enter selection:${RESET} ")" choice

    case "${choice^^}" in
        1) run_cpu_governor;   press_enter ;;
        2) run_gpu_governor;   press_enter ;;
        3) run_enable_swap;    press_enter ;;
        4) run_set_loglevel;   press_enter ;;
        5) run_disable_zram;   press_enter ;;
        6) run_overclock_menu ;;
        7) run_create_patch;   press_enter ;;
        A) run_all;            press_enter ;;
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
