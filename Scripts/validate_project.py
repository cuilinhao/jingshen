#!/usr/bin/env python3
"""Validate the actual OpenStep project, resources and Swift target membership. NOT an iOS compiler."""
import json
import pathlib
import plistlib
import subprocess
import xml.etree.ElementTree as ET
ROOT = pathlib.Path(__file__).resolve().parents[1]
project_path = ROOT/'PGYDepthDemo.xcodeproj/project.pbxproj'
raw = subprocess.check_output(['swift', str(ROOT/'Scripts/InspectProject.swift'), str(project_path)], text=True)
project = json.loads(raw)
objects = project['objects']
for key, obj in objects.items():
    for field in ['children','files','buildPhases','dependencies','targets','buildConfigurations']:
        for ref in obj.get(field,[]):
            assert ref in objects, (key,field,ref)
    for field in ['fileRef','mainGroup','productRefGroup','buildConfigurationList',
                  'productReference','target','targetProxy','containerPortal','remoteGlobalIDString']:
        if field in obj: assert obj[field] in objects, (key,field,obj[field])
    if obj['isa']=='PBXFileReference' and obj.get('sourceTree')=='<group>':
        assert (ROOT/obj['path']).exists(), obj['path']
    assert obj['isa'] not in ['PBXShellScriptBuildPhase','XCRemoteSwiftPackageReference'], obj

counts={}
for target_name,folder in [('PGYDepthDemo','PGYDepthDemo'),('PGYDepthDemoTests','Tests')]:
    target=next(v for v in objects.values() if v['isa']=='PBXNativeTarget' and v['name']==target_name)
    phase=next(objects[k] for k in target['buildPhases'] if objects[k]['isa']=='PBXSourcesBuildPhase')
    all_paths=[objects[objects[k]['fileRef']]['path'] for k in phase['files']]
    paths=[p for p in all_paths if p.endswith('.swift')]
    extras=[p for p in all_paths if not p.endswith('.swift')]
    expected=['PGYDepthDemo/Resources/Models/DepthAnythingV2SmallF16.mlpackage'] if target_name=='PGYDepthDemo' else []
    assert extras==expected, (target_name,extras)
    actual={str(p.relative_to(ROOT)) for p in (ROOT/folder).rglob('*.swift')}
    assert set(paths)==actual, (target_name,set(paths)^actual)
    assert len(paths)==len(set(paths)), 'Duplicate Compile Sources entry'
    counts[target_name]=len(paths)

for path in list((ROOT/'PGYDepthDemo').rglob('*.plist'))+list((ROOT/'PGYDepthDemo').rglob('*.xcprivacy')):
    plistlib.loads(path.read_bytes())
info=plistlib.loads((ROOT/'PGYDepthDemo/Resources/Info.plist').read_bytes())
assert info.get('NSPhotoLibraryAddUsageDescription')
privacy = plistlib.loads((ROOT/'PGYDepthDemo/Resources/PrivacyInfo.xcprivacy').read_bytes())
reasons = {entry['NSPrivacyAccessedAPIType']: set(entry['NSPrivacyAccessedAPITypeReasons']) for entry in privacy['NSPrivacyAccessedAPITypes']}
assert reasons.get('NSPrivacyAccessedAPICategoryFileTimestamp') == {'C617.1', '3B52.1'}, 'File metadata privacy reasons missing'
assert privacy['NSPrivacyTracking'] is False and not privacy['NSPrivacyCollectedDataTypes']
for path in (ROOT/'PGYDepthDemo/Resources/Assets.xcassets').rglob('*.json'): json.loads(path.read_text())
scheme=ET.parse(ROOT/'PGYDepthDemo.xcodeproj/xcshareddata/xcschemes/PGYDepthDemo.xcscheme')
for ref in scheme.findall('.//BuildableReference'): assert ref.attrib['BlueprintIdentifier'] in objects
for path in (ROOT/'Scripts').glob('*.sh'): subprocess.run(['bash','-n',str(path)],check=True)
subprocess.run(['plutil','-lint','--',str(project_path)],check=True)

state=(ROOT/'PGYDepthDemo/State/EditorModel.swift').read_text()
for guard in ['token == importGeneration','token == renderGeneration','self.photo?.id == photo.id']:
    assert guard in state
print(f'PASS: actual .pbxproj parsed; {len(objects)} object references; {counts}; resources, scheme, plist, script syntax.')
print('PASS: no Run Script build phase; no remote package reference; original latest-request-wins guards retained.')
print('NOT RUN HERE: Apple SDK typecheck/link/sign, native Core ML prediction, Core Image render, iPhone UI or offline first launch.')

app=next(v for v in objects.values() if v['isa']=='PBXNativeTarget' and v['name']=='PGYDepthDemo')
phase=next(objects[k] for k in app['buildPhases'] if objects[k]['isa']=='PBXResourcesBuildPhase')
resources=[objects[objects[k]['fileRef']]['path'] for k in phase['files']]
assert all(not p.startswith('Tests/') for p in resources), 'No human or precomputed test map in App'
assert all(not p.endswith('.mlpackage') for p in resources), 'Compile model, do not raw-copy it'
assert 'PGYDepthDemo/Resources/Apache-2.0.txt' in resources
model=next(v for v in objects.values() if v['isa']=='PBXFileReference' and v.get('path','').endswith('.mlpackage'))
assert model['lastKnownFileType']=='folder.mlpackage'
print('PASS: complete model is configured for native compilation in Sources (compilation NOT run here); no test maps in App Resources.')
