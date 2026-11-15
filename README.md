# libreecho-flash

[5L Labs](https://github.com/5L-Labs) community tooling, [MIT](LICENSE).
Flash Echo/Dot **2nd Gen** using the [upstream installer](https://github.com/aslater3/LibreEcho/blob/main/docs/install/README.md).
Read its wiring/safety instructions first. No firmware build, bundled payloads
or automatic flashing. The container and guide were adopted upstream in LibreEcho
0.14.6 ([`docs/install/podman.md`](https://github.com/aslater3/LibreEcho/blob/release/0.14.6/docs/install/podman.md),
[`tools/flash-container`](https://github.com/aslater3/LibreEcho/tree/release/0.14.6/tools/flash-container));
use that for plain flashing. This repo adds `setup.sh` on top (its image also
pins the `run-one-shot.sh` wrapper), plus the optional speaker and root SSH below.
Optionally, turn a flashed device into a [Hermes](https://github.com/NousResearch/hermes-agent)
speaker that one or more Hermes agents can talk through.

## Quick reference

Everything goes through `./setup.sh` (`./setup.sh help` lists it again):

```sh
./setup.sh flash [--unlocked]       # device in fastboot: check Dot/Echo, flash (ERASES it)
./setup.sh resume TAG SERIAL        # continue a flash that failed after slots were written
./setup.sh shell                    # flashing container by hand
./setup.sh devices                  # LibreEcho devices on USB: serial, Wi-Fi IP, "speaker" if set up
./setup.sh speaker "Kitchen Echo" hermes=ws://HERMES_HOST:PORT/gadget   # Hermes speaker
./setup.sh logs                     # follow the speaker log
./setup.sh root-ssh KEY.pub         # key-only root SSH on port 2222, so the device can leave USB
./setup.sh --serial SERIAL logs     # pick one device when several are on USB
```

`flash` automates the manual steps under "Flash and verify" below, which are what
has been run on hardware so far; use those steps if `flash` misbehaves.

## Host and USB

Native Linux, internet, direct data-capable USB. Debian/Ubuntu prerequisites
(one-time administrator setup):

```sh
sudo apt-get update
sudo apt-get install podman crun uidmap usbutils git
podman info --format '{{.Host.Security.Rootless}}'
id -nG
git clone https://github.com/5L-Labs/libreecho-flash.git
cd libreecho-flash
```

Require `true`; **never run Podman with sudo**. Container UID 0 maps to your user.
Rootless cannot bypass host permissions.
Check `lsusb` and read/write access to `/dev/bus/usb/BUS/DEVICE` after each mode
change. No universal `usb` group exists; `dialout` alone is insufficient.

Existing Android rules may suffice. Otherwise install our narrow `0660` fallback:

```sh
getent group plugdev || sudo groupadd --system plugdev
sudo usermod -aG plugdev "$USER"
sudo install -m 0644 70-libreecho.rules /etc/udev/rules.d/70-libreecho.rules
sudo udevadm control --reload-rules
```

Log out/in; reconnect safely. Known IDs:

- `0bb4:0c01` fastboot: [stock Echo](https://github.com/HuskerMinion/techo5-dot/blob/main/docs/hardware-radar.md), [unlocked Dot](https://github.com/wilbowes/EchoMuse/issues/697).
- `18d1:d001` LibreEcho ADB: [init source](https://github.com/aslater3/LibreEcho-Platform/blob/main/tools/mt8163-arm32/initramfs/libreecho-init).

Not serial-isolated; recovery IDs may differ. Inspect unfamiliar IDs; never grant
all-USB/world-writable access.

## Container

`./setup.sh flash`, `resume` and `shell` build the image (cached afterwards) and
run it in a disposable container. Open the shell by hand:

```sh
./setup.sh shell
```

Host permissions gate USB; fastboot flashes, ADB verifies and forwards setup.
Only Containerfile enters the build context; the pinned wrapper verifies the
release installer. `/work` mounts this checkout. USB-directory mounting supports
re-enumeration; `crun`/`keep-groups` preserve permissions. Host networking provides
loopback setup; ADB port 5038 avoids 5037 and must be free.

**Privileged rootless is not a sandbox:** other user-accessible devices and
writable `/work` are exposed. Trust the installer; disconnect unrelated flashable
devices. Opening the shell does not flash.

## Amonet: locked devices only

Dot: `amonet-biscuit-v2.0.0.zip` from [R0rt1z2's thread](https://xdaforums.com/t/unlock-root-twrp-unbrick-amazon-echo-dot-2nd-gen-2016-biscuit.4761416/)
([attachment](https://xdaforums.com/attachments/amonet-biscuit-v2-0-0-zip.6383906/)).
Search fallback: `"amonet-biscuit-v2.0.0.zip" "Rortiz2" site:xdaforums.com`.
Credit: R0rt1z2/k4y0z. Put the unmodified ZIP beside this README; no extraction,
2.0.1 substitution or separate FireOS procedure. Nothing is redistributed.

[Upstream pins](https://github.com/aslater3/LibreEcho/blob/main/release/amonet-pins.json)
enforce size/**SHA-256**. Verify the Dot archive:

```sh
test "$(stat -c %s amonet-biscuit-v2.0.0.zip)" = 55989416 &&
printf '%s  %s\n' \
  '98297293701082bc7272efe077f941c56fc7b6e1f27ef6f2e93b6e4c6fc7b62d' \
  'amonet-biscuit-v2.0.0.zip' | sha256sum --check
```

Require successful exit/`OK`; **stop on mismatch**. Checksums aren't publisher
authentication. Optional pilot SHA-512 fingerprint—not an upstream signature or
the installer's algorithm:

```sh
printf '%s  %s\n' \
  'ba4193de04ab376bfbfadb748c2af5931ca4dd6dc89cde4ad095cccd56aa98f99f84c815f77ff8836e91f0df8e3fefc9f8de859ec5a4e7dd2996befee5f973eb' \
  'amonet-biscuit-v2.0.0.zip' | sha512sum --check
```

Radar needs `amonet-radar-v1.0.0.zip` and **different pins**. Unlocked devices
need no ZIP. Never bypass installer/release checks or mix inputs.

## Flash and verify

Unplug power before moving wiring. Dot uses micro-USB; Echo uses bottom contacts
and separate power. **No shorting.** Enter fastboot holding **Action** (stock)
or **Volume Down only** (unlocked).

`./setup.sh flash` (or `flash --unlocked`) does the steps below: it stops unless
the product is `BISCUIT` or `RADAR`, picks the matching ZIP and asks before
erasing. By hand, inside `./setup.sh shell`:

```sh
lsusb
fastboot devices
fastboot getvar product
```

Require `BISCUIT` (Dot) or `RADAR` (Echo); never override a mismatch.
**The following erases userdata.** Substitute radar's ZIP, or omit `--amonet-zip`
when unlocked:

```sh
run-one-shot.sh latest --amonet-zip /work/amonet-biscuit-v2.0.0.zip \
  --fastboot-serial auto --slots both --execute-hardware
```

Require successful boot-readback/feature verification. Keep the installer open;
check ADB reports `device` and the shell responds:

```sh
adb devices
adb shell uname -r
```

Setup: `http://127.0.0.1:18080/setup.html` on the USB host. Remote browser:

```sh
ssh -N -L 18080:127.0.0.1:18080 USER@USB_HOST
```

Verify release/model during setup; don't expose the port publicly.

## Recovery and privacy

Keep `/work`, including `.installer-home` keys/cache/state and logs/downloads;
container removal preserves them. Never force-add or publish these ignored files,
backups or unreviewed diagnostics. After writes, **continue rather than reflash**.
Resume from the same directory/HOME with the original immutable tag and serial
(it runs `run-one-shot.sh TAG --continue --fastboot-serial SERIAL --slots both
--execute-hardware`):

```sh
./setup.sh resume radar-puffin-vX.Y.Z SERIAL
```

Replace placeholders with saved values. `--reinstall` intentionally erases again.

## Checks without flashing

```sh
for f in setup.sh dot-gadget/install.sh dot-gadget/run root-ssh/install.sh root-ssh/run; do bash -n "$f"; done
python3 -m py_compile dot-gadget/hermes_gadget_dot.py
podman build -t localhost/libreecho-flasher -f Containerfile .
podman run --rm localhost/libreecho-flasher bash -euc \
  'command -v adb fastboot curl python3 mke2fs dumpe2fs lsusb; bash -n /usr/local/bin/run-one-shot.sh'
```

[CI](.github/workflows/container.yml) runs these checks without USB; they do not
prove permissions or hardware compatibility.

## Hermes speaker (optional)

`dot-gadget/` makes a flashed device a [Hermes Gadget](https://github.com/Adolanium/hermes-gadget-sdk)
speaker, so Hermes can speak on it on demand: `send_message` to `gadget:<id>`,
cron delivery, or the gadget home channel. Hermes renders speech with its own
TTS and streams PCM; the client plays it on LibreEcho's announcement bus, which
ducks music and waits for the device's own speech. No microphone or wake word
is involved.

With the device booted and on USB, outside the container (needs host `adb`,
`curl` and `python3`):

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

## Root over the network (optional)

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
