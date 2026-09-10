# AR baseline result

Run: F23A8CBC-25CB-4C95-881C-0BDD58FA61CB

**Presentation and warmth are not inferred from callback or thermal measurements.**

| Build / condition | Value |
| --- | --- |
| build_source_commit | b45f43725166c156dfd69a8f871660d665f35923 |
| build_source_hash | 75992526eb10083c53fe86dd92c490f29d6268fa54e50d5065ef28ad97ca8250 |
| build_source_dirty | false |
| build_configuration | Release |
| device_machine | iPhone16,2 |
| os | Version 26.6 (Build 23G71) |
| experiment | disabled=assetPreload; delayedAsset=none; delaySeconds=0.0; missingAsset=DragonAnim; heroSource=roomDrop |
| asset | DragonAnim |
| distance_meters | unmeasured |
| brightness | unmeasured |
| charging | USB-quality |
| observed_warmth | not measured for this quality run; initial ProcessInfo serious |
| initially_cool | False |
| screen_recording | True |
| raw_trace_locations | ['runs/quality/Q-missing-dragon-attempts.mov', 'runs/quality/Q-missing-only-final/baseline-F23A8CBC-25CB-4C95-881C-0BDD58FA61CB.json'] |
| build_manifest | builds/Q/build-manifest.json |

Thermal-run eligibility: **unmeasured / not eligible** until screen recording is confirmed off.

Targets: ≥30 presented FPS; presented p95 ≤40 ms; no serious/critical thermal state through 10 minutes; observation through 15 minutes.

Actual presentation: **unmeasured**. Scene/postprocess statistics below are proxies.

Full-epoch percentiles are conservative 1 ms histogram upper bounds; overflow above 1000 ms remains explicit. Startup/recent percentiles use nearest rank.

## Epoch 1 · pre_camera · generation 0

Duration: 22.81 seconds. Fifteen-minute coverage: incomplete.

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
| ARView prepare.duration | 1 | 163.71 | unmeasured | 164.00 | 164.00 | 0 | 163.71 | 163.71 | 290419.98 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 10.00 | serious | 118718464 | 1.83 |

Thermal observation: **serious/critical observed**.
Dropped records: events=0, series=0, event names=0.

## Epoch 2 · coldStart · generation 1

Duration: 268.00 seconds. Fifteen-minute coverage: incomplete.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | DragonAnim |
| condition: batteryFraction | — | 0.95 |
| condition: batteryState | — | 2 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 1.967785 |
| condition: heroID | — | 4A00C3C0-29D2-4ED4-ABCE-C286C64E5479 |
| condition: initialThermalState | — | 2 |
| cameraIntent | 0.61 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 11976.72 | id=4A00C3C0-29D2-4ED4-ABCE-C286C64E5479 asset=DragonAnim source=roomSelection |
| firstFreshCameraFrameObserved | 306.17 | captureUptime=1967705.299264166 |
| placeholderPlaced | 11980.29 | id=4A00C3C0-29D2-4ED4-ABCE-C286C64E5479 |
| selectedAssetReady | unmeasured | unmeasured |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Asset decode latency.duration | 1 | 3.07 | unmeasured | 4.00 | 4.00 | 0 | unmeasured | 3.07 | 255990.98 |
| Capture delivery observation.duration | 8031 | 0.02 | unmeasured | 1.00 | 1.00 | 0 | 0.03 | 0.03 | 1.04 |
| GAR update.duration | 322 | 2.56 | unmeasured | 4.00 | 5.00 | 0 | 8.64 | 3.53 | 362.27 |
| GAR update.interval | 321 | 832.79 | 1.20 | unmeasured | unmeasured | 204 | 562.15 | 1033.23 | 364.96 |
| Person sentinel buffer hold.duration | 521 | 9.96 | unmeasured | 15.00 | 19.00 | 0 | 68.75 | 14.34 | 191.52 |
| Person sentinel inference.duration | 521 | 9.71 | unmeasured | 14.00 | 19.00 | 0 | 68.44 | 13.53 | 191.58 |
| Person sentinel inference.interval | 520 | 513.97 | 1.95 | 534.00 | 536.00 | 0 | 538.57 | 533.83 | 197.88 |
| Scene update elapsed.duration | 8032 | 0.23 | unmeasured | 1.00 | 5.00 | 0 | 2.37 | 0.35 | 31.66 |
| Session configuration.duration | 2 | 0.09 | unmeasured | 1.00 | 1.00 | 0 | 0.12 | 0.12 | 267922.12 |
| captureDelivery.interval | 8030 | 33.34 | 30.00 | 35.00 | 39.00 | 0 | 38.44 | 34.56 | 1.05 |
| captureSampleAge | 8031 | 58.11 | unmeasured | 69.00 | 83.00 | 0 | 70.13 | 67.77 | 1.05 |
| captureTimestamp.interval | 8030 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 38.18 |
| sceneUpdateProxy.interval | 8031 | 33.36 | 29.98 | 36.00 | 38.00 | 0 | 36.06 | 36.17 | 31.70 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 2 |
| GAR semantics | True | 267.06 | 2 |
| GAR session | True | 267.94 | 1 |
| cameraSessionRunning | True | 267.96 | 1 |
| cameraVisible | True | 268.00 | 1 |
| personSegmentationRequested | False | 0.00 | 1 |
| reconstructionRequested | True | 267.92 | 2 |
| sceneDepthRequested | False | 0.00 | 1 |

