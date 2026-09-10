# AR baseline result

Run: 9B2BF558-569F-4FD0-A310-4C9252DDCF4D

**Presentation and warmth are not inferred from callback or thermal measurements.**

| Build / condition | Value |
| --- | --- |
| build_source_commit | b45f43725166c156dfd69a8f871660d665f35923 |
| build_source_hash | 75992526eb10083c53fe86dd92c490f29d6268fa54e50d5065ef28ad97ca8250 |
| build_source_dirty | false |
| build_configuration | Release |
| device_machine | iPhone16,2 |
| os | Version 26.6 (Build 23G71) |
| experiment | disabled=; delayedAsset=none; delaySeconds=0.0; missingAsset=none; heroSource=roomDrop |
| asset | ROOM_TEST_TEXT |
| distance_meters | unmeasured |
| brightness | unmeasured |
| charging | USB-quality |
| observed_warmth | not measured for this quality run; previous thermal run ended very hot |
| initially_cool | False |
| screen_recording | True |
| raw_trace_locations | ['runs/quality/Q-readiness-supported.trace', 'runs/quality/Q-readiness.mov'] |
| build_manifest | builds/Q/build-manifest.json |

Thermal-run eligibility: **unmeasured / not eligible** until screen recording is confirmed off.

Targets: ≥30 presented FPS; presented p95 ≤40 ms; no serious/critical thermal state through 10 minutes; observation through 15 minutes.

Actual presentation: **unmeasured**. Scene/postprocess statistics below are proxies.

Full-epoch percentiles are conservative 1 ms histogram upper bounds; overflow above 1000 ms remains explicit. Startup/recent percentiles use nearest rank.

## Epoch 1 · pre_camera · generation 0

Duration: 22.26 seconds. Fifteen-minute coverage: incomplete.

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
| ARView prepare.duration | 1 | 369.04 | unmeasured | 370.00 | 370.00 | 0 | 369.04 | 369.04 | 296474.40 |
| Asset decode latency.duration | 8 | 631.73 | unmeasured | unmeasured | unmeasured | 2 | unmeasured | 2259.01 | 281785.69 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 5.05 | 16 |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 10.01 | nominal | 114556928 | 1.63 |

Thermal observation: **no serious/critical state in retained observations; gaps are unmeasured**.
Dropped records: events=0, series=0, event names=0.

## Epoch 2 · coldStart · generation 1

Duration: 71.43 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | text3D |
| condition: batteryFraction | — | 0.9 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.9684482 |
| condition: heroID | — | 1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| condition: initialThermalState | — | 0 |
| cameraIntent | 0.53 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 4624.63 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 asset=text3D source=roomSelection |
| firstFreshCameraFrameObserved | 496.52 | captureUptime=1966308.223434708 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | 4632.80 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| firstHeroSceneUpdateProxy | 4638.50 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 ms=4638; presentation unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 2131 | 0.01 | unmeasured | 1.00 | 1.00 | 0 | 0.01 | 0.02 | 203361.28 |
| GAR update.duration | 941 | 0.77 | unmeasured | 2.00 | 3.00 | 0 | 0.98 | 1.59 | 203634.15 |
| GAR update.interval | 940 | 75.17 | 13.30 | 220.00 | unmeasured | 11 | 36.00 | 219.45 | 203636.28 |
| Person sentinel buffer hold.duration | 138 | 11.38 | unmeasured | 13.00 | 16.00 | 0 | 321.37 | 12.89 | 203697.74 |
| Person sentinel inference.duration | 138 | 11.16 | unmeasured | 13.00 | 16.00 | 0 | 311.91 | 12.60 | 203697.80 |
| Person sentinel inference.interval | 137 | 514.16 | 1.94 | 534.00 | 536.00 | 0 | 543.37 | 533.18 | 203710.63 |
| Postprocess CPU encode.duration | 2723 | 0.05 | unmeasured | 1.00 | 1.00 | 0 | 0.07 | 0.08 | 203373.80 |
| Postprocess blit fallback.interval | 2722 | 25.70 | 38.91 | 37.00 | 49.00 | 0 | 35.79 | 36.88 | 203373.82 |
| Postprocess callback proxy.interval | 2722 | 25.70 | 38.91 | 37.00 | 49.00 | 0 | 35.82 | 36.88 | 203373.84 |
| Postprocess command buffer GPU | 2723 | 1.12 | unmeasured | 2.00 | 2.00 | 0 | 1.18 | 1.35 | 203363.73 |
| Scene update elapsed.duration | 2755 | 0.57 | unmeasured | 3.00 | 3.00 | 0 | 1.84 | 2.44 | 203376.98 |
| Semantic pipeline prepare.duration | 1 | 0.46 | unmeasured | 1.00 | 1.00 | 0 | 0.46 | 0.46 | 273325.89 |
| Session configuration.duration | 2 | 0.30 | unmeasured | 1.00 | 1.00 | 0 | 0.41 | 0.41 | 274666.16 |
| captureDelivery.interval | 2130 | 33.31 | 30.03 | 51.00 | 63.00 | 0 | 52.38 | 50.36 | 203361.29 |
| captureSampleAge | 2131 | 62.34 | unmeasured | 91.00 | 93.00 | 0 | 56.24 | 90.77 | 203361.28 |
| captureTimestamp.interval | 2130 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 203424.10 |
| sceneUpdateProxy.interval | 2754 | 25.88 | 38.64 | 35.00 | 49.00 | 0 | 40.53 | 34.92 | 203377.03 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 70.39 | 2 |
| GAR session | True | 71.33 | 1 |
| Semantic postprocess | True | 69.98 | 1 |
| cameraSessionRunning | True | 71.37 | 1 |
| cameraVisible | False | 71.43 | 2 |
| personSegmentationRequested | False | 0.00 | 1 |
| reconstructionRequested | True | 71.31 | 2 |
| sceneDepthRequested | False | 0.00 | 1 |

