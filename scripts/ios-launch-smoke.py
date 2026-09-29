#!/usr/bin/env python3
"""Install and launch the real no-secrets app on an exact simulator lane."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time
from uuid import uuid4


def run(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, check=False)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)} failed ({result.returncode}): {result.stdout}")
    return result


def wait_for_marker(preferences: Path, key: str, token: str, pid: int) -> None:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if preferences.is_file():
            try:
                with preferences.open("rb") as stream:
                    if plistlib.load(stream).get(key) == token:
                        return
            except (OSError, plistlib.InvalidFileException):
                pass
        try:
            os.kill(pid, 0)
        except ProcessLookupError as error:
            raise RuntimeError(f"App exited before {key} was reached") from error
        time.sleep(0.5)
    raise RuntimeError(f"App stayed up but did not reach {key} within 30 seconds")


def launch(udid: str, bundle_id: str, token: str, camera: bool) -> int:
    arguments = ["xcrun", "simctl", "launch", udid, bundle_id,
                 "-AMRSmokeToken", token]
    if camera:
        arguments.append("-AMRSmokeUnavailableCamera")
    result = run(*arguments)
    match = re.search(r":\s*(\d+)\s*$", result.stdout)
    if not match:
        raise RuntimeError(f"Could not read launched process ID: {result.stdout}")
    return int(match.group(1))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", required=True)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--bundle-id", default="com.adnan.augmentmereality")
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    record = {"simulatorUDID": args.udid, "app": str(args.app),
              "bundleID": args.bundle_id, "checks": []}
    try:
        if not args.app.is_dir():
            raise RuntimeError(f"Built application is missing: {args.app}")
        for secret in ("GoogleService-Info.plist", "Secrets.plist"):
            if list(args.app.rglob(secret)):
                raise RuntimeError(f"Refusing to launch app with bundled {secret}")
        devices = json.loads(run("xcrun", "simctl", "list", "devices", "-j").stdout)
        selected = next((device for group in devices["devices"].values() for device in group
                         if device.get("udid") == args.udid), None)
        if selected is None:
            raise RuntimeError("Selected simulator disappeared before smoke check")
        if selected.get("state") != "Booted":
            run("xcrun", "simctl", "boot", args.udid)
        run("xcrun", "simctl", "bootstatus", args.udid, "-b")
        run("xcrun", "simctl", "install", args.udid, str(args.app))
        # Request denied location for this simulator app. A system alert already
        # presented by XCTest can outlive its process and still cover screenshots;
        # appearance markers do not certify that system dialogs were dismissed.
        run("xcrun", "simctl", "privacy", args.udid, "revoke", "location", args.bundle_id)
        record["locationPermissionSetup"] = "revocation requested; authorization not asserted"
        record["scope"] = "View appeared and process survived; screenshots need visual inspection"
        container = Path(run("xcrun", "simctl", "get_app_container", args.udid,
                             args.bundle_id, "data").stdout.strip())
        preferences = container / "Library/Preferences" / f"{args.bundle_id}.plist"
        for name, camera, marker in (("non-ar-root", False, "root"),
                                     ("camera-unavailable", True, "cameraUnavailable")):
            run("xcrun", "simctl", "terminate", args.udid, args.bundle_id, check=False)
            token = uuid4().hex
            pid = launch(args.udid, args.bundle_id, token, camera)
            wait_for_marker(preferences, f"AMRSmoke_{marker}", token, pid)
            time.sleep(0.5)  # allow the SwiftUI appearance transaction to present
            os.kill(pid, 0)
            screenshot = args.evidence / f"{name}.png"
            run("xcrun", "simctl", "io", args.udid, "screenshot", str(screenshot))
            record["checks"].append({"surface": name, "reached": True, "pid": pid,
                                     "screenshot": screenshot.name})
            (args.evidence / "launch-smoke.json").write_text(
                json.dumps(record, indent=2, sort_keys=True) + "\n")
        run("xcrun", "simctl", "terminate", args.udid, args.bundle_id, check=False)
        print("No-secrets root and unavailable-camera launch smoke passed")
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        record["error"] = str(error)
        (args.evidence / "launch-smoke.json").write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n")
        log = run("xcrun", "simctl", "spawn", args.udid, "log", "show", "--last", "2m",
                  "--style", "compact", "--predicate",
                  f'process == "AugmentMeReality"', check=False)
        (args.evidence / "launch-failure-system.log").write_text(log.stdout)
        run("xcrun", "simctl", "io", args.udid, "screenshot",
            str(args.evidence / "launch-failure.png"), check=False)
        print(f"Launch smoke failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
