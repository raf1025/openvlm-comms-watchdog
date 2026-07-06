#!/bin/sh
# ============================================================================
# fix-openmanetd-gnss-panic.sh
#
# Run ON the OpenMANET node (OpenWrt) as root:
#     sh fix-openmanetd-gnss-panic.sh              # OPSEC-safe: no position broadcast
#     sh fix-openmanetd-gnss-panic.sh --broadcast  # also report GPS position (NMEA+CoT)
#
# Fixes the openmanetd crash where voice comms / PTT never work and a CPU core
# is pegged, caused by a nil-pointer panic in the status handler when GNSS is
# disabled (gnss.enable: false). See README "Bug 1" for the full explanation.
#
# What it does:
#   * Sets gnss.enable: true  -> the GPSService is constructed, so the status
#     handler stops nil-dereferencing and the panic loop ends.
#   * By DEFAULT sets sendAsNMEA/sendAsCoT: false so enabling GNSS does NOT
#     start broadcasting your position (no change to your RF/OPSEC footprint).
#     Pass --broadcast to turn position reporting on instead.
#   * Backs up the config, restarts openmanetd, verifies the panic is gone.
#
# Idempotent. Requires gpsd to be running (default on these nodes).
# ============================================================================
set -e

CONF=/etc/openmanetd/config.yml
BROADCAST=0
[ "$1" = "--broadcast" ] && BROADCAST=1

[ -f "$CONF" ] || { echo "ERROR: $CONF not found"; exit 1; }

echo "[*] Backing up $CONF -> ${CONF}.bak-gnssfix"
cp -a "$CONF" "${CONF}.bak-gnssfix"

echo "[*] Current gnss block:"
sed -n '/^gnss:/,/^[a-zA-Z]/p' "$CONF" | sed 's/^/    /'

# Edit ONLY inside the top-level gnss: block (until the next column-0 key).
if [ "$BROADCAST" = "1" ]; then NMEA=true; COT=true; else NMEA=false; COT=false; fi

awk -v nmea="$NMEA" -v cot="$COT" '
    /^gnss:/ { ingnss=1 }
    /^[a-zA-Z]/ && !/^gnss:/ { ingnss=0 }
    ingnss && /^[[:space:]]+enable:/     { sub(/enable:.*/,        "enable: true") }
    ingnss && /sendAsNMEA:/              { sub(/sendAsNMEA:.*/,    "sendAsNMEA: " nmea) }
    ingnss && /sendAsCoT:/               { sub(/sendAsCoT:.*/,     "sendAsCoT: " cot) }
    { print }
' "$CONF" > "${CONF}.new"

mv "${CONF}.new" "$CONF"

echo "[*] New gnss block:"
sed -n '/^gnss:/,/^[a-zA-Z]/p' "$CONF" | sed 's/^/    /'
[ "$BROADCAST" = "1" ] && echo "[*] Position broadcast: ON (NMEA + CoT)" \
                       || echo "[*] Position broadcast: OFF (panic fixed, no emissions)"

echo "[*] Restarting openmanetd"
/etc/init.d/openmanetd restart
echo "[*] Waiting for it to settle..."
sleep 16

echo "[*] Verifying:"
NP=$(pidof openmanetd); NP=${NP%% *}
if [ -z "$NP" ]; then echo "    WARNING: openmanetd not running"; exit 1; fi
echo "    openmanetd pid=$NP  state=$(cat /proc/$NP/stat 2>/dev/null | awk '{print $3}')"
echo "    load: $(uptime | sed 's/.*load average/load average/')"
if logread | grep -q "comms: subsystem enabled"; then
    echo "    comms subsystem: ENABLED (good)"
fi
NEWPANIC=$(logread | awk -v p="$NP" '$0 ~ "openmanetd\\["p"\\]" && /nil pointer/' | wc -l)
echo "    nil-pointer panics from the new pid: $NEWPANIC (should be 0)"

echo
echo "[+] Done. Fix persists across reboots (it is a config change)."
echo "[+] Toggle position broadcast later without re-running this:"
echo "      set sendAsNMEA/sendAsCoT under gnss: in $CONF, then /etc/init.d/openmanetd restart"
echo "[+] Revert entirely:  cp ${CONF}.bak-gnssfix $CONF && /etc/init.d/openmanetd restart"
