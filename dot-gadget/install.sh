#!/usr/bin/env bash
# Install the Hermes Gadget client on a LibreEcho Echo Dot over ADB.
#
#   dot-gadget/install.sh "Office Echo" hermes=ws://HERMES_HOST:PORT/gadget [NAME=URL ...] [--enable]
#
# Each NAME=URL is one upstream Hermes gateway; the Dot pairs with each one
# separately, under its own device key, and plays their messages in turn.
# Builds an Alpine armv7 Python root on this host (musl armhf, the same libc as
# LibreEcho), copies it and the client to /data/libreecho/local/hermes-gadget,
# and installs the libreecho-local service. --enable also creates the
# libreecho-local "enabled" marker, which starts it now and on every boot.
# The device key in state/ is kept across reinstalls.
set -euo pipefail

usage='usage: install.sh DEVICE_NAME UPSTREAM=WS_URL [UPSTREAM=WS_URL ...] [--enable]'
name=${1:?$usage}
shift
enable=
upstreams=()
for arg in "$@"; do
    case $arg in
        --enable) enable=--enable ;;
        *=ws://*|*=wss://*)
            [[ ${arg%%=*} =~ ^[A-Za-z0-9._-]+$ ]] || { echo "upstream NAME may use only letters, digits, . _ -: ${arg%%=*}" >&2; exit 2; }
            upstreams+=("$arg") ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
done
[[ ${#upstreams[@]} -gt 0 ]] || { echo "$usage" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
build=$here/build
adb=(adb -P "${ADB_PORT:-5038}" ${ADB_SERIAL:+-s "$ADB_SERIAL"})  # ADB_SERIAL picks one of several devices
alpine=https://dl-cdn.alpinelinux.org/alpine/v3.24
# The bootstrap apk and Alpine's signing keys are pinned by hash; apk then checks every
# package signature against those keys. When Alpine replaces either file, update the pin.
apk_tools=apk-tools-static-3.0.9-r0.apk
apk_tools_sha256=0a1a0682375f66a83b7b903f6e4638ccfe312547d50d336b5f2be9fc391281be
keys=alpine-keys-2.6-r0.apk
keys_sha256=e8a4ee971ef1891fbdd48e7459d07996d83861e80a0a02223ebf48f5e76b759e
app=/data/libreecho/local/hermes-gadget
svc=/data/libreecho/local/services/hermes-gadget

if [[ ! -f $build/py.tgz ]]; then
    rm -rf "$build" && mkdir -p "$build/root/etc/apk/keys"
    curl -fsSL -o "$build/apk-tools.apk" "$alpine/main/x86_64/$apk_tools"
    curl -fsSL -o "$build/keys.apk" "$alpine/main/armv7/$keys"
    printf '%s  %s\n' "$apk_tools_sha256" "$build/apk-tools.apk" "$keys_sha256" "$build/keys.apk" | sha256sum --check --quiet \
        || { echo "ERROR: Alpine bootstrap files do not match the pinned hashes" >&2; exit 1; }
    mkdir "$build/apk"
    tar -xzf "$build/apk-tools.apk" -C "$build/apk" --warning=no-unknown-keyword
    tar -xzf "$build/keys.apk" -C "$build/root" --warning=no-unknown-keyword
    cp "$build"/root/usr/share/apk/keys/armv7/*.pub "$build/root/etc/apk/keys/"
    "$build/apk/sbin/apk.static" --arch armv7 --root "$build/root" -X "$alpine/main" -X "$alpine/community" \
        --initdb --no-scripts --no-chown --usermode add python3 py3-websockets
    tar -czf "$build/py.tgz" -C "$build/root" .
fi

"${adb[@]}" shell "uname -m" | grep -q armv7 || { echo "ERROR: no armv7 LibreEcho device on ADB" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
python3 -c 'import json, sys
ups = [dict(zip(("name", "server"), a.split("=", 1))) for a in sys.argv[2:]]
print(json.dumps({"name": sys.argv[1], "upstreams": ups}, indent=2))' "$name" "${upstreams[@]}" > "$tmp/config.json"

"${adb[@]}" shell "mkdir -p $app/state $svc && chmod 700 $app/state && rm -rf $app/py.new && mkdir $app/py.new"
"${adb[@]}" push "$build/py.tgz" "$app/py.tgz" >/dev/null
"${adb[@]}" push "$here/hermes_gadget_dot.py" "$app/hermes_gadget_dot.py" >/dev/null
"${adb[@]}" push "$tmp/config.json" "$app/config.json" >/dev/null
"${adb[@]}" push "$here/run" "$svc/run" >/dev/null
"${adb[@]}" shell "cd $app/py.new && tar -xzf ../py.tgz && rm ../py.tgz && rm -rf ../py && mv ../py.new ../py"
# The supervisor runs this as root, so nothing in it may be writable by the
# device's SSH users (adb shell runs with umask 0, and tar keeps archive owners).
"${adb[@]}" shell "chown -R 0:0 /data/libreecho/local && chmod -R go-w /data/libreecho/local \
    && chmod 755 $svc/run && chmod 600 $app/config.json && chmod 700 $app/state"
echo "Device ids (upstream, id, server):"
"${adb[@]}" shell "$svc/run --print-ids" | tr -d '\r'
if [[ $enable == --enable ]]; then
    "${adb[@]}" shell "touch /data/libreecho/local/enabled"
    # A client already running keeps its old config; stop it and libreecho-local restarts it on the new one.
    # (It runs through ld-musl, so pidof can't find it: match the script in each cmdline, skipping this shell.)
    "${adb[@]}" shell "for d in /proc/[0-9]*; do [ \"\${d#/proc/}\" = \$\$ ] && continue; \
        grep -q hermes_gadget_dot.py \"\$d/cmdline\" 2>/dev/null && kill \"\${d#/proc/}\"; done; true"
    echo "Enabled. Logs: ${adb[*]} shell tail -f /var/log/libreecho/local/hermes-gadget.log"
else
    echo "Installed. A client already running keeps its old config until restarted; rerun with --enable to restart it."
    echo "Foreground test: ${adb[*]} shell $svc/run"
fi
