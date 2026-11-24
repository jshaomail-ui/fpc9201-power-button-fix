#!/usr/bin/env bash
# Revert to the stock fingerprint driver and the default LPS0 behaviour.
set -euo pipefail

BIN=/usr/local/lib/fingerpp-patched
DROPIN=/usr/lib/systemd/system/fprintd.service.d/zz-fingerpp-patched.conf
WAKE_UNIT=/etc/systemd/system/fix-lps0-wake.service
LPS0_PARAM=/sys/module/acpi_x86/parameters/sleep_no_lps0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"

log "Disabling the LPS0 wake fix"
systemctl disable --now fix-lps0-wake.service 2>/dev/null || true

log "Removing patched daemon and service configuration"
rm -f "$WAKE_UNIT" "$DROPIN" "$BIN"

if [[ -w "$LPS0_PARAM" ]]; then
    printf '0' > "$LPS0_PARAM"
    printf '    sleep_no_lps0 restored to %s\n' "$(cat "$LPS0_PARAM")"
fi

systemctl daemon-reload
systemctl restart fprintd

log "Done — the stock package driver is active again"
printf 'To remove the third-party apt repo as well, delete %s and apt purge fingerprint-ocv-fpc9201.\n' \
    /etc/apt/sources.list.d/fpc9201.list