Process CPU seconds across retained system samples: 57.09 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.03 | nominal | 309018624 | 14.15 |
| 10.35 | nominal | 491798528 | 25.11 |
| 17.76 | nominal | 491503616 | 32.89 |
| 20.55 | nominal | 491601920 | 35.57 |
| 30.77 | fair | 494075904 | 44.42 |
| 40.91 | fair | 495173632 | 53.31 |
| 47.76 | fair | 496009216 | 59.27 |
| 51.14 | fair | 495419392 | 62.34 |
| 61.31 | fair | 496680960 | 71.24 |

Thermal observation: **no serious/critical state in retained observations; gaps are unmeasured**.
Dropped records: events=0, series=0, event names=0.

## Epoch 3 · cameraInactive · generation 1

Duration: 0.83 seconds. Fifteen-minute coverage: incomplete.

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
| Capture delivery observation.duration | 25 | 0.03 | unmeasured | 1.00 | 1.00 | 0 | 0.05 | 0.05 | 202533.36 |
| GAR update.duration | 1 | 3.40 | unmeasured | 4.00 | 4.00 | 0 | 3.40 | 3.40 | 202828.56 |
| GAR update.interval | 0 | unmeasured | unmeasured | unmeasured | unmeasured | 0 | unmeasured | unmeasured | unmeasured |
| captureDelivery.interval | 24 | 33.33 | 30.00 | 34.00 | 34.00 | 0 | 33.47 | 33.47 | 202533.38 |
| captureSampleAge | 25 | 57.40 | unmeasured | 58.00 | 58.00 | 0 | 57.52 | 57.52 | 202533.36 |
| captureTimestamp.interval | 22 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 202590.71 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 0.83 | 0 |
| GAR session | True | 0.83 | 0 |
| Semantic postprocess | True | 0.83 | 0 |
| cameraSessionRunning | True | 0.83 | 0 |
| cameraVisible | False | 0.00 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | True | 0.83 | 0 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.09 | fair | 499187712 | 80.11 |

Thermal observation: **no serious/critical state in retained observations; gaps are unmeasured**.
Dropped records: events=0, series=0, event names=0.

## Epoch 4 · warmResume · generation 2

