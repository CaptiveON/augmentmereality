#!/usr/bin/env python3
"""Build provenance and honest summaries for AR baseline schema 1/2. Standard library only."""
import argparse
import hashlib
import json
import math
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path

SOURCE_PATHS = ['AugmentMeReality', 'AugmentMeRealityTests', 'Config', 'AugmentMeReality.xcodeproj']


def sha256(path):
    with Path(path).open('rb') as stream:
        digest = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])


def source_identity(root):
    paths = set(git(root, 'ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', *SOURCE_PATHS).decode().split('\0'))
    files = {}
    for name in sorted(paths - {''}):
        # Config presence is recorded separately; never export credentials or their hashes.
        if Path(name).name in {'Secrets.plist', 'GoogleService-Info.plist'}:
            continue
        files[name] = sha256(root / name) if (root / name).is_file() else 'deleted'
    source_hash = hashlib.sha256(json.dumps(files, sort_keys=True).encode()).hexdigest()
    return {
        'sourceCommit': git(root, 'rev-parse', 'HEAD').decode().strip(),
        'sourceHash': source_hash,
        'sourceDirty': bool(git(root, 'status', '--porcelain', '--', *SOURCE_PATHS).strip()),
        'sourceFileHashes': files,
        'serviceConfigurationPresent': {
            name: (root / 'AugmentMeReality/Support' / name).exists()
            for name in ['Secrets.plist', 'GoogleService-Info.plist']
        },
    }


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def manifest(root, app, output, configuration, identity=None):
    identity = identity or source_identity(root)
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    data = {
        'schemaVersion': 1, 'createdAt': datetime.now(timezone.utc).isoformat(),
        **identity, 'configuration': configuration,
        'appPath': str(app), 'bundleIdentifier': info['CFBundleIdentifier'],
        'executableSHA256': sha256(app / info['CFBundleExecutable']),
        'embeddedSourceCommit': info.get('ARBaselineSourceCommit', 'unmeasured'),
        'embeddedSourceHash': info.get('ARBaselineSourceHash', 'unmeasured'),
        'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
        'assetHashes': {str(p.relative_to(app)): sha256(p) for p in sorted(app.rglob('*.usdz'))},
        'deviceMeasurements': 'unmeasured; this manifest describes a build, not a field result',
    }
    write_json(output, data)
    return data


def build(args):
    root = args.root.resolve()
    identity = source_identity(root)
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    command = ['xcodebuild', '-project', str(root / 'AugmentMeReality.xcodeproj'),
               '-scheme', 'AugmentMeReality', '-configuration', 'Release',
               '-destination', 'generic/platform=iOS', '-derivedDataPath', str(args.derived_data.resolve()),
               '-disableAutomaticPackageResolution',
               'INFOPLIST_KEY_ARBaselineSourceCommit=' + identity['sourceCommit'],
               'INFOPLIST_KEY_ARBaselineSourceHash=' + identity['sourceHash'],
               'INFOPLIST_KEY_ARBaselineSourceDirty=' + str(identity['sourceDirty']).lower(),
               'INFOPLIST_KEY_ARBaselineBuildConfiguration=Release']
    if args.unsigned:
        command += ['CODE_SIGNING_ALLOWED=NO']
    elif args.team:
        command += ['DEVELOPMENT_TEAM=' + args.team, '-allowProvisioningUpdates']
    command += ['build']
    write_json(output / 'build-command.json', command)
    with (output / 'build.log').open('w') as log:
        subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
    # Refuse to assign pre-build provenance to source that changed during compilation.
    if source_identity(root)['sourceHash'] != identity['sourceHash']:
        raise ValueError('Sources changed during build; rebuild before using this artifact.')
    app = args.derived_data.resolve() / 'Build/Products/Release-iphoneos/AugmentMeReality.app'
    manifest(root, app, output / 'build-manifest.json', 'Release', identity)
    print(output / 'build-manifest.json')


