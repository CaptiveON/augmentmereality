import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name("ios-simulator-matrix.py")
spec = importlib.util.spec_from_file_location("ios_simulator_matrix", path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SimulatorMatrixTests(unittest.TestCase):
    def test_request_for_minimum_cannot_fall_forward_to_current(self):
        runtimes = [{"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                     "version": "26.5", "isAvailable": True}]
        self.assertIsNone(module.matching_runtime(runtimes, "17.0"))

    def test_exact_minor_accepts_patch_and_rejects_unavailable_runtime(self):
        runtimes = [
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0",
             "version": "17.0.1", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-1",
             "version": "17.1", "isAvailable": True},
            {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-0-stale",
             "version": "17.0.2", "isAvailable": False},
        ]
        self.assertEqual(module.matching_runtime(runtimes, "17.0")["version"], "17.0.1")
        self.assertIsNone(module.matching_runtime(runtimes, "26.5"))

    def test_device_selection_stays_with_selected_runtime(self):
        devices = {
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
                {"name": "iPhone 15", "udid": "old", "isAvailable": True}],
            "com.apple.CoreSimulator.SimRuntime.iOS-26-5": [
                {"name": "iPhone 17", "udid": "new", "isAvailable": True}],
        }
        selected = module.matching_device(devices,
            "com.apple.CoreSimulator.SimRuntime.iOS-17-0", "iPhone 15")
        self.assertEqual(selected["udid"], "old")
        self.assertIsNone(module.matching_device(devices, "missing", "iPhone 15"))


if __name__ == "__main__":
    unittest.main()
