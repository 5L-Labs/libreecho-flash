# libreecho-hermes-speaker

[5L Labs](https://github.com/5L-Labs) community tooling, [MIT](LICENSE).
Turns an Amazon Echo / Echo Dot **2nd Gen** running [LibreEcho](https://github.com/aslater3/LibreEcho)
into a speaker that one or more [Hermes](https://github.com/NousResearch/hermes-agent)
agents can talk through, and adds key-only root SSH so the device can leave USB.

## Flash first

Flash with LibreEcho's own installer: the [install guide](https://github.com/aslater3/LibreEcho/blob/main/docs/install/README.md),
or on Linux its rootless Podman route, [`docs/install/podman.md`](https://github.com/aslater3/LibreEcho/blob/release/0.14.6/docs/install/podman.md)
(adopted from this repo in LibreEcho 0.14.6). Finish the device's setup page and
leave it booted on USB. Nothing here flashes or erases a device.

## Quick reference

```sh
./setup.sh devices                  # LibreEcho devices on USB: serial, Wi-Fi IP, "speaker" if set up
./setup.sh speaker "Kitchen Echo" hermes=ws://HERMES_HOST:PORT/gadget   # Hermes speaker
./setup.sh logs                     # follow the speaker log
./setup.sh root-ssh KEY.pub         # key-only root SSH on port 2222, so the device can leave USB
./setup.sh --serial SERIAL logs     # pick one device when several are on USB
```

`setup.sh` talks to ADB server port 5038, the one LibreEcho's flashing container
uses; set `ADB_PORT` to use another.

## Checks

```sh
for f in setup.sh dot-gadget/install.sh dot-gadget/run root-ssh/install.sh root-ssh/run; do bash -n "$f"; done
python3 -m py_compile dot-gadget/hermes_gadget_dot.py
```

## Hermes speaker

`dot-gadget/` makes a flashed device a [Hermes Gadget](https://github.com/Adolanium/hermes-gadget-sdk)
speaker, so Hermes can speak on it on demand: `send_message` to `gadget:<id>`,
cron delivery, or the gadget home channel. Hermes renders speech with its own
TTS and streams PCM; the client plays it on LibreEcho's announcement bus, which
ducks music and waits for the device's own speech. No microphone or wake word
is involved.

With the device booted and on USB (host `adb`, `curl` and `python3`):

```sh
./setup.sh speaker "Kitchen Echo" hermes-a=ws://HOST_A:PORT/gadget hermes-b=ws://HOST_B:PORT/gadget
```

Each `NAME=URL` is one Hermes gateway's gadget endpoint (`NAME`: letters, digits,
`.`, `_`, `-`). The device connects to
all of them, with **its own key and device id per upstream** (a shared key would
let one Hermes impersonate the device to another), and prints a pairing code per
upstream. Approve each on its Hermes host:

```sh
hermes pairing approve gadget CODE
hermes gadget devices
```

Messages play one at a time in arrival order. A newer message from the same
upstream replaces one that is still arriving, never one that has fully arrived;
another upstream's message waits its turn. One message is capped at 600 s.

It runs on a downloaded Alpine armv7 Python (musl, like LibreEcho; about 47 MB
on `/data`, packages signature-checked by `apk`) under LibreEcho's
`libreecho-local` supervisor, which survives reboots and OTA updates, restarts
it with backoff, and disables local services after three boots that do not
stay up for 180 s. Device keys stay in `/data/libreecho/local/hermes-gadget/state`
across reinstalls; rerun the command to change the name or upstreams.
Logs: `./setup.sh logs`.

The connection is plain `ws://` unless the gateway terminates TLS (`wss://`), so
use it on a trusted network. `wss://` verifies the gateway against the device's
own CA bundle. To stop all local services remove
`/data/libreecho/local/enabled`; to uninstall also remove
`/data/libreecho/local/hermes-gadget` and `/data/libreecho/local/services/hermes-gadget`.

## Root over the network

LibreEcho's own SSH (port 22) accepts only passwords and never root, so changes
under `/data/libreecho` otherwise need USB ADB. After `./setup.sh speaker` has
run once (it fetches `apk`), add a second, key-only root SSH server. It creates
`/data/libreecho/local/enabled`, which starts **all** installed local services,
including an installed speaker:

```sh
./setup.sh root-ssh ~/.ssh/id_ed25519.pub
ssh -p 2222 root@DEVICE_IP
```

It is Alpine's musl Dropbear for armv7 under the same `libreecho-local`
supervisor, on port **2222**, **public keys only**, no port forwarding. Rerunning
replaces the keys; a running server picks them up at once. Dropbear's three
libraries are linked into the RAM-backed `/lib` at each start. Anyone holding a
listed key is root on the device. To remove it, delete
`/data/libreecho/local/services/root-ssh` and `/data/libreecho/local/root-ssh`,
then reboot.