Duration: 44.26 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | text3D |
| condition: batteryFraction | — | 0.9 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.9684111 |
| condition: heroID | — | 1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| condition: initialThermalState | — | 1 |
| cameraIntent | 0.10 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 0.11 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 source=retainedSelection |
| firstFreshCameraFrameObserved | 75.33 | captureUptime=1966380.0619365 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | 24.66 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| firstHeroSceneUpdateProxy | 75.39 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 ms=75; presentation unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 1328 | 0.01 | unmeasured | 1.00 | 1.00 | 0 | 0.01 | 0.02 | 158251.10 |
| GAR update.duration | 44 | 2.15 | unmeasured | 4.00 | 4.00 | 0 | 2.28 | 3.48 | 159064.30 |
| GAR update.interval | 43 | 1009.56 | 0.99 | unmeasured | unmeasured | 43 | 1013.28 | 1032.16 | 159066.39 |
| Person sentinel buffer hold.duration | 87 | 10.59 | unmeasured | 17.00 | 30.00 | 0 | 11.50 | 16.27 | 158620.41 |
| Person sentinel inference.duration | 87 | 10.32 | unmeasured | 16.00 | 30.00 | 0 | 11.17 | 15.70 | 158620.50 |
| Person sentinel inference.interval | 86 | 509.81 | 1.96 | 535.00 | 537.00 | 0 | 519.80 | 534.23 | 158631.68 |
| Postprocess CPU encode.duration | 1792 | 0.04 | unmeasured | 1.00 | 1.00 | 0 | 0.07 | 0.08 | 169432.71 |
| Postprocess blit fallback.interval | 1791 | 18.45 | 54.21 | 34.00 | 37.00 | 0 | 20.50 | 33.49 | 169432.74 |
| Postprocess callback proxy.interval | 1791 | 18.45 | 54.21 | 34.00 | 37.00 | 0 | 20.50 | 33.45 | 169432.76 |
| Postprocess command buffer GPU | 1792 | 1.13 | unmeasured | 2.00 | 2.00 | 0 | 1.37 | 1.35 | 169424.26 |
| Scene update elapsed.duration | 2127 | 0.12 | unmeasured | 1.00 | 4.00 | 0 | 0.08 | 0.17 | 158265.45 |
| captureDelivery.interval | 1327 | 33.34 | 29.99 | 35.00 | 38.00 | 0 | 33.70 | 34.85 | 158251.11 |
| captureSampleAge | 1328 | 61.62 | unmeasured | 67.00 | 70.00 | 0 | 64.47 | 66.97 | 158251.10 |
| captureTimestamp.interval | 1325 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 158321.17 |
| sceneUpdateProxy.interval | 2126 | 20.80 | 48.09 | 34.00 | 36.00 | 0 | 19.84 | 33.77 | 158265.60 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 44.26 | 0 |
| GAR session | True | 44.26 | 0 |
| Semantic postprocess | False | 33.07 | 1 |
| cameraSessionRunning | True | 44.26 | 0 |
| cameraVisible | False | 44.26 | 2 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | True | 44.26 | 0 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 34.64 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | fair | 499810304 | 80.71 |
| 5.47 | fair | 500842496 | 85.23 |
| 10.14 | fair | 499941376 | 89.21 |
| 20.23 | fair | 499859456 | 98.09 |
| 30.61 | serious | 369213440 | 106.69 |
| 35.47 | serious | 370753536 | 110.85 |
| 40.94 | serious | 374390784 | 115.35 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 5 · cameraInactive · generation 2

Duration: 4.99 seconds. Fifteen-minute coverage: incomplete.

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
| Capture delivery observation.duration | 150 | 0.04 | unmeasured | 1.00 | 1.00 | 0 | 0.07 | 0.07 | 153266.53 |
| GAR update.duration | 11 | 3.12 | unmeasured | 5.00 | 5.00 | 0 | 4.65 | 4.65 | 153261.84 |
| GAR update.interval | 10 | 414.82 | 2.41 | 421.00 | 421.00 | 0 | 420.64 | 420.64 | 153265.23 |
| captureDelivery.interval | 149 | 33.34 | 30.00 | 35.00 | 38.00 | 0 | 34.15 | 34.15 | 153266.55 |
| captureSampleAge | 150 | 54.57 | unmeasured | 56.00 | 59.00 | 0 | 55.45 | 55.45 | 153266.53 |
| captureTimestamp.interval | 147 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 153320.84 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 4.99 | 0 |
| GAR session | True | 4.99 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | False | 4.99 | 1 |
| cameraVisible | False | 0.00 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | False | 4.99 | 1 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.01 | serious | 375193600 | 117.93 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 6 · warmResume · generation 3

