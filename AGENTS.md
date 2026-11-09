# openOODA (.oo) Agent Quick Card
1. **The 8 Canonical Quick Cards** (Zero-bloat ~24-line cards built into `ooda`):
   - `ooda ooda`     -> `ooda.md`     (How to rapidly build, test, and adapt openOODA software)
   - `ooda layers`   -> `layers.md`   (The 8-Layer Architecture Map `L0`–`L7` across Desktop, Server & Mobile)
   - `ooda spec`     -> `spec.md`     (`.oo` syntax, types, structs, `match`, and `oostd` builtins)
   - `ooda rules`    -> `rules.md`    (Power-of-2 Shape Ladder `1/2/4/8/16/32/64/128/256` & CLI laws)
   - `ooda ui`       -> `ui.md`       (CLI, TUI, Desktop & Mobile UI + `ootheme` 25 presets & 34 tokens)
   - `ooda security` -> `security.md` (Zero-Trust `CapReg64` `0..31` caps, `oosandbox`, `oosign`, `ooprovenance`, `oovault`)
   - `ooda privacy`  -> `privacy.md`  (Zero-telemetry, PII/EXIF/SECRET scrubbing `ooredact`, LED & clipboard TTL gates)
   - `ooda defense`  -> `defense.md`  (Active defense `oodefense` IDS/canary/honeypot, `oofirewall`, DMA/DRAM/USB guards)
2. **Power-of-2 Shape Ladder (`1/2/4/8/16/32/64/128/256`)**:
   - `1`: Link count == 1 (0 symlinks/hardlinks) & max 1 statement/line. `2`: Lean 2-file `tests/` suite (`tests/test_functional.oo` + `tests/test_refusal.oo`, 0 source-grepping).
   - `4`: Max 4 nesting depth & **4-Axis Code Review** (`1. oohat Gate` + `2. Semantic Logic & Spec` + `3. Native Binary & Systems` + `4. Ecosystem & Registry`). `8`: Max 8 files/dir, 8 fns/file, 8 params/fn, & 8-entry repo root (`AGENTS.md`, `README.md`, `Makefile`, `ooda.pkg`, `anchor.oo`, `cli/`, `core/`, `tests/`). `16`: Min 16 lines/file.
   - `32`: 32 explicit capabilities (`&FsReadCap`, `&FsWriteCap`, `&NetCap`, `&ProcessCap`, `&EnvCap`), max 32 chars/name (no `*_1.oo` splits), <=32 files/repo.
   - `64`: Max 64 code lines/fn. `128`: Max 128 chars/line. `256`: Max 256 lines/file.
3. **Syntax, Mandatory `oostd` Reuse & Workflow**:
   - Relative string imports only (`import "core/engine.oo";` or `import "oostd/fs/os/fs.oo";`, never `::`). No parens on `if cond { }` / `while cond { }`. No struct trailing commas. Connect all CLI/TUI/GUI output to `ootheme` and expose `<binary> about`.
   - **Always import `oostd` (`L0`)** for math (`oostd/core/math/exact/...`, `geometry/...`), 2D/3D physics & collision (`oostd/core/science/phys/classical/...`, `gnc/...`, `relativistic/...`, `oostd/core/app/ui/game_engine/...`), frontier AI-for-science & graphs (`oostd/core/app/ai/...`), collections (`oostd/core/collection/...`), and crypto/hashing (`oostd/sec/hash/...`, `capability/...`)—never re-implement duplicate local helpers!
   - Build & Verify: `ooda build && ooda test && ooda check && ooda audit`.
