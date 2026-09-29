# FIELDTESTS.md — the on-device protocol (v0.9)

A wave is done when these pass **in the field**, not when the build succeeds. Every test
says what to do, what to record (screenshots support the observations), and the pass
bar. Run what fits your situation; FT-numbers make reporting one-liners:
*"FT-3: 0 ms ✓, FT-7: Σ 14 cm ✓, FT-12 failed — text visible through the building."*

**HUD legend:** mode badge · "N in view range" · `LiDAR` `VPS ±x m` `SEM` `TRANSIT` chips ·
status line · cyan "Rendered X m ahead · Y up" · `first object: X ms · fps · p95` ·
`vps corrections Σ cm`.

**Measurement correction — issue #3 (September 2026):** use the
[AR Release baseline protocol](docs/AR-BASELINE-PROTOCOL.md) and
[result template](docs/AR-BASELINE-RESULT-TEMPLATE.md) for startup/performance claims.
The historical HUD `fps`/`p95` counts scene-update callbacks, not proven display
presentation. Historical `first object`/TTFO measured holder existence, including
placeholders and retained content; neither its number nor a pre-warmed zero proves
the selected hero appeared. This correction supersedes those measurement claims
throughout this document, including the old S3 TTFO interpretation below. Keep
camera capture, scene-update/post-process proxies, intended-asset readiness and
actual presentation distinct. Preserve an unchanged Release baseline, use a
0–10-second startup window and a 15-minute sustained window, and keep visual
recordings separate from unplugged thermal runs. No physical-device pass follows
from this instrumentation change.

---

## A. Killer #1 — instant presence (no wait, no pop-in)

**FT-1 · Cold open reveal (ADR-043 semantics).** Force-quit. Open the app, stay on Map
~10 s (**verify: NO green camera dot**), tap Camera. **Pass:** the "Opening the
viewfinder" moment plays ≤1.6 s and lifts onto a camera with content ALREADY placed —
zero empty-viewfinder frames. Repeat ×5.

**FT-2 · Instant-tap cold camera.** Force-quit. Open the app and tap Camera
immediately. **Pass:** same as FT-1 — the reveal covers the whole bring-up; content
never materializes into a watched spot after the curtain lifts.

**FT-3 · Tab flip.** Camera → Map → within 5 s back to Camera. **Pass:** instant (grace
window keeps the session warm), content exactly where it was, no reveal replay. After
>5 s away: reveal plays again (session was released — by design, no background camera).

**FT-4 · No-pop-in observation (the feel test).** During any 5-minute session: content
must never *materialize* into an empty spot you were looking at. Glides = pass;
appearance = fail. **Record:** any violation + what the status line said.

## B. Killer #2 — real object, real occlusion (seam quality)

**FT-5 · VPS lock.** Outdoors, buildings visible, pan slowly across the street.
**Record:** time until the chip goes green `VPS ±x m`, and the ±value. **Pass:** lock
≤30 s daytime; content glides once (≤1.2 s) when it locks.

**FT-6 · Walk-to accuracy.** Pin a text 100+ m away at a spot you can identify exactly
(gate, lamppost). Walk to it with VPS locked. **Record:** how far the pillar stands from
the true spot at arrival. **Pass:** ≤5 m (VPS bar); note the `VPS ±` value alongside.

**FT-7 · Frozen hold (drift).** Stand still 2 minutes looking at a VPS-locked drop
10–30 m away. **Record:** `vps corrections Σ cm` at start/end + whether you *saw* it
move. **Pass:** no visible slide; Σ growth over the hold < ~30 cm.

**FT-8 · Parallax orbit (sticker check).** Walk a half-circle around a near drop
(5–15 m). **Pass:** you see its side/back; size changes only with your distance; it
behaves like a parked car, never a sticker.

**FT-9 · Near occlusion (LiDAR).** Put a parked car / pole / person between you and a
drop ≤8 m behind it. **Pass:** the blocked part is cleanly hidden; silhouette follows
the real edge with no glow-through. People walking through must occlude.

**FT-10 · Building occlusion (Streetscape).** VPS locked, pin a drop behind a building
corner, then walk so the corner reveals it. **Pass:** it emerges *exactly* at the real
edge, building-scale, beyond LiDAR range.

