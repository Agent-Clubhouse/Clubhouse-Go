#!/usr/bin/env python3
"""Bound admission through owned cleanup, without changing the reviewed core runner."""
import datetime
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

RUNNER = '/tmp/ux-610-evidence/proof/run-ticket-stabilized.py'

def parsed(rows):
    return [row.split(None, 3) for row in rows if len(row.split(None, 3)) == 4]

def supervise(process, *, root, phase, label, limit, started, clock, inspect_rows,
              group_signal, receipt_group, interrupted=lambda: None):
    errors, notes = [], []
    worker = None
    deadline_stop = False
    final_rows = None

    def problem(stage, error):
        errors.append({'stage': stage, 'error': repr(error)})

    def probe(stage):
        try:
            return parsed(inspect_rows())
        except Exception as error:
            problem(stage, error)
            return None

    def poll(stage):
        try:
            return process.poll()
        except Exception as error:
            problem(stage, error)
            return None

    try:
        while poll('monitor poll') is None and clock() - started < limit - 60:
            if interrupted():
                problem('interrupted', RuntimeError(interrupted()))
                break
            rows = probe('monitor process inspection')
            if rows is None:
                break
            for pid, ppid, pgid, command in rows:
                if ppid == str(process.pid) and RUNNER in command and command.endswith(phase + ' ' + label + ' --worker'):
                    if pid != pgid:
                        raise RuntimeError('Reviewed worker must own its separate group')
                    worker = int(pid)
            try:
                process.wait(timeout=min(5, max(.01, limit - 60 - (clock() - started))))
            except subprocess.TimeoutExpired:
                pass
        if poll('deadline poll') is None and not errors:
            deadline_stop = True
    except BaseException as error:
        problem('monitor', error)
    finally:
        # Probe/signal errors cannot skip cleanup of our own Popen child.
        if poll('cleanup poll') is None:
            try:
                process.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                notes.append('Owned supervisor exited before TERM')
            except Exception as error:
                problem('supervisor TERM', error)
            try:
                process.wait(timeout=max(.01, min(45, limit - 10 - (clock() - started))))
            except Exception as error:
                problem('supervisor graceful wait', error)
                rows = probe('fallback process inspection')
                if worker is not None and rows is not None:
                    members = [p for p in rows if p[2] == str(worker)]
                    owned = any(p[0] == str(worker) and RUNNER in p[3] and p[3].endswith(phase + ' ' + label + ' --worker') for p in members)
                    owned = owned or any(str(root) in p[3] for p in members)
                    if members and owned:
                        try:
                            group_signal(worker, signal.SIGKILL)
                        except ProcessLookupError:
                            notes.append('Proven worker group exited before KILL')
                        except Exception as error:
                            problem('worker group KILL', error)
                    elif members:
                        problem('worker ownership', RuntimeError('Unproven group; no unrelated signal'))
                # This is always our exact Popen child; never depend on a PS probe.
                try:
                    process.kill()
                except ProcessLookupError:
                    notes.append('Owned supervisor exited before KILL')
                except Exception as error:
                    problem('supervisor KILL', error)
                try:
                    process.wait(timeout=3)
                except Exception as error:
                    problem('supervisor final wait', error)
        try:
            recorded_worker = receipt_group()
            if worker is None:
                worker = recorded_worker
            elif recorded_worker is not None and worker != recorded_worker:
                problem('worker identity', RuntimeError('Core receipt group differs from observed child'))
        except Exception as error:
            problem('core worker receipt', error)
        final_rows = probe('final process inspection')
        supervisor_rc = poll('final supervisor poll')
        if worker is None:
            problem('final worker identity', RuntimeError('Worker group unknown; not empty'))
        members = None if final_rows is None or worker is None else [' '.join(p) for p in final_rows if p[2] == str(worker)]
        supervisor_members = None if final_rows is None else [' '.join(p) for p in final_rows if p[0] == str(process.pid)]
        # Timestamp and deadline acceptance come AFTER all potentially slow probes.
        elapsed = clock() - started
        report = dict(phase=phase, label=label, runner_pid=process.pid, worker_group=worker,
                      runner_rc=supervisor_rc, deadline_stop=deadline_stop, errors=errors, notes=notes,
                      outer_duration_seconds=elapsed, outer_bound_seconds=limit,
                      closed_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      final_process_inspection_known=final_rows is not None,
                      owned_worker_members_after=members, owned_supervisor_members_after=supervisor_members)
        report['rc'] = 0 if supervisor_rc == 0 and not deadline_stop and not errors and elapsed < limit and members == [] and supervisor_members == [] else 1
    return report

def main():
    started = time.monotonic()
    root = pathlib.Path(os.environ['UX610_PROOF_ROOT'])
    phase, label = sys.argv[1:3]
    limit = json.loads((root / 'manifest.json').read_text())['phases'][phase]['bound']
    assert limit >= 120
    envelope = json.loads((root / 'execution-envelope.json').read_text())
    digest = lambda path: hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    assert digest(__file__) == envelope['outer_sha256']
    assert digest(RUNNER) == envelope['core_runner_sha256']
    assert digest(root / 'manifest.json') == envelope['manifest_sha256']
    output = root / (label + '-outer-closure.json')
    assert not output.exists()
    stopped = []
    def interrupt(signum, unused):
        stopped.append(str(signum))
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    assert time.monotonic() - started < limit - 60 and not stopped, 'Preflight stopped; no worker started'
    process = subprocess.Popen([sys.executable, '-u', RUNNER, phase, label], start_new_session=True)
    def inspect():
        return subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,pgid=,command='], text=True, timeout=3).splitlines()
    def group():
        return json.loads((root / (label + '-receipt.json')).read_text())['owned_process_group']
    report = supervise(process, root=root, phase=phase, label=label, limit=limit,
                       started=started, clock=time.monotonic, inspect_rows=inspect,
                       group_signal=os.killpg, receipt_group=group,
                       interrupted=lambda: ','.join(stopped))
    output.write_text(json.dumps(report, indent=2) + '\n')
    print('OUTER CLOSURE ' + json.dumps(report), flush=True)
    return report['rc']

if __name__ == '__main__':
    sys.exit(main())
