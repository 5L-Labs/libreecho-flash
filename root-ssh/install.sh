#!/usr/bin/env bash
# Give a LibreEcho Echo / Echo Dot a key-only root SSH server on port 2222, over ADB.
#
#   root-ssh/install.sh PUBKEY_FILE [PUBKEY_FILE ...]
#
# LibreEcho's own Dropbear (port 22) accepts only passwords and never root. This adds Alpine's
# musl Dropbear (built for armv7 on this host, signatures checked by apk) as a libreecho-local
# service that survives reboots and OTA updates. Password logins are off; only the listed keys
# get in, as root. Keys replace any installed before. ADB_SERIAL picks one of several devices.
set -euo pipefail

[[ $# -ge 1 ]] || { echo "usage: install.sh PUBKEY_FILE [PUBKEY_FILE ...]" >&2; exit 2; }
for key in "$@"; do
    grep -qE '^(ssh-ed25519|ecdsa-sha2-|ssh-rsa) ' "$key" || { echo "ERROR: $key is not an SSH public key" >&2; exit 2; }
done
here=$(cd "$(dirname "$0")" && pwd)
build=$here/build
adb=(adb -P "${ADB_PORT:-5038}" ${ADB_SERIAL:+-s "$ADB_SERIAL"})
alpine=https://dl-cdn.alpinelinux.org/alpine/v3.24
dir=/data/libreecho/local/root-ssh
svc=/data/libreecho/local/services/root-ssh

if [[ ! -f $build/dropbear.tgz ]]; then
    gadget_build=$here/../dot-gadget/build
    [[ -x $gadget_build/apk/sbin/apk.static ]] || { echo "ERROR: run ./setup.sh speaker once first (it fetches apk)" >&2; exit 1; }
    rm -rf "$build" && mkdir -p "$build/root/etc/apk/keys"
    cp "$gadget_build"/root/etc/apk/keys/*.pub "$build/root/etc/apk/keys/"
    "$gadget_build/apk/sbin/apk.static" --arch armv7 --root "$build/root" -X "$alpine/main" \
        --initdb --no-scripts --no-chown --usermode add dropbear
    tar -czf "$build/dropbear.tgz" -C "$build/root" usr/sbin/dropbear usr/bin/dropbearkey usr/lib
fi

"${adb[@]}" shell "uname -m" | grep -q armv7 || { echo "ERROR: no armv7 LibreEcho device on ADB" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for key in "$@"; do cat "$key"; echo; done > "$tmp/authorized_keys"

"${adb[@]}" shell "mkdir -p $dir/keys $svc && chmod 700 $dir $dir/keys && rm -rf $dir/root && mkdir $dir/root"
"${adb[@]}" push "$build/dropbear.tgz" "$dir/dropbear.tgz" >/dev/null
"${adb[@]}" push "$tmp/authorized_keys" "$dir/keys/authorized_keys" >/dev/null
"${adb[@]}" push "$here/run" "$svc/run" >/dev/null
"${adb[@]}" shell "cd $dir/root && tar -xzf ../dropbear.tgz && rm ../dropbear.tgz"
# Run as root by the supervisor: nothing in it may be writable by the device's SSH users.
"${adb[@]}" shell "chown -R 0:0 $dir $svc && chmod -R go-w $dir $svc && chmod 755 $svc/run \
    && chmod 600 $dir/keys/authorized_keys && touch /data/libreecho/local/enabled"
# A server already running keeps reading the same key file, so a key change needs no restart.
ip=$("${adb[@]}" shell "ip -4 addr show wlan0" | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1) || true
echo "Installed. In a few seconds: ssh -p 2222 root@${ip:-<echo ip>}"
