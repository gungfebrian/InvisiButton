import importlib.util
import unittest
from pathlib import Path


DETECTOR_PATH = Path(__file__).parents[1] / "tools" / "detect" / "detector.py"
SPEC = importlib.util.spec_from_file_location("detector", DETECTOR_PATH)
detector = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(detector)


def sample_stream(count: int):
    period_ns = 1_250_000
    return [(i * period_ns, 0.0, 0.0, 0.0, i) for i in range(count)]


def quiet_scores(count: int):
    return [(0.0, [0.0, 0.0, 0.0]) for _ in range(count)]


class DetectorWindowTests(unittest.TestCase):
    def test_accepts_rotation_in_full_direction_window(self):
        """A valid knock must include the full 110 ms direction window."""
        count = 300
        onset = 100
        delayed_rotation = onset + 70  # 87.5 ms after onset
        accel = sample_stream(count)
        gyro = sample_stream(count)
        accel_scores = quiet_scores(count)
        gyro_scores = quiet_scores(count)
        accel_scores[onset] = (9.0, [0.080, 0.0, 0.0])
        gyro_scores[delayed_rotation] = (9.0, [2.0, 0.0, 0.0])

        knocks = detector.detect(
            accel,
            gyro,
            k_accel=8.0,
            k_gyro=5.0,
            require_both=True,
            ascore=accel_scores,
            gscore=gyro_scores,
            a_min=0.075,
            ratio_min=20.0,
        )

        self.assertEqual([event[1] for event in knocks], [onset])


if __name__ == "__main__":
    unittest.main()
