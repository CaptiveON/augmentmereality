# Issue #18 draft: per-drop scene ownership (unintegrated)

Preserved drafts:

- [PlacedObjectState.swift.txt](PlacedObjectState.swift.txt) — proposed `AugmentMeReality/AR/PlacedObjectState.swift`
- [PlacedObjectStateTests.swift.txt](PlacedObjectStateTests.swift.txt) — proposed `AugmentMeRealityTests/PlacedObjectStateTests.swift`

These `.swift.txt` files are outside the app and test source trees. They have **not been integrated** into `GeoARSessionManager`, **not been built** as part of the app or test target, and **not been run** as tests. The source drafts passed a **Swift parser check only**; parsing does not establish type checking, linking, runtime behavior, or test success. Issue [#18](https://github.com/CaptiveON/augmentmereality/issues/18) explicitly depends on [#11's synchronized frame and depth contract](https://github.com/CaptiveON/augmentmereality/issues/11). Complete that contract before full #18 integration; independent per-object state work can proceed without treating this draft as a finished manager migration.

The two preserved source files are byte-for-byte copies of the original draft at `/tmp/amr-phase4-sep30/phase5-draft/` (SHA-256: `PlacedObjectState.swift` `8340dedb3620d819e030a375da3d3fc72ec82b48cce47226483ce1f331185a9f`; `PlacedObjectStateTests.swift` `2db5f0ec886ca90bfa9c17be09dd837cf01d30f7482ff2614121f23063d7043a`). This handoff was adapted from that draft's `HANDOFF.md` (original SHA-256 `8577c5a19da6882dc972666aa7e2258f856a745c63da4e661f00f3c7105ad782`).

## API and intended ownership

`@MainActor PlacedObjectRegistry` is keyed by drop UUID. `upsert(_:scope:)` creates or refreshes a record, `state(for:)` is the direct hot-path lookup, and computed `visuals`/`dropsWithVisuals` snapshots support whole-scene loops. `unloadVisual(id:cleanup:)` detaches a live holder but retains the drop and room/local-pin pose for readmission; `remove(id:cleanup:)` retires one drop; `reset(cleanup:)` retires all records.

Each `PlacedObjectState` owns its resolved `GeoDrop`, an optional `Visual` bundle (holder, content, marker, contact disc, readiness, reveal state), optional ARGeo anchor pair, room/local-pin world poses, measured world-Y lock, and the applied geographic anchor intent. `attachVisual` admits a holder. `replaceVisual` swaps a complete holder under the same parent with the same local transform, retaining its ARGeo anchor. `replaceContent` swaps only an asset subtree. `bindGeoAnchor`/`releaseGeoAnchor` pair scene and AR session anchors. `Cleanup` callbacks let the manager remove a scene anchor, remove its ARGeoAnchor from the AR session, and invalidate VPS state without constructing a camera in tests.

The draft consolidates the visual/drop/readiness/reveal maps first. Edit gestures, epoch state, scene selection, asynchronous save tickets, local pin override admission, and VPS correction ownership remain in the manager until their lifecycle can be moved coherently. Do not treat these draft records as canonical while the old maps still control rendering.

## Test rationale

The tests use real unattached RealityKit `Entity`, `ModelEntity`, `AnchorEntity`, and `ARGeoAnchor` instances. They exercise room eviction pose retention and readmission, local-pin lock retention, asset-subtree replacement, whole-holder replacement with unchanged parent/pose/ARGeo anchor, and per-drop/reset detach plus cleanup callbacks. No `ARView`, `ARSession.run`, or camera is needed. These are lifecycle tests, not phone acceptance tests. Native target compile and tests remain pending.

## Integration points to review

- `GeoARSessionManager` currently has separate `placedHolders`, `placedDrops`, `contentEntities`, `markers`, `groundDiscs`, `readyContentIDs`, and `revealedDrops`. Migrate all seven reads and writes together before making the registry canonical. Use `state(for:)` in per-frame loops; snapshots allocate new dictionaries.
- For scene-budget detail changes, call `replaceVisual`; it retains the ARGeo anchor. For true visual eviction, call `unloadVisual`; it releases the ARGeo anchor and invalidates pending VPS. A room pose or local pin must survive an eviction. A full reset must clear the external edit/gesture, selection, correction, and epoch state in addition to registry records.
- The draft `replaceVisual` copies the holder's *local* transform to the new holder under the same parent, matching the current `replaceHolderContent` path. The manager's ARGeo release path reparents a holder under `worldRoot` using a *world* transform; keep that distinct operation intact.
- Cleanup callbacks are intended to be idempotent. **Known double-invalidation caveat:** the current draft may invoke VPS invalidation again if `remove` follows a prior `unloadVisual`; the manager must either tolerate that or refine the lifetime state before migration.
- Verify the final registry API against all admission/reconciliation paths, especially remote drop updates, local pins, room restart snapshots, stale epoch completions, and owner scene-budget eviction. This draft does not prove those manager paths.
