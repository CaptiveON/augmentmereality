# AR baseline result

Run: 7C4E2D17-318D-4A1F-AB20-C5A19EEE1705

**Presentation and warmth are not inferred from callback or thermal measurements.**

| Build / condition | Value |
| --- | --- |
| build_source_commit | d5d7a7f3c5693e6b17b7d04774c8db353a4ffa41 |
| build_source_hash | 8323583960bb63b9d6907bfbfb182307d3347632f241412c2c999bf335dcd853 |
| build_source_dirty | false |
| build_configuration | Release |
| device_machine | iPhone16,2 |
| os | Version 26.6 (Build 23G71) |
| experiment | shipping defaults |
| asset | ROOM_TEST_TEXT |
| distance_meters | unmeasured |
| brightness | unmeasured |
| charging | unplugged |
| observed_warmth | cool before launch; warm after placement; very hot near ten minutes and after trace ended, with text visible |
| initially_cool | True |
| screen_recording | False |
| raw_trace_locations | ['/Users/captiveon/Documents/AR-Baselines/issue-3-2026-09-08/runs/I-on.trace'] |
| build_manifest | ../builds/I/build-manifest.json |

Targets: ≥30 presented FPS; presented p95 ≤40 ms; no serious/critical thermal state through 10 minutes; observation through 15 minutes.

Actual presentation: **unmeasured**. Scene/postprocess statistics below are proxies.

Full-epoch percentiles are conservative 1 ms histogram upper bounds; overflow above 1000 ms remains explicit. Startup/recent percentiles use nearest rank.

## Epoch 1 · pre_camera · generation 0

Duration: 29.53 seconds. Fifteen-minute coverage: incomplete.

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
| ARView prepare.duration | 1 | 359.31 | unmeasured | 360.00 | 360.00 | 0 | 359.31 | 359.31 | 971974.23 |
| Asset decode latency.duration | 8 | 616.51 | unmeasured | unmeasured | unmeasured | 2 | unmeasured | 2129.13 | 957404.78 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 4.93 | 16 |

