# FPC9201 fingerprint power-button fix

A small, reproducible fix for laptops where the **fingerprint reader is physically
integrated into the power key**. On those machines the Linux fingerprint daemon can
kill the power button, and the power button may not wake the laptop from suspend.

This repository contains a **source patch** (no prebuilt binaries), the two systemd
configuration files, and install / uninstall / verification scripts.

> Community fix, provided as-is. It touches system services and kernel parameters —
> read this document before running the installer.

## Tested on

| | |
|---|---|
| Laptop | Xiaomi / Redmi Book Pro 14 2022 (`RMAAD4B0P0B0B`) |
| Sensor | FPC / Chipsailing USB fingerprint controller `10a5:9201` (`FW 021.26.2.031`) |
| OS | Ubuntu 24.04 |
| Kernel | `7.0.0-31-generic` (HWE) |
| Driver | `fingerprint-ocv-fpc9201` 1.0.0-1 (`home:Kiwironic` OBS repo) |

Other Xiaomi laptops with the same sensor may benefit, but have only been researched,
not tested. The LPS0 wake fix applies to a broader set of Intel s2idle systems.

## Symptoms

- Fingerprint enroll/verify works, but a **short press of the power button does nothing**
  while `fprintd` / `fingerpp` is running.
- Stopping the fingerprint service immediately restores the power button.
- After suspending (s2idle), the power button does not wake the machine, although an
  RTC alarm (`rtcwake`) wakes it reliably.

## Root cause

There are **two independent problems**:

1. **Power button suppressed by the driver.** `fingerprint-ocv`'s `end_session()`
   re-arms the sensor on every scan by chaining `WorkerControl::start_sensor()`.
   On these laptops the sensor shares the EC power-button line, so keeping it armed
   continuously swallows the power-key signal. The patch chains
   `WorkerControl::get_event()` instead, so the sensor is armed only while an actual
   enroll/verify is in progress (`FPP_StartSensor`) and returns to sleep afterwards.
   This is a known upstream bug
   ([issue #5](https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux/issues/5))
   with no released fix at the time of writing.

2. **Power button is not a wake source.** Suspend/resume itself works fine; the kernel's
   LPS0 (Low-Power S0 idle) firmware calls put the EC into a deep sleep state where it
   ignores the power button. The kernel parameter `sleep_no_lps0=1` skips those calls
   and keeps the EC responsive. `systemd/fix-lps0-wake.service` applies it at boot.

**Trade-off:** with LPS0 disabled the EC does not enter its deepest sleep state, so
suspend may consume slightly more battery. Fingerprint, power button and wake all work.

## Repository layout

```
patches/0001-arm-sensor-only-during-scan.patch   one-line driver source patch
systemd/fprintd.service.d/zz-fingerpp-patched.conf  run patched binary via fprintd
systemd/fix-lps0-wake.service                     apply sleep_no_lps0=1 at boot
scripts/install.sh                                build + install everything
scripts/uninstall.sh                              revert to the stock driver
scripts/verify.sh                                 non-destructive status check
docs/DIAGNOSIS.md                                 how the root causes were established
```

## Prerequisites

1. A sensor that appears as `10a5:9201`:

   ```bash
   lsusb | grep 10a5:9201
   ```

2. The `fingerprint-ocv-fpc9201` driver installed from the third-party
   [`home:Kiwironic` openSUSE OBS repository](https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux).
   Adding a third-party apt repo is a trust decision — review it before proceeding:

   ```bash
   sudo install -d -m 0755 /etc/apt/keyrings
   curl -fsSL https://download.opensuse.org/repositories/home:/Kiwironic/xUbuntu_24.04/Release.key \
     | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/fpc9201.gpg
   sudo chmod 0644 /etc/apt/keyrings/fpc9201.gpg
   echo 'deb [signed-by=/etc/apt/keyrings/fpc9201.gpg] https://download.opensuse.org/repositories/home:/Kiwironic/xUbuntu_24.04/ /' \
     | sudo tee /etc/apt/sources.list.d/fpc9201.list
   sudo apt update
   sudo apt install -y fingerprint-ocv-fpc9201
   ```

3. A kernel that exposes `/sys/module/acpi_x86/parameters/sleep_no_lps0`
   (inspect with `ls /sys/module/acpi_x86/parameters/`). If it is absent, the wake fix
   will not apply; the fingerprint/power-button patch still works. The installer will
   warn you.

## Install

```bash
git clone <this-repo-url>
cd fpc9201-power-button-fix
sudo ./scripts/install.sh
```

The installer downloads the upstream source tarball (sha256-pinned), applies the patch,
builds the daemon, installs it to `/usr/local/lib/fingerpp-patched`, adds the systemd
drop-in and wake service, then restarts `fprintd`. It does **not** modify the file owned
by the driver package (`/usr/lib/fingerpp`), so package upgrades will not undo the fix.

Environment overrides: `SRC_URL` and `SRC_SHA256` can point the installer at a mirror
or a newer upstream tarball.

## Verify

```bash
./scripts/verify.sh
```

Then check manually:

- `fprintd-verify <user>` — fingerprint still matches.
- Short-press the power button while the daemon is running — it should work.
- `sudo rtcwake -m mem -s 20` as a controlled suspend test, or simply suspend and
  press the power button to wake.

Expected state:

```
sleep_no_lps0 = Y
fingerpp-patched running (fprintd.service)
dpkg -V fingerprint-ocv-fpc9201    # no output = package files untouched
```

## Uninstall

```bash
sudo ./scripts/uninstall.sh
```

This disables and removes the wake service, removes the drop-in and the patched binary,
restores `sleep_no_lps0` to its default for the current boot, and restarts `fprintd`
so the stock package driver is used again.

## License

The patch modifies AGPL-3.0 licensed software
([`fingerprint-ocv`](https://github.com/vrolife/fingerprint-ocv) by vrolife and
contributors), so this project is distributed under the **GNU Affero General Public
License v3.0 or later**. See [LICENSE](LICENSE).

## References

- <https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux> (driver, build, issue #5)
- <https://github.com/vrolife/fingerprint-ocv> (upstream source)
- <https://github.com/Keller18306/xiaomi_s2idle_wakeup_fix> (EC/LPS0 research on Xiaomi RedmiBook Pro 2022)
- <https://www.reddit.com/r/linuxhardware/comments/1lxg764/redmi_book_pro_14_2022_black_screen_after_wake_up/>
