<div align="center">

<pre>
   ____  ____  ___  ____    ___   ___  ____    _
  / __ \/ __ \/ _ \/ __ \  / _ \ / _ \|  _ \  / \
 / /_/ / /_/ /  __/ / / / | | | | | | | | | |/ _ \
/_____/ .___/\___/_/ /_/  | |_| | |_| | |_| / ___ \
      /_/                   \___/ \___/|____/_/   \_\
</pre>

### `install` — Public Binary Distribution Hub (install@hub), install.sh bootstrap, and apt/dnf/pacman/winget packaging for openOODA.

[openooda.org](https://openooda.org) • [`openOODA/install`](https://github.com/openOODA/install) • [Public Binary Hub (`install@hub`)](https://github.com/openOODA/install/releases/tag/hub) • [Governance & Quick Cards (`openOODA/openOODA`)](https://github.com/openOODA/openOODA)

</div>

---

## Overview

**`install`** (`v0.2.6`) is a canonical repository in **Root (`@openOODA`)** of the [openOODA](https://github.com/openOODA) capability-secured computing stack (`L0`–`L7`).

- **Description**: Public Binary Distribution Hub (install@hub), install.sh bootstrap, and apt/dnf/pacman/winget packaging for openOODA.
- **Layer & Bundle**: Root (`@openOODA`) • Fedora-style bundle `@core` (`oopm install @core` or `oopm install install`)
- **Explicit Capabilities (`CapReg64`)**: `EnvCap`, `ProcessCap`, `FsReadCap`, `SysCap`, `TimeCap`, `FsWriteCap`, `AllocCap`
- **Security & CISA KEV Posture**: Hardened against `CWE-22` (path traversal admission), `CWE-78` (shell-free argv execution), `CWE-190`/`CWE-787` (checked bounds arithmetic), and `CWE-502` (depth-bounded `.oot` deserialization); verified under the 8-Hat adversarial consensus engine (`oohat cycle` `quorum_mask=255`) and deterministic double-compilation (`make det`).
- **Theme & Surface Integration**: Wired to [`ootheme`](https://github.com/openOODA-tools/ootheme) (`25` built-in dark/light/circadian presets, `34` semantic color tokens, `NO_COLOR=1`, and `--json`) and exposes `<binary> about` (`ooda about install`).
- **Tags**: `#openooda` `#capability-security` `#zero-trust` `#deterministic` `#post-quantum-cryptography` `#cisa-kev` `#installer` `#binary-hub` `#linux` `#package-distribution` `#supply-chain-security`

## Module Anatomy (`8` `.oo` Pages — Power-of-2 Shape Ladder `1/2/4/8/16/32/64/128/256`)

| Page | Role & Logline |
| :--- | :--- |
| [`anchor.oo`](anchor.oo) | How the toolchain lands on a machine. Thin bash shim for curl \| bash portability. Toolchain-only — LLM-harness scanning/wiring removed 2026-09-11 (020693a). |
| [`docs/anchor.oo`](docs/anchor.oo) | Per-package docs for how the toolchain lands on a machine. apt, dnf, pacman, and install.sh. |
| [`qa/anchor.oo`](qa/anchor.oo) | Re-exports install/ governance probes (line cap, binary manifest). Fails closed on file law violations, byte-count drift, or manifest mismatch. |
| [`qa/qa-01-line_caps.oo`](qa/qa-01-line_caps.oo) | Fail closed if any .oo/.oot file in install/ exceeds 256 lines or violates lowercase canonical naming. Re-verifies the RULES §1.8 and §1.19 invariants for this repo. |
| [`qa/qa-02-bin_manifest.oo`](qa/qa-02-bin_manifest.oo) | Fail closed if install.sh BINARIES map and docs/surface.oot disagree on the 7 release binaries. Re-verifies the install/ ↔ docs surface consistency invariant. |
| [`qa/suite.oo`](qa/suite.oo) | Run all install/ probes twice in sequence, report pass/fail. Fails closed on the first probe that fails typecheck or execution. |
| [`tests/test_install.oo`](tests/test_install.oo) | Positive and negative-trust assertions over the QA seal and the repo's canonical invariants. |
| [`tests/test_update.oo`](tests/test_update.oo) | Assert the update/pin trust surface in install.sh stays fail-closed: strict version grammar, charset-bound release refs, atomic state commit, and partial-install refusal. |

## Build, Deterministic Verification & 8-Hat Consensus Gates

```sh
make build                                         # Compile native ELF binary via oodac
make test                                          # Run functional /tmp round-trip + negative-trust refusal tests
make det                                           # Diverse Double-Compilation bit-for-bit determinism gate
/Projects/openOODA-agents/oohat/bin/oohat cycle .  # 8-Hat consensus + CISA KEV gate (quorum_mask=255)
```

---

License: Apache-2.0.