Process CPU seconds across retained system samples: unmeasured (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 10.01 | nominal | 117047296 | 1.49 |

Thermal observation: **no serious/critical state in retained observations; gaps are unmeasured**.
Dropped records: events=0, series=0, event names=0.

## Epoch 2 · coldStart · generation 1

Duration: 943.03 seconds. Fifteen-minute coverage: observed duration reached.

| Milestone | ms since epoch | Details |
| --- | --- | --- |
| condition: asset | — | text3D |
| condition: batteryFraction | — | 0.95 |
| condition: batteryState | — | 1 |
| condition: brightness | — | 0.949999988079071 |
| condition: distanceMetersAtPlacement | — | 406.11487 |
| condition: heroID | — | 3EAE26BB-6631-490D-A231-3C18B6C19169 |
| condition: initialThermalState | — | 0 |
| cameraIntent | 0.38 |  |
| recoveryIntent | unmeasured | unmeasured |
| selectedHero | 140.81 | id=3EAE26BB-6631-490D-A231-3C18B6C19169 asset=text3D |
| firstFreshCameraFrameObserved | 378.49 | captureUptime=1964911.411604125 |
| placeholderPlaced | unmeasured | unmeasured |
| selectedAssetReady | 569.23 | id=3EAE26BB-6631-490D-A231-3C18B6C19169 |
| firstHeroSceneUpdateProxy | unmeasured | unmeasured |

| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Capture delivery observation.duration | 28277 | 0.01 | unmeasured | 1.00 | 1.00 | 0 | 0.01 | 0.02 | 9.46 |
| GAR update.duration | 2604 | 1.26 | unmeasured | 3.00 | 4.00 | 0 | 0.83 | 2.68 | 257.28 |
| GAR update.interval | 2603 | 362.04 | 2.76 | unmeasured | unmeasured | 376 | 33.31 | 1001.19 | 259.83 |
| Person sentinel buffer hold.duration | 1852 | 8.00 | unmeasured | 12.00 | 14.00 | 0 | 262.18 | 11.73 | 16.57 |
| Person sentinel inference.duration | 1852 | 7.86 | unmeasured | 12.00 | 14.00 | 0 | 253.12 | 11.35 | 16.70 |
| Person sentinel inference.interval | 1851 | 509.13 | 1.96 | 534.00 | 535.00 | 0 | 533.25 | 533.38 | 26.63 |
| Postprocess CPU encode.duration | 11046 | 0.04 | unmeasured | 1.00 | 1.00 | 0 | 0.07 | 0.08 | 306327.38 |
| Postprocess blit fallback.interval | 8732 | 72.75 | 13.75 | 33.00 | 35.00 | 5 | 33.52 | 33.53 | 306327.39 |
| Postprocess callback proxy.interval | 11045 | 57.52 | 17.39 | 34.00 | 36.00 | 2 | 33.52 | 34.35 | 306327.43 |
| Postprocess command buffer GPU | 11046 | 1.09 | unmeasured | 2.00 | 2.00 | 0 | 0.97 | 1.88 | 306318.71 |
| Scene update elapsed.duration | 32829 | 0.21 | unmeasured | 2.00 | 4.00 | 0 | 1.55 | 2.25 | 26.69 |
| Semantic pipeline prepare.duration | 1 | 0.49 | unmeasured | 1.00 | 1.00 | 0 | 0.49 | 0.49 | 941613.78 |
| Session configuration.duration | 8 | 0.13 | unmeasured | 1.00 | 1.00 | 0 | 0.47 | 0.47 | 311636.97 |
| captureDelivery.interval | 28276 | 33.34 | 30.00 | 34.00 | 36.00 | 0 | 50.23 | 33.49 | 9.47 |
| captureSampleAge | 28277 | 54.63 | unmeasured | 68.00 | 71.00 | 0 | 79.78 | 62.37 | 9.46 |
| captureTimestamp.interval | 28276 | 33.34 | 30.00 | 34.00 | 34.00 | 0 | 33.34 | 33.34 | 64.84 |
| sceneUpdateProxy.interval | 32828 | 28.72 | 34.82 | 35.00 | 35.00 | 0 | 33.56 | 34.18 | 26.79 |

| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |
| --- | --- | --- | --- |
| Asset decode | False | 0.00 | 0 |
| GAR semantics | True | 942.04 | 2 |
| GAR session | True | 942.94 | 1 |
| Semantic postprocess | False | 216.88 | 6 |
| cameraSessionRunning | True | 942.98 | 1 |
| cameraVisible | True | 943.03 | 1 |
| personSegmentationRequested | False | 61.42 | 7 |
| reconstructionRequested | True | 942.91 | 2 |
| sceneDepthRequested | False | 61.42 | 7 |

Process CPU seconds across retained system samples: 810.87 (all process threads; not an inference attribution).

| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |
| --- | --- | --- | --- |
| 0.00 | nominal | 309313536 | 14.19 |
| 10.33 | nominal | 500809728 | 24.88 |
| 10.49 | nominal | 500891648 | 25.03 |
| 20.40 | nominal | 509722624 | 36.19 |
| 30.51 | nominal | 509067264 | 45.09 |
| 40.49 | nominal | 507838464 | 53.46 |
| 40.62 | nominal | 509886464 | 53.60 |
| 50.69 | nominal | 508608512 | 62.10 |
| 60.79 | fair | 513327104 | 70.35 |
| 70.49 | fair | 510689280 | 78.45 |
| 70.83 | fair | 513196032 | 78.76 |
| 80.95 | fair | 514703360 | 87.13 |
| 91.10 | fair | 515260416 | 95.41 |
| 100.49 | fair | 511213568 | 103.12 |
| 101.25 | fair | 513785856 | 103.76 |
| 111.34 | fair | 511623168 | 112.08 |
| 121.51 | fair | 512655360 | 120.58 |
| 130.49 | fair | 512458752 | 127.92 |
| 131.59 | fair | 515112960 | 128.87 |
| 141.68 | fair | 516096000 | 137.37 |
| 151.70 | fair | 517652480 | 145.81 |
| 160.49 | serious | 514621440 | 152.94 |
| 162.11 | serious | 517718016 | 154.21 |
| 172.46 | serious | 517046272 | 162.30 |
| 182.79 | serious | 514129920 | 170.45 |
| 190.49 | serious | 516915200 | 176.41 |
| 193.09 | serious | 518848512 | 178.52 |
| 203.42 | serious | 517079040 | 186.78 |
| 213.54 | serious | 519618560 | 194.72 |
| 220.49 | serious | 518701056 | 199.99 |
| 223.90 | serious | 519028736 | 202.67 |
| 234.23 | serious | 516161536 | 210.55 |
| 244.30 | serious | 515522560 | 217.93 |
| 250.49 | serious | 515735552 | 222.56 |
| 254.32 | serious | 520339456 | 225.43 |
| 264.37 | serious | 518668288 | 232.93 |
| 274.45 | serious | 518717440 | 240.91 |
| 280.49 | serious | 518242304 | 245.63 |
| 284.81 | serious | 461717504 | 248.85 |
| 295.21 | serious | 462831616 | 256.89 |
| 305.49 | serious | 466845696 | 265.43 |
| 310.49 | serious | 467402752 | 269.57 |
| 315.86 | serious | 472399872 | 273.81 |
| 326.18 | serious | 480411648 | 282.34 |
| 336.50 | serious | 484900864 | 291.15 |
| 340.49 | serious | 482279424 | 294.52 |
| 346.77 | serious | 483606528 | 299.97 |
| 357.04 | serious | 479985664 | 308.79 |
| 367.26 | serious | 479870976 | 317.54 |
| 370.49 | serious | 479444992 | 320.24 |
| 377.56 | serious | 479641600 | 326.21 |
| 387.88 | serious | 483196928 | 334.87 |
| 398.15 | serious | 483393536 | 343.45 |
| 400.49 | serious | 483721216 | 345.45 |
| 408.42 | serious | 486260736 | 352.27 |
| 418.72 | serious | 485883904 | 361.26 |
| 429.02 | serious | 483491840 | 370.09 |
| 430.49 | serious | 483524608 | 371.26 |
| 439.27 | serious | 483999744 | 378.90 |
| 449.60 | serious | 479969280 | 387.56 |
| 459.82 | serious | 480378880 | 396.25 |
| 460.49 | serious | 484294656 | 396.77 |
| 470.12 | serious | 479870976 | 405.06 |
| 480.37 | serious | 479838208 | 413.90 |
| 490.49 | serious | 479543296 | 422.70 |
| 490.69 | serious | 485687296 | 422.92 |
| 500.95 | serious | 486113280 | 431.65 |
| 511.24 | serious | 483737600 | 440.40 |
| 520.49 | serious | 483524608 | 448.20 |
| 521.47 | serious | 483885056 | 449.11 |
| 531.76 | serious | 480034816 | 457.95 |
| 542.00 | serious | 479985664 | 466.95 |
| 550.49 | serious | 483770368 | 474.36 |
| 552.25 | serious | 479920128 | 475.90 |
| 562.55 | serious | 480313344 | 484.80 |
| 572.84 | serious | 484376576 | 493.84 |
| 580.49 | serious | 484622336 | 500.57 |
| 583.12 | serious | 483934208 | 502.97 |
| 593.43 | serious | 481083392 | 512.14 |
| 603.71 | serious | 486326272 | 521.09 |
| 610.49 | serious | 487014400 | 527.14 |
| 614.08 | serious | 486686720 | 530.39 |
| 624.37 | serious | 487129088 | 539.77 |
| 634.68 | serious | 489832448 | 548.97 |
| 640.49 | serious | 483737600 | 554.03 |
| 644.92 | serious | 489619456 | 557.84 |
| 655.16 | serious | 489652224 | 566.45 |
| 665.40 | serious | 487555072 | 575.07 |
| 670.49 | serious | 483475456 | 579.28 |
| 675.65 | serious | 487866368 | 583.72 |
| 685.89 | serious | 487473152 | 592.48 |
| 696.20 | serious | 487882752 | 601.28 |
| 700.49 | serious | 484147200 | 604.96 |
| 706.44 | serious | 484556800 | 610.03 |
| 716.67 | serious | 484605952 | 618.70 |
| 726.99 | serious | 486752256 | 627.29 |
| 730.49 | serious | 484605952 | 630.21 |
| 737.25 | serious | 488062976 | 635.94 |
| 747.56 | serious | 484540416 | 645.04 |
| 757.87 | serious | 488783872 | 654.01 |
| 760.49 | serious | 484524032 | 656.25 |
| 768.12 | serious | 488587264 | 662.80 |
| 778.36 | serious | 484392960 | 671.65 |
| 788.59 | serious | 485703680 | 680.69 |
| 790.49 | serious | 489275392 | 682.36 |
| 798.89 | serious | 486195200 | 689.98 |
| 809.20 | serious | 489439232 | 699.19 |
| 819.50 | serious | 492503040 | 708.17 |
| 820.49 | serious | 486539264 | 708.99 |
| 829.82 | serious | 490274816 | 717.27 |
| 840.12 | serious | 490127360 | 726.13 |
| 850.42 | serious | 490405888 | 735.11 |
| 850.49 | serious | 487604224 | 735.17 |
| 860.62 | serious | 490045440 | 743.92 |
| 870.94 | serious | 486359040 | 752.70 |
| 880.49 | serious | 486293504 | 760.94 |
| 881.21 | serious | 488898560 | 761.63 |
| 891.50 | serious | 492339200 | 770.51 |
| 901.82 | serious | 499269632 | 779.90 |
| 910.49 | serious | 509558784 | 793.87 |
| 912.09 | serious | 508116992 | 795.26 |
| 922.40 | serious | 510902272 | 804.03 |
| 932.66 | serious | 495878144 | 812.57 |
| 940.47 | serious | 431636480 | 821.74 |
| 943.03 | serious | 435077120 | 825.07 |

Thermal observation: **serious/critical observed**.
Dropped records: events=1800, series=0, event names=0.

Eviction: epochs=0, system samples=0, late measurements=0.

A successful build or proxy target comparison does not establish presentation quality or a thermal improvement.
