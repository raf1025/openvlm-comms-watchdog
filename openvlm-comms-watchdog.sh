#!/bin/sh
# openvlm-comms-watchdog - auto-recover openmanetd voice comms after the
# OpenVLM (C-Media USB audio, 0d8c:0012) is unplugged/replugged.
# Works around openmanetd not re-binding audio + HID PTT on USB re-enumeration.
#
# Install path: /usr/bin/openvlm-comms-watchdog.sh   (chmod 755)
# Run under procd via /etc/init.d/openvlm-comms-watchdog

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
