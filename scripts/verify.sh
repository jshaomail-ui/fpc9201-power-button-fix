#!/usr/bin/env bash
# Non-destructive status check for the FPC9201 power-button fix.
set -uo pipefail

BIN=/usr/local/lib/fingerpp-patched
DROPIN=/usr/lib/systemd/system/fprintd.service.d/zz-fingerpp-patched.conf
WAKE_UNIT=/etc/systemd/system/fix-lps0-wake.service
LPS0_PARAM=/sys/module/acpi_x86/parameters/sleep_no_lps0

info() { printf '%-34s %s\n' "$1" "$2"; }
ok()   { printf '  [OK]   %-30s %s\n' "$1" "$2"; }
bad()  { printf '  [FAIL] %-30s %s\n' "$1" "$2"; }
check() { if eval "$2"; then ok "$1" "${3:-}"; else bad "$1" "${4:-}"; fi; }

printf 'FPC9201 power-button fix — status\n'
printf '%s\n' '------------------------------------------------------------'

info "USB sensor 10a5:9201:" "$(lsusb 2>/dev/null | grep -i '10a5:9201' | head -n1 || echo 'not found')"
info "Driver package:" "$(dpkg-query -W -f='${Version}' fingerprint-ocv-fpc9201 2>/dev/null || echo 'not installed')"

check "patched binary installed" "[[ -x $BIN ]]" "$BIN"
check "fprintd drop-in present" "[[ -f $DROPIN ]]"
check "package files untouched" "[[ -z \$(dpkg -V fingerprint-ocv-fpc9201 2>/dev/null) ]]" "" "dpkg -V reported changes"

RUNNING="$(pgrep -f '^/usr/local/lib/fingerpp-patched' | head -n1 || true)"
check "patched daemon running" "[[ -n '$RUNNING' ]]" "pid $RUNNING"

check "wake service installed" "[[ -f $WAKE_UNIT ]]"
check "wake service enabled" "systemctl is-enabled fix-lps0-wake.service 2>/dev/null | grep -q '^enabled$'"
check "wake service active" "systemctl is-active fix-lps0-wake.service 2>/dev/null | grep -q '^active$'"

if [[ -e "$LPS0_PARAM" ]]; then
    val="$(cat "$LPS0_PARAM")"
    check "sleep_no_lps0" "[[ '$val' = 'Y' || '$val' = '1' ]]" "$val" "$val (wake fix not applied)"
else
    bad "sleep_no_lps0" "parameter missing on this kernel"
fi

printf '\nManual checks:\n'
printf '  fprintd-verify %s                 # fingerprint still works\n' "${USER:-<user>}"
printf '  short-press the power button        # button works with daemon running\n'
printf '  sudo rtcwake -m mem -s 20           # controlled suspend test\n'
printf '  suspend, then press power           # wake from suspend\n'
