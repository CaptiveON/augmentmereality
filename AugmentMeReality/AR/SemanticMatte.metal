#include <metal_stdlib>
using namespace metal;

// SilhouetteRefiner v2 (ADR-018) + custom person occlusion (ADR-030). One pass
// composites two occluders into a single matte that restores the camera image
// over virtual content:
//   1. VPS Scene Semantics building/tree/structure, per-pixel depth-gated (far).
//   2. People: the high-res ARKit person stencil, edge-snapped to the camera luma
//      with a joint-bilateral (guided) filter, depth-tested against LiDAR scene
//      depth, then temporally EMA-smoothed and soft-feathered.
// The guided-filter step is the fix for ARKit's blurry 256×192 people occlusion:
// the stencil edge is pulled onto the true silhouette using the sharp luma image.

struct MatteUniforms {
    float3x3 viewToCapture;   // normalized view UV -> normalized capture UV
    float3x3 captureToSemantic;
    float3x3 captureToPerson;
    float3x3 personToCapture;
    float3x3 captureToDepth;
    float3x3 captureToMid;
    float attackAlpha;        // temporal response, matte appearing (occluder arrives)
    float releaseAlpha;       // …matte clearing (occluder leaves) — fast, no trail
    float debugTint;          // >0.5 tints matte red instead of restoring camera
    float projZZ;             // projection.columns.2.z
    float projZW;             // projection.columns.3.z
    float projWSign;          // projection.columns.2.w (−1 for RH cameras)
    float distTree;           // content deeper than this behind a tree pixel is matted
    float distBuilding;       // …behind a building/structure pixel
    float personEnabled;      // >0.5 when stencil + scene depth are bound
    float semanticEnabled;    // >0.5 when VPS labels are bound (far mode)
    float depthBias;          // real must be this much nearer (m) to occlude
    float edgeInner;          // smoothstep remap: coverage below this → 0 (erode)
    float edgeOuter;          // …above this → 1 (sharpen)
    float midEnabled;         // >0.5 when an aligned mid-field sample is bound
    float midA;               // ADR-031: 1/metric ≈ midA·rel + midB
    float midB;
    float midMinContent;      // content nearer than this is LiDAR/mesh territory
    float midMaxDepth;        // aligned depth beyond this is untrusted (per-fit:
                              // the LiDAR reference band + margin, counsel MATH-1)
    float midRelBias;         // required margin as fraction of content distance
    float midRelMin;          // MATH-1 input support: model outputs outside
    float midRelMax;          // [midRelMin, midRelMax] were never calibrated
    float contentFarPlane;    // MATH-2: metric presence boundary, derived per
                              // frame from the projection itself (meters)
    float historyValid;       // Wave D R2 (RENDER-2): 0 on the first encode
                              // after (re)allocating the matte history — the
                              // textures are .private and UNDEFINED; a NaN
                              // seed is absorbing under mix()
    int   refineRadius;       // guided-filter half-window (px); 0 = raw stencil
    uint labelBuilding;
    uint labelTree;
    uint labelStructure;
};

constexpr sampler bilinearSampler(filter::linear, address::clamp_to_edge);
constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);

static inline bool covered(float2 uv) {
    return all(isfinite(uv)) && all(uv >= 0.0) && all(uv <= 1.0);
}

// Camera YCbCr -> RGB (video-range matrix, per Apple's ARKit Metal sample).
static inline float3 cameraRGB(float y, float2 cbcr) {
    const float4x4 transform = float4x4(
        float4(+1.0000f, +1.0000f, +1.0000f, +0.0000f),
        float4(+0.0000f, -0.3441f, +1.7720f, +0.0000f),
        float4(+1.4020f, -0.7141f, +0.0000f, +0.0000f),
        float4(-0.7010f, +0.5291f, -0.8860f, +1.0000f));
    float4 rgba = transform * float4(y, cbcr.x, cbcr.y, 1.0);
    return clamp(rgba.rgb, 0.0, 1.0);
}

