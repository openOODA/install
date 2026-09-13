# Installing openOODA

openOODA ships as a small set of native binaries plus a git-cloned standard
library. There are three install paths: the one-line installer (recommended),
the source checkout (developers), or a distro package (apt / dnf / pacman).

## Quick install

```sh
curl -fsSL https://openooda.org/install.sh | bash
```

This installs everything to `~/.openooda/` and adds `~/.openooda/bin` to your
`PATH` for interactive shells.

After it finishes, either restart your shell or run `source ~/.bashrc` (or
`source ~/.zshrc`).

## What gets installed

```
~/.openooda/
├── bin/
│   ├── ooda         # workflow driver
│   ├── oodac        # compiler
│   ├── liboodar.a   # runtime substrate (static lib)
│   ├── opm          # package manager
│   ├── ooda-lsp     # language server
│   ├── ooda-mcp     # MCP server
│   └── bb            # execution flight recorder & crash autopsy
└── std/             # standard library (git clone)
```

If a component's binary is not yet published, `install.sh` prints
`— not yet shipped` and continues. A published binary without a
matching `{bin}-{os}-{arch}.sha256` sidecar is refused: missing
sidecar, empty hash, hasher absent, and hash mismatch all fail
closed. The temp download is deleted and that component is not
installed.

## The 7 binary components + standard library

| Component | Repo           | Binary       | Purpose                                  |
|-----------|----------------|--------------|------------------------------------------|
| `ooda`    | openOODA/ooda  | `ooda`       | Workflow driver                          |
| `oodac`   | openOODA/oodac | `oodac`      | Compiler                                 |
| `oodar`   | openOODA/oodar | `liboodar.a` | Runtime substrate (C static library)     |
| `opm`     | openOODA/opm   | `opm`        | Package manager                          |
| `lsp`     | openOODA/lsp   | `ooda-lsp`   | Language server                          |
| `mcp`     | openOODA/mcp   | `ooda-mcp`   | MCP server                               |
| `bb`| openOODA/bb | `bb` | Flight recorder & crash autopsy engine   |
| `std`     | openOODA/std   | (clone)      | Standard library                         |

## Environment variables

`install.sh` exports these for you in your shell rc files (`~/.bashrc`, `~/.bash_profile`, and `~/.zshrc`). If you need
to set them by hand (e.g. on a remote CI machine), add them to your shell configuration:

| Variable           | Default                          | Purpose                                              |
|--------------------|----------------------------------|------------------------------------------------------|
| `PATH`             | `~/.openooda/bin:$PATH`          | Where the toolchain binaries live                    |
| `OODA_STD_ROOT`    | `~/.openooda/std`                | Standard library location                            |
| `OODA_COMPILER`    | `~/.openooda/bin/oodac`          | Compiler binary for driver and tooling               |
| `OODA_FS_READDIR`  | `~/.openooda`                    | Default filesystem read confinement boundary         |
| `OODA_FS_WRITEDIR` | `~`                              | Default filesystem write confinement boundary        |
| `OODA_RUNTIME_ROOT`| (set by the toolchain at use)    | Where the runtime substrate stores transient state   |

## Installer CLI flags & configuration

The installer supports both command-line flags and environment variable overrides:

### Command-line flags

| Flag                | Effect                                                                               |
|---------------------|--------------------------------------------------------------------------------------|
| `--dry-run` (`-n`)  | Preview only — no downloads, no disk writes, no shell rc edits. Clean simulation.    |
| `--yes` (`-y`)      | Accept all prompts automatically (non-interactive mode).                             |
| `--no-modify-shell` | Install binaries and libraries without modifying shell rc files.                     |
| `--keep-stale`      | Do not delete legacy shadowing binaries in `~/.local/bin`.                           |
| `--clean-stale`     | Clean stale legacy binaries in `~/.local/bin` (default behavior).                     |
| `--uninstall`       | Remove toolchain from `~/.openooda` and surgically remove openOODA shell exports.    |

### Environment variables

