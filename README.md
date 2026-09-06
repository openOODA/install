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

Right after launch the installer asks `Install openOODA? [Y/n]` (auto-yes for `curl | bash` with no tty, `CI`, `OPENOODA_YES=1`, or `OPENOODA_DRY_RUN=1`). After the core toolchain lands, it scans for LLM harnesses and asks `Connect detected harnesses (…) to mcp, lsp, and blackbox? [Y/n]` — answering `n` skips wiring. When harnesses were wired, it reminds you to restart any open harnesses so the new config is read (hosts read at startup). Use `OPENOODA_YES=1` or `printf "y\ny\n" | bash install.sh` for non-interactive.

On each run the installer auto-detects installed LLM harnesses and idempotently wires `ooda-mcp --stdio`, `ooda-lsp --stdio`, and `blackbox mcp --stdio` with `OODA_COMPILER`, `OODA_FS_READDIR`, `OODA_FS_WRITEDIR`, `OODA_CODEX`/`OODACODEX`:

- **Core (already on this machine):** `antigravity-cli`/`agy`, `opencode`, `muse` (Muse), `grok`, `gemini`
- **New from web sweep (MCP-native, high adoption):** `claude-code` (`claude` CLI, `~/.claude.json`), `claude-desktop` (`claude_desktop_config.json`), `cursor` (`~/.cursor/mcp.json`), `windsurf` (`~/.codeium/windsurf/mcp_config.json`), `codex` (`~/.codex/config.toml`), `cline` (`cline_mcp_settings.json`), `continue` (`~/.continue/config.json`), `zed` (`~/.config/zed/settings.json` → `context_servers`), `vscode` (`~/.config/Code/User/mcp.json`), `goose` (`~/.config/goose/config.yaml`)
- **Stubs (no MCP yet):** `mistral-vibe`, `grok-build`, `devin`, `charm`/`crush`

`OPENOODA_DRY_RUN=1` previews without touching disk. Re-run is safe — existing `mcpServers`/`mcp`/`context_servers`/`servers` entries are merged, unrelated servers are preserved, and a `*.bak.openooda` backup is kept.

**Professional install (P0/P1):** `install.sh --help` (`--dry-run`/`--yes`/`--no-modify-shell`/`--uninstall`), pre-flight checks `curl`/`git`/`python3` + `df` >100 MB + `curl -Is raw.githubusercontent`, `fish` (`XDG_CONFIG_HOME/fish/config.fish`) + `bash`/`zsh` rc backed up as `*.bak.openooda`, `XDG_CONFIG_HOME` respected for all harness configs, `~/.openooda/install.log` (1M rotate) + `trap` cleanup, post-flight `verified: ooda/oodac/ooda-lsp/ooda-mcp/blackbox --help` + `harness mcp wiring contains openooda`, and cap-closed `harness_wire.oo` (172 lines) tried first (silent unless `OPENOODA_DEBUG=1`, falls back to bash for `curl | bash`).

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

## License

Licensed under MIT. See [LICENSE](LICENSE).
