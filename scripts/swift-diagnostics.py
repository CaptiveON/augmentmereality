#!/usr/bin/env python3
"""Inventory app diagnostics and gate the migrated AR ownership boundaries.

Use a full app compile: an incremental success cannot establish that unchanged
files are warning-free. Dependency and tool diagnostics are not app diagnostics.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


BOUNDARIES = (
    "AR/DropEffects.swift", "AR/DropEntityFactory.swift",
    "AR/GeoARSessionManager.swift", "AR/GeospatialEngine.swift",
    "AR/MidFieldDepthEstimator.swift", "AR/SemanticOcclusionPass.swift",
    "AR/SceneUpdateAdmission.swift",
    "Services/LocationService.swift", "Services/PersonSentinel.swift",
    "Services/AssetPreparationQueue.swift",
)


def inventory(log: str) -> dict:
    pattern = re.compile(
        r"^(?:.*?/)?AugmentMeReality/(?P<path>(?:AR|App|Create|Debug|Drops|Home|Map|Models|Profile|Services|Sharing)/[^:]+\.swift)"
        r":(?P<line>\d+):(?P<column>\d+): (?P<severity>warning|error): (?P<message>.*)$"
    )
    unique = {}
    compiled = set()
    for line in log.splitlines():
        match = pattern.match(line)
        if match:
            diagnostic = match.groupdict()
            diagnostic["line"] = int(diagnostic["line"])
            diagnostic["column"] = int(diagnostic["column"])
            unique[tuple(diagnostic.values())] = diagnostic
        if line.startswith("SwiftCompile "):
            for path in BOUNDARIES:
                if "AugmentMeReality/" + path in line:
                    compiled.add(path)
    diagnostics = sorted(unique.values(), key=lambda item: (
        item["path"], item["line"], item["column"], item["message"]))
    return {
        "logSHA256": hashlib.sha256(log.encode()).hexdigest(),
        "buildSucceeded": bool(re.search(r"\*\* (?:TEST )?BUILD SUCCEEDED \*\*", log)),
        "uniqueAppDiagnostics": len(diagnostics),
        "byFile": dict(sorted(Counter(d["path"] for d in diagnostics).items())),
        "diagnostics": diagnostics,
        "uncompiledBoundaries": sorted(set(BOUNDARIES) - compiled),
        "boundaryDiagnostics": [d for d in diagnostics if
            d["path"].startswith("AR/") or d["path"] in BOUNDARIES or
            d["path"].startswith(("Services/Streetscape", "Services/SceneContent",
                                  "Services/Render", "Services/Occlusion"))],
    }


def gate_passes(result: dict) -> bool:
    return (result["buildSucceeded"] and not result["uncompiledBoundaries"]
            and not result["boundaryDiagnostics"])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check-ar", action="store_true")
    args = parser.parse_args()
    result = inventory(args.log.read_text(errors="replace"))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"App diagnostics: {result['uniqueAppDiagnostics']}; "
          f"AR boundary diagnostics: {len(result['boundaryDiagnostics'])}; "
          f"uncompiled boundaries: {len(result['uncompiledBoundaries'])}")
    if args.check_ar and not gate_passes(result):
        print("AR ownership gate failed; inspect the diagnostic inventory.")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
