"""Execute the actual launcher's event loop with finite synthetic OS events.

Only the loop, outcome tail, wait_normal and exit expression use its AST. Launch,
environment, XR, compositor and fixture setup are never evaluated. Real pipe
delivery is checked separately through the unchanged OwnedCommands owner.
"""
import ast
import contextlib
import io
import json
from pathlib import Path
import queue
import subprocess
import sys
import types
import unittest
from unittest.mock import patch

E = Path(__file__).resolve().parent
OWNER = E.parent / 'godot-vr-visual-readiness-20261102'
sys.path.insert(0, str(OWNER))
from supervision import Supervision
from owned_commands import OwnedCommands

source = ast.parse((OWNER / 'live.py').read_text())
body = next(n for n in source.body if isinstance(n, ast.Try))
loop = next(n for n in body.body if isinstance(n, ast.While))
wait = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == 'wait_normal')
code = compile(ast.Module(body=[wait, *body.body[body.body.index(loop):]], type_ignores=[]), str(OWNER / 'live.py'), 'exec')
exit_code = compile(ast.Module(body=[source.body[-1]], type_ignores=[]), str(OWNER / 'live.py'), 'exec')


class Case:
    def __init__(self, schedule, expires=4000000):
        self.now = 100
        self.schedule = [(101, [('VR263_PREPARED', {'expires_ms': expires})]), *schedule]
        self.events = queue.Queue()
        self.output = io.StringIO()
        self.pipe = io.BytesIO()
        self.waits = []
        self.writes = []
        self.child = types.SimpleNamespace(pid=123, poll=lambda: None, stdin=self.pipe, wait=self.wait)
        self.owned = {'pid': 123, 'incarnation': [1, 2, 3], 'address': 'synthetic'}
        commands = OwnedCommands(self.child, [1, 2, 3], lambda: self.owned,
            lambda: [{'pid': 123, 'address': 'synthetic', 'mapped': True}],
            lambda: self.now, lambda name, reason: self.writes.append((name, reason)))
        self.supervisor = Supervision(100, commands.finish, lambda: commands.begin(self.supervisor))
        self.env = dict(child=self.child, started=100, supervisor=self.supervisor, commands=commands,
            time=types.SimpleNamespace(monotonic=lambda: self.now, time=lambda: 1000 + self.now - 101),
            select=types.SimpleNamespace(select=self.select), os=types.SimpleNamespace(read=lambda *a: b'x'),
            sys=types.SimpleNamespace(stdin=io.StringIO()), sock=object(), read_event=object(),
            events=self.events, record={}, failure=None, owned=self.owned, helpers={},
            prepared_reported=False, a=types.SimpleNamespace(launch_and_begin=True),
            private=Path('/synthetic'), save=lambda: None, json=json)

    def select(self, readers, writers, errors, timeout):
        assert 0 <= timeout <= 2100
        if self.schedule and self.schedule[0][0] <= self.now + timeout:
            self.now, markers = self.schedule.pop(0)
            for marker, payload in markers:
                self.events.put(('marker', marker + ' ' + json.dumps(payload)))
            return [self.env['read_event']], [], []
        self.now += timeout
        return [], [], []

    def wait(self, timeout):
        self.waits.append(timeout)
        return 0  # synthetic exit; never presented as a real application exit

    def run(self):
        with patch('owned_commands.identity', return_value=[1, 2, 3]), contextlib.redirect_stdout(self.output):
            exec(code, self.env)
        # Evaluate the real wrapper decision with synthetic successful EOFs.
        # This does not execute its finally block or claim native retirement.
        self.env['record'].update(eof={'stdout': True, 'stderr': True}, reader_errors=[])
        try:
            exec(exit_code, self.env)
        except SystemExit as result:
            self.exit = result.code
        return self

    def rejected(self):
        return [row for line in self.output.getvalue().splitlines() if line.startswith('{')
                if 'readiness_not_admitted' in (row := json.loads(line))]


