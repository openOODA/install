# install (openOODA) — Bootstrap Installer & Release Verification Gate

`@openOODA/install` is the single entry point for openOODA: the POSIX `install.sh`
installer, the `publish-hub.sh` release publisher, the `pkg/` distro bridges
(`apt/`, `dnf/`, `pacman/`, `winget/`), and a native `.oo` conformance surface
(`core/`, `tests/`, `anchor.oo`, `Makefile`) that proves the shipped tree keeps
its contract before any release advances.

## The Contract (fail closed, refuse unsigned)

1. **`install.sh`** — `curl -fsSL https://openooda.org/install.sh | bash`.
   Flags: `--help`, `--version`, `--dry-run`, `--yes`, `--no-modify-shell`,
   `--keep-stale`/`--clean-stale`, `--uninstall`, `--selftest-sha`,
   `--from-source[=DIR]`, `--pkg NAME`, `--group @GROUP`. Every flag is parsed
   in the `case` loop AND documented in `usage()`; a dangling `--pkg`/`--group`
   operand refuses (`--pkg --group` exits 1), unknown flags exit 1, and
   trailing positionals after `--` refuse.
2. **L0 binary map** — `REPOS`/`BINARIES` bind `ooda`, `oodac`,
   `oodar`→`liboodar.a`, `oopm`, `oolsp`, `oomcp`, `oohat`; the install loop
   `for key in ooda oodac oodar oopm oolsp oomcp oohat` is the canonical order.
3. **Master SHA256SUMS** — one hub manifest at
   `openOODA/install/releases/latest/download/SHA256SUMS`
   (`HUB_SUMS_URL`, cached per-run). `sums_ensure` fetches it, `sums_expected`
   looks up each asset, `sha256sum`/`shasum` verifies bytes, and every download
   path (`gh`, HTTPS, `--pkg`) refuses unsigned or mismatched assets
   (`refuse unsigned install`). Legacy `.sha256` sidecars are fallback-only for
   non-hub hosts; `--selftest-sha` proves the sidecar gate refuses missing,
   empty, forged, uppercase, non-hex, truncated, and over-length digests.
4. **VERSION alignment** — `VERSION` is the installer semver; the embedded
   curl|bash offline fallback `|| echo "X.Y.Z"` inside `install.sh` must equal
   it (kept in sync by `bump-version.yml`). `--version` prints exactly
   `openOODA installer $(cat VERSION)`.
5. **`versions.toml`** — optional `name = "vX.Y.Z"` pins read by `load_pins`;
   absent pins default to the hub release.

## Conformance Surface

- `core/install_check.oo` — semver parse, `pkg/{apt,dnf,pacman,winget}`
  non-empty census, `ins_repo_ok` repo-fold verdict (FsReadCap-jailed reads).
- `core/install_script.oo` — pure-source contracts: `ins_script_shape`
  (shebang + `set -euo pipefail` + `do_install` + `ensure_sysdep`),
  `ins_flags_ok` (all 8 canonical flags parsed and documented),
  `ins_bins_ok` (L0 map + `liboodar.a` + install loop), `ins_sums_ok`
  (SHA256SUMS channel + refusal strings + zero `sums_lookup` call sites),
  `ins_ver_aligned` (fallback == VERSION), `ins_script_ok` fold.
- `tests/test_functional.oo` — 10 positive assertions on the shipped tree.
- `tests/test_refusal.oo` — 12 negative-trust assertions on forged inputs.
- `anchor.oo` — re-exports both checker pages as the repo conformance surface.

## Build & Verify

```sh
make build && make test   # oodac builds both suites; suites + flag smoke run
make check                # oodac check every .oo page + bash -n shell gate
bash install.sh --dry-run        # simulated install, zero disk writes
bash install.sh --selftest-sha   # SHA-256 refusal-gate proof
oohat cycle .                    # 8-hat quorum_mask=255
```

## Invariants (Zero Trust)

- No download path installs unverified bytes; missing sums entries refuse.
- `sums_lookup` is a forbidden dead call — `ins_sums_ok` requires zero hits.
- Link count == 1 everywhere (0 symlinks/hardlinks); `.ooda-cache/` is scratch.
- Power-of-2 Shape Ladder holds on every `.oo` page (16..256 lines, <=8 fns,
  <=64 lines/fn, <=8 params, <=128 cols, <=4 depth, Academy headers, no tabs).
- workflows are `workflow_dispatch`-only; the root carries exactly the 11
  canonical entries (CI allowlist: AGENTS.md Makefile README.md VERSION
  anchor.oo core install.sh pkg publish-hub.sh tests versions.toml).
