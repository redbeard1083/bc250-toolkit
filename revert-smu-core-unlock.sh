#!/usr/bin/env bash
#
# revert-smu-core-unlock.sh
#
# Removes the deprecated SMU mailbox method of the BC-250 CPU Cores Unlock
# (rw-r-r-0644/bc250-core-unlock), which the toolkit no longer manages as
# of the switch to the EFI boot entry method. Run this once if you had the
# SMU method installed before upgrading the toolkit.
#
# Safe to run even if some or all of these were never installed — each
# step checks first and simply reports "not present" rather than failing.
#
# Usage: ./revert-smu-core-unlock.sh   (will re-run itself with sudo)

set -uo pipefail

# ==============================================================================
# COLORS & HELPERS
# ==============================================================================

RESET="\e[0m"; BOLD="\e[1m"; DIM="\e[2m"
RED="\e[31m"; GREEN="\e[32m"; YELLOW="\e[33m"; CYAN="\e[36m"; WHITE="\e[97m"

print_info()    { echo -e "  ${CYAN}→${RESET}  $1"; }
print_skip()    { echo -e "  ${DIM}·  $1${RESET}"; }
print_success() { echo -e "\n  ${BOLD}${GREEN}✔  $1${RESET}\n"; }
print_error()   { echo -e "  ${BOLD}${RED}✘  $1${RESET}" >&2; }

echo -e "${BOLD}${CYAN}"
echo "  ╔═════════════════════════════════════════════════════════════════════╗"
echo "  ║          BC-250 SMU Core Unlock Removal (deprecated method)           ║"
echo "  ╚═════════════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# Re-launch with sudo if not already root, preserving who actually invoked it
if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

SERVICE_NAME="bc250-unlock-cores"
GOVERNOR_DROPIN_DIR="/etc/systemd/system/cyan-skillfish-governor-smu.service.d"
GOVERNOR_DROPIN_FILE="$GOVERNOR_DROPIN_DIR/wait-for-core-unlock.conf"
WRAPPER="/usr/local/bin/bc250-unlock-wrapper.sh"
STATE_DIR="/var/lib/bc250-unlock"
DOWNLOADED_SCRIPT="$REAL_HOME/bc250-unlock-cores.py"

# --- Stop and disable the service ---
if systemctl list-unit-files "${SERVICE_NAME}.service" &>/dev/null; then
    print_info "Stopping ${SERVICE_NAME}.service..."
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    print_info "Disabling ${SERVICE_NAME}.service..."
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
else
    print_skip "${SERVICE_NAME}.service not found — skipping stop/disable."
fi

# --- Remove the service unit ---
if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    print_info "Removing /etc/systemd/system/${SERVICE_NAME}.service..."
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
else
    print_skip "/etc/systemd/system/${SERVICE_NAME}.service not found — skipping."
fi

# --- Remove the governor drop-in ---
if [[ -f "$GOVERNOR_DROPIN_FILE" ]]; then
    print_info "Removing $GOVERNOR_DROPIN_FILE..."
    rm -f "$GOVERNOR_DROPIN_FILE"
    rmdir --ignore-fail-on-non-empty "$GOVERNOR_DROPIN_DIR" 2>/dev/null || true
else
    print_skip "$GOVERNOR_DROPIN_FILE not found — skipping."
fi

# --- Remove the wrapper script ---
if [[ -f "$WRAPPER" ]]; then
    print_info "Removing $WRAPPER..."
    rm -f "$WRAPPER"
else
    print_skip "$WRAPPER not found — skipping."
fi

# --- Remove the state directory ---
if [[ -d "$STATE_DIR" ]]; then
    print_info "Removing $STATE_DIR..."
    rm -rf "$STATE_DIR"
else
    print_skip "$STATE_DIR not found — skipping."
fi

# --- Remove the downloaded unlock script from the real user's home ---
if [[ -n "$REAL_HOME" && -f "$DOWNLOADED_SCRIPT" ]]; then
    print_info "Removing $DOWNLOADED_SCRIPT..."
    rm -f "$DOWNLOADED_SCRIPT"
else
    print_skip "$DOWNLOADED_SCRIPT not found — skipping."
fi

# --- Reload systemd ---
print_info "Reloading systemd..."
systemctl daemon-reload

print_success "SMU core unlock cleanup complete."
echo -e "  ${DIM}Note: the unlock itself was volatile and only applied at boot, so if"
echo -e "  cores were unlocked this session they'll revert to stock (6) on your"
echo -e "  next full power cycle. No further action needed.${RESET}\n"