kernel void semanticMatte(
    texture2d<half, access::read> sourceColor      [[texture(0)]],
    depth2d<float, access::read>  sourceDepth      [[texture(1)]],
    texture2d<half, access::write> targetColor     [[texture(2)]],
    texture2d<float, access::sample> capturedY     [[texture(3)]],
    texture2d<float, access::sample> capturedCbCr  [[texture(4)]],
    texture2d<uint, access::read> semanticLabels   [[texture(5)]],
    texture2d<float, access::sample> semanticConf  [[texture(6)]],
    texture2d<float, access::read> previousMatte   [[texture(7)]],
    texture2d<float, access::write> nextMatte      [[texture(8)]],
    texture2d<float, access::sample> personStencil [[texture(9)]],
    texture2d<float, access::sample> sceneDepthTex [[texture(10)]],
    texture2d<float, access::sample> midDepthTex   [[texture(11)]],
    constant MatteUniforms &uniforms               [[buffer(0)]],
    uint2 gid                                      [[thread_position_in_grid]])
{
    const uint width = targetColor.get_width();
    const uint height = targetColor.get_height();
    if (gid.x >= width || gid.y >= height) { return; }

    half4 color = sourceColor.read(gid);

    float2 viewUV = (float2(gid) + 0.5) / float2(width, height);
    float3 mapped = uniforms.viewToCapture * float3(viewUV, 1.0);
    float2 captureUV = mapped.xy / mapped.z;
    // Unknown coverage is no matte, never a border pixel expanded by clamping.
    if (!covered(captureUV)) {
        nextMatte.write(float4(0.0), gid);
        targetColor.write(color, gid);
        return;
    }
    float2 semanticUV = (uniforms.captureToSemantic * float3(captureUV, 1.0)).xy;
    float2 personUV = (uniforms.captureToPerson * float3(captureUV, 1.0)).xy;
    float2 sceneUV = (uniforms.captureToDepth * float3(captureUV, 1.0)).xy;
    float2 midUV = (uniforms.captureToMid * float3(captureUV, 1.0)).xy;

    // Content presence + metric eye depth (shared by both occluders).
    // Counsel MATH-2: the old test was a fixed 1e-6 epsilon in nonlinear NDC,
    // written to accept both clear conventions — which also rejected real far
    // content (the boundary landed at ~500 m, inside the transit band). Decode
    // to METERS first, then test against the frame's own near/far boundaries
    // (derived CPU-side from the same projection): cleared pixels decode to the
    // far plane (forward-Z) or to non-finite/zero (reverse-Z infinite), so one
    // metric test covers both conventions with no magic epsilon.
    float depth = sourceDepth.read(gid);
    //   clip.z = zz·z_eye + zw, clip.w = wSign·z_eye  ⇒  d = zw/(zz − depth·wSign)
    float denom = uniforms.projZZ - depth * uniforms.projWSign;
    float contentDistance = (fabs(denom) > 1e-9) ? uniforms.projZW / denom : 0.0;
    bool distanceValid = isfinite(contentDistance)
        && contentDistance > 0.02
        && contentDistance < uniforms.contentFarPlane;

    // Instantaneous matte for this frame (max of the two occluders).
    float matte = 0.0;

    // --- (1) VPS semantic building/tree matte (ADR-018) ---
    if (uniforms.semanticEnabled > 0.5 && distanceValid && covered(semanticUV)) {
        uint2 labelSize = uint2(semanticLabels.get_width(), semanticLabels.get_height());
        uint2 labelPixel = min(uint2(semanticUV * float2(labelSize)), labelSize - 1);
        uint label = semanticLabels.read(labelPixel).r;
        // Per-pixel distance gate: a labeled real surface occludes only content
        // far enough behind it to be near-certainly farther than the surface.
        // A bad depth decode fails to matte-off (draw-over), never eats near content.
        bool occluding = false;
        if (label == uniforms.labelTree) {
            occluding = contentDistance > uniforms.distTree;
        } else if (label == uniforms.labelBuilding
                   || label == uniforms.labelStructure) {
            occluding = contentDistance > uniforms.distBuilding;
        }
        if (occluding) {
            matte = semanticConf.sample(bilinearSampler, semanticUV).r;
        }
    }

    // --- (2) Person occlusion with guided-filter edge refinement (ADR-030) ---
    if (uniforms.personEnabled > 0.5 && distanceValid && covered(personUV) && covered(sceneUV)) {
        // Conservative far-depth test (FT-27 round 2, "holes between fingers"):
        // bilinear sampling of the 256×192 depth blended finger-gap pixels toward
        // finger depth, so gaps occluded the object and showed background. Take
        // the FARTHEST of the 4 surrounding depth texels instead — if any of them
        // sees through the gap, the object stays. Bias stays toward
        // under-coverage: a sliver of object on the finger edge beats a hole.
        float2 dTexel = 1.0 / float2(sceneDepthTex.get_width(),
                                     sceneDepthTex.get_height());
        float sceneFar = 0.0;
        bool sceneCovered = true;
        for (int oy = -1; oy <= 1; oy += 2) {
            for (int ox = -1; ox <= 1; ox += 2) {
                float2 uv = sceneUV + float2(ox, oy) * 0.5 * dTexel;
                if (!covered(uv)) { sceneCovered = false; continue; }
                float d = sceneDepthTex.sample(nearestSampler, uv).r;
                if (!isfinite(d) || d <= 0.0) { sceneCovered = false; continue; }
                sceneFar = max(sceneFar, d);
            }
        }
        if (sceneCovered && sceneFar > 0.05 && sceneFar < contentDistance - uniforms.depthBias) {
            float personMatte;
            int R = uniforms.refineRadius;
            // ADR-034 early-out: the 50-taps-per-pixel guided filter only earns
            // its cost at the silhouette. Deep inside/outside the stencil the
            // answer is already known — with large content on screen this skips
            // ~95% of pixels and most of the pass's GPU wattage.
            float centreStencil = personStencil.sample(bilinearSampler, personUV).r;
            if (R <= 0) {
                personMatte = centreStencil;
            } else if (centreStencil < 0.02) {
                personMatte = 0.0;
            } else if (centreStencil > 0.98) {
                float2 corner = float2(R) / float2(personStencil.get_width(),
                                                   personStencil.get_height());
                float c0 = personStencil.sample(bilinearSampler, personUV + corner).r;
                float c1 = personStencil.sample(bilinearSampler, personUV - corner).r;
                float c2 = personStencil.sample(bilinearSampler,
                                                personUV + float2(corner.x, -corner.y)).r;
                float c3 = personStencil.sample(bilinearSampler,
                                                personUV + float2(-corner.x, corner.y)).r;
                bool cornersCovered = covered(personUV + corner) && covered(personUV - corner)
                    && covered(personUV + float2(corner.x, -corner.y))
                    && covered(personUV + float2(-corner.x, corner.y));
                if (cornersCovered && min(min(c0, c1), min(c2, c3)) > 0.98) {
                    personMatte = 1.0;
                } else {
                    personMatte = -1.0; // sentinel: edge band, run the filter
                }
            } else {
                personMatte = -1.0;
            }
            if (personMatte < 0.0) {
                // Joint-bilateral (guided) upsample: snap the stencil edge onto the
                // true silhouette using the sharp camera luma as the guide. Weight
                // each neighbour by luma similarity to the centre × spatial falloff.
                float2 step = 1.0 / float2(personStencil.get_width(),
                                           personStencil.get_height());
                float centreLuma = capturedY.sample(bilinearSampler, captureUV).r;
                float msum = 0.0, wsum = 0.0;
                for (int dy = -R; dy <= R; dy++) {
                    for (int dx = -R; dx <= R; dx++) {
                        float2 uv = personUV + float2(dx, dy) * step;
                        float2 imageUV = (uniforms.personToCapture * float3(uv, 1.0)).xy;
                        if (!covered(uv) || !covered(imageUV)) { continue; }
                        float s = personStencil.sample(bilinearSampler, uv).r;
                        float luma = capturedY.sample(bilinearSampler, imageUV).r;
                        float dl = luma - centreLuma;
                        float wl = exp(-dl * dl * 30.0);           // luma range term
                        float ws = exp(-float(dx*dx + dy*dy)
                                       / (2.0 * float(R*R) + 1.0)); // spatial term
                        float w = wl * ws;
                        msum += w * s;
                        wsum += w;
                    }
                }
                personMatte = (wsum > 0.0) ? msum / wsum : 0.0;
            }
            // Erode + sharpen (FT-27 "gap between hand and object"): ARKit's
            // stencil over-covers, and every extra pixel restores background where
            // the object should be. Remap so partial coverage collapses to 0 —
            // under-coverage (a sliver of object on the hand edge) reads as a soft
            // edge; over-coverage reads as a broken object.
            personMatte = smoothstep(uniforms.edgeInner, uniforms.edgeOuter, personMatte);
            matte = max(matte, personMatte);
        }
    }

    // --- (3) LiDAR-aligned neural depth: ordering only within per-fit support ---
    if (uniforms.midEnabled > 0.5 && distanceValid && covered(midUV)
        && contentDistance > uniforms.midMinContent) {
        float rel = midDepthTex.sample(bilinearSampler, midUV).r;
        float inv = uniforms.midA * rel + uniforms.midB;
        // MATH-1: only interpolate. A model output outside the band the LiDAR
        // reference spanned was never calibrated — decoding it is extrapolation
        // (sky at rel≈0 once decoded to a hallucinated 5 m wall that ate far
        // content). Unknown means no matte, never a surface.
        bool inSupport = rel >= uniforms.midRelMin && rel <= uniforms.midRelMax;
        if (inSupport && isfinite(inv) && inv > 1.0 / uniforms.midMaxDepth) {
            float metric = 1.0 / inv;
            // Below ~3 m LiDAR/mesh/person own occlusion; above, require the
            // surface to be nearer by a distance-proportional margin (monocular
            // error grows with range), feathered across the margin for a soft,
            // honest edge instead of a hard guess.
            if (metric > 3.0) {
                float margin = max(0.5, uniforms.midRelBias * contentDistance);
                float occl = smoothstep(margin * 0.5, margin * 1.5,
                                        contentDistance - metric);
                matte = max(matte, occl);
            }
        }
    }

    // Asymmetric temporal smoothing (SilhouetteRefiner): enough memory to kill
    // single-frame stencil noise, but a fast release — a slow decay left a trail
    // of restored background behind a moving hand (FT-27's gap).
    // Wave D R2 (RENDER-2): the history read is GATED, not isfinite-checked —
    // fast-math may fold isfinite away, and a NaN/Inf seed from the undefined
    // .private allocation is absorbing under mix(). Seeding from the current
    // matte also removes the EMA ramp after every resize.
    float previous = (uniforms.historyValid > 0.5)
        ? previousMatte.read(gid).r : matte;
    float alpha = (matte >= previous) ? uniforms.attackAlpha : uniforms.releaseAlpha;
    float smoothed = mix(previous, matte, alpha);
    nextMatte.write(float4(smoothed), gid);

    if (smoothed > 0.01) {
        if (uniforms.debugTint > 0.5) {
            color.rgb = mix(color.rgb, half3(1.0, 0.1, 0.1), half(smoothed) * 0.6h);
        } else {
            float y = capturedY.sample(bilinearSampler, captureUV).r;
            float2 cbcr = capturedCbCr.sample(bilinearSampler, captureUV).rg;
            float3 gammaRGB = cameraRGB(y, cbcr);
            // The render target is linear; camera RGB is gamma-encoded.
            half3 linearRGB = half3(pow(gammaRGB, 2.2));
            color.rgb = mix(color.rgb, linearRGB, half(smoothed));
        }
    }

    targetColor.write(color, gid);
}