Duration: 10.04 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | text3D |
| condition: batteryFraction | — | 0.9 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.9659489 |
| condition: heroID | — | 1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| condition: initialThermalState | — | 2 |
| cameraIntent | 0.16 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 0.17 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 source=retainedSelection |
| firstFreshCameraFrameObserved | 211.85 | captureUptime=1966450.417722958 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | 15.88 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| firstHeroSceneUpdateProxy | 211.91 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 ms=212; presentation unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 293 | 0.02 | unmeasured | 1.00 | 1.00 | 0 | 0.04 | 0.04 | 122340.40 |
| GAR update.duration | 11 | 2.14 | unmeasured | 4.00 | 4.00 | 0 | 3.00 | 3.00 | 123157.33 |
| GAR update.interval | 10 | 913.23 | 1.10 | unmeasured | unmeasured | 9 | 1033.79 | 1033.79 | 123159.80 |
| Person sentinel buffer hold.duration | 19 | 12.10 | unmeasured | 16.00 | 16.00 | 0 | 15.78 | 15.78 | 123041.98 |
| Person sentinel inference.duration | 19 | 11.82 | unmeasured | 16.00 | 16.00 | 0 | 15.25 | 15.25 | 123042.05 |
| Person sentinel inference.interval | 18 | 512.78 | 1.95 | 534.00 | 534.00 | 0 | 533.42 | 533.42 | 123057.30 |
| Scene update elapsed.duration | 281 | 0.21 | unmeasured | 1.00 | 5.00 | 0 | 0.15 | 0.15 | 122927.23 |
| Session configuration.duration | 1 | 0.38 | unmeasured | 1.00 | 1.00 | 0 | 0.38 | 0.38 | 132307.36 |
| captureDelivery.interval | 292 | 33.45 | 29.90 | 34.00 | 36.00 | 0 | 33.50 | 33.50 | 122340.42 |
| captureSampleAge | 293 | 55.73 | unmeasured | 61.00 | 62.00 | 0 | 60.91 | 60.91 | 122340.40 |
| captureTimestamp.interval | 292 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 122400.84 |
| sceneUpdateProxy.interval | 280 | 33.43 | 29.91 | 35.00 | 37.00 | 0 | 34.57 | 34.57 | 122927.28 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 10.04 | 0 |
| GAR session | True | 10.04 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | False | 10.03 | 2 |
| cameraVisible | False | 10.04 | 2 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | False | 10.03 | 2 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | serious | 376635392 | 122.87 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 7 · cameraInactive · generation 3

Duration: 29.05 seconds. Fifteen-minute coverage: incomplete.

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
| Capture delivery observation.duration | 2 | 0.02 | unmeasured | 1.00 | 1.00 | 0 | 0.03 | 0.03 | 122156.57 |
| captureDelivery.interval | 1 | 0.06 | 17817.37 | 1.00 | 1.00 | 0 | 0.06 | 0.06 | 122156.57 |
| captureSampleAge | 2 | 194.23 | unmeasured | 211.00 | 211.00 | 0 | 210.87 | 210.87 | 122156.57 |
| captureTimestamp.interval | 0 | unmeasured | unmeasured | unmeasured | unmeasured | 0 | unmeasured | unmeasured | unmeasured |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 29.05 | 0 |
| GAR session | True | 29.05 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | False | 0.00 | 0 |
| cameraVisible | False | 0.00 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | False | 0.00 | 0 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 0.56 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.01 | serious | 437354496 | 130.23 |
| 15.98 | serious | 436125696 | 130.79 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 8 · warmResume · generation 4

Duration: 11.61 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | text3D |
| condition: batteryFraction | — | 0.9 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.9662113 |
| condition: heroID | — | 1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| condition: initialThermalState | — | 2 |
| cameraIntent | 0.10 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 0.10 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 source=retainedSelection |
| firstFreshCameraFrameObserved | 387.54 | captureUptime=1966489.798574208 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | 4.82 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 |
| firstHeroSceneUpdateProxy | 387.66 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 ms=388; presentation unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 336 | 0.02 | unmeasured | 1.00 | 1.00 | 0 | 0.04 | 0.04 | 81533.88 |
| GAR update.duration | 13 | 2.76 | unmeasured | 5.00 | 5.00 | 0 | 4.83 | 4.83 | 81978.70 |
| GAR update.interval | 12 | 926.82 | 1.08 | unmeasured | unmeasured | 11 | 1033.33 | 1033.33 | 81981.50 |
| Person sentinel buffer hold.duration | 23 | 13.55 | unmeasured | 18.00 | 37.00 | 0 | 17.08 | 17.08 | 81739.57 |
| Person sentinel inference.duration | 23 | 12.72 | unmeasured | 16.00 | 28.00 | 0 | 15.60 | 15.65 | 81739.63 |
| Person sentinel inference.interval | 22 | 515.05 | 1.94 | 533.00 | 533.00 | 0 | 532.70 | 532.34 | 81750.76 |
| Scene update elapsed.duration | 344 | 0.26 | unmeasured | 1.00 | 6.00 | 0 | 0.38 | 0.32 | 81516.30 |
| Session configuration.duration | 1 | 0.08 | unmeasured | 1.00 | 1.00 | 0 | 0.08 | 0.08 | 93107.98 |
| captureDelivery.interval | 335 | 33.42 | 29.92 | 34.00 | 39.00 | 0 | 33.83 | 33.85 | 81533.89 |
| captureSampleAge | 336 | 52.50 | unmeasured | 54.00 | 58.00 | 0 | 53.07 | 53.12 | 81533.88 |
| captureTimestamp.interval | 335 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 81586.54 |
| sceneUpdateProxy.interval | 343 | 33.73 | 29.65 | 35.00 | 48.00 | 0 | 34.82 | 34.79 | 81516.74 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 11.61 | 0 |
| GAR session | True | 11.61 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | True | 11.61 | 1 |
| cameraVisible | True | 11.61 | 1 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | True | 11.61 | 1 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 7.99 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.01 | serious | 353828864 | 131.54 |
| 10.35 | serious | 314392576 | 139.53 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 9 · recovery · generation 5

