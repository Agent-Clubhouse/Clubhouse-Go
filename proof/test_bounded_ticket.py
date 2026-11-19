"""Mocked deadline/cleanup proof. No process, signal, test worker or simulator starts."""
import importlib.util
import pathlib
import subprocess
import unittest

spec = importlib.util.spec_from_file_location('bounded_ticket', pathlib.Path(__file__).with_name('run-bounded-ticket.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class Clock:
    value = 0.0
    def __call__(self): return self.value

class Process:
    pid = 100
    returncode = None
    def __init__(self, clock, deadline=False, complete_at=.25, term_error=False):
        self.clock, self.deadline, self.complete_at = clock, deadline, complete_at
        self.term_error = term_error
        self.waits = self.terms = self.kills = 0
    def poll(self): return self.returncode
    def wait(self, timeout):
        self.waits += 1
        if self.kills: self.returncode = -9; return -9
        if not self.deadline: self.clock.value = self.complete_at; self.returncode = 0; return 0
        if self.waits == 1: self.clock.value = 840
        else: self.clock.value += min(timeout, 45)
        raise subprocess.TimeoutExpired('MOCK', timeout)
    def send_signal(self, signal):
        self.terms += 1
        if self.term_error: raise OSError('MOCK TERM error')
    def kill(self): self.kills += 1; self.returncode = -9

class BoundedTicketTests(unittest.TestCase):
    def exercise(self, *, deadline=False, complete_at=.25, fallback='owned', final_error=False,
                 final_delay=.1, group_exited=False, term_error=False):
        clock = Clock(); process = Process(clock, deadline, complete_at, term_error)
        calls, signals = [], []
        worker = '200 100 200 python3 -u ' + module.RUNNER + ' P1 p1-test --worker'
        def rows():
            calls.append('PS')
            if len(calls) == 1: return [worker]
            if deadline and len(calls) == 2:
                if fallback == 'timeout':
                    clock.value += 3
                    raise subprocess.TimeoutExpired('MOCK PS', 3)
                if fallback == 'unproven': return ['999 1 200 unrelated-command']
                return [worker]
            clock.value += final_delay
            if final_error: raise subprocess.TimeoutExpired('MOCK final PS', 3)
            return ['999 1 200 unrelated-command'] if fallback == 'unproven' else []
        def signal(group, value):
            signals.append((group, value))
            if group_exited: raise ProcessLookupError('MOCK exited')
        report = module.supervise(process, root=pathlib.Path('/MOCK/proof'), phase='P1', label='p1-test',
            limit=900, started=0, clock=clock, inspect_rows=rows, group_signal=signal, receipt_group=lambda: 200)
        return report, process, signals

    def test_normal_closure_is_after_known_final_inspection(self):
        report, process, signals = self.exercise()
        self.assertEqual(report['rc'], 0)
        self.assertEqual(report['owned_worker_members_after'], [])
        self.assertTrue(report['final_process_inspection_known'])
        self.assertAlmostEqual(report['outer_duration_seconds'], .35)
        self.assertEqual(process.kills, 0); self.assertEqual(signals, [])

    def test_final_ps_crossing_deadline_cannot_pass(self):
        report, process, signals = self.exercise(complete_at=899.5, final_delay=1)
        self.assertEqual(report['outer_duration_seconds'], 900.5)
        self.assertEqual(report['rc'], 1)
        self.assertEqual(report['owned_worker_members_after'], [])

    def test_fallback_ps_timeout_still_kills_and_waits_own_supervisor(self):
        report, process, signals = self.exercise(deadline=True, fallback='timeout')
        self.assertEqual(process.kills, 1); self.assertEqual(process.waits, 3)
        self.assertEqual(signals, [])
        self.assertEqual(report['runner_rc'], -9); self.assertEqual(report['rc'], 1)
        self.assertIn('fallback process inspection', [e['stage'] for e in report['errors']])

    def test_group_exit_race_cannot_abandon_supervisor_cleanup(self):
        report, process, signals = self.exercise(deadline=True, group_exited=True)
        self.assertEqual(process.kills, 1); self.assertEqual(process.waits, 3)
        self.assertEqual(len(signals), 1)
        self.assertIn('Proven worker group exited before KILL', report['notes'])
        self.assertEqual(report['rc'], 1)

    def test_unknown_final_inspection_is_not_empty_or_success(self):
        report, process, signals = self.exercise(final_error=True)
        self.assertFalse(report['final_process_inspection_known'])
        self.assertIsNone(report['owned_worker_members_after'])
        self.assertIsNone(report['owned_supervisor_members_after'])
        self.assertEqual(report['rc'], 1)

    def test_unproven_group_is_not_signalled_and_is_retained_as_surviving_evidence(self):
        report, process, signals = self.exercise(deadline=True, fallback='unproven')
        self.assertEqual(signals, [])
        self.assertEqual(process.kills, 1); self.assertEqual(process.waits, 3)
        self.assertTrue(report['owned_worker_members_after'])
        self.assertIn('worker ownership', [e['stage'] for e in report['errors']])
        self.assertEqual(report['rc'], 1)

    def test_term_error_still_completes_bounded_kill_wait(self):
        report, process, signals = self.exercise(deadline=True, term_error=True)
        self.assertEqual(process.kills, 1); self.assertEqual(process.waits, 3)
        self.assertIn('supervisor TERM', [e['stage'] for e in report['errors']])
        self.assertEqual(report['rc'], 1)

if __name__ == '__main__': unittest.main()
