#!/usr/bin/env python3
"""Check the real Xcode project and offline model package. NOT an iOS compiler."""
import collections
import json
import pathlib
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODEL_PATH = 'PGYDepthDemo/Resources/DepthAnythingV2SmallF16.mlpackage'
ESTIMATOR_PATH = 'PGYDepthDemo/Imaging/CoreMLDepthEstimator.swift'
FIXTURE_PATH = 'Tests/Fixtures/FocusScene.png'


def load_project(root=ROOT):
    raw = subprocess.check_output([
        'swift', str(root/'Scripts/InspectProject.swift'),
        str(root/'PGYDepthDemo.xcodeproj/project.pbxproj')], text=True)
    return json.loads(raw)['objects']


def validate_references(objects, root=ROOT):
    for key, obj in objects.items():
        for field in ['children', 'files', 'buildPhases', 'dependencies', 'targets', 'buildConfigurations']:
            for ref in obj.get(field, []):
                assert ref in objects, (key, field, ref)
        for field in ['fileRef', 'mainGroup', 'productRefGroup', 'buildConfigurationList',
                      'productReference', 'target', 'targetProxy', 'containerPortal', 'remoteGlobalIDString']:
            if field in obj:
                assert obj[field] in objects, (key, field, obj[field])
        if obj['isa'] == 'PBXFileReference' and obj.get('sourceTree') == '<group>':
            assert (root/obj['path']).exists(), obj['path']
        assert obj['isa'] not in ['PBXShellScriptBuildPhase', 'XCRemoteSwiftPackageReference'], obj


def validate_membership(objects, root=ROOT):
    targets = {obj['name']: obj for obj in objects.values() if obj['isa'] == 'PBXNativeTarget'}
    owners = collections.defaultdict(list)
    for name, target in targets.items():
        for phase_id in target['buildPhases']:
            owners[phase_id].append(name)

    # Count all phases, including orphaned phases, to catch duplicate compilation/copying.
    memberships = collections.defaultdict(list)
    for phase_id, phase in objects.items():
        if not phase['isa'].endswith('BuildPhase'):
            continue
        for build_id in phase.get('files', []):
            path = objects[objects[build_id]['fileRef']]['path']
            memberships[path].append((tuple(owners[phase_id]), phase['isa']))

    for path, target, phase in [
        (MODEL_PATH, 'PGYDepthDemo', 'PBXSourcesBuildPhase'),
        (ESTIMATOR_PATH, 'PGYDepthDemo', 'PBXSourcesBuildPhase'),
        (FIXTURE_PATH, 'PGYDepthDemoTests', 'PBXResourcesBuildPhase'),
    ]:
        assert memberships[path] == [((target,), phase)], f'Wrong or duplicate membership: {path}: {memberships[path]}'

    counts = {}
    for target_name, folder in [('PGYDepthDemo', 'PGYDepthDemo'), ('PGYDepthDemoTests', 'Tests')]:
        phases = [objects[key] for key in targets[target_name]['buildPhases']
                  if objects[key]['isa'] == 'PBXSourcesBuildPhase']
        assert len(phases) == 1, f'Expected one Sources phase: {target_name}'
        paths = [objects[objects[key]['fileRef']]['path'] for key in phases[0]['files']]
        expected = {str(path.relative_to(root)) for path in (root/folder).rglob('*.swift')}
        if target_name == 'PGYDepthDemo':
            expected.add(MODEL_PATH)  # Xcode compiles the package into a bundled .mlmodelc.
        assert set(paths) == expected, (target_name, set(paths) ^ expected)
        assert len(paths) == len(set(paths)), f'Duplicate Compile Sources entry: {target_name}'
        counts[target_name] = len(paths)
    packages = {str(path.relative_to(root)) for path in (root/'PGYDepthDemo').rglob('*.mlpackage')}
    assert packages == {MODEL_PATH}, f'Unexpected model packages: {packages}'
    return counts


