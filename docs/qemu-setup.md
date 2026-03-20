# QEMU VM Setup — Void Linux FDE Builder

This document explains how to run the Void Linux FDE build inside a QEMU
virtual machine.  This method works on Windows (via WSL 2 or MSYS2), macOS,
and Linux without requiring privileged Docker.

## Why QEMU?

| Method | Privileges needed | Works on |
|--------|------------------|----------|
| Docker (privileged) | `--privileged`, `/dev/loop-control` | Linux, WSL 2 |
| QEMU VM | QEMU user-space (KVM optional) | Windows, macOS, Linux |
| GitHub Actions | Managed runner | Any OS (CI) |

The QEMU method creates a Debian guest VM with all required tools installed.
The repository root is shared into the VM via **9p virtfs**, so `config/`,
`scripts/`, and `output/` are all accessible from inside the guest without
copying files.

## Prerequisites

### Host tools

Install the following on your host machine:

**Linux / WSL 2:**
```bash
sudo apt-get install qemu-system-x86 qemu-utils genisoimage openssh-client
```

**macOS (Homebrew):**
```bash
brew install qemu xorriso
```

**Windows:**
- Install [QEMU for Windows](https://www.qemu.org/download/#windows)
- Run the wrapper scripts from WSL 2 or MSYS2

### Hardware requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| Disk (host) | 60 GB free | 100 GB free |
| RAM (available for VM) | 2 GB | 4 GB |
| CPU | x86-64 (no KVM required) | x86-64 with KVM/HVF |

> Disk budget: 40 GB VM image + 15 GB output image + ~5 GB working space.
> Adjust `QEMU_VM_DISK_SIZE` and `disk_size_mib` in `config/disk.conf` together
> if you need a larger output image.

KVM (Linux) or HVF (macOS) acceleration is strongly recommended — without it,
the build may take several hours.

## Step 1 — One-time VM setup

Run the setup script once to create and configure the QEMU VM:

```bash
./wrappers/qemu-setup-vm.sh
```

This script:
1. Creates `vm/void-builder.qcow2` (40 GB QCOW2 disk, sparse).
2. Downloads the Debian 12 netinstall ISO to `vm/debian-installer.iso`.
3. Runs an unattended Debian installation (15–40 minutes).
4. Installs the XBPS static binary and `xchroot` inside the VM.
5. Shuts the VM down and leaves it ready for builds.

### Configuration options

Override via environment variables:

```bash
export QEMU_VM_DISK_SIZE=60G      # Larger VM disk
export QEMU_VM_RAM=8192           # 8 GB RAM for faster builds
export QEMU_VM_CPUS=4             # More CPUs
export QEMU_VM_SSH_PORT=3333      # Different SSH port (if 2222 is in use)
./wrappers/qemu-setup-vm.sh
```

## Step 2 — Running a build

```bash
export LUKS_PASSWORD="your-luks-passphrase"
export ROOT_PASSWORD="your-root-password"
export USER_PASSWORD="your-user-password"

./wrappers/qemu-run-build.sh
# or equivalently:
./wrappers/run-build.sh qemu
```

The script:
1. Starts the VM in the background.
2. Mounts the repository root via 9p into the VM.
3. Runs `entrypoint.sh` inside the VM with a 2-hour timeout.
4. Shuts the VM down.
5. The finished `.img` file is available in `output/`.

### Auto-detection

```bash
./wrappers/run-build.sh          # or run-build.sh auto
```

This chooses Docker if available and configured, falling back to QEMU.

## Directory layout

```
vm/                          ← gitignored (do not commit)
├── void-builder.qcow2       ← VM disk image
├── debian-installer.iso     ← Debian installer (cached)
├── vm.pid                   ← PID file while VM is running
├── preseed/                 ← Preseed files used during install
└── .ssh/
    ├── vm_key               ← Private key for VM SSH
    └── vm_key.pub           ← Public key installed in VM
```

> The `vm/` directory is listed in `.gitignore` and must not be committed to
> the repository.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `qemu-system-x86_64: command not found` | QEMU not installed | Install QEMU |
| SSH timeout during setup | VM failed to boot | Delete `vm/` and re-run setup |
| `9p mount failed` inside VM | Virtfs not compiled into host QEMU | Install `qemu-system-x86` (not `-kvm` only) |
| Build timeout | Slow host or too little RAM | Increase `QEMU_VM_RAM` or `QEMU_BUILD_TIMEOUT` |
| `.img` not in `output/` | Build failed inside VM | Check the SSH session output above |

## Resetting the VM

To recreate the VM from scratch:

```bash
rm -rf vm/
./wrappers/qemu-setup-vm.sh
```

## Security notes

- Passwords are passed as SSH environment variables and are never written to
  the VM disk.
- The VM has no internet access to production systems during the build; the
  9p share is the only external connection.
- SSH authentication is key-based; the generated key is stored in `vm/.ssh/`
  (gitignored).
- The Debian root password set during preseed is a build-time credential used
  only to bootstrap SSH key access; it should be treated as low-sensitivity.
