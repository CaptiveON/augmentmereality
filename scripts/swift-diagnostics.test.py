import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("diagnostics", Path(__file__).with_name("swift-diagnostics.py"))
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class DiagnosticGateTests(unittest.TestCase):
    def full_compile(self):
        return "\n".join("SwiftCompile normal arm64 /repo/AugmentMeReality/" + path
                         for path in diagnostics.BOUNDARIES) + "\n** TEST BUILD SUCCEEDED **\n"

    def test_requires_compilation_not_just_success(self):
        self.assertFalse(diagnostics.gate_passes(diagnostics.inventory("** BUILD SUCCEEDED **")))
        self.assertTrue(diagnostics.gate_passes(diagnostics.inventory(self.full_compile())))

    def test_blocks_boundary_diagnostic_and_deduplicates_batch_output(self):
        warning = "/some path/AugmentMeReality/AugmentMeReality/AR/GeospatialEngine.swift:15:2: warning: capture risks data race\n"
        result = diagnostics.inventory(self.full_compile() + warning * 2)
        self.assertFalse(diagnostics.gate_passes(result))
        self.assertEqual(result["uniqueAppDiagnostics"], 1)
        self.assertEqual(result["diagnostics"][0]["path"], "AR/GeospatialEngine.swift")

    def test_remaining_storage_blocker_is_visible_without_claiming_migration(self):
        warning = "AugmentMeReality/Services/DropStore.swift:4:8: warning: non-Sendable store\n"
        result = diagnostics.inventory(self.full_compile() + warning)
        self.assertTrue(diagnostics.gate_passes(result))
        self.assertEqual(result["uniqueAppDiagnostics"], 1)
        self.assertEqual(result["byFile"], {"Services/DropStore.swift": 1})

    def test_dependency_warning_is_excluded_and_failed_build_is_rejected(self):
        log = self.full_compile().replace("** TEST BUILD SUCCEEDED **", "** BUILD FAILED **")
        log += "/SourcePackages/Firebase/Firebase.swift:3:7: warning: dependency issue\n"
        result = diagnostics.inventory(log)
        self.assertEqual(result["uniqueAppDiagnostics"], 0)
        self.assertFalse(diagnostics.gate_passes(result))

    def test_new_boundary_helpers_are_gated(self):
        for directory in ("Streetscape", "SceneContent", "Render", "Occlusion"):
            result = diagnostics.inventory(self.full_compile() +
                f"AugmentMeReality/Services/{directory}Test.swift:1:1: error: failed isolation\n")
            self.assertFalse(diagnostics.gate_passes(result))


if __name__ == "__main__":
    unittest.main()
