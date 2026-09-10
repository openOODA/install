<div align="center">

<pre>
   ____  ____  ___  ____    ___   ___  ____    _
  / __ \/ __ \/ _ \/ __ \  / _ \ / _ \|  _ \  / \
 / /_/ / /_/ /  __/ / / / | | | | | | | | | |/ _ \
/_____/ .___/\___/_/ /_/  | |_| | |_| | |_| / ___ \
      /_/                   \___/ \___/|____/_/   \_\
</pre>

### openOODA — Sovereign Systems Language for the AI Era

[openooda.org](https://openooda.org)

</div>

---

## This repo: install

How the toolchain lands on a machine: `install.sh`, apt, dnf,
pacman (winget deferred). Not the `ooda install` subcommand.

## Install

```sh
curl -fsSL https://openooda.org/install.sh | bash
```

Right after launch the installer asks `Install openOODA? [Y/n]` (auto-yes for `curl | bash` with no tty, `CI`, `OPENOODA_YES=1`, or `OPENOODA_DRY_RUN=1`). Use `OPENOODA_YES=1` or `printf "y\n" | bash install.sh` for non-interactive.

Toolchain-only: the installer no longer scans for or wires LLM harnesses (removed 2026-09-11). Binaries land in `~/.openooda/bin`, the std tree in `~/.openooda/std`, and `~/.bashrc` gets the `PATH`/`OODA_*` exports (bash only; zsh/fish users export the same lines manually).

`OPENOODA_DRY_RUN=1` previews without touching disk. Re-run is safe — the install is idempotent and `~/.bashrc` is backed up as `~/.bashrc.bak.openooda` before any edit.

**Professional install (P0/P1):** `install.sh --help` (`--dry-run`/`--yes`/`--no-modify-shell`/`--uninstall`), pre-flight checks `curl`/`git`/`python3` + `df` >100 MB + `curl -Is raw.githubusercontent`, `~/.openooda/install.log` (1M rotate) + `trap` cleanup, post-flight verifies `ooda`/`oodac`/`ooda-lsp`/`ooda-mcp`/`blackbox` respond to `--help`.

## Docs

All design, RFCs, practices, and onboarding live in [openOODA/openOODA](https://github.com/openOODA/openOODA) or at [openooda.org](https://openooda.org).

## The Polyrepo

| Repo | Purpose |
|------|---------|
| [openOODA/openOODA](https://github.com/openOODA/openOODA) | Governance, RFCs, laws |
| [openOODA/oodar](https://github.com/openOODA/oodar) | Runtime substrate |
| [openOODA/oodac](https://github.com/openOODA/oodac) | Compiler |
| [openOODA/std](https://github.com/openOODA/std) | Standard library |
| [openOODA/ooda](https://github.com/openOODA/ooda) | `ooda` workflow driver |
| [openOODA/install](https://github.com/openOODA/install) | How the toolchain lands (install.sh, apt, dnf, pacman) |
| [openOODA/opm](https://github.com/openOODA/opm) | Package manager |
| [openOODA/catalog](https://github.com/openOODA/catalog) | Public package catalog |
| [openOODA/lsp](https://github.com/openOODA/lsp) | Language server |
| [openOODA/mcp](https://github.com/openOODA/mcp) | MCP server |
| [openOODA/blackbox](https://github.com/openOODA/blackbox) | Operational Logistics: Agent-native execution flight recorder and crash autopsy engine |
| [openOODA/website](https://github.com/openOODA/website) | Website source |
| [openOODA/.github](https://github.com/openOODA/.github) | Org profile, shared community files, workflows |

## Troubleshooting

**`ooda update` fails with `curl: (6) Could not resolve host: openooda.org`**

The ooda update flow runs curl in a child process. That child sometimes
inherits a stripped environment (no DNS resolver, or a sandboxed one).
The ooda binary's own hint already covers this — fetch the install
script yourself and pass it via `--installer`:

```bash
curl -O https://openooda.org/install.sh
ooda update --installer ./install.sh
```

The parent shell does the DNS-resolved fetch; ooda update only sees a
local file path, so no DNS is needed inside the child.

**`openooda.org` is unreachable from your network (corporate proxy,
firewall, airgap)**

Same workaround — fetch the script from a different mirror and pass
it to `--installer`:

```bash
# from a machine that can reach the internet:
curl -O https://raw.githubusercontent.com/openOODA/install/main/install.sh
scp install.sh your-server:/tmp/
# on the airgapped box:
ooda update --installer /tmp/install.sh
```

**`bash: $BIN_DIR/ooda: cannot execute: required file not found` after install**

The install's `/usr/local/bin` shim may have been removed by the OS
package manager. Re-run the installer without uninstalling; the
shim-creation step is idempotent.

## License

Licensed under MIT. See [LICENSE](LICENSE).
