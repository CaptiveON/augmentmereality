# PRODUCT-ROUTE.md — the commercial route (Wave 6 → 10)

Governing product plan for the pivot to commercial users. Companion to BRIEF.md (experience
bars) and DECISIONS.md (ADR log). Researched 2026-07-09; sources inline. The user's stated
decisions are law here: **App Clip deferred** (invite link = app download invitation),
receiver reacts from the full app; profiles, public drops, premium objects, auto-capture
profiles are in scope.

---

## 0 · North star and the one loop that matters

**North star:** a delivered moment — someone opens a drop at a place, their reaction is
captured, and the sender keeps it. Everything serves the count of *moments delivered per week*.

**The loop (each step feeds the next):**

```
COMPOSE (sender, paid object optional)
   → INVITE (link out of the app = distribution)
      → REVEAL (receiver installs → watches at the place; sender present live)
         → REACT (one tap; captured)
            → MEMORY (auto-capture keepsake on both profiles)
               → SHARE-OUT (keepsake exported to TikTok/IG/WhatsApp = more distribution)
                  → REPLY ("send one back" = re-entry into COMPOSE)
```

Two arrows leave the app (INVITE, SHARE-OUT) — both must carry the magic with them.
Two arrows re-enter (install, reply) — both must be one tap.

## 1 · Research digest — what the graveyard and the winners teach