class LiveChecks(unittest.TestCase):
    def test_visible_stereo_keeps_original_preparation_bound(self):
        saved = json.loads((E.parent / 'godot-visibility-test-20261103/attempt-visual02-result.json').read_text())
        c = Case([(131, [('VR263_FIRST_XR_FRAME', saved['first_frame'])]),
                  (279, [('VR263_STATUS', saved['native_cutoff'])])]).run()
        self.assertEqual(c.now, 280)
        self.assertEqual(c.writes, [('begin', None), ('finish', 'preparation_failure')])
        self.assertIsNone(c.supervisor.participant_deadline)
        self.assertEqual(c.waits, [60])
        self.assertEqual(c.env['failure'], 'preparation_failure before visual readiness')
        self.assertEqual(c.exit, 1)

    def test_visual_marker_at_preparation_cutoff_cannot_pass(self):
        c = Case([(280, [('VR263_VISUAL_READY', {'expired': False})])]).run()
        self.assertEqual(c.now, 280)
        self.assertEqual(c.writes, [('begin', None), ('finish', 'preparation_failure')])
        self.assertIsNone(c.supervisor.participant_deadline)
        self.assertEqual(c.waits, [60])
        self.assertEqual(c.rejected(), [{'readiness_not_admitted': 'VR263_VISUAL_READY',
            'finish_reason': 'preparation_failure', 'participant_interval_already_started': False}])
        self.assertEqual(c.env['failure'], 'preparation_failure before visual readiness')
        self.assertEqual(c.exit, 1)

    def test_auth_expiry_before_visual_has_same_failure_with_or_without_marker(self):
        for schedule in [[], [(120, [('VR263_VISUAL_READY', {'expired': False})])]]:
            with self.subTest(schedule=schedule):
                c = Case(schedule, expires=1019000).run()
                self.assertEqual(c.now, 120)
                self.assertEqual(c.writes, [('begin', None), ('finish', 'auth_expired')])
                self.assertIsNone(c.supervisor.participant_deadline)
                self.assertEqual(c.waits, [60])
                if schedule:
                    self.assertEqual(c.rejected(), [{'readiness_not_admitted': 'VR263_VISUAL_READY',
                        'finish_reason': 'auth_expired', 'participant_interval_already_started': False}])
                self.assertEqual(c.env['failure'], 'auth_expired before visual readiness')
                self.assertEqual(c.exit, 1)

    def test_rendering_report_does_not_claim_visual_or_interaction_admission(self):
        c = Case([(131, [('VR263_FIRST_XR_FRAME', {'session_state': 'Visible', 'xr_frames': 1})])]).run()
        rows = [json.loads(line) for line in c.output.getvalue().splitlines() if line.startswith('{')]
        rendering_rows = [row for row in rows if 'RENDERING_ONLY' in row]
        self.assertEqual(len(rendering_rows), 1)
        rendering = rendering_rows[0]
        self.assertFalse(rendering['interactive_readiness_claim'])
        self.assertFalse(rendering['visual_readiness_claim'])

    def test_visual_then_interaction_never_restarts_participant_interval(self):
        c = Case([(279, [('VR263_VISUAL_READY', {'expired': False})]),
                  (280, [('VR263_READY', {'expired': False})]),
                  (300, [('VR263_VISUAL_READY', {'expired': False})]),
                  (320, [('VR263_STATE', {'signed_world': False, 'expired': False})])]).run()
        self.assertEqual(c.now, 2079)
        self.assertEqual(c.writes, [('begin', None), ('finish', 'participant_cutoff')])
        self.assertEqual(c.output.getvalue().count('"VISUAL_READY":'), 1)
        self.assertEqual(c.output.getvalue().count('"INTERACTION_READY":'), 1)
        self.assertEqual(c.rejected(), [{'readiness_not_admitted': 'VR263_VISUAL_READY',
            'finish_reason': None, 'participant_interval_already_started': True}])
        self.assertEqual(c.exit, 0)

    def test_expired_interaction_marker_is_not_reported_ready(self):
        c = Case([(110, [('VR263_VISUAL_READY', {'expired': False})]),
                  (120, [('VR263_READY', {'expired': True})])], expires=1019000).run()
        self.assertEqual(c.writes, [('begin', None), ('finish', 'auth_expired')])
        self.assertNotIn('"INTERACTION_READY":', c.output.getvalue())
        self.assertEqual(c.rejected(), [{'readiness_not_admitted': 'VR263_READY', 'finish_reason': 'auth_expired'}])

    def test_defensive_stopped_batch_cannot_report_interaction_ready(self):
        c = Case([(110, [('VR263_VISUAL_READY', {})]),
                  (120, [('VR263_BLOCKER', {}), ('VR263_READY', {})])]).run()
        self.assertEqual(c.writes, [('begin', None), ('finish', 'visual_admission_failure')])
        self.assertNotIn('"INTERACTION_READY":', c.output.getvalue())
        self.assertEqual(c.rejected(), [{'readiness_not_admitted': 'VR263_READY', 'finish_reason': 'visual_admission_failure'}])

    def test_defensive_interaction_without_visual_admission_is_not_ready(self):
        c = Case([(110, [('VR263_READY', {})])]).run()
        self.assertIsNone(c.supervisor.participant_deadline)
        self.assertNotIn('"INTERACTION_READY":', c.output.getvalue())
        self.assertEqual(c.rejected(), [{'readiness_not_admitted': 'VR263_READY', 'finish_reason': None}])

    def test_uncertain_finish_is_fenced_before_io(self):
        sent = []
        def send(reason):
            sent.append(reason)
            raise BrokenPipeError('synthetic uncertain write')
        s = Supervision(100, send, lambda: None)
        with self.assertRaises(BrokenPipeError):
            s.stop('participant_stop', 110)
        s.stop('supervision_failure', 111)
        s.cutoff(280)
        s.command('finish', 281)
        self.assertEqual(sent, ['participant_stop'])
        self.assertEqual(s.finish_at, 110)

    def test_normal_close_rechecks_same_absolute_deadline(self):
        c = Case([])
        with patch('owned_commands.identity', return_value=[1, 2, 3]):
            c.supervisor.stop('participant_stop', 110)
        c.now = 169
        def timeout(value=None, **kwargs):
            c.waits.append(kwargs['timeout'])
            raise subprocess.TimeoutExpired('synthetic child', kwargs['timeout'])
        c.child.wait = timeout
        exec(compile(ast.Module(body=[wait], type_ignores=[]), 'live.py', 'exec'), c.env)
        for now in [169, 170, 171]:
            c.now = now
            with self.assertRaises(subprocess.TimeoutExpired):
                c.env['wait_normal']()
        self.assertEqual(c.waits, [1, 0, 0])
        self.assertEqual(c.pipe.getvalue(), b'finish\n')


if __name__ == '__main__':
    unittest.main(verbosity=2)
