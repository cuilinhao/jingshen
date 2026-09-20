# Native Vision rewrite — 2026-09-20
Approved scope: native Vision subject segmentation + Core Image blur, preserve reference UI and original native depth, explicit local-blur fallback, no external model downloads.
Workspace: isolated extraction of the uploaded ZIP. No user repository or remote was modified.
Baseline: original 12 Swift core tests passed; Linux host has no Xcode or Apple SDK.

- Core labels/coverage, subject/background selection, local masks, v2 recipe: implemented; regression tests added before implementation; 28 relevant core tests pass.
- DraftStore v2 with typed binary analysis cache, source/recipe preservation and v1 migration: implemented; 7 tests pass.
- Native Vision request, native depth reading, shared Core Image rendering and caches: implemented; syntax and API-source review performed. Apple SDK execution remains pending.
- Main UI retained, truthful source/fallback messages, controls and mask preview updated. Reference constants statically checked, runtime comparison pending.
- External model download phase, files, scripts, runtime loading and stale docs removed; actual project references rebuilt and validated.
- Review corrections: valid Section header/footer initializer, file metadata privacy reasons. Static checks observed fail before corrections, then pass.
- Delivery: 35 core tests + 6 static project tests pass; 11 iOS image tests provided but not run. Clean archive excludes build caches, Git metadata, and old validation logs.

Limit: self-review only; no independent reviewer tool, no Xcode compile/link/sign, no real Vision/Core Image/device validation.