def validate_model_package(package):
    manifest = json.loads((package/'Manifest.json').read_text())
    assert manifest['fileFormatVersion'] == '1.0.0', 'Unsupported model manifest format'
    entries = manifest['itemInfoEntries']
    assert manifest['rootModelIdentifier'] in entries, 'Missing root model entry'
    data = (package/'Data').resolve()
    paths = {}
    for identifier, entry in entries.items():
        relative = pathlib.PurePosixPath(entry['path'])
        assert not relative.is_absolute() and '..' not in relative.parts, 'Model entry escapes package'
        path = (data/relative).resolve()
        assert path.is_relative_to(data) and path.exists(), f'Missing model asset: {relative}'
        paths[identifier] = path
    model = paths[manifest['rootModelIdentifier']]
    assert model.is_file() and model.suffix == '.mlmodel', 'Root model is not an ML model specification'
    weights = [path for identifier, path in paths.items() if entries[identifier]['name'] == 'weights']
    assert len(weights) == 1 and weights[0].is_dir(), 'Missing model weights directory'
    weight_files = list(weights[0].rglob('*.bin'))
    assert weight_files, 'Missing model weight data'
    for path in [model, *weight_files]:
        assert path.stat().st_size > 0, f'Empty model asset: {path}'
        with path.open('rb') as handle:
            assert not handle.read(128).startswith(b'version https://git-lfs.github.com/spec/v1'), f'LFS pointer instead of model asset: {path}'


def validate_offline_sources(root=ROOT):
    # This is a dependency guard, not proof of radio-disabled execution; iOS tests cover inference.
    forbidden = re.compile(r'\b(?:URLSession|NSURLConnection|NWConnection|MLModelCollection)\b|https?://')
    for path in (root/'PGYDepthDemo').rglob('*.swift'):
        assert not forbidden.search(path.read_text()), f'Runtime network/download dependency: {path}'


def main():
    objects = load_project()
    validate_references(objects)
    counts = validate_membership(objects)
    validate_model_package(ROOT/MODEL_PATH)
    validate_offline_sources()
    for path in list((ROOT/'PGYDepthDemo').rglob('*.plist')) + list((ROOT/'PGYDepthDemo').rglob('*.xcprivacy')):
        plistlib.loads(path.read_bytes())
    info = plistlib.loads((ROOT/'PGYDepthDemo/Resources/Info.plist').read_bytes())
    assert info.get('NSPhotoLibraryAddUsageDescription')
    privacy = plistlib.loads((ROOT/'PGYDepthDemo/Resources/PrivacyInfo.xcprivacy').read_bytes())
    reasons = {entry['NSPrivacyAccessedAPIType']: set(entry['NSPrivacyAccessedAPITypeReasons'])
               for entry in privacy['NSPrivacyAccessedAPITypes']}
    assert reasons.get('NSPrivacyAccessedAPICategoryFileTimestamp') == {'C617.1', '3B52.1'}, 'File metadata privacy reasons missing'
    assert privacy['NSPrivacyTracking'] is False and not privacy['NSPrivacyCollectedDataTypes']
    for path in (ROOT/'PGYDepthDemo/Resources/Assets.xcassets').rglob('*.json'):
        json.loads(path.read_text())
    scheme = ET.parse(ROOT/'PGYDepthDemo.xcodeproj/xcshareddata/xcschemes/PGYDepthDemo.xcscheme')
    for ref in scheme.findall('.//BuildableReference'):
        assert ref.attrib['BlueprintIdentifier'] in objects
    for path in (ROOT/'Scripts').glob('*.sh'):
        subprocess.run(['bash', '-n', str(path)], check=True)
    subprocess.run(['plutil', '-lint', '--', str(ROOT/'PGYDepthDemo.xcodeproj/project.pbxproj')], check=True)
    state = (ROOT/'PGYDepthDemo/State/EditorModel.swift').read_text()
    for guard in ['token == importGeneration', 'token == renderGeneration', 'self.photo?.id == photo.id']:
        assert guard in state
    print(f'PASS: actual .pbxproj parsed; {len(objects)} object references; {counts}; resources, scheme, plist, script syntax.')
    print('PASS: bundled Core ML specification and weights; model compiled once in App Sources; test fixture only in Test Resources.')
    print('PASS: no Run Script phase, remote package, or runtime network dependency; latest-request-wins guards retained.')
    print('NOT RUN HERE: Apple SDK typecheck/link/sign, Core ML inference, Core Image render, iPhone UI or offline first launch.')


if __name__ == '__main__':
    main()
