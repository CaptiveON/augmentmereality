# Scene content budget — 2026-09-30

The camera admits geographic and Room Test drops through one `SceneContentBudget` selection. It keeps selected, edited, imminent, and nearby full content first, with a 25% distance preference for an already admitted item to avoid jitter at the boundary. Every other eligible drop remains in the library or Room Test record. At most 24 of those locations get a lightweight one-sphere scene cue in normal operation. Geographic drops outside the scene allocation remain in the map/list; Room Test drops keep their world poses and can re-enter the scene as the viewer approaches. The HUD reports the deferred count. Room Test poses are also included in reset recovery. Eviction removes full RealityKit subtrees and invalidates geo anchors when their drop leaves the visible allocation.

| State | Full models | Relative work units | Compressed USDZ source proxy across clones | Cues | Maximum scene drop holders |
| --- | ---: | ---: | ---: | ---: | ---: |
| Normal | 8 | 16 | 64 MiB total, 32 MiB per clone | 24 | 32 |
| Serious thermal or recent memory warning | 4 | 8 | 32 MiB total, 32 MiB per clone | 12 | 16 |
| Critical thermal or recovery | 1 | 4 | 32 MiB total, 32 MiB per clone | 6 | 7 |

Simple beacons cost one work unit; text, balloons, gifts and hearts cost two; long text and fireworks cost three; animated USDZ clones cost four. Generated text is capped at 160 Unicode scalars in the AR mesh, while the saved message stays intact. Unknown or over-budget USDZ source sizes cannot enter a full slot and remain cues. The bundled catalog's largest compressed file was 31,207,769 bytes on this checkout, below the individual cap. The source-size lookup is cached because the bundle cannot change while the app runs.

A hidden camera retains its current scene allocation for a quick return and admits no new item. If thermal or memory pressure arrives while hidden, it sheds to the critical limits using only already visible identities and never promotes a cue to a full model. Asset preparation separately remains one decoder with at most eight queued identifiers and three resident templates under a 24 MiB compressed-source proxy; unused templates are released on memory warning. These limits count admission and compressed files. They do **not** measure decoded mesh geometry, texture residency, GPU allocations, or total process RAM. Actual startup, frame pacing, memory, and fifteen-minute thermal behavior still require the Issue #3/#9 Release iPhone protocol with representative heavy assets and dense catalogs.

`SceneContentBudgetTests` covers a 500-drop combined catalog, selection hysteresis, unknown and oversized files, thermal/hidden pressure, and rapid hero changes while an asset decode is in flight. `AssetPreparationQueueTests` covers decoder, queue, cache, cancellation, and negative-cache behavior. Physical-device validation is outstanding.