**FT-11 · Semantic matte silhouette.** Drop 100+ m away, partially blocked by a distant
tree/building, `SEM` chip armed (v0.9: arms when any drop is >15 m). **Record:**
silhouette quality where content meets the obstruction; any faint color patch where
restore happens. **Pass:** content does not paint over the building/tree; edges stable
(no shimmer). If misaligned, say so — I flip `semanticMatteDebugTint` and your next
screenshot shows the matte in red.

**FT-12 · The original window regression.** Re-run your first failed test: pin text on
the road outside, view from the window at night. Tap the HUD lighting chip to **Bright**
(v0.9: natural scene-lit is the default; the glow is now the viewer's toggle). **Pass:**
visible immediately in the right direction, correct height, glowing, pillar marking the
spot.

**FT-24 · Pan-and-hold bearing stability (v0.9 regression of "it keeps moving").**
Pin a drop 80–150 m away. Stand still. (a) Stare at it 60 s: it must not slide
sideways. (b) Pan the phone left-right across ~180° several times, then return to the
drop: it must be within ~1 body-width of where it was — never "wherever I'm now
facing". **Record:** `VPS ±` value, and whether any slide was a smooth glide (allowed
once, when VPS locks) vs repeated wandering (fail).

**FT-25 · Walk-up tree occlusion (v0.9 regression of "draws over everything").**
Drop 100+ m away with trees between you and it. Walk toward it. **Pass:** trees keep
hiding the content the whole approach until you are ~15 m out (per-pixel gate);
near-er trees (≤5 m) occlude via LiDAR. **Record:** the distance band, if any, where
draw-over still happens — that number tunes `semanticMatteTreeDistance`.

**FT-26 · Facing control.** Pin one drop with Faces = North and one with the default
Auto. **Pass:** the North one's front faces true north regardless of your approach
side; the Auto one faces where you first saw it from.

**FT-27 · Person occlusion edge quality (v0.9, ADR-030 — INDOOR OK).** Room Test: place
a drop, then have someone (or your hand/arm) pass between you and it at 0.5–2 m. **Record:**
is the silhouette where the person hides the object clean and stable, or blurry/flickering?
**Pass:** edge follows the real person outline, no glow-through, no shimmer. If the edge is
soft/wrong, say so — I flip `semanticMatteDebugTint` (matte renders red) and your screenshot
shows exactly where the matte lands so I can tune `personMatteRefineRadius` /
`occlusionDepthBias`. Compare against the old path by setting `customPersonOcclusion=false`.

**FT-28 · 30 fps + thermal (v0.9, ADR-030).** Camera on 10 min. **Record:** the `fps` line
(scene-update proxy), independently measured presentation cadence, observed warmth,
`ProcessInfo.thermalState` and any `Device is hot` warning. Use issue #3's protocol
to extend to 15 minutes. **Pass:** sustained presented fps ≥30, presented-frame
p95 ≤40 ms, no serious/critical thermal state through minute 10; report the
15-minute result separately. Without presentation evidence, that gate is unmeasured.

**FT-29 · Mid-field depth occlusion (v0.9, ADR-031).** Outdoors, drop 15–40 m away with
a tree/car/pole between you and it (this band used to draw over). `DPT` chip should
appear once the model aligns (needs LiDAR-visible ground/objects within ~4 m — normal
when standing on a street). **Pass:** the obstacle hides the content with a soft edge;
content in FRONT of a backdrop (e.g. text before a wall) is NOT eaten. **Record:** chip
state, distance, what occluded/didn't. Debug: `semanticMatteDebugTint` shows this matte
red too.

**FT-30 · Launch responsiveness (v0.9, ADR-032 hang regression).** Force-quit. Open the
app, go to camera IMMEDIATELY, tap Room test IMMEDIATELY, pick the biggest model
(Castle). **Pass:** the menu opens instantly, a small glowing orb appears at the spot
right away, and the real model replaces it in place within a few seconds — the UI never
freezes, everything stays tappable throughout. Repeat ×3.

**FT-31 · Sustained session (v0.9, ADR-033 — THE launch bar).** Mild day, 60 minutes,
camera open throughout: ~10 min looking at drops (FULL), ~20 min walking with drops out
of view (chip `ECO`), ~30 min camera tab open with no drops in range (chip `IDLE`).
**Record:** battery % at 0/30/60 min (also auto-logged every 5 min with tier), whether
`Device is hot` ever appeared, fps stability, and which chips you saw when. **Pass:** no
thermal warning the entire hour; the phone may be warm only during the FULL stretches;
`ECO`/`IDLE` chips appear when they should (out-of-view / nothing rendered).

