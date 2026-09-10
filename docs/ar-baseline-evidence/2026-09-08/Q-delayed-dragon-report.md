# AR baseline result

Run: F3301204-B73F-41A0-929D-A7F6752578BF

**Presentation and warmth are not inferred from callback or thermal measurements.**

| Build / condition | Value |
| --- | --- |
| build_source_commit | b45f43725166c156dfd69a8f871660d665f35923 |
| build_source_hash | 75992526eb10083c53fe86dd92c490f29d6268fa54e50d5065ef28ad97ca8250 |
| build_source_dirty | false |
| build_configuration | Release |
| device_machine | iPhone16,2 |
| os | Version 26.6 (Build 23G71) |
| experiment | disabled=assetPreload; delayedAsset=DragonAnim; delaySeconds=3.0; missingAsset=none; heroSource=roomDrop |
| asset | DragonAnim |
| distance_meters | unmeasured |
| brightness | unmeasured |
| charging | USB-quality |
| observed_warmth | not measured; hot-state HUD visible; separate quality run |
| initially_cool | False |
| screen_recording | True |
| raw_trace_locations | ['runs/quality/Q-delayed-dragon.trace', 'runs/quality/Q-delayed-dragon.mov'] |
| build_manifest | builds/Q/build-manifest.json |

Thermal-run eligibility: **unmeasured / not eligible** until screen recording is confirmed off.

Targets: ≥30 presented FPS; presented p95 ≤40 ms; no serious/critical thermal state through 10 minutes; observation through 15 minutes.

Actual presentation: **unmeasured**. Scene/postprocess statistics below are proxies.

Full-epoch percentiles are conservative 1 ms histogram upper bounds; overflow above 1000 ms remains explicit. Startup/recent percentiles use nearest rank.

## Epoch 1 · pre_camera · generation 0

Duration: 21.07 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| cameraIntent | unmeasured | unmeasured |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | unmeasured | unmeasured |
| firstFreshCameraFrameObserved | unmeasured | unmeasured |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | unmeasured | unmeasured |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| ARView prepare.duration | 1 | 214.08 | unmeasured | 215.00 | 215.00 | 0 | 214.08 | 214.08 | 159939.96 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 10.01 | serious | 116998144 | 1.83 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 2 · coldStart · generation 1

Duration: 61.30 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | DragonAnim |
| condition: batteryFraction | — | 0.95 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.9779564 |
| condition: heroID | — | DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 |
| condition: initialThermalState | — | 2 |
| cameraIntent | 0.58 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 4279.97 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 asset=DragonAnim source=roomSelection |
| firstFreshCameraFrameObserved | 283.46 | captureUptime=1967003.053476375 |
| placeholderPlaced | 4285.45 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 |
| selectedAssetReady | 15925.21 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 |
| firstHeroSceneUpdateProxy | 15925.26 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 ms=15925; presentation unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Asset decode latency.duration | 1 | 8604.55 | unmeasured | unmeasured | unmeasured | 1 | unmeasured | 8604.55 | 123282.55 |
| Capture delivery observation.duration | 1830 | 0.01 | unmeasured | 1.00 | 1.00 | 0 | 0.03 | 0.03 | 77905.59 |
| GAR update.duration | 359 | 1.18 | unmeasured | 3.00 | 4.00 | 0 | 8.43 | 2.59 | 77986.04 |
| GAR update.interval | 358 | 170.20 | 5.88 | 533.00 | 535.00 | 0 | 534.07 | 532.40 | 77986.81 |
| Person sentinel buffer hold.duration | 118 | 9.76 | unmeasured | 15.00 | 15.00 | 0 | 87.32 | 14.25 | 78400.97 |
| Person sentinel inference.duration | 118 | 9.57 | unmeasured | 15.00 | 15.00 | 0 | 87.00 | 14.04 | 78401.01 |
| Person sentinel inference.interval | 117 | 514.85 | 1.94 | 534.00 | 535.00 | 0 | 533.08 | 533.40 | 78406.46 |
| Postprocess CPU encode.duration | 1029 | 0.04 | unmeasured | 1.00 | 1.00 | 0 | unmeasured | 0.07 | 77932.70 |
| Postprocess blit fallback.interval | 1028 | 25.65 | 38.98 | 38.00 | 50.00 | 0 | unmeasured | 37.26 | 77932.71 |
| Postprocess callback proxy.interval | 1028 | 25.65 | 38.98 | 38.00 | 50.00 | 0 | unmeasured | 37.26 | 77932.72 |
| Postprocess command buffer GPU | 1029 | 1.14 | unmeasured | 2.00 | 2.00 | 0 | unmeasured | 1.37 | 77923.31 |
| Scene update elapsed.duration | 2075 | 0.40 | unmeasured | 2.00 | 4.00 | 0 | 2.33 | 1.99 | 77935.58 |
| Semantic pipeline prepare.duration | 1 | 1.38 | unmeasured | 2.00 | 2.00 | 0 | unmeasured | 1.38 | 104305.11 |
| Session configuration.duration | 2 | 0.10 | unmeasured | 1.00 | 1.00 | 0 | 0.12 | 0.12 | 139124.91 |
| captureDelivery.interval | 1829 | 33.36 | 29.98 | 51.00 | 60.00 | 0 | 37.12 | 50.08 | 77905.59 |
| captureSampleAge | 1830 | 63.12 | unmeasured | 82.00 | 83.00 | 0 | 60.04 | 81.36 | 77905.59 |
| captureTimestamp.interval | 1829 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 77971.58 |
| sceneUpdateProxy.interval | 2074 | 29.49 | 33.91 | 37.00 | 49.00 | 0 | 37.43 | 36.23 | 77935.62 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 8.60 | 2 |
| GAR semantics | True | 60.35 | 2 |
| GAR session | True | 61.24 | 1 |
| Semantic postprocess | True | 26.41 | 1 |
| cameraSessionRunning | True | 61.26 | 1 |
| cameraVisible | False | 61.30 | 2 |
| personSegmentationRequested | False | 0.00 | 1 |
| reconstructionRequested | True | 61.22 | 2 |
| sceneDepthRequested | False | 0.00 | 1 |

