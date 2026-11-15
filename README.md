# libreecho-flash

[5L Labs](https://github.com/5L-Labs) community tooling, [MIT](LICENSE).
Flash Echo/Dot **2nd Gen** using the [upstream installer](https://github.com/aslater3/LibreEcho/blob/main/docs/install/README.md).
Read its wiring/safety instructions first. No firmware build, bundled payloads
or automatic flashing. Upstream adoption is proposed; this remains the fallback.

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

Open the shell:

```sh
./flash-shell.sh
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
or **Volume Down only** (unlocked). Inside the container:

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
Reopen `./flash-shell.sh` with the same directory/HOME, original immutable tag,
serial and slots:

```sh
run-one-shot.sh radar-puffin-vX.Y.Z --continue --fastboot-serial SERIAL \
  --slots both --execute-hardware
```

Replace placeholders with saved values. `--reinstall` intentionally erases again.

## Checks without flashing

```sh
bash -n flash-shell.sh
podman build -t localhost/libreecho-flasher -f Containerfile .
podman run --rm localhost/libreecho-flasher bash -euc \
  'command -v adb fastboot curl python3 mke2fs dumpe2fs lsusb; bash -n /usr/local/bin/run-one-shot.sh'
```

[CI](.github/workflows/container.yml) runs these checks without USB; they do not
prove permissions or hardware compatibility.
