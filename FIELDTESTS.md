# FIELDTESTS.md — the on-device protocol (v0.9)

A wave is done when these pass **in the field**, not when the build succeeds. Every test
says what to do, what to record (the HUD is the instrument — screenshot it), and the pass
bar. Run what fits your situation; FT-numbers make reporting one-liners:
*"FT-3: 0 ms ✓, FT-7: Σ 14 cm ✓, FT-12 failed — text visible through the building."*

**HUD legend:** mode badge · "N in view range" · `LiDAR` `VPS ±x m` `SEM` `TRANSIT` chips ·
status line · cyan "Rendered X m ahead · Y up" · `first object: X ms · fps · p95` ·
`vps corrections Σ cm`.

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
(should sit ~30, steady), whether it's warmer/cooler than before, and any `Device is hot`
warning. **Pass:** steady ~30 fps, no thermal warning on a mild day.

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

**FT-33 · Apparent size vs distance (ADR-049).** Place a drop of known height (scale-3
text ≈ 1.8 m), then view it from ~15 m, ~50 m, and ~150 m. The HUD metrics line now
appends the rendered angular size and the perceptual factor (e.g. `· 1.9° ×2.3`).
**Record:** at each distance, the readout pair + one screenshot. **Pass:** (1) the
degree number matches 2·atan(h/2d)·(factor folded in) within ~10 %; (2) the object
still clearly GROWS while walking toward it and never pops; (3) the gut-check — "a
giant far away," not "a toy nearby" and not "a sticker pinned to the scene." If the
gut-check fails, tune `perceptualBeta` (0.25–0.45) / `perceptualCap` in AppConfig
before touching any other code.

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
sliding"; panning feels like looking past real landmarks. **Record:** fps (bar ≥30).

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
minute 10, and whether the thermal warning appeared. **Pass:** no `Device is hot`
warning on a mild day; fps ≥ 30 throughout.

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
