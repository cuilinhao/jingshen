"""Validate the delivered project, offline assets, and depth-source provenance."""
import copy
import importlib.util
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('validate_project', ROOT/'Scripts/validate_project.py')
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class NativeProjectTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.objects = validator.load_project()

    def test_actual_project_membership_and_schema(self):
        result = subprocess.run([sys.executable, str(ROOT/'Scripts/validate_project.py')],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_no_download_build_phase_or_remote_package(self):
        validator.validate_references(self.objects)
        for name in ['Scripts/PrepareDepthModel.sh', 'Scripts/model-lock.json',
                     'Scripts/ModelManifest.json', 'Download_Model.command']:
            self.assertFalse((ROOT/name).exists(), name)
        validator.validate_offline_sources()

    def test_offline_guard_rejects_runtime_downloader(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            (root/'PGYDepthDemo').mkdir()
            source = root/'PGYDepthDemo/Downloader.swift'
            for code in ['let session = URLSession.shared', 'let url = "https://example.com/model"']:
                with self.subTest(code=code):
                    source.write_text(code)
                    with self.assertRaisesRegex(AssertionError, 'Runtime network/download dependency'):
                        validator.validate_offline_sources(root)

    def test_bundled_model_contains_specification_and_real_weights(self):
        validator.validate_model_package(ROOT/validator.MODEL_PATH)
        validator.validate_membership(self.objects)
        self.assertTrue((ROOT/'Docs/DepthAnythingV2-LICENSE.txt').is_file())

    def test_model_validation_rejects_missing_empty_or_pointer_weights(self):
        original = ROOT/validator.MODEL_PATH
        with tempfile.TemporaryDirectory() as temp:
            package = pathlib.Path(temp)/original.name
            shutil.copytree(original, package, ignore=shutil.ignore_patterns('weight.bin'))
            weight = package/'Data/com.apple.CoreML/weights/weight.bin'
            with self.assertRaisesRegex(AssertionError, 'Missing model weight data'):
                validator.validate_model_package(package)
            weight.touch()
            with self.assertRaisesRegex(AssertionError, 'Empty model asset'):
                validator.validate_model_package(package)
            weight.write_text('version https://git-lfs.github.com/spec/v1\noid sha256:placeholder\nsize 49419072\n')
            with self.assertRaisesRegex(AssertionError, 'LFS pointer'):
                validator.validate_model_package(package)

    def test_model_manifest_must_reference_its_bundled_model(self):
        with tempfile.TemporaryDirectory() as temp:
            package = pathlib.Path(temp)
            manifest = json.loads((ROOT/validator.MODEL_PATH/'Manifest.json').read_text())
            manifest['rootModelIdentifier'] = 'absent'
            (package/'Manifest.json').write_text(json.dumps(manifest))
            with self.assertRaisesRegex(AssertionError, 'Missing root model entry'):
                validator.validate_model_package(package)

    def test_membership_rejects_wrong_phase_target_and_duplicate_entries(self):
        def phase(objects, target_name, kind):
            target = next(obj for obj in objects.values()
                          if obj['isa'] == 'PBXNativeTarget' and obj['name'] == target_name)
            return next(objects[key] for key in target['buildPhases'] if objects[key]['isa'] == kind)

        for path, owner, current_kind, wrong_owner, wrong_kind in [
            (validator.MODEL_PATH, 'PGYDepthDemo', 'PBXSourcesBuildPhase', 'PGYDepthDemo', 'PBXResourcesBuildPhase'),
            (validator.ESTIMATOR_PATH, 'PGYDepthDemo', 'PBXSourcesBuildPhase', 'PGYDepthDemo', 'PBXResourcesBuildPhase'),
            (validator.FIXTURE_PATH, 'PGYDepthDemoTests', 'PBXResourcesBuildPhase', 'PGYDepthDemo', 'PBXResourcesBuildPhase'),
        ]:
            for duplicate in [False, True]:
                with self.subTest(path=path, duplicate=duplicate):
                    objects = copy.deepcopy(self.objects)
                    source = phase(objects, owner, current_kind)
                    build = next(key for key in source['files'] if objects[objects[key]['fileRef']]['path'] == path)
                    if not duplicate:
                        source['files'].remove(build)
                    phase(objects, wrong_owner, wrong_kind)['files'].append(build)
                    with self.assertRaisesRegex(AssertionError, 'Wrong or duplicate membership'):
                        validator.validate_membership(objects)

    def test_estimated_depth_remains_distinct_after_serialization(self):
        # Exercise the shipped Swift types rather than matching their source spelling.
        harness = '''
import Foundation
let field = try DepthField(width: 2, height: 1, values: [0.2, 0.8])
let native = PhotoAnalysis.native(field)
let estimated = PhotoAnalysis.estimated(DepthEstimate(field: field))
precondition(native != estimated)
precondition(native.isNative && !native.isEstimated)
precondition(!estimated.isNative && estimated.isEstimated)
precondition(native.sourceDescription != estimated.sourceDescription)
let encoder = PropertyListEncoder()
let decoder = PropertyListDecoder()
for analysis in [native, estimated] {
    let restored = try decoder.decode(PhotoAnalysis.self, from: encoder.encode(analysis))
    precondition(restored == analysis)
    precondition(restored.depthField == field)
    precondition(restored.isNative == analysis.isNative)
    precondition(restored.isEstimated == analysis.isEstimated)
}
let oldModel = PhotoAnalysis.estimated(DepthEstimate(field: field, modelIdentifier: "older-model"))
precondition(!oldModel.supportsAutomaticDepthCache)
precondition(native.supportsAutomaticDepthCache && estimated.supportsAutomaticDepthCache)
print("PASS: camera and estimated depth retain their provenance")
'''
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            main = root/'main.swift'
            main.write_text(harness)
            executable = root/'provenance-check'
            sources = sorted((ROOT/'PGYDepthDemo/Core').glob('*.swift'))
            result = subprocess.run(['swiftc', *map(str, sources), str(main), '-o', str(executable)],
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS: camera and estimated depth retain their provenance', result.stdout)

    def test_only_swift_product_code(self):
        for suffix in ['.m', '.mm', '.c', '.cpp', '.metal']:
            self.assertFalse(list((ROOT/'PGYDepthDemo').rglob('*'+suffix)))

    def test_reference_geometry_and_fixed_pointer_are_retained(self):
        view = (ROOT/'PGYDepthDemo/UI/DepthEditorView.swift').read_text()
        for measured in ['width: 402, height: 874', 'width: 388, height: 518', 'x: 7, y: 62',
                         'x: 5, y: 621', 'x: 10, y: 695', 'x: 5, y: 766', 'x: 337, y: 766']:
            self.assertIn(measured, view)
        controls = (ROOT/'PGYDepthDemo/UI/ReferenceControls.swift').read_text()
        self.assertIn('private let indexX: CGFloat = 191', controls)
        self.assertIn('log2(f / Aperture.clamp(value))', controls)
        panel = (ROOT/'PGYDepthDemo/UI/EditorPanel.swift').read_text()
        # A title-only Section initializer does not accept a trailing footer.
        self.assertNotIn('Section("选择方式")', panel)
        self.assertIn('} header: { Text("选择方式") } footer: {', panel)


if __name__ == '__main__':
    unittest.main()
