# `@openOODA/install`

Universal installer, OS ISO & Buildbox distribution hub, and native package manager bridges (`pkg/`) for [openOODA](https://openOODA.org).

## One-Line Bootstrap

```sh
curl -fsSL https://openOODA.org/install.sh | bash
```

Installs the `L0` core toolchain (`ooda`, `oodac`, `oopm`, `oolsp`, `oomcp`, `oohat`, `liboodar.a`, and `oostd`) into `~/.openooda/bin` and verifies every binary against [`SHA256SUMS`](https://github.com/openOODA/install/releases/download/hub/SHA256SUMS).

`oostd` ships the expanded scientific & mathematical discovery library: `oostd/core/math/{exact,geometry,blas,fft,algebra,graph_topology}/...`, `oostd/core/proofs/...`, `oostd/core/science/{phys,chem,bio,comm,econ}/...`, frontier AI-for-science `oostd/core/app/ai/...`, 2D/3D engine physics `oostd/core/app/ui/game_engine/...` (`collision_{aabb,circle,gjk,sat}` + `ecs_*`), `oostd/core/collection/...`, and `oostd/sec/{hash,capability,pqc,symmetric}/...`.

## Live Bootable ISO & Buildbox (`install@hub`)

Published directly on [`openOODA/install@hub`](https://github.com/openOODA/install/releases/tag/hub):

- **[`ooda-os-x86_64.iso`](https://github.com/openOODA/install/releases/download/hub/ooda-os-x86_64.iso)** — Bootable UEFI + BIOS El Torito Hybrid Live OS image (`ooboot` + `ookernel` + `ooinit` + `oosh`). Flash to USB with `ooflash write ooda-os-x86_64.iso --device /dev/sdX`.
- **[`ooda-buildbox-x86_64.tar.gz`](https://github.com/openOODA/install/releases/download/hub/ooda-buildbox-x86_64.tar.gz)** — Hermetic rootless container & chroot sysroot containing the complete `L0`–`L7` binary toolchain.
- **[`SHA256SUMS`](https://github.com/openOODA/install/releases/download/hub/SHA256SUMS)** — Cryptographic SHA-256 manifest covering all 105 package binaries, the Live OS ISO, and the Buildbox tarball.

## Repository Layout

- [`install.sh`](install.sh) — POSIX bootstrap installer
- [`publish-hub.sh`](publish-hub.sh) — Stages and publishes all 105 binaries, `ooda-os-x86_64.iso`, `ooda-buildbox-x86_64.tar.gz`, and `SHA256SUMS` to `install@hub`
- [`versions.toml`](versions.toml) — Canonical version matrix across `L0`–`L7`
- [`pkg/`](pkg) — Distro repository metadata for `apt/`, `dnf/`, `pacman/`, and `winget/`
