# OpenMANET / openmanetd voice-comms fixes

Two independent fixes that make **voice comms / PTT** reliable on OpenMANET
nodes (OpenWrt) running `openmanetd` with an **OpenVLM** — the C-Media USB
audio module (USB ID `0d8c:0012`) whose PTT button is on its HID interface.

| # | Problem | Fix in this repo |
|---|---------|------------------|
| 1 | PTT/comms never work and a CPU core is pegged | `fix-openmanetd-gnss-panic.sh` — a one-time config fix |
| 2 | Comms die after unplug/replug of the OpenVLM and never come back | `openvlm-comms-watchdog` — a self-healing service |

Both work around bugs in `openmanetd` itself (see **For the engineer** at the
bottom). They are safe, reversible, and survive reboots.

---

## Quick start (recommended order)

Copy this folder onto the node (or `git clone` it there) and run, as root:

```sh
# 1. Fix the GNSS nil-pointer panic (do this first)
sh fix-openmanetd-gnss-panic.sh

# 2. Install the hotplug self-healing watchdog
sh install-openvlm-comms-watchdog.sh
```

That's it. After step 1 PTT works; after step 2 it keeps working across cable
swaps.

> **Windows users:** if you get `bad interpreter` or `syntax error` after
> transferring a script, it picked up CRLF line endings. Fix with:
> `sed -i 's/\r$//' <script>.sh`

---

## Fix 1 — GNSS nil-pointer panic (`fix-openmanetd-gnss-panic.sh`)

### Symptoms
- OpenVLM plugs in and makes a sound (it enumerates fine) but **pressing PTT
  does nothing**.
- `top` shows `openmanetd` in state `R` with load average pinned near a full
  core.
- `logread` is full of, every ~10 seconds:
  ```
  http: panic serving 127.0.0.1:...: runtime error: invalid memory address or nil pointer dereference
  gpsd.(*GPSService).GetPosition            position.go:160
  handlers.(*StatusService).GetServiceStatus  status.go:99
  ```

### Cause
With `gnss.enable: false` in `/etc/openmanetd/config.yml`, the `GPSService`
object is **nil**, but the status handler calls `GetPosition()` on it anyway →
nil-pointer dereference. The panic is recovered per-request so the process
survives, but every status poll fails, comms never reports healthy, and the
constant panic + stack-trace spam pegs the CPU. PTT can't arm.

### The fix
Give openmanetd a non-nil `GPSService` by enabling GNSS (gpsd already runs on
these nodes). This stops the panic. Position **broadcast** is a separate,
OPSEC-relevant choice controlled by `sendAsNMEA` / `sendAsCoT`.

```sh
sh fix-openmanetd-gnss-panic.sh              # fix panic, NO position broadcast (default)
sh fix-openmanetd-gnss-panic.sh --broadcast  # fix panic AND report position (NMEA + CoT)
```

The script backs up the config to `config.yml.bak-gnssfix`, edits only the
`gnss:` block, restarts openmanetd, and verifies the panic is gone
(`nil-pointer panics from new pid: 0`).

### Manual version
Edit `/etc/openmanetd/config.yml` so the `gnss:` block reads:
```yaml
gnss:
    enable: true                 # <-- was false; this is the actual fix
    sendAsExternalGNSSSource:
        sendAsNMEA: false        # true = broadcast position as NMEA
        sendAsCoT: false         # true = broadcast position as CoT to TAK
```
Then: `/etc/init.d/openmanetd restart`

### Toggle position broadcast later
Set `sendAsNMEA` / `sendAsCoT` to `true` (report) or `false` (silent) in the
config and `/etc/init.d/openmanetd restart`. No need to re-run the script.

### Verify
```sh
logread | grep "comms: subsystem enabled"    # should print
logread | grep "nil pointer" | tail          # should stop appearing after the restart
uptime                                        # load should fall back to normal
```

### Revert
```sh
cp /etc/openmanetd/config.yml.bak-gnssfix /etc/openmanetd/config.yml
/etc/init.d/openmanetd restart
```

---

## Fix 2 — USB hotplug recovery (`openvlm-comms-watchdog`)

### Symptoms
You swapped a cable / re-seated the OpenVLM and **PTT is dead again**, even
though the module is plugged in and working. `logread` shows:
```
OpenVLM: HID read error; stopping
comms: subsystem stopped
```
...and it never restarts after the device re-enumerates.

