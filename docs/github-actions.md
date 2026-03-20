# GitHub Actions — Void Linux FDE Builder

This document explains how to use the GitHub Actions workflow to build an
encrypted Void Linux disk image in CI/CD.

## Overview

The workflow file `.github/workflows/build-void-fde.yml` runs automatically on:
- Every push to `main` / `master`
- Every pull request targeting `main` / `master`
- Manual dispatch (`workflow_dispatch`) with an optional "create release" flag

The runner is `ubuntu-latest`, which provides KVM access and Docker support
required for the privileged build.

## Prerequisites

### Repository Secrets

Navigate to **Settings → Secrets and variables → Actions** and add:

| Secret name    | Description                              |
|----------------|------------------------------------------|
| `LUKS_PASSWORD` | Passphrase used to encrypt the LUKS1 volume |
| `ROOT_PASSWORD` | Password for the `root` account in the installed system |
| `USER_PASSWORD` | Password for the regular user account in the installed system |

> **Security warning:** These passwords are passed to the build container as
> environment variables.  They are never stored in files, never echoed to
> logs, and never committed to the repository.  GitHub Actions redacts secret
> values from log output automatically.

### Repository Variables (optional)

| Variable name           | Default value                                     |
|-------------------------|---------------------------------------------------|
| `VOID_XBPS_REPOSITORY`  | `https://repo-default.voidlinux.org/current`      |

Override this to point at a faster mirror for your region.

## How the Workflow Works

```
1. Checkout repository
2. Load kernel modules: dm-mod, dm-crypt, loop
3. docker build → void-fde-builder:ci
4. docker run --privileged ... (executes entrypoint.sh)
5. Upload voidlinux_fde_*.img as a workflow artifact (30-day retention)
6. [Optional] Create a GitHub Release with the image attached
```

## Downloading the Artifact

After a successful run:

1. Go to the **Actions** tab in your repository.
2. Click the completed workflow run.
3. Scroll to the **Artifacts** section at the bottom.
4. Download `void-fde-image-<run-number>`.

The ZIP archive contains the raw `.img` file.  Flash it with:

```bash
unzip void-fde-image-*.zip
sudo dd if=voidlinux_fde_*.img of=/dev/sdX bs=4M status=progress
```

## Creating a GitHub Release

### Automatically on a tag push

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow detects the `refs/tags/v*` pattern and attaches the image to a
new release.

### Manually via workflow_dispatch

1. Go to **Actions → Build Void Linux FDE Image → Run workflow**.
2. Set **Create a GitHub Release** to `true`.
3. Click **Run workflow**.

## Build Time and Artifact Size

| Phase                          | Typical time |
|--------------------------------|--------------|
| Docker image build             | 3–5 min      |
| Base package installation      | 10–25 min    |
| Minimal + extras configuration | 5–15 min     |
| **Total**                      | **20–45 min** |

The produced `.img` file size depends on `disk_size_mib` in `config/disk.conf`
(default: 15 000 MiB ≈ 14.6 GiB).

> Note: GitHub artifact uploads are limited to 2 GiB per file by default.
> If your image exceeds this, either reduce `disk_size_mib` or compress the
> image before upload (requires modifying the workflow).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `LUKS_PASSWORD is required` | Missing secret | Add all three secrets in repo settings |
| `docker: Cannot connect to the Docker daemon` | Runner issue | Re-run the workflow |
| `modprobe: ERROR: could not insert 'dm_crypt'` | Kernel module unavailable | The module is loaded best-effort; the build may still succeed |
| Artifact missing | Build failed before upload | Check the run logs |
| Image too large for upload | `disk_size_mib` is large | Reduce the value in `config/disk.conf` |
