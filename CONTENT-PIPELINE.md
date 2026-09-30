# CONTENT-PIPELINE.md — the launch object catalog (ADR-046)

How we source, prepare, and QA the prebuilt 3D objects. Read with PRODUCT-ROUTE §3E
(premium objects). Rule zero: **"unique" and "free marketplace download" are opposites**
— anything downloadable by everyone will be seen everywhere. Uniqueness comes from
tiers 1–3; marketplaces are filler only.

## Object spec (hard budgets)

Runtime update, September 29: physical content keeps authored dimensions at every
viewing distance. The independent discovery marker carries distance readability.
Selected/current content prepares on demand; there is no whole-catalog preload.
One decoder, eight queued identifiers, and a three-template / 24 MiB source-cost
cache bound preparation. The September 30 runtime adds one shared geographic
and Room Test limit: normally 8 full models plus 24 cues, with a 64 MiB aggregate
compressed-source proxy and reduced thermal/memory-pressure limits. Generated
AR text is capped at 160 Unicode scalars without changing the saved message.
Source cost is not decoded RAM, and these runtime compatibility caps do not
relax the authoring targets below. Asset geometry optimization, rights and
explicit grounded/animated behavior still need the #15/#20 gates. See ADR-056
and the [scene budget](Scene-Content-Budget-2026-09-30.md).

| Property | Budget | Why |
|---|---|---|
| File size | ≤ 5 MB (hero ≤ 10 MB) | app size, load time |
| Triangles | ≤ 50 k (hero ≤ 100 k) | A12-class devices must hold 30 fps |
| Textures | ≤ 2048², 1–2 maps | memory |
| Format | USDZ (converted from GLB) | RealityKit runtime |
| Pivot | base of object, y=0 | factory normalizes but base must be sane |
| Front | faces +Z | facing picker points +Z at the viewer |
| Animation | looping idle baked in, OR none | static models get the ADR-046 effects layer |

## Tier 1 — Procedural + the effects layer (0 MB, fully ours)

Already shipped: text/balloons/gift/heart/beacon + **DropEffects** (sparkle aura,
reveal burst, idle bob/spin). Every static object becomes "animated" for free.
Grow this tier: procedural fireworks show, floating lantern swarm, neon frames —
pure code, zero size, impossible to rip from a marketplace.

## Tier 2 — AI-generated (unique by construction)

- **HiggsField (MCP already connected):** `generate_image` (concept in our Night/
  celebration style) → `generate_3d` (image → GLB mesh). Static output → effects
  layer supplies motion.
- **Meshy / Tripo** (text→3D, auto-rig + animation presets like dance/wave —
  good for character-class gifts). Export GLB.
- Style prompt base: "stylized low-poly celebration object, warm gold+coral palette,
  soft rounded forms, clean silhouette, no text, single object on empty background".
- AI output is a DRAFT: always run the prep checklist; regenerate until silhouette
  reads at 50 m.

## Tier 3 — Commissioned (the premium/hero moat)

Fiverr/Upwork stylized-3D artists, ~$80–300 per animated object, full rights buyout.
Launch heroes worth commissioning: golden dragon (premium), fireworks cake, neon
"marquee" letter set, gift-explosion box. **Brief template:**
> Stylized low-poly [object], warm gold (#FFC857) + coral (#FF4D6D) accents, reads
> clearly from 50 m (strong silhouette), ≤50k tris, ≤2048 textures (baked lighting
> ok), pivot at base, front = +Z, one seamless idle loop 3–6 s baked in, deliver
> GLB + source. Full commercial rights transfer.

## Tier 4 — Curated marketplace filler (restyle mandatory)

Sketchfab (filter: downloadable + animated, license CC0 or CC-BY — **CC-BY needs
in-app credits screen**), Quaternius/Kenney (CC0 packs), Fab/CGTrader (paid royalty
licenses — check "app distribution" clause). Never ship as-is: recolor to palette,
recompose, add effects layer, so it doesn't look stock. Never use "editorial-only".

## Prepare: GLB → shipping USDZ

1. Convert: **Reality Converter** (free, Apple) — drag GLB in, export USDZ.
   Check animations play in the preview. CLI alternative: `usdzconvert`.
2. If over budget: Blender → Decimate modifier to tri budget, resize textures,
   re-export GLB, reconvert.
3. Name it well (`golden_dragon.usdz` — the name shows in pickers), drop into
   `AugmentMeReality/Assets3D/`, rebuild. Zero wiring (ADR-021).
4. QA in **Room Test**: silhouette at 2 m and (outdoors) 50 m · idle motion or baked
   loop plays · aura/burst look right against the model · fps steady on device ·
   occlusion behaves (walk behind furniture).

## Launch catalog target (12–16 objects)

- **Free tier (6–8):** current procedurals + 2–3 AI-generated (confetti crown,
  balloon arch, star shower) — genuinely good, not crippled.
- **Premium (6–8, $1.99–$14.99):** commissioned heroes (dragon, fireworks cake,
  marquee letters, gift explosion) + occasion packs (birthday deluxe, anniversary,
  graduation, new-baby). Scarcity counter + seasonal retirement per PRODUCT-ROUTE.
- Replace the Apple sample models (toy_drummer, hummingbird) before submission —
  they're dev-license only.
