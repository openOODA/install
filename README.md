<div align="center">

<pre>
   ____  ____  ___  ____    ___   ___  ____    _
  / __ \/ __ \/ _ \/ __ \  / _ \ / _ \|  _ \  / \
 / /_/ / /_/ /  __/ / / / | | | | | | | | | |/ _ \
/_____/ .___/\___/_/ /_/  | |_| | |_| | |_| / ___ \
      /_/                   \___/ \___/|____/_/   \_\
</pre>

### openOODA — Capability-Secure Computing Stack (L0–L7)

[openooda.org](https://openooda.org) • [@openOODA](https://github.com/openOODA)

</div>

---

## This Repository (`install`)

Bootstrap distribution endpoint for `openOODA` (`install.sh` and system package hooks).

```sh
curl -fsSL https://openooda.org/install.sh | bash
```

### `install.sh` options

```text
--help              show this help
--version           print the installer version and exit
--dry-run           preview without downloading (also OPENOODA_DRY_RUN=1)
--yes, -y           auto-answer y to all prompts (also OPENOODA_YES=1)
--no-modify-shell   do not edit shell rc files
--keep-stale        don't remove stale openooda binaries in legacy shadow locations
--clean-stale       same as default — remove stale openooda binaries
--uninstall         remove binaries and std
--from-source[=DIR] build + install from a local checkout instead of downloading
                    release binaries (also OPENOODA_SOURCE=DIR)
```

Unknown options, bare positional arguments, and any argument after `--` are refused
(fail-closed, exit 1). Downloaded artifacts are verified against SHA-256 sidecars
before execution; a missing or mismatched sidecar aborts the install.
`--selftest-sha` runs the sidecar-verification self-test in a temporary home.

System packages: `apt/`, `dnf/`, and `pacman/` carry the distro packaging specs;
`versions.toml` pins component versions for reproducible installs.
