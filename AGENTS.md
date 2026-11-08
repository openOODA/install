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
   - `1`: Link count == 1 (0 symlinks/hardlinks) & max 1 statement/line. `2`: Min 2 tests (functional + negative-trust exit != 0).
   - `4`: Max 4 nesting depth. `8`: Max 8 files/dir, 8 fns/file, 8 params/fn. `16`: Min 16 lines/file.
   - `32`: 32 explicit capabilities (`&FsReadCap`, `&FsWriteCap`, `&NetCap`, `&ProcessCap`, `&EnvCap`), max 32 chars/name (no `*_1.oo` splits), <=32 files/repo.
   - `64`: Max 64 code lines/fn. `128`: Max 128 chars/line. `256`: Max 256 lines/file.
3. **Syntax & Workflow**:
   - Relative string imports only (`import "core/engine.oo";` or `import "oostd/fs/os/fs.oo";`, never `::`). No parens on `if cond { }` / `while cond { }`. No struct trailing commas. Connect all CLI/TUI/GUI output to `ootheme` and expose `<binary> about`.
   - Build & Verify: `ooda build && ooda test && ooda check && ooda audit`.
