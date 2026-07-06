# OpenVLM Comms Watchdog

A small self-healing watchdog for OpenMANET nodes (OpenWrt) that keeps
**voice comms / PTT** working across USB unplug/replug of the OpenVLM
(the C-Media USB audio module, USB ID `0d8c:0012`, with the PTT button on
its HID interface).

It exists to work around a bug in **openmanetd** — see "For the engineer"
below. This is a workaround, not the real fix.

---

## The problem it solves

`openmanetd` opens the OpenVLM's audio + HID (PTT) devices once, at startup.
When the module is unplugged (cable swap, loose connector, power dip) the
daemon logs:

```
ALSA lib pcm_direct.c: recover: unable to prepare slave
ERR comms  OpenVLM: HID read error; stopping
INF comms  comms: subsystem stopped
```

...and it **never re-binds** when the device comes back — even though the
kernel re-enumerates it fine. Result: PTT is dead until openmanetd is
restarted by hand. The watchdog does that restart automatically.

---

## What the watchdog does

Every 3 seconds it checks:

1. Is the OpenVLM attached? (`grep "USB Audio" /proc/asound/cards`)
2. Is openmanetd actually bound to it? (does it hold a `/dev/hidraw*` fd?)

If the module is **present but openmanetd isn't using it** — the exact state
a hotplug leaves behind — it waits ~4s for USB to settle, runs
`/etc/init.d/openmanetd restart`, and confirms comms came back. During normal
operation it does nothing (no spurious restarts). Recovery takes ~20s after a
replug (openmanetd needs ~15s to fully re-initialize).

Everything is logged to the system log, tagged `openvlm-watchdog`.

---

## Install

Copy `install-openvlm-comms-watchdog.sh` to the node and run it as root:

```sh
sh install-openvlm-comms-watchdog.sh
```

That writes both files, enables the service (starts on boot), and starts it.
It's idempotent — safe to re-run.

> If you get `bad interpreter` or `syntax error` after transferring the file
> from Windows, it picked up CRLF line endings. Fix with:
> `sed -i 's/\r$//' install-openvlm-comms-watchdog.sh`

### Manual install (instead of the installer)

```sh
cp openvlm-comms-watchdog.sh   /usr/bin/openvlm-comms-watchdog.sh
cp openvlm-comms-watchdog.init /etc/init.d/openvlm-comms-watchdog
chmod 755 /usr/bin/openvlm-comms-watchdog.sh /etc/init.d/openvlm-comms-watchdog
/etc/init.d/openvlm-comms-watchdog enable
/etc/init.d/openvlm-comms-watchdog start
```

## Watch it work

```sh
logread -f | grep openvlm-watchdog
```

Unplug the OpenVLM, plug it back in, wait ~20s — you should see
`OpenVLM attached but comms unbound; restarting openmanetd` followed by
`comms recovered`.

## Test without touching hardware

You can simulate a physical unplug/replug in software (the kernel sees the
same disconnect/reconnect). Find the OpenVLM's USB path first
(`readlink -f /sys/bus/usb/devices/*/idProduct` etc.); on the reference node
it was `3-1.1`:

```sh
echo 0 > /sys/bus/usb/devices/3-1.1/authorized   # unplug
sleep 3
echo 1 > /sys/bus/usb/devices/3-1.1/authorized   # replug
```

## Uninstall

```sh
/etc/init.d/openvlm-comms-watchdog disable
/etc/init.d/openvlm-comms-watchdog stop
rm /etc/init.d/openvlm-comms-watchdog /usr/bin/openvlm-comms-watchdog.sh
```

## Tuning

Edit the constants at the top of `/usr/bin/openvlm-comms-watchdog.sh`:
`POLL` (check interval), `SETTLE` (settle delay before acting),
`COOLDOWN` (wait after restart), `MAXFAIL`/`BACKOFF` (loop protection).
Lower `COOLDOWN` for faster recovery at the risk of re-checking before
openmanetd has finished starting.

---

## For the engineer — the two underlying openmanetd bugs

The watchdog only papers over bug #2. Both belong in openmanetd:

### Bug 1 — `GetServiceStatus` panics when GNSS is disabled
With `gnss.enable: false`, `StatusService.GetServiceStatus` (status.go:99)
unconditionally calls `GPSService.GetPosition` (position.go:160) on a **nil**
`*GPSService` → nil-pointer dereference panic on every status poll (~10s).
The panic is recovered per-request so the process survives, but each call
returns `EOF`, comms never reports healthy, and the constant panic +
stacktrace generation pegs a full core.

```
runtime error: invalid memory address or nil pointer dereference
internal/gpsd.(*GPSService).GetPosition            position.go:160
internal/openmanet/server/handlers.(*StatusService).GetServiceStatus  status.go:99
```

**Fix:** guard the GPS call when GNSS is disabled / the service is nil, and
make `GetPosition` nil-receiver safe as defense in depth. Field workaround was
to set `gnss.enable: true` (gpsd already running) so the service is non-nil.

### Bug 2 — no USB hotplug recovery (what this watchdog handles)
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

Reproduce both: node with `gnss.enable: false` shows bug 1 immediately;
`echo 0 > .../authorized; echo 1 > .../authorized` on the OpenVLM's USB port
reproduces bug 2.
