#!/usr/bin/env bash
# One entry point for preparing a LibreEcho Echo / Echo Dot 2nd Gen.
#
#   ./setup.sh flash [--unlocked]          flash a device in fastboot (ERASES it)
#   ./setup.sh resume TAG SERIAL           continue a flash that failed after slots were written
#   ./setup.sh shell                       open the flashing container by hand
#   ./setup.sh devices                     list LibreEcho devices on USB (ADB)
#   ./setup.sh speaker NAME UP=ws://... [UP=ws://...]
#                                          make it a Hermes speaker (dot-gadget), started now and at boot
#   ./setup.sh logs                        follow the speaker log
#   ./setup.sh root-ssh KEY.pub [...]      root SSH with these keys on port 2222, so USB isn't needed
#
# With several devices on USB, put --serial SERIAL before the command (the fastboot serial for flash).
# Run as your normal user, not with sudo. See README.md for the details.
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export ADB_PORT=5038  # the flasher's own ADB server; leaves the host's usual 5037 alone

usage() { sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-2}"; }
die() { echo "ERROR: $*" >&2; exit 1; }

serial=
if [[ ${1:-} == --serial ]]; then serial=${2:?--serial needs a value}; shift 2; fi
cmd=${1:-}; shift || true

# Disposable rootless container with fastboot, adb and the pinned upstream installer.
container() {
    mkdir -p "$here/.installer-home"
    chmod 700 "$here/.installer-home"  # installer keys and state
    adb -P $ADB_PORT kill-server 2>/dev/null || true  # the container runs its own ADB server on this port
    podman build --quiet --network host -t localhost/libreecho-flasher -f "$here/Containerfile" "$here" >/dev/null
    # Mount the USB directory, not one device node: fastboot -> adb re-enumerates.
    # Host networking keeps the installer's loopback-only setup page (port 18080) reachable.
    podman run --rm -it --runtime crun --group-add keep-groups --privileged --network host \
        --env ANDROID_ADB_SERVER_PORT=$ADB_PORT \
        --volume /dev/bus/usb:/dev/bus/usb --volume "$here:/work" \
        localhost/libreecho-flasher "$@"
}

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
flash)
    unlocked=0
    [[ ${1:-} == --unlocked ]] && unlocked=1
    lsusb | grep -q '0bb4:0c01' || die "no Echo in fastboot (0bb4:0c01). Unplug it, hold Action (stock) or
       Volume Down (already unlocked), and plug it in while holding."
    echo "This ERASES the device. Ctrl-C now to stop, Enter to go on."; read -r
    # Inside the container: pick the Amonet unlock archive for the detected board, then run the installer.
    container bash -c '
        set -euo pipefail
        fb=(fastboot); [[ $3 == auto ]] || fb+=(-s "$3")
        product=$("${fb[@]}" getvar product 2>&1 | sed -n "s/^product: *//p")
        case $product in
            BISCUIT) zip=/work/amonet-biscuit-v2.0.0.zip ;;
            RADAR)   zip=/work/amonet-radar-v1.0.0.zip ;;
            *) echo "ERROR: unexpected product \"$product\"; stopping" >&2; exit 2 ;;
        esac
        echo "Detected $product."
        args=(latest --fastboot-serial "$3" --slots both --execute-hardware)
        if [[ $1 == 0 ]]; then
            [[ -f $zip ]] || { echo "ERROR: put $(basename "$zip") in the repo (LibreEcho does not ship it)" >&2; exit 2; }
            args+=(--amonet-zip "$zip")
        fi
        echo "Setup page: on your browser machine run  ssh -N -L 18080:127.0.0.1:18080 $2@<this host>"
        echo "then open http://127.0.0.1:18080/setup.html. WRITE DOWN the release tag and serial printed below."
        run-one-shot.sh "${args[@]}"
    ' _ "$unlocked" "$(id -un)" "${serial:-auto}"
    ;;
resume)
    [[ $# == 2 ]] || die "usage: ./setup.sh resume TAG SERIAL  (the tag and serial the failed flash printed)"
    container run-one-shot.sh "$1" --continue --fastboot-serial "$2" --slots both --execute-hardware
    ;;
shell)
    container bash
    ;;
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