**FT-32 · Through-window viewing (ADR-044).** Pin a drop 20+ m outside, view it from
indoors through a closed window. **Pass:** within ~2 s the `GLASS` chip appears and the
drop renders visibly through the pane (no invisible-wall cutoff, no holes from your
reflection); step away from the window toward an open view and the chip clears within
a few seconds. **Record:** chip timing, any flicker during the transition.

**FT-33 · Fixed physical size while walking (supersedes ADR-049's compensation test).**
Place content with known authored dimensions, then walk a 5–60–5 m route through
its old 8 m compensation threshold, orbit it, and compare it with a measured real
reference. The HUD reports angular size without a compensation factor.
**Record:** distance, authored dimensions, angular readout and screenshots.
**Pass:** world dimensions and grounding footprint remain unchanged; the angular
size follows `2·atan(h/(2d))` within measurement tolerance; approach/retreat is
continuous. Repeat for an asset that finishes loading after a size edit and for
Natural/Bright changes. The separate waypoint marker may grow for readability;
its size must never alter the content or grounding disc. No test result is
recorded yet for the September 29 implementation.

**FT-34 · Person occlusion actually engages (Wave B, ARP-1/ARP-2).** Pro (LiDAR)
device, portrait, a drop 3–8 m away: have someone walk between you and the content.
**Pass:** occlusion engages within ~1–2 s (the sentinel's stated latency), the person
hides the content cleanly, and it disengages a few seconds after they leave frame. If
available, repeat on a non-Pro (no LiDAR) device: **Pass:** the content still hides
behind the person (blurrier edge — RealityKit's built-in fallback is expected and
correct there).

**FT-35 · Interruption resume, placements intact (Wave B, SWE-1/ARP-4).** Looking at
a placed drop: take a phone call (or app-switch for ~10 s), then return. **Pass:** the
camera un-freezes by itself within ~2 s, and the drop is still in the SAME spot — no
re-spawn, no re-glide, ground lock intact. Then app-switch for 6+ s (past the pause
grace) and reopen the camera cover: same bar. **Record:** any drop that visibly moved.

**FT-36 · Cross-account reaction toast (Wave B, PBS-3 — ADR-040 gap).** Two devices,
two accounts. A shares a fresh drop to B (no other library changes), B opens it and
reacts. **Pass:** A's toast appears within ~2 s WITHOUT A creating/deleting anything
or relaunching. This exact path was never field-tested before Wave B.

**FT-37 · Cold-start heading honesty (Wave B, MATH-3).** Force-quit, airplane-mode
GPS-cold start outdoors, open the camera on a drop ~100 m away and note its initial
bearing; watch the first ~10 s. **Pass:** if the first placement was off sideways
(magnetic seed), it visibly corrects once — the log line `MATH-3: first true-north
sample…` — and then stays; no repeated sideways stepping. **Record:** the log line +
whether a correction was visible.

**FT-38 · Sync honesty (Wave C, PBS-4/SWE-3).** Airplane mode ON. Create a drop and
share it. **Pass:** Profile shows "Uploading 1 drop…" (NOT "Synced"), and the share
sheet's footer says the link starts working once the upload lands. Reconnect:
**Pass:** within ~10 s Profile flips to "Synced — the server has confirmed your
drops" with no user action, and the link then resolves for the recipient. Then
force-quit while offline with a pending drop, relaunch online: **Pass:** the pending
upload completes on its own (the pending set survives restarts).

**FT-39 · Profile survives reinstall (Wave C, PBS-7).** Set display name + handle.
Cold-launch in airplane mode: **Pass:** the profile does NOT revert to "New
Dropper" (the old bug re-seeded the profile from an empty cache). Reconnect and
verify the server copy kept the real name.

## C. Killer #3 — Transit Mode (bus/train/car passenger)

**FT-13 · Classifier timing.** As a passenger, camera open or not: **record** when the
`TRANSIT` chip appears after sustained speed and when it drops after you get off. Brief
station stops must NOT drop it. **Pass:** enters within ~10 s of cruising, no flapping.

**FT-14 · Window stability.** In transit, camera out the window, pan the phone across
the scene. **Pass:** far drops (50 m–2 km) hold their bearing — no smear, no "world
sliding"; panning feels like looking past real landmarks. **Record:** scene-update
fps as a proxy; the ≥30 presented-fps bar requires independent presentation evidence.

**FT-15 · Distance-correct giants.** A big drop ~500 m–2 km out. **Pass:** it sits on
the horizon at the right spot, correct angular size, slides past at the believable rate
as the vehicle moves (like a distant tower, not a HUD element).

**FT-16 · Transit occlusion.** As real buildings pass between you and a far drop:
**Pass:** the drop hides behind them (semantic matte; `SEM` armed). Window frame and
seats will NOT occlude in transit — that's by design (LiDAR is off through glass).

**FT-17 · Tunnel honesty.** Enter a tunnel / GPS-dead stretch. **Pass:** status says
"GPS stale (tunnel?)" — it never pretends. On exit, drops recover within a few seconds.

## D. Systems health & failure modes (the "don't strand me" tests)

**FT-18 · 10-minute thermal.** Continuous camera for 10 min. **Record:** fps + p95 at
minute 10 with the measured stream named, observed warmth, the actual thermal-state
timeline and whether the warning appeared. **Pass:** no serious/critical thermal
state through minute 10; presented fps ≥30 and p95 ≤40 ms. Extend observation to
minute 15 under the issue #3 protocol; HUD proxy values alone leave presentation
unmeasured, and no warning alone does not establish thermal-state compliance.

**FT-19 · Battery.** Note battery % before/after FT-18. **Record:** the delta. (No
bar yet — this sets the baseline.)

**FT-20 · Interruption sandwich.** Mid-session: take a phone call, then background the
app, then relock/unlock the phone. **Pass:** each return recovers to a working camera
with content within ~2 s; no black screen, no restart needed.

**FT-21 · Offline.** Airplane mode ON (GPS still works): **Pass:** your own drops still
place/render (local store); status/chips stay honest about VPS being unavailable.

**FT-22 · Permission denial.** Settings → deny Location, open camera tab. **Pass:** HUD
says exactly what's wrong ("Location access is denied — enable it in Settings"), no
infinite "waiting" spinner. Re-grant → works without reinstall. Same for Camera.

**FT-23 · Demo button honesty.** Indoors with no GPS fix: the demo button must show
"Demo needs a GPS fix…" and be disabled — not silently do nothing.

---

## Reporting shorthand
Send: FT-number → the recorded number/observation (+ HUD screenshot when it's a fail).
Every fail goes into DECISIONS.md as field evidence, gets fixed, and the FT re-run.

## Automated pre-flight (runs before any field trip)
`xcodebuild build-for-testing … && xcodebuild test-without-building …` — 21 unit tests
covering geo math (ENU/bearing/dead-reckoning caps), motion-classifier hysteresis,
model codability/color fallbacks, store corruption-quarantine, and geo-radius filtering.
**v0.8: 21/21 passed on Muhammad's iPhone (2026-07-07).**

## FT-40 · GROUND-SNAP (Wave D round 4 — the case whose absence let a CRITICAL live a full round)
Use a **geo drop you created yourself** (Create flow → placed outdoors) — NOT the demo drop and NOT a room drop: only the geo drop exercises the persist path assertion (d) exists to prove. Stand where the camera can see real ground (pavement, floor), place the drop, raise it with the height slider and RELEASE the slider, then tap **"Place on ground"** once with no slider touched.
**Two distinct outcomes — know which you saw (round 5, counsel F-D4-FT40):**
- **Snap**: the content moves to the surface → run assertions (a)–(e).
- **Decline**: a banner reading "Couldn't find the ground here — move closer and try again" appears and the drop does NOT move → the designed decline (LiDAR found no surface), not yet a pass of anything; reposition with clear ground in view and try once more.
- **Silence** — no movement AND no banner — **is the FAIL**. That is the round-3 dead-button CRITICAL; report it as FT-40 ✗(a) immediately.
**PASS, all five:** (a) the content drops to the measured surface within a frame; (b) the height readout changes after syncSliders; (c) no persist-error toast; (d) after force-quit and relaunch the drop is STILL on the ground (proves `library.update(persist: true)` ran); (e) staying in-session five more minutes, the drop never moves again on its own (the orphaned-groundLock symptom).
**A run that never produces a snap is NOT a pass** (round 6, counsel F-D5-06) — FT-40 is complete only when assertions (a)–(e) have been evaluated on an actual snap. Report a run that only ever declined as "FT-40: incomplete (declined ×N)" and repeat on a surface with clear ground (indoors on a hard floor is acceptable). Reserve "✓-decline" for exactly one thing: it declined, you repositioned, it snapped, and all five assertions then passed.
Report as "FT-40: ✓ / ✓-decline / ✗(letter) / incomplete (declined ×N)".

## FT-41 · TWO-THUMB EDIT (Wave D round 5 — NON-OPTIONAL, alongside FT-40 and FT-3)
This is the only guard on the round-5 blocker fix (the shared gesture capture surviving until the last finger lifts). No unit test constructs the manager, so if this regresses, only this case catches it.
**Setup:** create TWO geo drops 3–5 m apart — message them "A" and "B" so you can tell them apart. Stand nearer A; the HUD title should read A.
**Steps, in order, without rushing:**
1. Press and HOLD the height slider with one thumb (do not release). Drag a little — A moves.
2. With a SECOND finger, press and drag the size slider. Both fingers are now down.
3. Release the FIRST thumb (height). Keep the second finger down and still.
4. Walk to B and stand right next to it (unambiguously closer to B than to A — round 6, counsel F-D6-02: "a few steps" leaves the flip unverifiable) — while STILL holding the size slider.
5. Drag the size slider some more, then release it.
**PASS, all four:** (a) the size change landed on A — walk to both drops and look; (b) B never moved or resized; (c) the HUD title stayed "A" for the entire interaction — it must NOT flip to B while any finger was down; (d) after force-quit and relaunch, A keeps both edits and B is untouched.
**Variant (e), the authored interleave:** hold the height slider on A with one thumb, tap "Place on ground" with another finger, then hold the slider STILL for ~10 seconds before dragging again. PASS, all three (round 6, counsel F-D6-03 — the still-hold is the round-6 assertion): (1) during the still hold, A does not drift, glide, or fight your finger; (2) the held slider still edits A when you drag again (no dead slider, no jump to another drop); (3) the snap's ground placement held until your drag overrode the height.
**FAIL signatures:** the size jumping to B (wrong-drop edit — report ✗(a/b) with a video if possible); the HUD title flipping mid-hold (✗(c)); edits vanishing on relaunch (✗(d)).
Report as "FT-41: ✓/✗(letter)".

---

# WAVE D FIELD PROTOCOL — the four sessions (round 6; run ALL on the round-6 build)
The wave's four bars: (1) 99.5% crash-free — **measured by NO session**; it is a post-TestFlight fleet statistic and must not be claimed from these runs. (2) Sustained ≥30 presented fps with **p95 ≤40 ms**; a 2-second mean cannot establish interval-tail compliance. The old HUD is a scene-update proxy, so historical screenshots alone do not establish this bar. (3) No thermal `.serious` or `.critical` through 10 minutes (and across the hour), measured from actual thermal state. (4) Zero draw-over-person frames — measurable ONLY from scrubbed video, never live. Issue #3 adds the controlled 15-minute baseline without replacing the hour-long quality/use scenario.

**Standing rules for every session:**
- **Screen recorder** (Control Center → Screen Recording): ON for every occlusion-bearing pass (anything with a person in frame or content behind real objects) so bar 4 can be scrubbed frame by frame afterwards; OFF during FT-28's 10-minute fps window and FT-31's hour (recording costs fps and heat and would contaminate bars 2–3).
- **Hang Detection**: Settings → Developer → Hang Detection → ON, threshold 250 ms, for S3 and S4. This is the substitute for MetricKit's hang instrument, which does not deliver in Xcode-installed builds. Report every on-screen hang banner with what you were doing.
- **Log capture**: after each session, with the phone connected to the Mac, run:
  `sudo log collect --device-name "Muhammad's iPhone" --last 2h --output ~/Desktop/ft-sN.logarchive`
  and hand the archive over. (The debrief filters on subsystem `com.adnan.augmentmereality` and greps: `TTFO`, `Battery `, `Perception recon=`, `Semantic pass attached`, `Semantic pass detached`, `PersonSentinel buffer hold`, `MetricKit diagnostics`.)
- **Dwell-floor assertion, corrected scope** (round 6, counsel F-D5-TOGGLE): the "no two toggles within 10 s" rule applies only to TIER-path toggles during steady use. A detach at a call banner, Control Center pull, app switch, or tab-flip-past-grace is a designed immediate detach — do not count those pairs.

**S1 · Desk gate — already executed by the supervisor; re-verified on the round-6 SHA.** Device suite green; simulator TSan grep-zero; strict-concurrency audit counted. Measures no bar; it is the precondition.

**S2 · Device sanitizer walk (≈20 min, correctness only).** In Xcode: Product → Scheme → Edit Scheme → Run → Diagnostics → check Address Sanitizer + Undefined Behavior Sanitizer (leave Thread Sanitizer unchecked — it cannot run on device). Run from Xcode onto the phone. Walk 10–15 minutes of ordinary use: place, edit, snap, tab-flip, take a call, background and return, let a person walk through frame. **Ignore fps and heat entirely** — ASan costs 2–3× CPU and every performance number under it is meaningless. PASS: zero sanitizer reports in Xcode's console and no crash. Then uncheck both boxes, run once more for 2 minutes to confirm the app behaves normally unsanitized.
**S3 · The measured pass (≈40 min).** On the plain (unsanitized) build, in this order:
  1. FT-40 (recorder ON — this is an occlusion-adjacent pass).
  2. FT-41 including variant (e) (recorder ON).
  3. FT-3 tab flip ×5 (recorder ON) — make at least ONE of the five a LONG flip: stay on the map tab 15+ seconds before returning (round 6, counsel F-D6-06: the debrief's double-run check needs a >10 s return to exist in the log). Debrief confirms: no "Perception recon=" line within ~1 s of that long return.
  4. FT-28: screen recorder OFF, camera on 10 minutes of engaged use. Record the HUD metrics line VERBATIM at t=0, 2, 5, 10 min, labeling fps/p95 as scene-update proxies. Follow issue #3 for independent presentation measurements, actual thermal-state capture and the extension to 15 min. PASS requires presented fps ≥30, presented-frame **p95 ≤40 ms** and no serious/critical thermal state; missing evidence stays unmeasured.
  **Historical TTFO note, superseded by issue #3:** build 701a547 had an inverted cold/recovery tag. The earlier instruction that "The NUMBER is measured correctly either way" is withdrawn: the underlying holder-existence measurement does not prove selected-asset readiness or presentation, even after correcting the tag. Preserve those logs as historical placement observations only. Use separate camera epochs, fresh-frame/placeholder/selected-asset milestones and explicitly labeled scene-update proxies; first-presented-hero remains unmeasured without independent visual/presentation evidence.
  5. Touched-path re-runs, recorder ON where a person or occlusion is in frame: FT-9, FT-25, FT-27, FT-29, FT-34, FT-35, FT-36, FT-30.
**S4 · The hour (≈80 min).** FT-31: mild day, 70 minutes of mixed use (walking, editing, idling, pocketing the phone, two deliberate call-banner interruptions, three tab flips past the grace window). Recorder OFF for the hour. Record the HUD line + battery % + warmth every 10 minutes. Then, recorder ON: ten deliberate resume observations (background the app or flip tabs, return, watch the first two seconds) — these are scrubbed frame-by-frame for bar 4. PASS: no thermal banner across the hour; no draw-over frame in any scrubbed resume; the log's attach/detach timeline shows the dwell floor holding on tier-path toggles.
**ADR-035 heat re-measure (rides inside S4, no extra time):** the attach/detach timeline plus the 10-minute thermal/battery readings from the hour are the inputs; the supervisor computes the attached-time vs heat delta from the logarchive to decide whether install-once is now affordable (the recorded ADR-035 number is stale).

**Wave D closes on:** S1 re-verified on the final SHA · S2 zero reports · S3 with FT-40/FT-41/FT-3 all ✓ and FT-28 at p95 ≤ 40 ms with no banner · S4 hour clean with zero draw-over frames across all scrubbed video · bar 1 explicitly re-scoped in the closing ADR (never claimed from these sessions). A failure on FT-40, FT-41, or FT-3 re-opens the wave regardless of every other number.
