# v4 execution record
Scope approved in chat: ordinary photos automatically acquire relative depth using the complete user-uploaded Core ML model; no build/runtime download, no human annotation prerequisite, existing UI retained.

Baseline: v3 Swift suite: 60 passing. Root cause: PhotoPipeline.analyzeLayers creates only an unknown label map.
Model: manifest, protobuf and weight file match locked hashes; 49,819,122 total bytes.
Model contract from the actual protobuf: spec 8 / CoreML7; image RGB 518×392, depth GRAYSCALE_FLOAT16 518×392; preprocessing is already inside the graph, not an extra 0…1 input normalization.
Reference computation: all 2,459 MLProgram operations evaluated on the exact uploaded weights using a limited CPU PyTorch reference evaluator, Float16 boundaries emulated; original photograph, no manual label map. This is not Apple Core ML execution.
Implementation sequence:
1. Cache identity + estimated-depth type, focus mask protection and v4 recipe migration; tests.
2. Bundled model loading + full-image stretch input + checked prediction output; ordinary import and v1/v2/v3 recovery; no unassigned intermediate editor.
3. UI wording/debug information + shared sample import; keep existing layout.
4. Native Xcode model source membership; offline/model hash tests; iOS real-model tests.
5. Re-run Swift/statically available checks, document unexecuted Apple SDK tests and package full model.

Tasks 1–4: implemented. Actual model reference input replay and eight-tap production-mask checks passed.
Review: legacy hand annotations moved to test-only resources; no reference-specific branch in prepare.
Review: constant inferred caches now rejected (red → green); error does not publish a blank PhotoSession.
Review: native model Source membership checked against the official sample; compiler was not available here.
Review: no independent reviewer tool available; self-review only, Apple tests unexecuted.

Final available checks complete: 75 XCTest cases, 16 project tests; actual model graph replay and masks verified. Apple SDK build/runtime remains unexecuted.
