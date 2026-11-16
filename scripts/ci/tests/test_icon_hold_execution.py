"""The execution gate must reject silent availability skips and partial argument sets."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("check_icon_hold_execution", Path(__file__).resolve().parents[1] / "check_icon_hold_execution.py")
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def complete_log():
    return "\n".join(f"✔ Test {name}{'(omission:)' if cases else '()'}{cases} passed after 0.123 seconds."
                     for name, cases in check.REQUIRED.items())


class IconHoldExecutionTests(unittest.TestCase):
    def test_accepts_all_required_passes_with_color(self):
        self.assertEqual(check.missing_passes("\x1b[32m" + complete_log() + "\x1b[0m"), [])

    def test_started_or_skipped_records_do_not_count(self):
        log = "\n".join(f"◇ Test {name}() started.\n✘ Test {name}() skipped."
                        for name in check.REQUIRED)
        self.assertEqual(check.missing_passes(log), list(check.REQUIRED))

    def test_requires_all_four_icon_map_cases(self):
        log = complete_log().replace("with 4 test cases", "with 3 test cases")
        self.assertEqual(check.missing_passes(log), [next(iter(check.REQUIRED))])

    def test_failure_summary_does_not_count_as_a_pass(self):
        log = complete_log().replace("passed after", "failed after")
        self.assertEqual(check.missing_passes(log), list(check.REQUIRED))


if __name__ == "__main__":
    unittest.main()
