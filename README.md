# libreecho-flash

Minimal Linux + Podman environment for flashing **Echo 2nd Gen** or **Echo Dot
2nd Gen** using the [upstream installer](https://github.com/aslater3/LibreEcho/blob/main/docs/install/README.md).
An unofficial convenience wrapper: no firmware build, daemon, speech services,
or automatic flashing. Read the upstream hardware and installation instructions
before connecting or erasing a device.

Maintained by **5L Labs**, licensed under [MIT](LICENSE). This is independent
community tooling, not the official LibreEcho-Platform repository. We intend to
offer the minimal container workflow upstream; until it is accepted, this
repository remains the standalone home. Upstream adoption would become the
preferred entry point rather than a second, diverging installer.

**No Amonet archive, firmware, device keys, or installer state is distributed
with this repository or image.** Locked-device users supply their own exact
upstream-required unlock archive at runtime; it is excluded from Git and the
container build context.

## USB flashing architecture

The Linux host owns USB permissions and runs rootless Podman. The disposable
container supplies `adb`, `fastboot`, filesystem tools, and the pinned upstream
bootstrap wrapper. USB fastboot handles installation; after reboot, USB ADB
handles verification and the loopback-only setup forward. No network connection
to the Echo, speech model, Hermes service, or firmware compilation is needed.
Internet access is needed to build the image and download the release.

- **Image/build context:** only `Containerfile`; no downloaded ZIP, local
  configuration, or installer state is copied into the image.
- **Runtime:** the host's USB bus and this working directory are mounted into
  the container. The user-supplied Amonet ZIP is read from `/work` only when
  required; logs and recovery state stay in that local directory.
- **Trust:** rootless privileged mode is not a sandbox for untrusted installers.
  The container has the host user's USB access and write access to `/work`.
  USB permissions may need one-time administrator setup; flashing does not.
- **Destructive boundary:** opening the shell does not flash. The upstream
  installer requires the explicit `--execute-hardware` command below and erases
  userdata. Keep its original state and immutable release tag for continuation.

## Linux prerequisites

Use a Linux machine physically connected to the Echo. Install Podman, `crun`,
rootless UID/GID mapping support, and USB utilities using your distribution's
packages. For Debian/Ubuntu, this is a one-time administrator step:

```sh
sudo apt-get update
sudo apt-get install podman crun uidmap usbutils
```

Run all Podman and flashing commands as your normal user, **not with sudo**.
Check that Podman is rootless and inspect your host groups:

```sh
podman info --format '{{.Host.Security.Rootless}}'
id -nG
```

The first command must print `true`. If rootless Podman cannot start, fix its
subordinate UID/GID configuration using your distribution's documentation;
do not work around it by running the flasher as host root.

## Start

Clone this repository, open its directory, and check USB permissions below
before connecting the device:

```sh
git clone https://github.com/5L-Labs/libreecho-flash.git
cd libreecho-flash
./flash-shell.sh
```

This builds the image (cached on subsequent runs) and opens a shell in a
disposable container. Container UID 0 maps to your normal host user, not host
root. The upstream bootstrap wrapper is pinned in `Containerfile`;
the release is selected when you invoke it. The wrapper verifies the downloaded
installer against the release checksums.

**Security:** this uses **rootless, privileged Podman**, the USB bus directory,
and host networking for simple hotplug support. It cannot bypass your host user's
device permissions. `--group-add keep-groups` with `crun` preserves access through
your host groups. Use only trusted installer code and disconnect unrelated
flashable devices. A separate ADB server port (5038) avoids sharing the host's
usual ADB server (5037). Privileged Podman may also expose other host devices
accessible to your user; the USB bind mount is not a device-isolation boundary.

## USB permissions

Rootless `--privileged` cannot bypass host USB permissions. Existing distribution
Android udev rules may already grant access through a group you belong to; use
them if they work. There is no universally required group named `usb`, and
membership in `dialout` alone does not grant raw USB access.

Use `lsusb` to identify the Echo's bus/device number and inspect that device
node under `/dev/bus/usb/`. Your normal user needs read/write access, including
after the device changes between fastboot, recovery, and LibreEcho ADB.

Expected USB identities:

| USB ID | Mode / evidence |
| --- | --- |
| `0bb4:0c01` | Stock Echo 2nd Gen fastboot, documented in [hardware-radar.md](https://github.com/HuskerMinion/techo5-dot/blob/main/docs/hardware-radar.md) |
| `0bb4:0c01` | Unlocked Echo Dot 2nd Gen fastboot, reported in [EchoMuse #697](https://github.com/wilbowes/EchoMuse/issues/697) |
| `18d1:d001` | LibreEcho ADB, set in [libreecho-init](https://github.com/aslater3/LibreEcho-Platform/blob/main/tools/mt8163-arm32/initramfs/libreecho-init) |

Confirm with `lsusb` on your unit, including after unlocking. If a different ID
appears, stop and inspect it rather than allowing an entire vendor or all USB devices.
The same IDs can be used by other hardware, so this is not serial-number isolation.
The installer can also use TWRP/recovery ADB during the unlock handoff. The exact
USB identity of the recovery image in the pinned Amonet archive has not been
verified, so these two IDs are not an exhaustive hardware-coverage guarantee.

`70-libreecho.rules` is an optional fallback for hosts missing these permissions.
It grants only the two listed IDs to `plugdev` with mode `0660`. **Do not install
it if the existing rules already work.** On a host that needs it, create the group
if absent, add your normal user, and install the rule as a one-time administrator
step; the container and flashing remain rootless:

```sh
getent group plugdev || sudo groupadd --system plugdev
sudo usermod -aG plugdev "$USER"
sudo install -m 0644 70-libreecho.rules /etc/udev/rules.d/70-libreecho.rules
sudo udevadm control --reload-rules
```

Log out and back in after changing group membership, then check `id -nG` again.
After installing or changing rules, reconnect the Echo in fastboot (unplug power
before moving its USB wiring). New USB nodes receive the permissions automatically,
including when the device changes mode. No broad `chmod`, world-writable `0666`,
or rootful container is needed. `plugdev` access works over SSH too; it does not
rely on a local desktop session's `uaccess` ACL.

## Connect and check (inside the container)

Use a direct USB port and a data-capable cable. For a stock device, hold **Action**
while connecting power; for an already unlocked device, hold **Volume Down only**.
The Dot uses its micro-USB port. The full-size Echo needs its bottom USB contacts
and its own power supply; read the upstream wiring/safety instructions first.
No shorting is required.

```sh
lsusb
fastboot devices
fastboot getvar product
```

Expected product: `BISCUIT` for Dot 2nd Gen, `RADAR` for Echo 2nd Gen. Stop on a
mismatch; do not force a target override.

## Obtain and verify Amonet (locked devices only)

The name is **Amonet**. For our **Echo Dot 2nd Gen / biscuit** pilot, the exact
archive was `amonet-biscuit-v2.0.0.zip`. Obtain it yourself from the author's
[XDA thread](https://xdaforums.com/t/unlock-root-twrp-unbrick-amazon-echo-dot-2nd-gen-2016-biscuit.4761416/),
using its [2.0.0 attachment](https://xdaforums.com/attachments/amonet-biscuit-v2-0-0-zip.6383906/).
If the link moves, search Google for
`"amonet-biscuit-v2.0.0.zip" "Rortiz2" site:xdaforums.com` and locate the author's
post, not a repackaged mirror. Search results and filenames are not verification.
Credit for the unlock work belongs to Roger Ortiz / R0rt1z2 and k4y0z.

**The thread now advertises 2.0.1; do not substitute it for LibreEcho's pinned
2.0.0.** Follow the selected LibreEcho release's requirements, not the forum's
independent unlock/FireOS installation procedure. Keep the ZIP unmodified beside
this README; do not extract it or run its shell scripts yourself. Neither this
project nor LibreEcho redistributes the archive.

The [LibreEcho Amonet pins](https://github.com/aslater3/LibreEcho/blob/main/release/amonet-pins.json)
record the expected archive size and **SHA-256**, which the installer enforces.
The Dot pilot ZIP is **55,989,416 bytes**. Before flashing, run from this directory
on the Linux host (or `/work` inside the container):

```sh
test "$(stat -c %s amonet-biscuit-v2.0.0.zip)" = 55989416 &&
printf '%s  %s\n' \
  '98297293701082bc7272efe077f941c56fc7b6e1f27ef6f2e93b6e4c6fc7b62d' \
  'amonet-biscuit-v2.0.0.zip' | sha256sum --check
```

Require a successful exit and `amonet-biscuit-v2.0.0.zip: OK`. A size or digest
mismatch means **stop**, not rename the file, override the check, or flash anyway.

For an additional comparison, the **SHA-512 computed from our exact pilot ZIP**
is below. This is a secondary local fingerprint, not an upstream SHA-512
signature or the algorithm the installer used:

```sh
printf '%s  %s\n' \
  'ba4193de04ab376bfbfadb748c2af5931ca4dd6dc89cde4ad095cccd56aa98f99f84c815f77ff8836e91f0df8e3fefc9f8de859ec5a4e7dd2996befee5f973eb' \
  'amonet-biscuit-v2.0.0.zip' | sha512sum --check
```

These checks establish byte-for-byte agreement with the recorded archive, not
independent publisher authentication or hardware compatibility. The wrapper
also verifies the release installer, and the installer verifies the release
assets and selected unlock payload. Do not mix releases or bypass those checks.

For **Echo 2nd Gen / radar**, obtain `amonet-radar-v1.0.0.zip` using upstream's
model-specific requirements and pins. The biscuit links and checksums above
must not be used for radar. An already-unlocked device needs no Amonet ZIP.

## Flash (explicit, destructive)

**This erases device userdata.** Verify the target product and any required
archive first. For a **Dot 2nd Gen**, run inside the container:

```sh
run-one-shot.sh latest --amonet-zip /work/amonet-biscuit-v2.0.0.zip \
  --fastboot-serial auto --slots both --execute-hardware
```

For **Echo 2nd Gen**, use `amonet-radar-v1.0.0.zip` instead. For an already
unlocked device, omit `--amonet-zip`. Keep the printed immutable release tag and
device serial for recovery. Do not use `--reinstall` unless you intend to erase
an existing installation again.

The USB directory mount survives device re-enumeration between fastboot and ADB.
Keep the installer/container open during first-boot setup. The installer forwards
the setup page to **port 18080 on the USB-connected Linux host**, on loopback only.
If your browser is on another machine, use an SSH tunnel from that machine:

```sh
ssh -N -L 18080:127.0.0.1:18080 USER@USB_HOST
```

Then open `http://127.0.0.1:18080/setup.html` in your browser. Substitute your SSH
username and the USB host's address; no public setup port is exposed.

## Verify the installation

Before writing, require the rootless check to print `true`, confirm your user's
USB read/write permissions, check `fastboot getvar product`, and verify the
archive above if the device is locked. The wrapper's installer-checksum check
is a separate mandatory gate; do not continue after any failed check.

After writing, require the upstream installer to finish successfully, including
its boot readback verification and feature staging. Keep the printed immutable
release tag and reviewed logs locally. While the container is still open:

```sh
adb devices
adb shell uname -r
```

The target must appear in ADB as `device`, not `unauthorized` or `offline`, and
respond to the shell command. Then use the forwarded setup page above, complete
setup, and confirm the expected LibreEcho release and device model in its UI.
These are separate checks: a container build proves tool availability, a matching
ZIP proves archive identity, and only a real completed install checks the
hardware path. None alone proves long-term reliability.

If installation stops, retain state and follow the continuation procedure below;
do not rerun a destructive installation just to obtain a clean success message.

## State and recovery

`/work` is this directory on the host. Installer logs, downloads, and
`.installer-home/` (HOME, including cache, state, and ADB keys) survive container
removal. New files are owned by your normal host user. **Keep them after a failure.**
After boot slots have been written, do not start a fresh flash; follow upstream's
continuation instructions with the original immutable tag and serial, in a new
`./flash-shell.sh` session using the same directory:

```sh
run-one-shot.sh radar-puffin-vX.Y.Z --continue --fastboot-serial SERIAL \
  --slots both --execute-hardware
```

Use the actual saved tag and serial, not the placeholders above. Exit the shell
when finished; the container is removed, but the local image and state remain.

## Keeping local data private

Git ignores installer state (including ADB keys and shell history), logs,
diagnostic archives, downloaded unlock archives, and the local wrapper download.
Keep those files on disk for recovery; do not force-add them to Git or share
unreviewed logs or diagnostic bundles. The container build context is restricted
to `Containerfile`; runtime still mounts this directory at `/work` for flashing.

The repository contains only the flasher sources and documentation. Device
backups, unlock archives, ADB keys, `.env` files, and logs must remain local.
Do not publish a container or archive made by copying a used working directory.

## Checks without flashing

CI builds the container and checks the installed tools without mounting USB or
running the installer against hardware. Locally, you can build the same image:

```sh
bash -n flash-shell.sh
podman build -t localhost/libreecho-flasher -f Containerfile .
podman run --rm localhost/libreecho-flasher bash -euc \
  'command -v adb fastboot curl python3 mke2fs dumpe2fs lsusb; bash -n /usr/local/bin/run-one-shot.sh'
```

These checks do not prove USB permissions or hardware compatibility. For upstream
support, report the actual device model, release tag, and a reviewed, redacted
error excerpt—not private keys, a full state directory, or the unlock archive.
