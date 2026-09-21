# Depth focus implementation plan

Approved design: implement bundled Depth Anything V2 Small F16 for ordinary photos; focus selects a depth range, preserve existing native-depth support, offline operation, and validate against the user's near/far Xingtu examples. User explicitly requested implementation and simulator testing on 2026-09-20.

## Architecture and scope
- iOS 17+, SwiftUI interface and JPEG <=2048 export remain.
- Bundle the user-provided mlpackage; no build-time or runtime model downloads.
- Add typed estimated depth with model/version provenance. Legacy subject caches must reanalyze while keeping original and recipe.
- Use full-image relative inverse depth; normalize consistently and preserve orientation/coordinate transforms.
- Use robust focus sampling, a clear depth band, continuous falloff and foreground-aware rendering. No instance IDs as distance.
- Keep all processing on the PhotoPipeline actor; estimate once per import, cache for focus/aperture updates.

## Tasks and verification
- [x] 1. Probe actual Core ML IO and depth output on user's original; save depth map and near/far statistics.
- [x] 2. Add regressions for same-depth disconnected regions, near/far focus reversal, aperture/clear-range behavior, estimated provenance and stale-cache invalidation. Observe failure before implementing core behavior.
- [x] 3. Bundle model, implement estimator with full-frame preprocessing and lazy model load; integrate into PhotoPipeline with recoverable failure and cached model identity. Exercise actual model in Apple SDK tests.
- [x] 4. Update UI status, adjustable depth range, mask preview and draft restore; update obsolete no-model static checks to enforce bundled/offline model instead.
- [x] 5. Build for iPhone Simulator, run full Swift core + Xcode imaging suites; fix failures. Run real image near/far cases and inspect rendered images for clear-plane behavior and boundary defects.
- [ ] 6. Interactive gesture/picker/share acceptance remains: Xcode 27 Device Hub automation repeatedly times out. Simulator XCTest real import/pipeline/render/export and draft round-trip, f16/off, clear-band cache changes are verified. Independent review completed and native-cache precedence fixed; evidence saved. Do not claim full manual UI acceptance.

## Acceptance and review focus
- Selecting the bottle preserves other pixels in its clear-depth band; selecting the cabinet defocuses near desk objects.
- Transparent bottle sampling must not simply inherit distant background; use real photo checks rather than promises based on synthetic tests.
- Portrait/landscape and EXIF orientations keep taps aligned with depth.
- Old subject caches cannot silently bypass the new model. Failed imports preserve the previous photo.
- f16/disabled effect preserve unblurred pixels and existing crop/style/exposure semantics.
- Export and preview select the same focal region. No hardcoded sample-specific masks or coordinates in production.

## Progress
- Clean baseline source at e9738b0. Work in requested existing project; no unrelated local edits present.
- The provided zip contains one 49,819,122-byte model package. Native iPhone simulators and Xcode are available.

- Final pipeline uses simulator CPU after a real GPU all-zero failure; invalid predictions rejected and model provenance bumped to v2.
- Near/far sample rendering inspected, edge silhouette regression fixed (43→5), default estimated radius moderated. 56 iOS tests / 40 Swift core tests / 10 Python checks pass; iPhone Release builds. See Docs/VERIFICATION.md.
