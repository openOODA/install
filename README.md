# `@openOODA/install`

Universal installer, OS ISO & Buildbox distribution hub, and native package manager bridges (`pkg/`) for [openOODA](https://openOODA.org).

## One-Line Bootstrap

```sh
curl -fsSL https://openOODA.org/install.sh | bash
```

Installs the `L0` core toolchain (`ooda`, `ooda-compiler`, `ooda-runtime` (`libooda-runtime.a`), `ooda-package`, `ooda-language`, `ooda-bridge`, `ooda-verify`, and the `ooda-standard` library tree) into `~/.openooda/bin` and verifies every binary against [`SHA256SUMS`](https://github.com/openOODA/install/releases/download/hub/SHA256SUMS).

`ooda-standard` ships the expanded scientific & mathematical discovery library: `ooda-standard/core/math/{exact,geometry,blas,fft,algebra,graph_topology}/...`, `ooda-standard/core/proofs/...`, `ooda-standard/core/science/{phys,chem,bio,comm,econ}/...`, frontier AI-for-science `ooda-standard/core/app/ai/...`, 2D/3D engine physics `ooda-standard/core/app/ui/game_engine/...` (`collision_{aabb,circle,gjk,sat}` + `ecs_*`), `ooda-standard/core/collection/...`, and `ooda-standard/sec/{hash,capability,pqc,symmetric}/...`.

## Live Bootable ISO & Buildbox (`install@hub`)

Published directly on [`openOODA/install@hub`](https://github.com/openOODA/install/releases/tag/hub):

- **[`ooda-os-x86_64.iso`](https://github.com/openOODA/install/releases/download/hub/ooda-os-x86_64.iso)** — Bootable UEFI + BIOS El Torito Hybrid Live OS image (`ooda-boot` + `ooda-kernel` + `ooda-start` + `ooda-shell`). Flash to USB with `ooda-flasher write ooda-os-x86_64.iso --device /dev/sdX`.
- **[`ooda-buildbox-x86_64.tar.gz`](https://github.com/openOODA/install/releases/download/hub/ooda-buildbox-x86_64.tar.gz)** — Hermetic rootless container & chroot sysroot containing the complete `L0`–`L7` binary toolchain.
- **[`SHA256SUMS`](https://github.com/openOODA/install/releases/download/hub/SHA256SUMS)** — Cryptographic SHA-256 manifest covering the 72 package assets, Live OS ISO, Buildbox tarball, codex bundle, and `cap_table.oot`.

## Repository Layout

- [`install.sh`](install.sh) — POSIX bootstrap installer
- [`publish-hub.sh`](publish-hub.sh) — Stages and publishes the 72 canonical packages, `ooda-os-x86_64.iso`, `ooda-buildbox-x86_64.tar.gz`, codex bundle, `cap_table.oot`, and `SHA256SUMS` to `install@hub`
- [`versions.toml`](versions.toml) — Canonical shipped version matrix across `@core`/`@system`/`@apps` (`72` packages)
- [`VERSION`](VERSION) — Installer semver, aligned with the embedded `install.sh` fallback
- [`Makefile`](Makefile) — `make build && make test` conformance gate (`make check` for ooda-compiler + `bash -n`)
- [`core/`](core) — `install_check.oo` repo-fold checker + `install_script.oo` install.sh contract
- [`tests/`](tests) — Functional (10) and refusal (12) assertion suites
- [`pkg/`](pkg) — Distro repository metadata for `apt/`, `dnf/`, `pacman/`, and `winget/`
