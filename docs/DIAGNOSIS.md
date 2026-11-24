# Diagnosis notes

Record of how the two root causes were established on the test machine
(Redmi Book Pro 14 2022, FPC `10a5:9201`, Ubuntu 24.04, kernel `7.0.0-31-generic`).

## 1. Power button dead while the fingerprint daemon runs

Evidence gathered:

- Simply keeping the USB device open (`python3 watch_power.py /dev/input/event1`)
  did **not** break the power button.
- Starting the stock `fingerpp` daemon **did** break it — no input event was emitted
  on a short power-button press.
- Stopping `fprintd` restored the button immediately.

Therefore the conflict is in the driver's handling of the sensor, not in the USB
claim itself. In `src/drv_fpc/fpc9201.cpp`:

```cpp
Async end_session() {
    ...
    return *this
        / _control_transfer(...)
        / &WorkerControl::start_sensor;   // <-- re-arms after every scan
}
```

`start_sensor()` keeps the finger-detection interrupt active continuously. On this
laptop the sensor and the EC power key share a line, so the EC never sees the press.
The patch replaces that continuation with `&WorkerControl::get_event;`: the sensor is
armed by `FPP_StartSensor` only while an enroll/verify is in progress, and released
again in `end_session()`.

Validated after rebuild:

- short power press worked with the patched daemon running (user-confirmed);
- `fprintd-verify` still returned `verify-match`;
- the sensor remained visible at `/net/reactivated/Device/0`.

Known upstream report: <https://github.com/Kiwironic/xiaomi-fpc9201-fingerprint-linux/issues/5>.

## 2. Power button does not wake from suspend

Independent of the driver. Sequence of tests:

- `sudo rtcwake -m mem -s 15` woke the machine exactly on schedule → s2idle
  suspend/resume itself works.
- Suspending and pressing the power button did not wake it; only a long press
  (forced reboot) recovered.
- The power button (`PNP0C0C:00`) is registered as a wake source, so the missing
  piece is the EC not forwarding the press during s2idle.
- Linux's LPS0 flow calls ACPI `_DSM` functions that put the EC into deep sleep.
  Related research:
  <https://github.com/Keller18306/xiaomi_s2idle_wakeup_fix/blob/master/RESEARCH.md>
  (HTKS register `0x14`: `0x21` = LPS0 entry, `0x22` = LPS0 exit).

Setting `sleep_no_lps0=1` in `/sys/module/acpi_x86/parameters/` skips the LPS0
firmware calls. With that parameter set, the laptop woke ~6 seconds after suspending
in response to a power-button press, well before a 20-second RTC alarm, and the log
showed a clean `PM: suspend entry (s2idle)` / `PM: suspend exit` cycle.

Persistence across reboots is provided by `systemd/fix-lps0-wake.service`.

Caveat: if a future kernel removes or renames the `sleep_no_lps0` module parameter,
the service will fail silently and wake may break again after that kernel update.
`scripts/verify.sh` checks for this.

## Installation durability

- The patched binary lives at `/usr/local/lib/fingerpp-patched`, outside the dpkg
  package; the package's `/usr/lib/fingerpp` is left untouched (`dpkg -V` clean).
- The `zz-fingerpp-patched.conf` drop-in has a lexically later name than the package's
  `fingerpp.conf`, so systemd applies it last.
- Both changes therefore survive reboots and driver package upgrades.
