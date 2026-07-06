#!/bin/sh
# ============================================================================
# install-openvlm-comms-watchdog.sh
#
# One-shot installer. Run this ON the OpenMANET node (OpenWrt) as root:
#     sh install-openvlm-comms-watchdog.sh
#
# It installs a small self-healing watchdog that auto-restarts openmanetd's
# voice-comms subsystem whenever the OpenVLM (C-Media USB audio + HID PTT)
# is unplugged/replugged. Works around an openmanetd bug where comms stops
# on USB disconnect and never re-binds when the device comes back.
#
# Safe to re-run (idempotent). Uninstall instructions at the bottom.
# ============================================================================
set -e

echo "[*] Writing /usr/bin/openvlm-comms-watchdog.sh"
cat > /usr/bin/openvlm-comms-watchdog.sh <<'WDEOF'
#!/bin/sh
# openvlm-comms-watchdog - auto-recover openmanetd voice comms after the
# OpenVLM (C-Media USB audio, 0d8c:0012) is unplugged/replugged.
# Works around openmanetd not re-binding audio + HID PTT on USB re-enumeration.

POLL=3          # seconds between checks
SETTLE=4        # let USB settle before acting
COOLDOWN=15     # wait after a restart before re-checking (openmanetd needs ~15s)
MAXFAIL=3       # consecutive failed heals before backing off
BACKOFF=60      # back-off sleep after MAXFAIL

log() { logger -t openvlm-watchdog "$1"; }

first_pid() { p=$(pidof openmanetd); echo "${p%% *}"; }

# comms is "bound" when openmanetd holds the OpenVLM HID (PTT button) device
comms_bound() {
    for f in /proc/$1/fd/*; do
        case "$(readlink "$f" 2>/dev/null)" in
            */hidraw*) return 0 ;;
        esac
    done
    return 1
}

dev_present() { grep -q "USB Audio" /proc/asound/cards 2>/dev/null; }

log "started (poll=${POLL}s)"
fails=0

while :; do
    sleep "$POLL"

    pid=$(first_pid)
    [ -z "$pid" ] && continue          # daemon down; procd owns respawn

    dev_present || { fails=0; continue; }   # no module attached, nothing to do

    if comms_bound "$pid"; then
        fails=0
        continue                        # healthy, leave it alone
    fi

    # device attached but comms not bound -> post-hotplug stop; settle & re-verify
    sleep "$SETTLE"
    dev_present || continue             # flapped away again, wait

    log "OpenVLM attached but comms unbound; restarting openmanetd"
    /etc/init.d/openmanetd restart
    sleep "$COOLDOWN"

    pid=$(first_pid)
    if [ -n "$pid" ] && comms_bound "$pid"; then
        log "comms recovered"
        fails=0
    else
        fails=$((fails+1))
        log "comms still unbound after restart (attempt ${fails})"
        if [ "$fails" -ge "$MAXFAIL" ]; then
            log "backing off ${BACKOFF}s"
            sleep "$BACKOFF"
            fails=0
        fi
    fi
done
WDEOF
chmod 755 /usr/bin/openvlm-comms-watchdog.sh

echo "[*] Writing /etc/init.d/openvlm-comms-watchdog"
cat > /etc/init.d/openvlm-comms-watchdog <<'INITEOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=01

start_service() {
    procd_open_instance
    procd_set_param command /usr/bin/openvlm-comms-watchdog.sh
    procd_set_param respawn ${respawn_threshold:-3600} ${respawn_timeout:-5} ${respawn_retry:-0}
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
INITEOF
chmod 755 /etc/init.d/openvlm-comms-watchdog

echo "[*] Syntax check"
sh -n /usr/bin/openvlm-comms-watchdog.sh && echo "    worker OK"
sh -n /etc/init.d/openvlm-comms-watchdog && echo "    init OK"

echo "[*] Enabling (start on boot) and starting"
/etc/init.d/openvlm-comms-watchdog enable
/etc/init.d/openvlm-comms-watchdog restart

sleep 2
echo "[*] Status:"
ps w | grep -v grep | grep openvlm-comms-watchdog || echo "    (not running yet - check: logread | grep openvlm-watchdog)"

echo
echo "[+] Installed. Watch it with:  logread -f | grep openvlm-watchdog"
echo "[+] Uninstall with:"
echo "      /etc/init.d/openvlm-comms-watchdog disable"
echo "      /etc/init.d/openvlm-comms-watchdog stop"
echo "      rm /etc/init.d/openvlm-comms-watchdog /usr/bin/openvlm-comms-watchdog.sh"
