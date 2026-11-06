#!/usr/bin/env bash
set -euo pipefail

here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$here/.installer-home"
chmod 700 "$here/.installer-home"

podman build --network host -t localhost/libreecho-flasher -f "$here/Containerfile" "$here"

if [[ $# == 0 ]]; then
    set -- bash
fi

# Mount the USB directory, not one device node: fastboot -> adb re-enumerates.
# Host networking keeps adb's loopback-only setup forward reachable on the host.
exec podman run --rm -it \
    --runtime crun \
    --group-add keep-groups \
    --privileged \
    --network host \
    --env ANDROID_ADB_SERVER_PORT=5038 \
    --volume /dev/bus/usb:/dev/bus/usb \
    --volume "$here:/work" \
    localhost/libreecho-flasher "$@"
