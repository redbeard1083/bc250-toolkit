#!/bin/bash
#
# ac3-surround.sh — HDMI AC-3 (Dolby Digital) Surround Encoding
#
# Enables real-time Dolby Digital 5.1 encoding over HDMI/DisplayPort via eARC.
# All audio (games, browsers, media players) is encoded to AC-3 by the native
# ALSA a52 plugin, with zero added latency and ~1-2% CPU overhead.
# Stereo content is automatically upmixed to 5.1 by PipeWire's channel mixer.
#
# This script is self-contained and can be used on any Linux system with
# PipeWire + WirePlumber (SteamOS, CachyOS, Arch, etc.) that has:
#   - An HDMI audio device (HDA ATI HDMI or similar)
#   - alsa-plugins (provides the a52 PCM plugin)
#   - ffmpeg (provides libavcodec used by the a52 plugin)
#   - alsa-card-profile (provides hdmi-ac3.conf profile set)
#
# On SteamOS (BC-250), the hdmi-ac3.conf profile set ships with the OS but is
# never loaded because the DMI identifies as "AMD BC-250" instead of Valve's
# "OEM F7F". On other distros, you may need to create the profile set manually
# (see create_hdmi_ac3_conf below) or install a package that provides it.
#
# Usage:
#   sudo ./ac3-surround.sh install    — enable AC-3 surround encoding
#   sudo ./ac3-surround.sh revert     — restore default HDMI stereo
#   sudo ./ac3-surround.sh status     — check current state
#
set -euo pipefail

# --- Colors -------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# --- Paths --------------------------------------------------------------------
UDEV_RULE="/etc/udev/rules.d/91-ac3-audio.rules"
WP_CONF_DIR="${SUDO_USER:+$(getent passwd "$SUDO_USER" | cut -d: -f6)}${HOME:-/root}/.config/wireplumber/wireplumber.conf.d"
WP_CONF="$WP_CONF_DIR/ac3-profile.conf"
ACP_PROFILE_DIR="/usr/share/alsa-card-profile/mixer/profile-sets"
ACP_PROFILE_FILE="$ACP_PROFILE_DIR/hdmi-ac3.conf"

# Resolve real home directory when running under sudo
if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    WP_CONF_DIR="$REAL_HOME/.config/wireplumber/wireplumber.conf.d"
    WP_CONF="$WP_CONF_DIR/ac3-profile.conf"
else
    REAL_HOME="${HOME:-/root}"
fi

# --- Helpers ------------------------------------------------------------------
print_info()  { echo -e "  ${CYAN}i${RESET} $*"; }
print_ok()    { echo -e "  ${GREEN}✓${RESET} $*"; }
print_error() { echo -e "  ${RED}✗${RESET} $*"; }
print_step()  { echo -e "\n${BOLD}${CYAN}[$1]${RESET} $2"; }

confirm() {
    local resp
    read -rp "$(echo -e "  ${BOLD}${YELLOW}$1 (y/N): ${RESET}")" resp
    [[ "${resp,,}" == "y" || "${resp,,}" == "yes" ]]
}

is_steamos() {
    [[ -f /etc/os-release ]] && grep -q "SteamOS" /etc/os-release 2>/dev/null
}

steamos_rw() {
    if is_steamos; then
        steamos-readonly disable 2>/dev/null || true
    fi
}

steamos_ro() {
    if is_steamos; then
        steamos-readonly enable 2>/dev/null || true
    fi
}

# Run a command as the non-root user with systemd/session DBus environment inherited
run_as_user() {
    local cmd="$1"
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        local user_uid
        user_uid=$(id -u "$SUDO_USER")
        sudo -u "$SUDO_USER" XDG_RUNTIME_DIR="/run/user/$user_uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_uid/bus" bash -c "$cmd"
    else
        eval "$cmd"
    fi
}

