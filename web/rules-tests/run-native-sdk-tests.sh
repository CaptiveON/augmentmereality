#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: bash web/rules-tests/run-native-sdk-tests.sh SIMULATOR_UDID [SOURCE_PACKAGES_PATH]" >&2
  exit 2
fi
amr_simulator="$1"
amr_repo="$(cd "$(dirname "$0")/../.." && pwd)"
amr_output="${AMR_TEST_OUTPUT_DIR:-$(mktemp -d /tmp/amr-native-sdk.XXXXXX)}"
mkdir -p "$amr_output"
amr_output="$(cd "$amr_output" && pwd)"
cd "$amr_repo"

# Keep this array nonempty: macOS Bash 3.2 treats an empty-array expansion as an
# unbound variable under set -u. The default matches the isolated Xcode cache.
amr_packages=(-clonedSourcePackagesDirPath "${2:-$amr_output/DerivedData/SourcePackages}")
echo "Building config-free Debug test host; artifacts: $amr_output"
# Resolve explicitly from the committed lock so a clean CI runner can fetch the
# pinned checkouts. The build itself is not permitted to choose newer versions.
xcodebuild -project AugmentMeReality.xcodeproj -scheme AugmentMeReality \
  -derivedDataPath "$amr_output/DerivedData" "${amr_packages[@]}" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
  -resolvePackageDependencies > "$amr_output/packages.log" 2>&1
xcodebuild -project AugmentMeReality.xcodeproj -scheme AugmentMeReality \
  -configuration Debug -destination "id=$amr_simulator" \
  -derivedDataPath "$amr_output/DerivedData" "${amr_packages[@]}" \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates CODE_SIGNING_ALLOWED=NO \
  'EXCLUDED_SOURCE_FILE_NAMES=GoogleService-Info.plist Secrets.plist' \
  build-for-testing > "$amr_output/build.log" 2>&1

amr_xctestrun="$(python3 - "$amr_output" <<'PY'
from pathlib import Path
import plistlib
import sys

products = Path(sys.argv[1]) / "DerivedData/Build/Products"
app = products / "Debug-iphonesimulator/AugmentMeReality.app"
if not app.is_dir():
    raise SystemExit("Missing test app")
for resource in app.rglob("*.plist"):
    if resource.name in ("GoogleService-Info.plist", "Secrets.plist"):
        raise SystemExit("Service configuration was bundled; refusing to launch test host")
candidates = list(products.glob("AugmentMeReality_*.xctestrun"))
if len(candidates) != 1:
    raise SystemExit("Expected exactly one generated xctestrun")
data = plistlib.loads(candidates[0].read_bytes())
data["AugmentMeRealityTests"].setdefault("EnvironmentVariables", {})[
    "AMR_NATIVE_FIRESTORE_EMULATOR_TEST"
] = "1"
output = products / "NativeSDK.xctestrun"
output.write_bytes(plistlib.dumps(data))
print(output)
PY
)"

amr_child=(node "$amr_repo/web/rules-tests/native-sdk-emulator.mjs"
  xcodebuild -xctestrun "$amr_xctestrun" -destination "id=$amr_simulator"
  -parallel-testing-enabled NO -resultBundlePath "$amr_output/native-contract-tests.xcresult"
  CODE_SIGNING_ALLOWED=NO)
if [[ "${AMR_ALL_LOCAL_TESTS:-0}" == 1 ]]; then
  amr_child+=(-skip-testing:AugmentMeRealityTests/FirebaseIntegrationTests)
else
  for amr_suite in FirestoreAckedTests LocalDropStoreTests DropLibraryTests \
    RefusalTaxonomyTests ReactionShapeTests ReactionSessionTests ReactionListenKeyTests \
    GeoDropCompatibilityTests GeoDropTests FirestoreServerReadTests FirestoreServerReadEmulatorTests; do
    amr_child+=("-only-testing:AugmentMeRealityTests/$amr_suite")
  done
fi
amr_child+=(test-without-building)
# emulators:exec accepts one shell command. Bash %q safely quotes every argument,
# including spaces/metacharacters in a user's workspace or artifact directory.
printf -v amr_quoted_child '%q ' "${amr_child[@]}"
(
  # Keep emulator diagnostics in the uploaded artifact directory, not the repo.
  cd "$amr_output"
  env -u DEBUG firebase --config "$amr_repo/web/rules-tests/native-sdk.firebase.json" \
    --project demo-amr-native-sdk emulators:exec --only firestore \
    "$amr_quoted_child"
) 2>&1 | tee "$amr_output/native-tests.log"
echo "Native SDK and local client-contract results: $amr_output"
