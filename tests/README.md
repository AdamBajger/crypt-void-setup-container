# Test suite

This repository uses a lightweight shell-based test layout intended to be easy to extend:

- `tests/run.sh` — test runner that executes all `test_*.sh` scripts.
- `tests/lib/common.sh` — shared assertions and helper functions.
- `tests/integration/` — integration tests against built image artifacts.

## Running tests

Run all tests and let the integration test pick the newest image from `output/`:

```bash
sudo ./tests/run.sh
```

Run tests against a specific image:

```bash
sudo ./tests/run.sh output/voidlinux_fde_x86_64_20260313-120000.img
```

## Current integration tests

- `tests/integration/test_grub_efi_modules.sh`
  - Attaches the image as a loop device.
  - Mounts EFI partition 1 read-only.
  - Verifies `EFI/BOOT/BOOTX64.EFI` exists.
  - Checks that module names `part_gpt fat ext2 normal cryptodisk luks lvm`
    are present in the EFI binary strings output.

The module-name check is a practical pre-flash smoke test. It does not replace
an actual boot test on hardware (or QEMU + OVMF).
