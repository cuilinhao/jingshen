"""Checks the delivered project itself, not a hand-written configuration snapshot."""
import pathlib
import re
import subprocess
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[1]

class NativeProjectTests(unittest.TestCase):
    def test_actual_project_membership_and_schema(self):
        import sys
        subprocess.run([sys.executable, str(ROOT/'Scripts/validate_project.py')], check=True, capture_output=True, text=True)

    def test_no_model_build_phase(self):
        project = (ROOT/'PGYDepthDemo.xcodeproj/project.pbxproj').read_text()
        self.assertNotIn('PBXShellScriptBuildPhase', project)
        self.assertNotIn('PrepareDepthModel', project)
        self.assertNotIn('XCRemoteSwiftPackageReference', project)

    def test_no_model_download_scripts_or_weights(self):
        for name in ['Scripts/PrepareDepthModel.sh', 'Scripts/model-lock.json',
                     'Scripts/ModelManifest.json', 'Download_Model.command',
                     'PGYDepthDemo/Imaging/DepthEstimator.swift']:
            self.assertFalse((ROOT/name).exists(), name)
        self.assertFalse(list((ROOT/'PGYDepthDemo').rglob('*.mlpackage')))
        self.assertFalse(list((ROOT/'PGYDepthDemo').rglob('*.mlmodel')))

    def test_native_request_replaces_external_model(self):
        code = '\n'.join(p.read_text() for p in (ROOT/'PGYDepthDemo').rglob('*.swift'))
        self.assertIn('VNGenerateForegroundInstanceMaskRequest', code)
        self.assertIn('generateScaledMaskForImage', code)
        for forbidden in ['import CoreML', 'MLModel(', 'DepthAnything', 'URLSession',
                          'huggingface.co', 'missingModel', 'unsupportedModel']:
            self.assertNotIn(forbidden, code)

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