Process CPU seconds across retained system samples: 42.11 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | serious | 124600320 | 2.53 |
| 10.22 | serious | 440893440 | 11.09 |
| 18.94 | serious | 453083136 | 17.85 |
| 20.62 | serious | 456900608 | 19.22 |
| 31.03 | serious | 457555968 | 27.35 |
| 41.21 | fair | 461766656 | 35.92 |
| 48.94 | fair | 462503936 | 42.55 |
| 51.35 | fair | 462635008 | 44.64 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 3 · cameraInactive · generation 1

Duration: 1.03 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| cameraIntent | unmeasured | unmeasured |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | unmeasured | unmeasured |
| firstFreshCameraFrameObserved | unmeasured | unmeasured |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | unmeasured | unmeasured |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 31 | 0.04 | unmeasured | 1.00 | 1.00 | 0 | 0.16 | 0.16 | 76887.13 |
| GAR update.duration | 1 | 3.35 | unmeasured | 4.00 | 4.00 | 0 | 3.35 | 3.35 | 77180.50 |
| GAR update.interval | 0 | unmeasured | unmeasured | unmeasured | unmeasured | 0 | unmeasured | unmeasured | unmeasured |
| captureDelivery.interval | 30 | 33.33 | 30.00 | 35.00 | 37.00 | 0 | 34.72 | 34.72 | 76887.14 |
| captureSampleAge | 31 | 51.35 | unmeasured | 53.00 | 55.00 | 0 | 52.74 | 52.74 | 76887.13 |
| captureTimestamp.interval | 28 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 76938.18 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 1.03 | 0 |
| GAR session | True | 1.03 | 0 |
| Semantic postprocess | True | 1.03 | 0 |
| cameraSessionRunning | True | 1.03 | 0 |
| cameraVisible | False | 0.00 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | True | 1.03 | 0 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.30 | fair | 462929920 | 53.16 |

Thermal observation: **no serious/critical state in retained observations; gaps are unmeasured**.
Dropped records: events=0, series=0, event names=0.

## Epoch 4 · warmResume · generation 2