### Cause
`openmanetd` opens the OpenVLM's audio + HID devices once, at startup. On USB
disconnect it stops the comms subsystem and **does not re-bind** when the
device comes back. The daemon keeps running; comms stays dead until it is
restarted.

### The watchdog
A tiny procd service that polls every 3 s. If the OpenVLM is attached but
`openmanetd` isn't bound to it (holds no `/dev/hidraw*`), it waits for USB to
settle, runs `openmanetd restart`, and confirms comms came back. It does
nothing during normal operation (no spurious restarts). Recovery ≈ 20 s after
a replug.

### Install
```sh
sh install-openvlm-comms-watchdog.sh
```
Installs `/usr/bin/openvlm-comms-watchdog.sh` + `/etc/init.d/openvlm-comms-watchdog`,
enables it (starts on boot), and starts it. Idempotent.

### Watch it work
```sh
logread -f | grep openvlm-watchdog
```
Unplug the OpenVLM, plug it back in, wait ~20 s → you should see
`OpenVLM attached but comms unbound; restarting openmanetd` then
`comms recovered`.

### Uninstall
```sh
/etc/init.d/openvlm-comms-watchdog disable
/etc/init.d/openvlm-comms-watchdog stop
rm /etc/init.d/openvlm-comms-watchdog /usr/bin/openvlm-comms-watchdog.sh
```

### Tuning
Edit the constants at the top of `/usr/bin/openvlm-comms-watchdog.sh`:
`POLL`, `SETTLE`, `COOLDOWN`, `MAXFAIL`, `BACKOFF`. Lower `COOLDOWN` for faster
recovery at the risk of re-checking before openmanetd has finished starting.

---

## Files in this repo

| File | Purpose |
|------|---------|
| `fix-openmanetd-gnss-panic.sh` | One-shot fix for the GNSS nil-pointer panic (Fix 1) |
| `install-openvlm-comms-watchdog.sh` | One-shot installer for the hotplug watchdog (Fix 2) |
| `openvlm-comms-watchdog.sh` | The watchdog worker (reference / manual install) |
| `openvlm-comms-watchdog.init` | The procd service file (reference / manual install) |
| `README.md` | This guide |

---

## Testing without touching hardware

Simulate a physical unplug/replug in software (the kernel sees the same
disconnect/reconnect). Find the OpenVLM's USB path (on the reference node it was
`3-1.1`), then:

```sh
echo 0 > /sys/bus/usb/devices/3-1.1/authorized   # unplug
sleep 3
echo 1 > /sys/bus/usb/devices/3-1.1/authorized   # replug
```
With the watchdog installed you'll see it auto-recover in `logread`.

---

## For the engineer — the two underlying openmanetd bugs

These workarounds live outside the daemon. Both root causes belong in
openmanetd:

### Bug 1 — `GetServiceStatus` panics when GNSS is disabled
With `gnss.enable: false`, `StatusService.GetServiceStatus` (status.go:99)
unconditionally calls `GPSService.GetPosition` (position.go:160) on a **nil**
`*GPSService` → nil-pointer dereference panic on every status poll (~10 s). The
panic is recovered per-request so the process survives, but each call returns
`EOF`, comms never reports healthy, and the constant panic + stacktrace
generation pegs a core.

```
runtime error: invalid memory address or nil pointer dereference
internal/gpsd.(*GPSService).GetPosition            position.go:160
internal/openmanet/server/handlers.(*StatusService).GetServiceStatus  status.go:99
```

**Fix:** guard the GPS call when GNSS is disabled / the service is nil, and make
`GetPosition` nil-receiver safe as defense in depth. (Field workaround: set
`gnss.enable: true` so the service is non-nil.)

### Bug 2 — no USB hotplug recovery
When the OpenVLM disconnects, openmanetd stops the comms subsystem
(`OpenVLM: HID read error; stopping` → `comms: subsystem stopped`) and never
restarts it after the device re-enumerates. The daemon keeps running; comms
stays dead until a manual restart.

**Fix:** treat device loss as recoverable, not terminal. Watch for re-attach
(udev/netlink monitor, or reopen-on-`EIO`/`-ENODEV` with backoff) and
re-initialize the comms subsystem automatically — reopen the ALSA PCMs and the
HID PTT endpoint. The teardown path also needs to survive a mid-stream device
yank cleanly (it currently throws `pcm_direct.c recover: unable to prepare
slave`).

**Reproduce:** a node with `gnss.enable: false` shows Bug 1 immediately;
`echo 0 > .../authorized; echo 1 > .../authorized` on the OpenVLM's USB port
reproduces Bug 2.