# --- Create hdmi-ac3.conf if it doesn't exist ---------------------------------
# On SteamOS this file ships with the OS. On other distros (CachyOS, Arch, etc.)
# it may not exist, so we create it with the standard AC-3 profile mappings.
create_hdmi_ac3_conf() {
    if [[ -f "$ACP_PROFILE_FILE" ]]; then
        return 0
    fi

    print_info "Creating $ACP_PROFILE_FILE (not found on this system)..."

    steamos_rw
    mkdir -p "$ACP_PROFILE_DIR"

    cat > "$ACP_PROFILE_FILE" << 'ACPEOF'
; Profile set with HDMI/AC3 profiles.
; Enables AC-3 (Dolby Digital) encoding via the ALSA a52 plugin.
; The a52 plugin encodes 6-channel PCM to AC-3 in real-time using libavcodec.

.include default.conf

[Mapping hdmi-ac3-surround]
description = Digital Surround 5.1 (HDMI/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,3'"}
paths-output = hdmi-output-0
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra1]
description = Digital Surround 5.1 (HDMI 2/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,7'"}
paths-output = hdmi-output-1
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra2]
description = Digital Surround 5.1 (HDMI 3/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,8'"}
paths-output = hdmi-output-2
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra3]
description = Digital Surround 5.1 (HDMI 4/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,9'"}
paths-output = hdmi-output-3
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra4]
description = Digital Surround 5.1 (HDMI 5/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,10'"}
paths-output = hdmi-output-4
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra5]
description = Digital Surround 5.1 (HDMI 6/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,11'"}
paths-output = hdmi-output-5
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra6]
description = Digital Surround 5.1 (HDMI 7/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,12'"}
paths-output = hdmi-output-6
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra7]
description = Digital Surround 5.1 (HDMI 8/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,13'"}
paths-output = hdmi-output-7
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra8]
description = Digital Surround 5.1 (HDMI 9/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,14'"}
paths-output = hdmi-output-8
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra9]
description = Digital Surround 5.1 (HDMI 10/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,15'"}
paths-output = hdmi-output-9
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Mapping hdmi-ac3-surround-extra10]
description = Digital Surround 5.1 (HDMI 11/AC3)
device-strings = plug:{SLAVE="a52:%f,'hw:%f,16'"}
paths-output = hdmi-output-10
channel-map = front-left,front-right,rear-left,rear-right,front-center,lfe
priority = 1
direction = output

[Profile output:hdmi-ac3-surround]
description = Digital Surround 5.1 (HDMI/AC3) Output
output-mappings = hdmi-ac3-surround
priority = 100
skip-probe = no

[Profile output:hdmi-ac3-surround-extra1]
description = Digital Surround 5.1 (HDMI 2/AC3) Output
output-mappings = hdmi-ac3-surround-extra1
priority = 100
skip-probe = no

[Profile output:hdmi-ac3-surround-extra2]
description = Digital Surround 5.1 (HDMI 3/AC3) Output
output-mappings = hdmi-ac3-surround-extra2
priority = 100
skip-probe = no

[Profile output:hdmi-ac3-surround-extra3]
description = Digital Surround 5.1 (HDMI 4/AC3) Output
output-mappings = hdmi-ac3-surround-extra3
priority = 100
skip-probe = no
ACPEOF

    steamos_ro
    print_ok "Created hdmi-ac3.conf profile set."
}

