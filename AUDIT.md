# Audit log

This document records a code review of the repository as it exists in this PR.
It is an assessment of whether the generated image should be flashable and
bootable, plus the places where real-hardware testing is still required.

## Scope reviewed

- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/Dockerfile`
- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/docker-compose.yml`
- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/scripts/entrypoint.sh`
- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/scripts/void-installation-script.sh`
- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/config/disk.yaml`
- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/config/system.yaml`
- `/home/runner/work/crypt-void-setup-container/crypt-void-setup-container/tools/get-device-spec.sh`

## Verdict

**The build logic looks viable for producing a directly flashable encrypted disk
image for an x86_64 UEFI machine.**

The overall design is correct:

1. A full-disk GPT image is created.
2. An EFI System Partition is created for firmware boot.
3. An unencrypted `/boot` partition is created so GRUB can read the kernel and
   initramfs without unlocking the encrypted root volume.
4. The remaining space is encrypted with LUKS1 and used as an LVM physical
   volume.
5. Root and swap logical volumes are created inside LVM.
6. dracut is configured to include the `crypt` and `lvm` modules.
7. GRUB is installed in removable-media mode, which writes the fallback loader
   path `EFI/BOOT/BOOTX64.EFI`.

That is the right high-level shape for a removable encrypted Linux install.

## Why it should boot after flashing

The expected boot chain is:

1. UEFI firmware reads the GPT and finds the EFI System Partition.
2. The firmware loads `EFI/BOOT/BOOTX64.EFI` from the flashed image.
3. GRUB reads the kernel and initramfs from the unencrypted ext4 `/boot`
   partition.
4. dracut reads the kernel command line, unlocks the LUKS container by UUID,
   activates the LVM volume group, and mounts the root logical volume.
5. Void Linux continues booting from the encrypted root filesystem.

The current scripts explicitly support each step:

- GPT + ESP creation: `scripts/entrypoint.sh`
- LUKS + LVM provisioning: `scripts/entrypoint.sh`
- `/etc/crypttab` generation: `scripts/void-installation-script.sh`
- GRUB EFI removable install: `scripts/void-installation-script.sh`
- initramfs regeneration after dracut config changes:
  `scripts/void-installation-script.sh`

## Cross-check against the Void Linux docs

The current implementation was compared against the Void Linux handbook pages
for:

- installation via chroot
- full disk encryption
- kernel / dracut boot parameter handling

The comparison lines up well with the project design:

- Void's chroot guide uses `xbps-install -r /mnt ...` followed by `xchroot /mnt`
  for final configuration. This repository follows the same bootstrap model.
- Void's FDE guide recommends LUKS1 for GRUB compatibility. This repository also
  formats the encrypted partition as **LUKS1**.
- Void's FDE guide adds `rd.luks.uuid=...` and `rd.lvm.vg=...` to the kernel
  command line. This repository does the same in `/etc/default/grub`.
- Void's FDE guide includes `/etc/crypttab` in the initramfs through dracut.
  This repository also installs `/etc/crypttab` into the initramfs.

One important difference is intentional:

- The upstream FDE guide shows a layout where GRUB may need to unlock the
  encrypted volume itself, so it documents `GRUB_ENABLE_CRYPTODISK=y`.
- This repository keeps `/boot` on a separate **unencrypted ext4 partition**,
  so GRUB only needs to read `/boot` and the EFI files. The encrypted root
  volume is unlocked later by **dracut**, not by GRUB.

Because of that layout, not setting `GRUB_ENABLE_CRYPTODISK=y` here is
consistent with the design rather than an omission.

## Changes made during this review

- Simplified the main README so the run/flash flow is easier to follow.
- Added this separate audit log.
- Set `hostonly="no"` in dracut configuration so the generated initramfs is
  generic enough for removable media and not tied to the container build
  environment.

That last change is important for bootability: a host-only initramfs is a poor
fit for an image that is meant to be flashed onto another device and booted on
different hardware.

## Important constraints and limitations

### 1. Target firmware and CPU architecture

The image is built with `grub-x86_64-efi`, so it targets:

- **x86_64**
- **UEFI**

It does **not** target:

- legacy BIOS boot
- ARM boards
- SBC-specific boot flows

So while the image can be written to a USB drive or SD card, it is only expected
to boot when that removable media is used with an **x86_64 UEFI** machine.

### 2. Secure Boot is not configured

There is no Secure Boot signing flow in this repository. On machines with Secure
Boot enforced, the image may not boot until Secure Boot is disabled or a signed
boot chain is added.

### 3. Real hardware testing is still required

The scripts are internally consistent, but that is not the same as a proven
boot test. Before depending on the image, it should be flashed and tested on at
least one real target machine.

## Potential problems to be aware of

### Medium risk: target media must be at least as large as the configured image

The image size is fixed up front. Flashing will only work if the destination
device is at least that large. The repository already provides example layouts
for smaller and larger media, and `tools/get-device-spec.sh` helps generate a
safe `disk.yaml`.

### Medium risk: network assumption on first boot

The install enables `dhcpcd` and `sshd`. That is reasonable for a headless
setup, but connectivity still depends on the target hardware having a supported
network device and working firmware/drivers in the installed system.

### Low risk: discard in `crypttab`

`/etc/crypttab` uses `luks,discard`. That can improve flash-media behavior, but
it also leaks some allocation pattern information through TRIM/discard. This is
not a bootability problem, but it is worth being aware of from a privacy and
threat-model perspective.

## Manual verification checklist

Before saying the image is fully proven, run this on real hardware:

- Flash the produced image onto a spare USB drive or SD card.
- Boot an x86_64 UEFI machine from that removable device.
- Confirm that GRUB appears.
- Confirm that the initramfs prompts for the LUKS passphrase.
- Confirm that the root filesystem mounts and the system reaches userspace.
- Confirm that login works for both `root` and the configured regular user.
- Confirm that networking comes up as expected.

## Validation performed for this PR

- `bash -n scripts/entrypoint.sh`
- `bash -n scripts/void-installation-script.sh`
- `bash -n tools/get-device-spec.sh`
- `docker compose config`

These checks do not replace a real flash-and-boot test, but they do confirm
that the reviewed scripts are syntactically valid and that the Compose setup is
well-formed.
