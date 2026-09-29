#!/usr/bin/env python3
"""Select an exact iOS simulator lane; never substitute a newer runtime."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time


def major_minor(version: str) -> tuple[int, int]:
    parts = version.split(".")
    if len(parts) < 2 or not parts[0].isdigit() or not parts[1].isdigit():
        raise ValueError(f"Expected iOS major.minor version, got {version!r}")
    return int(parts[0]), int(parts[1])


def matching_runtime(runtimes: list[dict], requested: str) -> dict | None:
    target = major_minor(requested)
    matches = [runtime for runtime in runtimes
               if runtime.get("isAvailable", False)
               and major_minor(runtime.get("version", "0.0")) == target
               and runtime.get("identifier", "").startswith(
                   "com.apple.CoreSimulator.SimRuntime.iOS-")]
    return max(matches, key=lambda item: tuple(int(part) for part in
               item["version"].split(".") if part.isdigit()), default=None)


def matching_device(devices: dict[str, list[dict]], runtime_id: str,
                    preferred_name: str) -> dict | None:
    candidates = [item for item in devices.get(runtime_id, [])
                  if item.get("isAvailable", False) and "iPhone" in item.get("name", "")]
    if not candidates:
        return None
    return next((item for item in candidates if item["name"] == preferred_name),
                candidates[0])


def command(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT).strip()


def simctl_json(category: str) -> dict:
    return json.loads(command("xcrun", "simctl", "list", category, "-j"))


def save(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ios", required=True, help="Exact major.minor runtime, e.g. 17.0")
    parser.add_argument("--preferred-device", required=True)
    parser.add_argument("--expected-xcode", default="Xcode 26.6\nBuild version 17F113")
    parser.add_argument("--expected-sdk", default="26.5")
    parser.add_argument("--download-if-missing", action="store_true")
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--github-output", type=Path)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    record: dict = {"requestedIOS": args.ios, "preferredDevice": args.preferred_device,
                    "host": platform.platform(), "architecture": platform.machine(),
                    "runnerImage": os.environ.get("ImageOS"),
                    "runnerImageVersion": os.environ.get("ImageVersion"),
                    "sourceCommit": os.environ.get("GITHUB_SHA")}
    try:
        xcode = command("xcodebuild", "-version")
        sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-version")
        record.update(xcode=xcode, sdk=sdk)
        if xcode != args.expected_xcode or sdk != args.expected_sdk:
            raise RuntimeError(f"Toolchain changed: expected {args.expected_xcode!r} / "
                               f"SDK {args.expected_sdk}, found {xcode!r} / {sdk}")
        resolved = Path("AugmentMeReality.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        if not resolved.is_file():
            raise RuntimeError(f"Missing pinned dependencies: {resolved}")
        record["packageResolvedSHA256"] = hashlib.sha256(resolved.read_bytes()).hexdigest()
        runtimes = simctl_json("runtimes")["runtimes"]
        runtime = matching_runtime(runtimes, args.ios)
        if runtime is None and args.download_if_missing:
            variant = "arm64" if platform.machine() == "arm64" else "universal"
            request = ["xcodebuild", "-downloadPlatform", "iOS", "-buildVersion",
                       args.ios, "-architectureVariant", variant]
            record["runtimeDownloadCommand"] = request
            print(f"Requested iOS {args.ios} is absent; downloading exactly that runtime.",
                  flush=True)
            with (args.evidence / "runtime-download.log").open("w") as log:
                result = subprocess.run(request, stdout=log, stderr=subprocess.STDOUT,
                                        check=False)
            record["runtimeDownloadExitCode"] = result.returncode
            if result.returncode:
                raise RuntimeError(f"iOS {args.ios} download failed (exit {result.returncode}); "
                                   "see runtime-download.log")
            for _ in range(30):
                runtimes = simctl_json("runtimes")["runtimes"]
                runtime = matching_runtime(runtimes, args.ios)
                if runtime is not None:
                    break
                time.sleep(2)
        record["installedIOSRuntimes"] = [item for item in runtimes
                                           if item.get("identifier", "").startswith(
                                               "com.apple.CoreSimulator.SimRuntime.iOS-")]
        if runtime is None:
            raise RuntimeError(f"Requested iOS {args.ios} runtime is unavailable; "
                               "refusing a newer simulator")
        runtime_id = runtime["identifier"]
        devices = simctl_json("devices")["devices"]
        device = matching_device(devices, runtime_id, args.preferred_device)
        if device is None:
            types = simctl_json("devicetypes")["devicetypes"]
            model = next((item for item in types
                          if item.get("name") == args.preferred_device), None)
            if model is None:
                raise RuntimeError(f"No device type {args.preferred_device!r} for {args.ios}")
            name = f"AMR iOS {args.ios} {args.preferred_device}"
            udid = command("xcrun", "simctl", "create", name, model["identifier"], runtime_id)
            devices = simctl_json("devices")["devices"]
            device = next((item for item in devices.get(runtime_id, [])
                           if item.get("udid") == udid), None)
            if device is None:
                raise RuntimeError(f"Created {udid}, but it is not available for {args.ios}")
        record.update(selectedRuntime=runtime, selectedDevice=device)
        save(args.evidence / "environment.json", record)
        if args.github_output:
            with args.github_output.open("a") as output:
                output.write(f"udid={device['udid']}\n")
                output.write(f"runtime={runtime['version']}\n")
        print(f"Selected {device['name']} {device['udid']} on iOS "
              f"{runtime['version']} ({runtime.get('buildversion', 'unknown')})")
        return 0
    except (OSError, KeyError, ValueError, subprocess.CalledProcessError, RuntimeError) as error:
        record["error"] = str(error)
        save(args.evidence / "environment.json", record)
        print(f"Simulator matrix gate failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