Duration: 71.25 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | DragonAnim |
| condition: batteryFraction | — | 0.95 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.9753288 |
| condition: heroID | — | DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 |
| condition: initialThermalState | — | 1 |
| cameraIntent | 0.13 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 0.14 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 source=retainedSelection |
| firstFreshCameraFrameObserved | 66.58 | captureUptime=1967065.158404041 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | 14.81 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 |
| firstHeroSceneUpdateProxy | 66.64 | id=DDA8AB6E-08AD-4FE2-9800-9D6A6B4BF240 ms=67; presentation unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 2138 | 0.01 | unmeasured | 1.00 | 1.00 | 0 | 0.01 | 0.03 | 5605.96 |
| GAR update.duration | 360 | 1.28 | unmeasured | 3.00 | 3.00 | 0 | 1.30 | 2.61 | 6052.70 |
| GAR update.interval | 359 | 197.17 | 5.07 | 533.00 | 535.00 | 0 | 100.39 | 532.21 | 6055.62 |
| Person sentinel buffer hold.duration | 139 | 9.76 | unmeasured | 15.00 | 17.00 | 0 | 8.97 | 14.09 | 6034.49 |
| Person sentinel inference.duration | 139 | 9.59 | unmeasured | 14.00 | 16.00 | 0 | 8.89 | 13.70 | 6034.57 |
| Person sentinel inference.interval | 138 | 512.94 | 1.95 | 534.00 | 536.00 | 0 | 533.65 | 533.38 | 6051.12 |
| Postprocess CPU encode.duration | 1031 | 0.05 | unmeasured | 1.00 | 1.00 | 0 | 0.07 | 0.09 | 49126.57 |
| Postprocess blit fallback.interval | 1030 | 26.90 | 37.18 | 38.00 | 48.00 | 0 | 37.56 | 37.81 | 49126.60 |
| Postprocess callback proxy.interval | 1030 | 26.90 | 37.18 | 38.00 | 48.00 | 0 | 37.54 | 37.76 | 49126.63 |
| Postprocess command buffer GPU | 1031 | 1.15 | unmeasured | 2.00 | 2.00 | 0 | 1.32 | 1.32 | 49116.88 |
| Scene update elapsed.duration | 2335 | 0.39 | unmeasured | 3.00 | 4.00 | 0 | 2.02 | 2.12 | 5623.53 |
| captureDelivery.interval | 2137 | 33.33 | 30.00 | 51.00 | 53.00 | 0 | 50.17 | 50.03 | 5605.96 |
| captureSampleAge | 2138 | 69.77 | unmeasured | 78.00 | 84.00 | 0 | 83.60 | 77.79 | 5605.96 |
| captureTimestamp.interval | 2135 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 5666.81 |
| sceneUpdateProxy.interval | 2334 | 30.51 | 32.77 | 36.00 | 46.00 | 0 | 34.60 | 35.83 | 5623.59 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 71.25 | 0 |
| GAR session | True | 71.25 | 0 |
| Semantic postprocess | False | 27.75 | 1 |
| cameraSessionRunning | True | 71.25 | 0 |
| cameraVisible | False | 71.25 | 2 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | True | 71.25 | 0 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 50.56 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | fair | 463798272 | 53.73 |
| 10.30 | fair | 467189760 | 62.75 |
| 16.60 | fair | 467533824 | 68.03 |
| 20.42 | fair | 467140608 | 71.16 |
| 30.79 | serious | 468074496 | 79.29 |
| 41.19 | serious | 468271104 | 87.46 |
| 46.60 | serious | 468516864 | 91.82 |
| 51.60 | serious | 467664896 | 95.82 |
| 62.00 | serious | 466010112 | 104.29 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 5 · cameraInactive · generation 2

Duration: 5.00 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| cameraIntent | unmeasured | unmeasured |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | unmeasured | unmeasured |
| firstFreshCameraFrameObserved | unmeasured | unmeasured |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | unmeasured | unmeasured |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 150 | 0.03 | unmeasured | 1.00 | 1.00 | 0 | 0.05 | 0.05 | 620.42 |
| GAR update.duration | 11 | 3.43 | unmeasured | 5.00 | 5.00 | 0 | 4.80 | 4.80 | 773.25 |
| GAR update.interval | 10 | 415.01 | 2.41 | 434.00 | 434.00 | 0 | 433.08 | 433.08 | 776.93 |
| captureDelivery.interval | 149 | 33.33 | 30.00 | 34.00 | 40.00 | 0 | 33.59 | 33.59 | 620.44 |
| captureSampleAge | 150 | 46.33 | unmeasured | 47.00 | 53.00 | 0 | 46.43 | 46.43 | 620.42 |
| captureTimestamp.interval | 147 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 666.46 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 5.00 | 0 |
| GAR session | True | 5.00 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | False | 5.00 | 1 |
| cameraVisible | False | 0.00 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | False | 5.00 | 1 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 0.84 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | serious | 467664896 | 111.65 |
| 1.10 | serious | 470958080 | 112.49 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 6 · cameraInactive · generation 2

Duration: 0.59 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| cameraIntent | unmeasured | unmeasured |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | unmeasured | unmeasured |
| firstFreshCameraFrameObserved | unmeasured | unmeasured |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | unmeasured | unmeasured |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 1 | 0.05 | unmeasured | 1.00 | 1.00 | 0 | 0.05 | 0.05 | 586.96 |
| captureDelivery.interval | 0 | unmeasured | unmeasured | unmeasured | unmeasured | 0 | unmeasured | unmeasured | unmeasured |
| captureSampleAge | 1 | 46.14 | unmeasured | 47.00 | 47.00 | 0 | 46.14 | 46.14 | 586.97 |
| captureTimestamp.interval | 0 | unmeasured | unmeasured | unmeasured | unmeasured | 0 | unmeasured | unmeasured | unmeasured |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 0.59 | 0 |
| GAR session | True | 0.59 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | False | 0.00 | 0 |
| cameraVisible | False | 0.00 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | False | 0.00 | 0 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 0.05 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.01 | serious | 473595904 | 115.50 |
| 0.02 | serious | 473612288 | 115.51 |
| 0.59 | serious | 473432064 | 115.55 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

Eviction: epochs=0, system samples=0, late measurements=0.

A successful build or proxy target comparison does not establish presentation quality or a thermal improvement.