| Variable               | Default       | Effect                                                                        |
|------------------------|---------------|-------------------------------------------------------------------------------|
| `OPENOODA_DRY_RUN=1`   | unset         | Preview only — zero disk mutation.                                            |
| `OPENOODA_YES=1`       | unset         | Non-interactive mode; auto-accept all prompts.                                |
| `NO_MODIFY_SHELL=1`    | unset         | Skip shell rc modifications.                                                  |
| `KEEP_STALE=1`         | unset         | Preserve legacy shadowing binaries.                                          |
| `OPENOODA_HOME=…`      | `~/.openooda` | Relocate the install root directory.                                          |
| `NO_COLOR=1`           | unset         | Disable colored terminal output (auto-disabled if not a TTY).                  |
| `OPENOODA_DEBUG=1`     | unset         | Enable verbose step-by-step diagnostic output.                                |

Example:

```sh
OPENOODA_DRY_RUN=1 NO_COLOR=1 curl -fsSL https://openooda.org/install.sh | bash
```

The installer also auto-detects UTF-8 from `LANG` / `LC_ALL` and swaps the
progress bar from `▰▱` to `##--` on non-UTF-8 terminals — no flag needed.

## Updating

Once `ooda` itself is on your `PATH`, you can run:

```sh
ooda update
```

`ooda update` will reinstall every component to its latest release, re-clone
`std` if it has gone stale, and refresh the shell rc lines. (This subcommand
is on the `ooda` roadmap but is not yet shipped — until then, re-run
`install.sh`.)

## Uninstalling

To uninstall openOODA cleanly, run the installer with `--uninstall`:

```sh
bash install.sh --uninstall
```

This removes installed binaries, standard library sources, and shims, and
surgically removes the openOODA configuration block from `~/.bashrc`,
`~/.bash_profile`, and `~/.zshrc` without clobbering other user modifications.

Alternatively, to manually remove openOODA:

```sh
rm -rf ~/.openooda
```

Then remove the `# openOODA` block from your shell configuration file(s).

For distro-package installs, use your package manager: `sudo apt remove openooda`,
`sudo dnf remove openooda`, or `sudo pacman -Rns openooda`.

## Per-distro install

### Debian / Ubuntu (apt)

Pre-built `.deb` packages live in this repo under `apt/`. To build one:

```sh
sudo apt-get install build-essential debhelper devscripts
cd apt
make
sudo dpkg -i ../openooda_*.deb
```

### Fedora / RHEL (dnf)

Pre-built `.rpm` packages live under `dnf/`. To build one:

```sh
sudo dnf install rpm-build rpmdevtools
rpmdev-setuptree
cp <source-tarball> ~/rpmbuild/SOURCES/
rpmbuild -ba dnf/openooda.spec
sudo dnf install ~/rpmbuild/RPMS/*/openooda-*.rpm
```

### Arch (pacman)

Pre-built Arch packages live under `pacman/`. To build one:

```sh
sudo pacman -S --needed base-devel
cd pacman
makepkg -si
```

### Windows (winget)

**Not yet shipped.** Windows packaging is deferred until the openOODA
toolchain builds for `windows-x86_64`. Tracking: depends on the `oodac`
binary and an `oodar` C build matrix.

## Troubleshooting

### `git: command not found`

The standard library is cloned via `git`. If `git` is missing, `install.sh`
skips the `std` clone and prints the manual command. Install `git` and run:

```sh
git clone --depth 1 https://github.com/openOODA/std ~/.openooda/std
```

### `permission denied` when running installed binaries

`install.sh` installs to `~/.openooda/`, which lives in your home directory.
If you see `permission denied`, check that `$HOME` is owned by you and that
`~/.openooda/bin/<binary>` is executable:

```sh
ls -la ~/.openooda/bin
chmod +x ~/.openooda/bin/*
```

### `command not found: ooda` after install

Your shell hasn't picked up the new `PATH` yet. Either:

- open a new terminal, or
- `source ~/.bashrc` (bash) / `source ~/.zshrc` (zsh), or
- run `~/.openooda/bin/ooda --version` directly to confirm the binary works.

### A component prints `— not yet shipped`

That component's repo has not published a release yet. `install.sh` continues
with the rest. Re-run `install.sh` later, or pin a specific version in
`versions.toml` (see below).

### Pin a specific version

To pin a component to a specific tag, copy `versions.toml` next to
`install.sh` and uncomment the line you want:

```toml
ooda = "v0.2.6"
oodac = "v0.1.10"
```

`install.sh` reads `versions.toml` from the same directory it is in, and
falls back to `latest` for any component not listed.
