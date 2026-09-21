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

    def test_no_download_scripts_or_placeholder_model(self):
        for name in ['Scripts/PrepareDepthModel.sh', 'Download_Model.command', 'Scripts/ModelManifest.json']:
            self.assertFalse((ROOT/name).exists(), name)
        self.assertEqual(len(list((ROOT/'PGYDepthDemo').rglob('*.mlpackage'))), 1)

    def test_automatic_model_replaces_subject_only_depth_guess(self):
        code = (ROOT/'PGYDepthDemo/Imaging/PhotoPipeline.swift').read_text()
        self.assertIn('depthEstimator.estimate', code)
        self.assertIn('AutomaticDepthCache.reusable', code)
        self.assertNotIn('analyzeLayers', code)
        self.assertNotIn('segmenter.analyze', code)
        all_code = '\n'.join(p.read_text() for p in (ROOT/'PGYDepthDemo').rglob('*.swift'))
        self.assertNotIn('URLSession', all_code)

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

    def test_no_single_subject_focus_rule_remains(self):
        code = (ROOT/'PGYDepthDemo/Core/SubjectMasks.swift').read_text()
        self.assertNotIn('func sharpMask(',code)
        self.assertIn('case .layered(let scene)',code)
        self.assertIn('scene.map.focusMasks',code)
        self.assertNotIn('safe.focusMode == .local || analysis.isFallback',code)

    def test_layer_changes_invalidate_cached_masks(self):
        pipeline = (ROOT/'PGYDepthDemo/Imaging/PhotoPipeline.swift').read_text()
        state = (ROOT/'PGYDepthDemo/State/EditorModel.swift').read_text()
        self.assertIn('func replacingAnalysis',pipeline)
        self.assertIn('PhotoSession(id: UUID()',pipeline)
        self.assertIn('self.photo = photo.replacingAnalysis',state)
        self.assertIn('photo.id == sourceID',state)
        self.assertIn('scene.map.layer(at: point) == .unknown',state)

    def test_human_fixture_is_test_only_and_normal_import_is_automatic(self):
        import hashlib, json
        fixture = json.loads((ROOT/'Tests/Fixtures/ReferenceLayers.json').read_text())
        self.assertEqual(fixture['sourceSHA256'],hashlib.sha256((ROOT/'PGYDepthDemo/Resources/ReferencePhoto.png').read_bytes()).hexdigest())
        self.assertIn('人工',fixture['description'])
        pipeline=(ROOT/'PGYDepthDemo/Imaging/PhotoPipeline.swift').read_text()
        state=(ROOT/'PGYDepthDemo/State/EditorModel.swift').read_text()
        self.assertNotIn('func loadReference()',pipeline)
        self.assertNotIn('referenceData',state)
        self.assertNotIn('title.contains(',pipeline)
        self.assertFalse((ROOT/'PGYDepthDemo/Resources/ReferenceLayers.json').exists())
        data=(ROOT/'Tests/Fixtures/AutomaticReference.f32').read_bytes()
        actual=json.loads((ROOT/'Tests/Fixtures/AutomaticReference.json').read_text())
        self.assertEqual(hashlib.sha256(data).hexdigest(),actual['predictionSHA256'])
        self.assertEqual(actual['imageSHA256'], fixture['sourceSHA256'])

    def test_selected_layer_is_protected_after_diffusion(self):
        code=(ROOT/'PGYDepthDemo/Imaging/DepthRenderer.swift').read_text()
        self.assertIn('if let protection = selections.protection',code)
        self.assertGreater(code.index('if let protection = selections.protection'),code.index('expanded.composited'))

if __name__ == '__main__':
    unittest.main()