Duration: 81.50 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: batteryFraction | — | 0.9 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: initialThermalState | — | 2 |
| cameraIntent | unmeasured | unmeasured |
| recoveryIntent | 0.19 |  |
| selectedHero | 0.20 | id=1912CA4B-A2EC-46E9-9426-E8E8CBE90904 source=retainedSelection |
| firstFreshCameraFrameObserved | 88.25 | captureUptime=1966501.066101708 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | unmeasured | unmeasured |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 2446 | 0.02 | unmeasured | 1.00 | 1.00 | 0 | 0.04 | 0.04 | 0.85 |
| GAR update.duration | 81 | 2.78 | unmeasured | 4.00 | 6.00 | 0 | 3.57 | 3.68 | 62.58 |
| GAR update.interval | 80 | 1011.08 | 0.99 | unmeasured | unmeasured | 79 | 1033.22 | 1033.35 | 65.27 |
| Person sentinel buffer hold.duration | 158 | 12.81 | unmeasured | 19.00 | 21.00 | 0 | 17.04 | 18.73 | 319.09 |
| Person sentinel inference.duration | 158 | 12.55 | unmeasured | 19.00 | 21.00 | 0 | 16.78 | 18.36 | 319.26 |
| Person sentinel inference.interval | 157 | 515.20 | 1.94 | 534.00 | 536.00 | 0 | 533.58 | 533.78 | 332.22 |
| Scene update elapsed.duration | 2438 | 0.23 | unmeasured | 1.00 | 5.00 | 0 | 0.31 | 0.32 | 32.21 |
| Session configuration.duration | 2 | 0.18 | unmeasured | 1.00 | 1.00 | 0 | 0.26 | 0.26 | 81491.98 |
| captureDelivery.interval | 2445 | 33.31 | 30.02 | 34.00 | 37.00 | 0 | 34.02 | 33.87 | 0.86 |
| captureSampleAge | 2446 | 57.92 | unmeasured | 64.00 | 66.00 | 0 | 54.09 | 63.74 | 0.85 |
| captureTimestamp.interval | 2443 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 47.20 |
| sceneUpdateProxy.interval | 2437 | 33.39 | 29.95 | 35.00 | 37.00 | 0 | 34.43 | 34.51 | 32.27 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 81.04 | 2 |
| GAR session | True | 81.50 | 0 |
| Semantic postprocess | False | 0.00 | 0 |
| cameraSessionRunning | True | 81.50 | 0 |
| cameraVisible | True | 81.50 | 0 |
| personSegmentationRequested | False | 0.00 | 0 |
| reconstructionRequested | True | 81.49 | 2 |
| sceneDepthRequested | False | 0.00 | 0 |

Process CPU seconds across retained system samples: 66.50 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | serious | 314949632 | 140.49 |
| 4.47 | serious | 367935488 | 144.44 |
| 10.01 | serious | 376373248 | 148.93 |
| 20.18 | serious | 377569280 | 157.38 |
| 30.57 | serious | 377405440 | 165.66 |
| 34.47 | serious | 377929728 | 168.95 |
| 40.68 | serious | 378044416 | 173.93 |
| 50.68 | serious | 377716736 | 182.04 |
| 60.78 | serious | 327696384 | 190.35 |
| 64.47 | serious | 299679744 | 193.44 |
| 71.15 | serious | 301236224 | 198.60 |
| 81.50 | serious | 302694400 | 206.99 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

Eviction: epochs=0, system samples=0, late measurements=0.

A successful build or proxy target comparison does not establish presentation quality or a thermal improvement.