Process CPU seconds across retained system samples: 220.69 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | serious | 124731392 | 2.69 |
| 10.09 | serious | 424542208 | 11.18 |
| 17.20 | serious | 442400768 | 17.14 |
| 20.36 | serious | 442499072 | 19.80 |
| 30.73 | serious | 449413120 | 28.68 |
| 41.11 | serious | 450428928 | 37.21 |
| 47.20 | serious | 449003520 | 42.14 |
| 51.11 | serious | 449183744 | 45.32 |
| 61.47 | serious | 445464576 | 53.61 |
| 71.85 | serious | 450625536 | 61.98 |
| 77.20 | serious | 450445312 | 66.58 |
| 81.98 | serious | 449822720 | 70.69 |
| 92.08 | serious | 451592192 | 79.24 |
| 102.37 | serious | 450854912 | 87.81 |
| 107.20 | serious | 450936832 | 91.78 |
| 112.77 | serious | 451706880 | 96.38 |
| 123.17 | serious | 451837952 | 104.75 |
| 133.57 | serious | 452771840 | 113.45 |
| 137.20 | serious | 452329472 | 116.45 |
| 143.98 | serious | 450117632 | 121.81 |
| 154.38 | serious | 453378048 | 130.09 |
| 164.78 | serious | 450297856 | 138.51 |
| 167.20 | serious | 450052096 | 140.51 |
| 175.18 | serious | 453214208 | 147.15 |
| 185.58 | serious | 300466176 | 155.32 |
| 195.98 | serious | 300777472 | 164.09 |
| 197.20 | serious | 300761088 | 165.10 |
| 206.39 | serious | 301645824 | 172.71 |
| 216.79 | serious | 304185344 | 181.24 |
| 227.19 | serious | 302923776 | 189.66 |
| 227.20 | serious | 302923776 | 189.67 |
| 237.35 | serious | 308592640 | 197.55 |
| 247.45 | serious | 311296000 | 206.17 |
| 257.20 | serious | 310853632 | 214.38 |
| 257.65 | serious | 310870016 | 214.80 |
| 268.00 | serious | 310722560 | 223.37 |

Thermal observation: **serious/critical observed**.
Dropped records: events=426, series=0, event names=0.

Eviction: epochs=0, system samples=0, late measurements=0.

A successful build or proxy target comparison does not establish presentation quality or a thermal improvement.