**The graveyard (our exact category):** [WallaMe](https://en.wikipedia.org/wiki/WallaMe)
(AR messages hidden at places, 2015–~2021, shut down) and the location-social class
([Yik Yak post-mortem](https://www.failory.com/cemetery/yik-yak)) died from the same three
wounds: (1) **empty-world problem** — location content with no density means most users open
the app to nothing; (2) **no reason to return** after novelty; (3) **abuse/moderation
collapse** once anonymous location content scaled. → Our answers: private drops are the
core (density-independent — your drop is FOR you), public drops are a layer not the base,
and safety tooling ships *with* public drops, not after.

**The flash-in-the-pan class** ([BeReal stats](https://www.charle.co.uk/articles/bereal-statistics/),
[Poparazzi shutdown](https://thedeadpixelssociety.com/poparazzi-photo-sharing-app-shuts-down/)):
BeReal fell from 20M to 6M DAU in ~6 months; Poparazzi topped 5M installs then closed.
Post-mortems converge: **novelty mechanics without reward decay** — "authenticity without
reward is just effort with no return"; no creator/value loop for the people generating the
content. Notably BeReal's *retained* users show 72% daily engagement — the mechanic works,
the growth+reward loops were missing. → Our answers: the sender gets a *keepsake asset*
(reaction capture) every time — an emotional payoff banked on the profile; Wave 9 adds a
creator economy so power users earn.

**The gifting economics** ([TikTok Live gifting](https://www.tubefilter.com/2025/12/02/tiktok-live-ipsos-virtual-gifting-data-study/),
[gift psychology](https://pulse-iq.ca/academy/level-3/gift-economy-explained)): TikTok's
virtual gifts run ~$1B+/quarter of IAP; 60k+ US creators earn part-time income from gifts.
The documented psychology: **gifts are emotional, not transactional — people pay at the
moment of feeling, for connection, with their name attached.** → Premium objects are
occasion-emotional ("her 30th deserves the gold dragon"), purchased at compose time when
feeling is highest; never coins/consumables mechanics in v1.

**Virality mechanics** ([viral loop fundamentals](https://www.reforge.com/guides/discover-viral-growth-loops),
[K-factor](https://getlaunchlist.com/blog/viral-coefficient-k-factor-guide)): K = invites ×
conversion; strongest loops are **pull-product virality** — the product needs the other
person (WhatsApp-class). A drop IS a pull invite: the receiver must come to see *their* gift.
The download wall cuts conversion — mitigation below keeps wow ahead of the wall.

**The download-wall mitigation (platform-verified):**
[AR Quick Look](https://webkit.org/blog/8421/viewing-augmented-reality-assets-in-safari-for-ios/)
renders a USDZ **in AR from a plain Safari link with no app installed** (`rel="ar"`, MIME
`model/vnd.usdz+zip`). The invite page shows the actual object in the receiver's room
*before* the install ask: "This is waiting for you at your gate — get the app to see it
there + react live." Wow first, wall second. (Our objects are already USDZ — zero content
work.) App Clip remains the Wave-10 upgrade of this same page, per the deferral decision.

**App Store compliance (hard gate for public drops)**
([Guideline 1.2](https://developer.apple.com/app-store/review/guidelines/)): UGC apps MUST
ship content filtering, per-item reporting, user blocking, and published support contact —
at review time, not later. Public drops = UGC.

## 2 · The viral engine: the reaction is the asset

The unique thing this app produces that nothing else can: **a captured human reaction to a
giant surprise standing in the real world.** That's the Ring-doorbell/unboxing class of
content — inherently shareable. Everything bends toward making that asset excellent:

- **Auto-capture** (receiver-consented, below): during WATCH/REACT, capture (a) a clean AR
  snapshot of the object in place, (b) an optional 5–10 s front-camera reaction clip,
  (c) the reaction timeline (❤️ at 8 s).
- **The Memory card** composes these into one beautiful keepsake (the mock's stage 5).
- **Share-out engine**: one tap exports a watermarked vertical clip (object reveal + reaction
  + "made with AugmentMeReality" end-card with the sender's invite link) sized for
  TikTok/Reels/WhatsApp. This is the app's *external* growth arrow — optimize it like a product.

## 3 · Feature architecture

### A. Identity & profiles (user ask, refined)
- Sign-in with Apple (mandatory anyway when accounts exist) + display name, avatar, handle.
- **Profile = trophy shelf, not feed**: Moments grid (auto-captures of opened drops, both
  sent and received), reactions received (counts + highlights), places lit up (map of
  delivered moments, privacy-coarse), streak-free (no guilt mechanics — occasion-driven, not
  daily-driven).
- Privacy defaults: profile private; each Memory has per-item visibility (private / friends /
  public); *nothing auto-publishes* — auto-capture ≠ auto-share.

### B. Private drops v1.5 (current flow + decisions)
- Invite = **rich link page**: sender's message + AR Quick Look of the object (pre-install
  wow) + place teaser + App Store button. Deep link (Universal Link) routes post-install
  straight into RECEIVE for that drop — no dead-end first-run.
- Live presence + reactions over the backend's realtime channel; session self-closes into
  Memory (already designed, stage 3–5 of the concept).

### C. Public drops (user ask; the density layer, gated by safety)
- A drop can be published "to this place" — anyone nearby sees it on the map + AR.
- **Sparks map layer**: public drops glow on the map tab; reactions/counts visible.
- Reactions on public drops accrue to the creator's profile (the reward loop the graveyard
  apps lacked).
- Safety design (non-negotiable, ships same wave): per-drop Report + per-user Block wired to
  backend ([1.2](https://developer.apple.com/app-store/review/guidelines/)); text filtered
  through a profanity/PII screen before publish; **exclusion zones** (schools, private
  residences beyond the creator's own — public drops snap to public-place grid, never exact
  home doors); public drops expire by default (72 h) unless renewed; age gate 13+; moderation
  queue in a simple internal web tool.

### D. Reaction capture & consent (user ask; the legal/ethical spine)
- **Consent is a feature, not a dialog**: receiver sees "Adnan will see your reaction live —
  camera clip of your reaction? [Just emoji] [Emoji + clip]" on first reveal; per-sender
  remembered; re-promptable. No silent front-camera capture, ever (store review + trust +
  various two-party consent norms).
- Sender never gets the raw stream — only the composed Memory after the receiver's
  choice is honored. Receiver can delete their clip from the Memory at any time (both sides'
  copies).

### E. Premium objects (user ask; the business)
- **Occasion packs** (birthday deluxe, anniversary, graduation, new-baby, congrats) +
  **hero objects** (the gold dragon, fireworks show, custom-text neon) — non-consumable IAP,
  $1.99–$14.99 ladder; StoreKit 2; family-shareable off.
- Free tier stays genuinely good (current procedural objects) — the paid tier is *more
  unique*, not *less crippled*: exclusivity counters ("only 214 people own this"), seasonal
  rotation (this year's NYE set retires), preview-in-AR before buying.
- Purchased at compose time (the emotional moment — TikTok lesson) with a one-screen buy.
- Later (Wave 9): creator-made objects with rev-share = the missing creator economy;
  requires moderation pipeline for models.
- Anti-goals: no coins, no gambling mechanics (loot boxes), no NFTs.

### F. Features the research adds (the ones you asked me to dig up)
1. **Share-out engine** (§2) — the single highest-leverage growth feature.
2. **Occasion engine** — contacts' birthdays/calendar opt-in → "Sara's birthday in 3 days.
   Drop something at her gate?" Gifting is occasion-driven; this is the retention heartbeat
   (returns users at natural intervals, no streak guilt).
3. **Reply-with-a-drop** — already in the Memory screen; instrument it as a first-class loop.
4. **Trails** — multi-drop sequences (birthday scavenger hunt ending at the cake); premium
   composer feature, deeply shareable captures.
5. **Time capsules** — drops that unlock at a date/time (midnight birthday, anniversary,
   "open when you land"); creates anticipation + scheduled return.
6. **Collab drops** — several friends fund one premium object + each adds a message;
   group-to-one gifting multiplies senders per moment.
7. **Home-screen widget** (Locket's lesson — widget presence drove its growth): latest
   Memory / "a drop is waiting" on the home screen.
8. **Nearby notification** (opt-in, battery-kind): geofence wake when you're near an
   unopened drop addressed to you.

### G. Backend (ADR-006 closes now — accounts force it)
Requirements: auth, profiles, drop store with geo-queries, realtime presence/reactions,
media storage (captures), push (invite nudges, "she's watching now"), purchase receipts,
moderation tooling. **Recommendation: Firebase** (Auth + Firestore w/ geohash + Storage +
FCM + Cloud Functions) — fastest credible path, cross-platform for the Android wave,
generous free tier; Supabase/PostGIS is the fallback if we want SQL/geo purity. Formalize
as ADR-039 with a spike before Wave 6.1 commits.

## 4 · Virality: instrument the loop, then tune it

Track from day one: invites sent per drop · link-open rate · **link→install conversion**
(the wall; AR Quick Look on the invite page is the lever) · reveal completion · reaction
rate · share-out rate per Memory · reply-drop rate. K = invites × conversion; the goal is
K near 1 with paid-zero acquisition — every moment delivered should market the next one.
The share-out clip is the multiplier outside K (non-invite distribution).

## 5 · The route (staged, each wave gated on field metrics)

| Wave | Scope | Gate to next |
|---|---|---|
| **6.1 Foundations** | Firebase spike + ADR-039 · Sign in with Apple · profile v1 · drop sync to cloud | Auth + cloud drops field-tested |
| **6.2 The Loop** | Invite link page (AR Quick Look + Universal Link) · receive flow · live presence + reactions · session close → Memory (the approved 5-screen design, SwiftUI) · consent UX | 10 real sender→receiver moments end-to-end |
| **6.3 Growth arrows** | Share-out engine (watermarked clip) · reply-with-a-drop · widget · occasion engine v1 (birthdays) | share-out rate >20% of Memories |
| **7 Public layer** | Public drops + Sparks map + expiry · full 1.2 safety kit (report/block/filter/queue/exclusion zones) | App Store approval w/ UGC; abuse rate near zero |
| **8 The business** | Premium objects (occasion packs + heroes) · StoreKit 2 · preview-in-AR · collab drops | conversion ≥2% of active senders |
| **9 Depth** | Trails · time capsules · creator objects beta (rev-share) | creator supply w/o moderation debt |
| **10 Reach** | **App Clip** (per deferral) — invite page upgrades to instant AR at the place · Android (BRIEF mandate) | — |

AR quality work (killers 1–3, FT suite) continues underneath every wave — the engine is the
product's floor; this route is its ceiling.

## 6 · Risks & anti-goals
- **Empty-world**: never let public density be the pitch; private moments carry the app.
- **Creep factor**: location + camera + recording = handle consent/photos of bystanders
  conservatively; public drops never at private homes; captures default private.
- **Novelty decay**: the occasion engine + premium refresh are the counter; measure
  8-week sender retention as the truth metric.
- **Scope**: no chat/DMs (WhatsApp exists — deep-link out), no feed-scrolling product, no
  streaks, no coins/NFTs, App Clip stays deferred until the loop proves itself.
