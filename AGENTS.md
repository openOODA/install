# install: Agent Engineering Standards (v1)

This repository houses the multi-platform installer (`install.sh`, apt, dnf, pacman) and packaging specifications for openOODA.
All work in this repository strictly defers to the organization standards in [`openOODA/AGENTS.md`](file:///home/ubermetroid/Projects/openOODA/openOODA/AGENTS.md).

---

## 1. Packaging Architecture & Invariants
- **Fail-Closed Verification**: SHA-256 sidecars verified before execution. Corrupt downloads abort immediately.
- **Idempotency**: Running `install.sh` twice leaves the system in a bit-identical state.
- **Clean Uninstallation**: Uninstallation cleanly purges binaries, man pages, and profile scripts without leaving dirty state.

---

## 2. Invariants & Quality Standards
- **Pure POSIX Shell**: Host installation scripts must run cleanly on Ubuntu/Debian, Fedora/RHEL, Arch, and Alpine (`sh` / `bash`).
- **Zero Sudo Without Consent**: Script detects write permissions before prompting for elevated privileges.

---

## 3. Local Verification Commands
```bash
bash tests/test_e2e_install.sh
bash tests/test_idempotent.sh
```

---

## 7. Multi-Engine Audit Protocol (Pre-Release)

Advisory tiered audit run before tagging releases, budgeted by token capacity:
1. **`mcode`** (Abundant tokens): Full codebase scan for contract mismatches, packaging specs, and CI gates.  
   `mcode exec --permission full "<prompt>"`
2. **`vibe`** (Moderate tokens): Adversarial diff inspection for subtle regressions, security bypasses, and API validity.  
   `vibe -p "<prompt>" --trust --auto-approve`
3. **`grok`** (Strict quota): High-value referee and final sanity check on critical release diffs.  
   `grok -p "<prompt>" --always-approve`

**Rule:** External audits are strictly advisory; all findings must be verified against source code. External LLMs never gate CI—the §5 Verification Ladder is the sole canonical authority.
