#!/usr/bin/env bash
# Turn a flashed LibreEcho Echo / Echo Dot 2nd Gen into a Hermes speaker, over USB ADB.
#
#   ./setup.sh devices                     list LibreEcho devices on USB (ADB)
#   ./setup.sh speaker NAME UP=ws://... [UP=ws://...]
#                                          make it a Hermes speaker (dot-gadget), started now and at boot
#   ./setup.sh logs                        follow the speaker log
#   ./setup.sh root-ssh KEY.pub [...]      root SSH with these keys on port 2222, so USB isn't needed
#
# With several devices on USB, put --serial SERIAL before the command.
# Needs host adb, curl and python3. Flash first with LibreEcho's installer; see README.md.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# 5038 is the ADB server of LibreEcho's flashing container; it leaves the host's usual 5037 alone.
export ADB_PORT=${ADB_PORT:-5038}

usage() { sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "ERROR: $*" >&2; exit 1; }

serial=
if [[ ${1:-} == --serial ]]; then serial=${2:?--serial needs a value}; shift 2; fi
cmd=${1:-}; shift || true

# The one LibreEcho device to talk to over ADB (or --serial).
pick_device() {
    [[ -n $serial ]] && return
    mapfile -t found < <(adb -P $ADB_PORT devices | awk 'NR > 1 && $2 == "device" {print $1}')
    case ${#found[@]} in
        1) serial=${found[0]} ;;
        0) die "no LibreEcho device on USB ADB (is it booted and plugged in?)" ;;
        *) die "several devices on USB; rerun with --serial, one of: ${found[*]}" ;;
    esac
}

case $cmd in
devices)
    adb -P $ADB_PORT devices | awk 'NR > 1 && $2 == "device" {print $1}' | while read -r s; do
        info=$(adb -P $ADB_PORT -s "$s" shell 'ip -4 addr show wlan0 | sed -n "s/.*inet \([0-9.]*\).*/\1/p";
            [ -f /data/libreecho/local/enabled ] && [ -x /data/libreecho/local/services/hermes-gadget/run ] && echo speaker' \
            </dev/null | tr -d '\r' | paste -sd' ')
        echo "$s  ${info:-?}"
    done
    ;;
speaker)
    [[ $# -ge 2 ]] || die "usage: ./setup.sh speaker \"Kitchen Echo\" NAME=ws://HOST:PORT/gadget [NAME=ws://... ...]"
    name=$1; shift
    pick_device
    ADB_SERIAL=$serial "$here/dot-gadget/install.sh" "$name" "$@" --enable
    echo
    echo "Pairing codes (approve each on its Hermes, with: hermes pairing approve gadget CODE):"
    # The restarted client logs one start line per upstream, then connects and gets its codes; show
    # only what came after its last start, once every upstream has reported.
    for _ in $(seq 20); do
        sleep 1
        since=$(adb -P $ADB_PORT -s "$serial" shell 'tail -50 /var/log/libreecho/local/hermes-gadget.log' \
            | tr -d '\r' | awk '/hermes-gadget-dot .*upstream/ {buf = ""} {buf = buf $0 "\n"} END {printf "%s", buf}') || true
        [[ $(grep -cE 'paired=|PAIRING CODE' <<<"$since") -ge $# ]] && break
    done
    grep -E 'PAIRING CODE|paired=' <<<"$since" || echo "  none yet; watch ./setup.sh logs"
    ;;
root-ssh)
    [[ $# -ge 1 ]] || die "usage: ./setup.sh root-ssh ~/.ssh/id_ed25519.pub [MORE.pub ...]"
    pick_device
    ADB_SERIAL=$serial "$here/root-ssh/install.sh" "$@"
    ;;
logs)
    pick_device
    adb -P $ADB_PORT -s "$serial" shell tail -f /var/log/libreecho/local/hermes-gadget.log
    ;;
-h|--help|help) usage 0 ;;
*) usage ;;
esac
