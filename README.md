# AugmentMeReality 🎈

Pin virtual 3D surprises (giant birthday text, balloons, gifts, hearts…) to real-world
places from a map — then anyone who goes there and opens the AR camera sees them floating
in the real world.

See [MASTERPLAN.md](MASTERPLAN.md) for the research, architecture, and the full feature
roadmap (Waves 1–6). Waves 1–3 are implemented in this repo.

## Run it

1. Open `AugmentMeReality.xcodeproj` in Xcode 16 or newer.
2. Select the **AugmentMeReality** target → *Signing & Capabilities* → pick your Team
   (a free Apple ID works for on-device development).
3. Plug in an iPhone (iOS 17+, A12 chip or newer) and hit **Run**.
   AR world tracking does not work in the Simulator — the Map and My Drops tabs do.
4. Allow **camera** and **location** access when prompted.

## Try the birthday scenario

1. **Map tab** → search your friend's address (or tap anywhere on the map).
2. Compose the drop: *3D Text*, message `HAPPY BIRTHDAY SARA! 🎂`, size ~5× (≈3 m letters),
   floating 4 m above the ground, pick a color → **Place it here**.
3. At the location, open the **Camera tab**: the text appears anchored in the real world.
   The HUD shows distance + a direction arrow until it's in view.
4. Impatient? Tap **"Demo: text 15 m ahead"** in the camera to see one instantly.

## Street-accurate precision (Wave 4 — VPS, strongly recommended)

The app ships with Google's ARCore Geospatial support built in: ~1–5 m placement
accuracy + occlusion by real buildings, anywhere Street View exists. It activates the
moment you add an API key (free, generous quota):

1. Go to [Google Cloud Console](https://console.cloud.google.com) → create a project
   (or reuse one).
2. *APIs & Services → Library* → search **"ARCore API"** → **Enable**.
3. *APIs & Services → Credentials* → **Create credentials → API key**. Recommended:
   restrict the key to iOS apps with bundle ID `com.adnan.augmentmereality`, and to the
   ARCore API only.
4. Copy `AugmentMeReality/Support/Secrets.sample.plist` to `Secrets.plist` (same
   folder), paste the key inside, and rebuild. `Secrets.plist` is gitignored so the
   key never lands in source control.

In the AR HUD you'll see a chip go from "VPS searching…" (point the camera at
buildings across the street) to **"VPS ±1.x m"** — at that moment drops glide to their
exact real-world spots, terrain height comes from Google's Earth model, and nearby
building meshes silently occlude content behind them.

## How placement works (short version)

- Everywhere: session axes are aligned to gravity + true north, and drops are placed at
  their east/north offset in meters from your GPS fix (~5–15 m accuracy — make it big).
- In [Apple-supported cities](https://developer.apple.com/documentation/arkit/argeotrackingconfiguration),
  the app automatically upgrades to `ARGeoAnchor` precise tracking (camera is matched
  against street imagery).
- Wave 4 adds Google's ARCore Geospatial API for ~1–5 m accuracy in 87+ countries.

## Adding animated 3D models (ADR-021)

Drop any `.usdz` file into `AugmentMeReality/Assets3D/` and rebuild — it appears in the
composer under **Animated 3D → Model** automatically (no project-file edits). All
animations inside the file auto-play on loop; models are auto-normalized so the Size
slider means "largest side ≈ N meters".

Where to get animated USDZ:
- **Apple AR Quick Look gallery** — free animated samples, USDZ-native:
  https://developer.apple.com/augmented-reality/quick-look/ (two are bundled:
  `toy_drummer`, `hummingbird` — dev/demo use only, replace before shipping).
- **Sketchfab** (filter: Animated + Downloadable, license CC0/CC-BY) — downloads as
  glTF; convert with Apple **Reality Converter**.
- **Mixamo** (free, Adobe) — rigged + animated characters, FBX; convert with Reality
  Converter.
- **Reality Composer / Reality Composer Pro** (ships with Xcode) — build your own,
  exports USDZ directly.

Only USDZ loads at runtime on iOS — convert glTF/FBX/OBJ on the Mac first
(Reality Converter, or `usdzconvert` from Apple's USD tools). Check licenses:
CC-BY needs in-app attribution; "editorial use" assets can't ship in a product.

## Cloud sync & accounts (Wave 6.1 — Firebase, ADR-039)

The app runs fully local until Firebase is configured. To light it up:

1. [console.firebase.google.com](https://console.firebase.google.com) → **Add project**
   (name it anything; Analytics optional/off is fine).
2. In the project: **Add app → iOS**, bundle ID `com.adnan.augmentmereality`.
3. Download **GoogleService-Info.plist** → put it in `AugmentMeReality/Support/`
   (it's gitignored, same as Secrets.plist).
4. Console → **Build → Authentication → Sign-in method → Anonymous → Enable**.
5. Create the Firestore database in production mode. Use the reviewed
   [rules candidate](web/firestore.rules) and the
   [release verification/runbook](web/FIRESTORE-RELEASE.md). The former README v2
   rules permitted cross-owner overwrite and shared-document enumeration and
   must not be copied into a new project.
6. Rebuild with the intended Firebase configuration. Cloud state must be earned
   from acknowledged operations; configuring Firebase alone does not establish
   synchronization or cross-device account recovery.

The deployment target is recorded without credentials in
[firestore-target.json](web/firestore-target.json). Local emulator results describe
candidate/historical fixtures, not the active backend. Use the read-only verifier
to capture a dated release ID and source hash before and after an authorized rollout.

## Sharing drops with everyone (Wave 3, flag-gated)

Out of the box, drops are stored locally on your device (JSON). To make every user see
every drop via CloudKit's free public database:

1. You need a **paid Apple Developer Program team**.
2. In Xcode: target → *Signing & Capabilities* → **+ Capability** → *iCloud* →
   check **CloudKit** → add container `iCloud.com.adnan.augmentmereality`
   (or your own — then update `AppConfig.cloudKitContainerID`).
3. Set `AppConfig.cloudKitEnabled = true` in
   [AppConfig.swift](AugmentMeReality/App/AppConfig.swift).
4. First run creates the `GeoDrop` record type in development; before shipping, deploy
   the schema to Production in the [CloudKit Console](https://icloud.developer.apple.com)
   and add an index on `location` (queryable) plus `recordName` (queryable).

## Project layout

```
AugmentMeReality/
├── App/        entry point, root tabs, feature flags
├── Models/     GeoDrop (the pinned-content model)
├── Services/   location, geo math, local + CloudKit stores
├── Map/        map screen, address search, drop composer
├── AR/         AR camera, placement engine, procedural 3D content
└── Drops/      list of placed drops
```