# --- Install ------------------------------------------------------------------
do_install() {
    print_step "AC3" "Installing HDMI AC-3 Surround Encoding (Dolby Digital)"

    echo -e "  ${DIM}Enables AC-3 (Dolby Digital) encoding over HDMI/DP for 5.1 surround${RESET}"
    echo -e "  ${DIM}via eARC. Bypasses TV LPCM downmix — receiver gets true 5.1 DD.${RESET}"
    echo -e "  ${DIM}Zero added latency, minimal CPU overhead (native a52 encoding).${RESET}"
    echo -e "  ${DIM}After installing, select the AC-3 sink in your desktop audio settings.${RESET}"
    echo ""

    # Check dependencies
    local missing=()
    [[ -f /usr/lib/alsa-lib/libasound_module_pcm_a52.so ]] || missing+=("alsa-plugins")
    compgen -G "/usr/lib/libavcodec.so*" >/dev/null || missing+=("ffmpeg")
    if (( ${#missing[@]} > 0 )); then
        print_info "Installing missing dependencies: ${missing[*]}"
        if command -v pacman &>/dev/null; then
            pacman -S --needed --noconfirm "${missing[@]}" 2>&1 | tail -5 || {
                print_error "Failed to install dependencies: ${missing[*]}"
                return 1
            }
        elif command -v apt &>/dev/null; then
            local apt_pkgs=()
            [[ " ${missing[*]} " == *" alsa-plugins "* ]] && apt_pkgs+=("libasound2-plugins")
            [[ " ${missing[*]} " == *" ffmpeg "* ]] && apt_pkgs+=("ffmpeg")
            apt-get update -qq && apt-get install -y "${apt_pkgs[@]}" 2>&1 | tail -5 || {
                print_error "Failed to install dependencies: ${apt_pkgs[@]}"
                return 1
            }
        else
            print_error "Missing packages: ${missing[*]}"
            print_info "Install manually with your package manager."
            return 1
        fi
    fi

    # Check physical sound cards directly via ALSA sysfs
    if ! grep -q -iE "hdmi|displayport|hda" /proc/asound/cards 2>/dev/null; then
        print_error "No HDMI/DP audio hardware found in /proc/asound/cards."
        return 1
    fi

    if ! confirm "Continue with AC-3 Surround Encoding installation?"; then
        print_info "Cancelled."
        return 0
    fi

    # 0. Create hdmi-ac3.conf if missing (non-SteamOS systems)
    create_hdmi_ac3_conf

    # 1. Install udev rule to set ACP_PROFILE_SET for the HDMI audio card
    print_info "Installing udev rule for ACP_PROFILE_SET=hdmi-ac3.conf..."
    steamos_rw
    echo 'SUBSYSTEM=="sound", KERNEL=="card0", ENV{ACP_PROFILE_SET}="hdmi-ac3.conf"' > "$UDEV_RULE"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger /sys/class/sound/card0 2>/dev/null || true
    steamos_ro

    # 2. Install WirePlumber config
    print_info "Installing WirePlumber config for AC-3 profiles..."
    mkdir -p "$WP_CONF_DIR"
    cat > "$WP_CONF" << 'WPEOF'
monitor.alsa.rules = [
  {
    matches = [
      {
        device.name = "~alsa_card.pci-.*"
      }
    ]
    actions = {
      update-props = {
        api.acp.disable-pro-audio = true
        device.profile-set = "hdmi-ac3.conf"
        device.routes.default-sink-volume = 1.0
      }
    }
  },
  {
    matches = [
      {
        node.name = "~alsa_output.pci-.*hdmi.*"
      }
    ]
    actions = {
      update-props = {
        session.suspend-timeout-seconds = 3600
      }
    }
  },
  {
    matches = [
      {
        node.name = "~alsa_output.pci-.*hdmi.*"
        alsa.name = "~a52.*"
      }
    ]
    actions = {
      update-props = {
        api.alsa.start-delay = 1536
      }
    }
  }
]
WPEOF
    if [[ -n "${SUDO_USER:-}" ]] && [[ "${SUDO_USER}" != "root" ]]; then
        chown -R "$SUDO_USER":"$SUDO_USER" "$WP_CONF_DIR" 2>/dev/null || true
    fi

    # 3. Restart WirePlumber and set the AC-3 profile & sink
    print_info "Restarting WirePlumber and activating AC-3 output..."

    run_as_user "systemctl --user restart wireplumber"
    sleep 2

    local CARD_NAME AC3_SINK
    CARD_NAME=$(run_as_user "pactl list cards short | awk '{print \$2}' | head -1")

    if [[ -n "$CARD_NAME" ]]; then
        run_as_user "pactl set-card-profile \"$CARD_NAME\" output:hdmi-ac3-surround" || true
    fi

    AC3_SINK=$(run_as_user "pactl list sinks short | grep 'hdmi-ac3-surround' | awk '{print \$2}'")

    if [[ -n "$AC3_SINK" ]]; then
        run_as_user "pactl set-default-sink \"$AC3_SINK\""
        print_ok "AC-3 Surround Encoding installed!"
        print_ok "Active default sink:"
        run_as_user "pactl get-default-sink"
        echo ""
        print_info "Your receiver should show Dolby Digital when audio plays."
        print_info "The sink stays active for 1 hour after last sound to prevent PCM fallback."
    else
        print_error "AC-3 profile command executed, but no matching AC-3 sink was found."
        print_info "Check available profiles with: pactl list cards"
        return 1
    fi
}

# --- Revert -------------------------------------------------------------------
do_revert() {
    print_step "AC3" "Reverting HDMI AC-3 Surround Encoding"

    if [[ ! -f "$UDEV_RULE" && ! -f "$WP_CONF" ]]; then
        print_info "AC-3 Surround Encoding is not installed — nothing to revert."
        return 0
    fi

    if ! confirm "This will restore the default HDMI stereo profile. Proceed?"; then
        print_info "Cancelled."
        return 0
    fi

    # Remove udev rule
    steamos_rw
    rm -f "$UDEV_RULE"
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger /sys/class/sound/card0 2>/dev/null || true
    steamos_ro

    # Remove WirePlumber config
    rm -f "$WP_CONF"

    # Restart WirePlumber
    run_as_user "systemctl --user restart wireplumber"
    sleep 3

    # Restore default HDMI stereo profile
    local card_name
    card_name=$(run_as_user "pactl list cards short | awk '{print \$2}' | head -1")

    if [[ -n "$card_name" ]]; then
        run_as_user "pactl set-card-profile \"$card_name\" output:hdmi-stereo" || true
        sleep 1
    fi

    local stereo_sink
    stereo_sink=$(run_as_user "pactl list sinks short | grep 'hdmi-stereo' | awk '{print \$2}'")
    if [[ -n "$stereo_sink" ]]; then
        run_as_user "pactl set-default-sink \"$stereo_sink\""
    fi

    print_ok "AC-3 Surround Encoding reverted. HDMI stereo profile restored."
}

# --- Status -------------------------------------------------------------------
do_status() {
    print_step "AC3" "HDMI AC-3 Surround Encoding Status"
    echo ""

    if [[ -f "$UDEV_RULE" ]]; then
        print_ok "Udev rule: $UDEV_RULE"
    else
        print_error "Udev rule: not installed"
    fi

    if [[ -f "$WP_CONF" ]]; then
        print_ok "WirePlumber config: $WP_CONF"
    else
        print_error "WirePlumber config: not installed"
    fi

    if [[ -f "$ACP_PROFILE_FILE" ]]; then
        print_ok "ACP profile set: $ACP_PROFILE_FILE"
    else
        print_error "ACP profile set: not found"
    fi

    echo ""

    # Check current card profile
    local card_name active_profile
    card_name=$(run_as_user "pactl list cards short | awk '{print \$2}' | head -1")
    if [[ -n "$card_name" ]]; then
        active_profile=$(run_as_user "pactl list cards" | grep -A20 "Name: $card_name" | grep "Active Profile" | awk -F': ' '{print $2}')
        print_info "Card: $card_name"
        print_info "Active profile: ${active_profile:-unknown}"
    else
        print_error "No audio card found."
    fi

    # Check current default sink
    local default_sink
    default_sink=$(run_as_user "pactl get-default-sink" 2>/dev/null || true)
    if [[ -n "$default_sink" ]]; then
        print_info "Default sink: $default_sink"
    fi

    # Check available AC3 profiles
    local ac3_profiles
    ac3_profiles=$(run_as_user "pactl list cards" 2>/dev/null | grep "hdmi-ac3" | head -5 || true)
    if [[ -n "$ac3_profiles" ]]; then
        echo ""
        print_info "Available AC-3 profiles:"
        echo "$ac3_profiles" | sed 's/^/    /'
    fi
}

# --- Main ---------------------------------------------------------------------
case "${1:-}" in
    install) do_install ;;
    revert)  do_revert ;;
    status)  do_status ;;
    *)
        echo "Usage: sudo $0 {install|revert|status}"
        echo ""
        echo "  install  — Enable AC-3 (Dolby Digital) 5.1 surround encoding over HDMI"
        echo "  revert   — Restore default HDMI stereo profile"
        echo "  status   — Show current AC-3 encoding state"
        echo ""
        echo "Requirements:"
        echo "  - PipeWire + WirePlumber"
        echo "  - alsa-plugins (a52 PCM plugin)"
        echo "  - ffmpeg (libavcodec, used by a52)"
        echo "  - alsa-card-profile (hdmi-ac3.conf — auto-created if missing)"
        echo ""
        echo "After install, select the AC-3 sink in your desktop audio settings."
        exit 1
        ;;
esac