def finite(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def clean(value):
    return str(value).replace('|', '\\|').replace('\n', ' ')


def number(value, digits=2):
    return f'{value:.{digits}f}' if finite(value) else 'unmeasured'


def summarize(data, conditions=None):
    if data.get('schemaVersion') not in (1, 2):
        raise ValueError('Unsupported baseline schema; expected 1 or 2.')
    conditions = conditions or {}
    metadata = data.get('metadata', {})
    lines = ['# AR baseline result', '', f"Run: {clean(data.get('runID', 'unmeasured'))}", '',
             '**Presentation and warmth are not inferred from callback or thermal measurements.**', '',
             '| Build / condition | Value |', '| --- | --- |']
    for key in ['build_source_commit', 'build_source_hash', 'build_source_dirty', 'build_configuration',
                'device_machine', 'os', 'experiment', 'asset', 'distance_meters', 'brightness', 'charging']:
        lines.append(f'| {key} | {clean(metadata.get(key, "unmeasured"))} |')
    for key in ['observed_warmth', 'initially_cool', 'screen_recording', 'raw_trace_locations', 'build_manifest']:
        lines.append(f'| {key} | {clean(conditions.get(key, "unmeasured"))} |')
    if conditions.get('screen_recording') is not False:
        lines += ['', 'Thermal-run eligibility: **unmeasured / not eligible** until screen recording is confirmed off.']
    lines += ['', 'Targets: ≥30 presented FPS; presented p95 ≤40 ms; no serious/critical thermal state through 10 minutes; observation through 15 minutes.',
              '', 'Actual presentation: **unmeasured**. Scene/postprocess statistics below are proxies.',
              '', 'Full-epoch percentiles are conservative 1 ms histogram upper bounds; overflow above 1000 ms remains explicit. Startup/recent percentiles use nearest rank.']
    for epoch in data.get('epochs', []):
        start, end = epoch['intentUptime'], epoch.get('endedUptime') or data['exportedUptime']
        duration = max(0, end - start)
        lines += ['', f"## Epoch {epoch['id']} · {clean(epoch['kind'])} · generation {epoch['generation']}",
                  '', f'Duration: {number(duration)} seconds. Fifteen-minute coverage: {"observed duration reached" if duration >= 900 else "incomplete"}.', '',
                  '| Milestone | ms since epoch | Details |', '| --- | --- | --- |']
        for name, value in sorted(epoch.get('conditions', {}).items()):
            lines.append(f'| condition: {clean(name)} | — | {clean(value)} |')
        events = epoch.get('firstEventsByName', {})
        for key in ['cameraIntent', 'recoveryIntent', 'selectedHero', 'firstFreshCameraFrameObserved',
                    'placeholderPlaced', 'selectedAssetReady', 'firstHeroSceneUpdateProxy']:
            event = events.get(key, {})
            elapsed = event.get('secondsSinceIntent')
            lines.append(f'| {key} | {number(elapsed * 1000 if finite(elapsed) else None)} | {clean(event.get("details", "unmeasured"))} |')
        lines += ['', '| Stream | Count | Mean ms | Mean callbacks/s | Full p95 upper ms | Full p99 upper ms | >1000 ms | Startup p95 ms | Recent p95 ms | Last-sample age ms |',
                  '| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
        for series in epoch.get('series', []):
            mean = series.get('meanMilliseconds')
            cadence = series['name'].endswith('.interval')
            rate = 1000 / mean if cadence and finite(mean) and mean > 0 else None
            full = series.get('wholeEpochHistogram', {})
            lines.append('| ' + ' | '.join([clean(series['name']), str(series['totalCount']), number(mean), number(rate),
                number(full.get('p95UpperBoundMilliseconds')), number(full.get('p99UpperBoundMilliseconds')),
                str(full.get('overflowCount', 'unmeasured')),
                number(series.get('startupFirstTenSeconds', {}).get('p95Milliseconds')),
                number(series.get('recentSamples', {}).get('p95Milliseconds')), number(series.get('sampleAgeMilliseconds'))]) + ' |')
        lines += ['', '| Workload | Enabled at endpoint | Active seconds in epoch | Transitions |', '| --- | --- | --- | --- |']
        for name, activity in sorted(epoch.get('workloadActivity', {}).items()):
            lines.append(f'| {clean(name)} | {activity["enabled"]} | {number(activity["observedActiveSeconds"])} | {activity["transitions"]} |')
        samples = [s for s in data.get('recentSystemSamples', []) if s.get('epochID') == epoch['id']]
        cpu = [(s['uptime'], s['processCPUSeconds']) for s in samples if finite(s.get('processCPUSeconds'))]
        lines += ['', f'Process CPU seconds across retained system samples: {number(cpu[-1][1] - cpu[0][1] if len(cpu) >= 2 else None)} (all process threads; not an inference attribution).']
        lines += ['', '| System-sample elapsed s | Thermal state | Resident bytes | Process CPU seconds |', '| --- | --- | --- | --- |']
        for sample in samples:
            lines.append(f'| {number(sample["uptime"] - start)} | {clean(sample["processThermalState"])} | {sample.get("residentMemoryBytes", "unmeasured")} | {number(sample.get("processCPUSeconds"))} |')
        serious = 'thermalSeriousOrCritical' in events or any(s.get('processThermalState') in ['serious', 'critical'] for s in samples)
        lines += ['', 'Thermal observation: **' + ('serious/critical observed' if serious else 'no serious/critical state in retained observations; gaps are unmeasured') + '**.',
                  f"Dropped records: events={epoch.get('droppedEvents', 0)}, series={epoch.get('droppedSeries', 0)}, event names={epoch.get('droppedEventNames', 0)}."]
    lines += ['', f"Eviction: epochs={data.get('droppedEpochs', 0)}, system samples={data.get('droppedSystemSamples', 0)}, late measurements={data.get('droppedLateMeasurements', 0)}.",
              '', 'A successful build or proxy target comparison does not establish presentation quality or a thermal improvement.', '']
    return '\n'.join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    b = sub.add_parser('build', help='Build Release with embedded source identity and an artifact manifest')
    b.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    b.add_argument('--derived-data', type=Path, required=True)
    b.add_argument('--output', type=Path, required=True)
    b.add_argument('--unsigned', action='store_true')
    b.add_argument('--team')
    m = sub.add_parser('manifest', help='Describe an existing app; embedded identity may remain unmeasured')
    m.add_argument('--root', type=Path, required=True)
    m.add_argument('--app', type=Path, required=True)
    m.add_argument('--configuration', required=True)
    m.add_argument('--output', type=Path, required=True)
    r = sub.add_parser('report', help='Summarize exported JSON without inventing device evidence')
    r.add_argument('input', type=Path)
    r.add_argument('--conditions', type=Path)
    r.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'build':
        build(args)
    elif args.command == 'manifest':
        manifest(args.root.resolve(), args.app.resolve(), args.output, args.configuration)
    else:
        data = json.loads(args.input.read_text())
        conditions = json.loads(args.conditions.read_text()) if args.conditions else {}
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(summarize(data, conditions))
        print(args.output)


if __name__ == '__main__':
    main()
