#!/usr/bin/env bash
# Build and install the FPC9201 fingerprint power-button fix.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/patches/0001-arm-sensor-only-during-scan.patch"

SRC_URL="${SRC_URL:-https://download.opensuse.org/repositories/home:/Kiwironic/xUbuntu_24.04/fingerprint-ocv-fpc9201_1.0.0.orig.tar.gz}"
SRC_SHA256="${SRC_SHA256:-75619b12b81e00c6584eef0b258d23e1044f7e18905cf8c5617352a765c6f84b}"

BIN=/usr/local/lib/fingerpp-patched
DROPIN=/usr/lib/systemd/system/fprintd.service.d/zz-fingerpp-patched.conf
WAKE_UNIT=/etc/systemd/system/fix-lps0-wake.service
LPS0_PARAM=/sys/module/acpi_x86/parameters/sleep_no_lps0

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root: sudo $0"
[[ -f "$PATCH" ]] || die "patch file not found: $PATCH"
command -v apt-get >/dev/null || die "this installer targets Debian/Ubuntu (apt-get not found)"

# ---------------------------------------------------------------- prerequisites
if ! dpkg-query -W -f='${Status}' fingerprint-ocv-fpc9201 2>/dev/null | grep -q '^install ok installed$'; then
    die "fingerprint-ocv-fpc9201 is not installed. See README.md > Prerequisites."
fi

DEPS=(build-essential cmake libusb-1.0-0-dev libevent-dev libdbus-1-dev
      libssl-dev libopencv-dev pkg-config patch curl ca-certificates)
missing=()
for pkg in "${DEPS[@]}"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q '^install ok installed$' || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
    log "Installing build dependencies: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

if command -v lsusb >/dev/null && ! lsusb | grep -qi '10a5:9201'; then
    printf 'WARNING: fingerprint sensor 10a5:9201 not detected; continuing anyway.\n' >&2
fi
if [[ ! -e "$LPS0_PARAM" ]]; then
    printf 'WARNING: %s is missing; the wake fix will not work on this kernel.\n' "$LPS0_PARAM" >&2
fi

# ------------------------------------------------------------------ build patch
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

log "Downloading upstream source"
curl -fL --retry 3 --max-time 180 "$SRC_URL" -o "$WORKDIR/src.tar.gz"
printf '%s  %s\n' "$SRC_SHA256" "$WORKDIR/src.tar.gz" | sha256sum -c - \
    || die "source checksum mismatch (upstream tarball changed? override SRC_SHA256)"

log "Extracting and applying patch"
tar -xzf "$WORKDIR/src.tar.gz" -C "$WORKDIR"
SRCDIR="$(find "$WORKDIR" -maxdepth 1 -type d -name 'fingerprint-ocv-*' | head -n1)"
[[ -n "$SRCDIR" ]] || die "could not find unpacked source directory"
cd "$SRCDIR"
patch -p1 --forward < "$PATCH"

log "Building patched daemon"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build build -j"$(nproc)" >/dev/null
[[ -x build/src/fingerprint-ocv ]] || die "build did not produce build/src/fingerprint-ocv"

# --------------------------------------------------------------------- install
log "Installing files"
install -d -m 0755 /usr/local/lib /usr/lib/systemd/system/fprintd.service.d
install -m 0755 -o root -g root build/src/fingerprint-ocv "$BIN"
install -m 0644 "$ROOT/systemd/fprintd.service.d/zz-fingerpp-patched.conf" "$DROPIN"
install -m 0644 "$ROOT/systemd/fix-lps0-wake.service" "$WAKE_UNIT"

log "Enabling services"
systemctl daemon-reload
systemctl enable --now fix-lps0-wake.service
systemctl restart fprintd

cd /
log "Done"
[[ -e "$LPS0_PARAM" ]] && printf 'sleep_no_lps0 = %s\n' "$(cat "$LPS0_PARAM")"
printf '\nVerify with: %s/scripts/verify.sh\n' "$ROOT"
printf 'Test: fprintd-verify <user>, press the power button, and suspend/wake.\n'
