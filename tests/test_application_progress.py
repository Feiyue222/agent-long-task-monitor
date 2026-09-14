"""Layer 2 contract and harmless process integration tests (stdlib unittest)."""
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from progress_protocol import ProgressError, Validator, decode, encode, safe_details, validate, read_latest
from progress_publisher import Publisher, PublisherError, atomic_publish
from progress_consumer import Consumer
from progress_identity import own_identity, query_windows


def snapshot(**changes):
    stamp = '2026-09-14T00:00:00+00:00'
    result = dict(protocol_version='agent-long-task-progress-v1', task_id='test',
        execution_instance_id='execution-a', stream_id='stream-a', application_process_id=None,
        application_creation_identity=None, publication_sequence=0, progress_sequence=0,
        progress_scope_id='items', stage='PROCESS', substage=None, state='RUNNING',
        completed_units=0, total_units=10, unit_name='items', heartbeat_at=stamp,
        last_progress_at=None, started_at=stamp, updated_at=stamp, monotonic_elapsed_ns=0,
        durability_kind='ATOMIC_LATEST_SNAPSHOT', terminal_state=None, safe_details={})
    result.update(changes)
    return result


def next_snapshot(old, *, progress=False, **changes):
    result = copy.deepcopy(old)
    result['publication_sequence'] += 1
    result['monotonic_elapsed_ns'] += 1_000_000_000
    if progress:
        result['progress_sequence'] += 1
        result['last_progress_at'] = result['heartbeat_at']
    result.update(changes)
    return result


class Clock:
    def __init__(self):
        self.value = 0
    def __call__(self):
        return self.value
    def step(self, seconds=1):
        self.value += int(seconds * 1e9)


class ProtocolTests(unittest.TestCase):
    def reject(self, **changes):
        with self.assertRaises(ProgressError):
            validate(snapshot(**changes))

    def pair_rejected(self, original, replacement):
        validator = Validator()
        validator.accept(original)
        with self.assertRaises(ProgressError):
            validator.accept(replacement)
        self.assertEqual(validator.previous, original)

    def test_valid_minimal(self):
        self.assertEqual(decode(encode(snapshot())), snapshot())

    def test_domain_agnostic_schema(self):
        forbidden = ('pol012', 'train', 'dev', 'epoch', 'batch', 'loss', 'model', 'normalizer', 'mahjong')
        self.assertFalse(any(word in field.lower() for word in forbidden for field in snapshot()))

    def test_null_unknown(self):
        value = snapshot(stage=None, state='UNKNOWN', completed_units=None, total_units=None, unit_name=None)
        self.assertEqual(validate(value), value)

    def test_version_missing_extra(self):
        self.reject(protocol_version='other')
        self.reject(extra=True)
        value = snapshot(); del value['stage']
        with self.assertRaises(ProgressError): validate(value)

    def test_negative_sequences_and_types(self):
        for field in ('publication_sequence', 'progress_sequence', 'monotonic_elapsed_ns'):
            for bad in (-1, True, 1.5, None, '1', 2**63):
                with self.subTest(field=field, bad=bad): self.reject(**{field: bad})

    def test_heartbeat_only_sequence(self):
        old = snapshot(); new = next_snapshot(old)
        validator = Validator(); validator.accept(old)
        self.assertTrue(validator.accept(new))
        self.assertEqual(new['progress_sequence'], old['progress_sequence'])
        self.assertFalse(validator.accept(new))

    def test_progress_regression(self):
        old = snapshot(progress_sequence=5, last_progress_at='2026-09-14T00:00:00Z')
        self.pair_rejected(old, next_snapshot(old, progress_sequence=4))

    def test_publication_regression(self):
        old = snapshot(publication_sequence=5)
        self.pair_rejected(old, next_snapshot(old, publication_sequence=4))

    def test_same_publication_conflict(self):
        old = snapshot(); new = {**old, 'safe_details': {'other': 'value'}}
        self.pair_rejected(old, new)

    def test_same_progress_conflict(self):
        old = snapshot()
        for changes in ({'completed_units': 1}, {'stage': 'WRITE_OUTPUT'}, {'safe_details': {'phase': 'new'}}):
            self.pair_rejected(old, next_snapshot(old, **changes))

    def test_coalesced_progress_jump(self):
        old = snapshot(); new = next_snapshot(old, progress=True, progress_sequence=9, completed_units=9)
        validator = Validator(); validator.accept(old); self.assertTrue(validator.accept(new))

    def test_scope_change_counter_reset(self):
        old = snapshot(completed_units=8)
        new = next_snapshot(old, progress=True, progress_scope_id='output', stage='WRITE_OUTPUT', completed_units=0, total_units=2)
        validator = Validator(); validator.accept(old); self.assertTrue(validator.accept(new))

    def test_counter_regression(self):
        old = snapshot(completed_units=8)
        self.pair_rejected(old, next_snapshot(old, progress=True, completed_units=7))

    def test_revisited_scope_keeps_history(self):
        old = snapshot(completed_units=8)
        other = next_snapshot(old, progress=True, progress_scope_id='other', completed_units=0)
        validator = Validator(); validator.accept(old); validator.accept(other)
        with self.assertRaises(ProgressError):
            validator.accept(next_snapshot(other, progress=True, progress_scope_id='items', completed_units=1))

    def test_fixed_total_mutation(self):
        old = snapshot()
        for total in (9, 11, None): self.pair_rejected(old, next_snapshot(old, progress=True, total_units=total))

    def test_unknown_total_becomes_known(self):
        old = snapshot(total_units=None)
        validator = Validator(); validator.accept(old)
        self.assertTrue(validator.accept(next_snapshot(old, progress=True, total_units=10)))

    def test_overflow_zero_negative_counters(self):
        for changes in ({'completed_units': 11}, {'total_units': 0}, {'completed_units': -1},
                        {'total_units': -1}, {'completed_units': True}, {'completed_units': None}, {'unit_name': None}):
            self.reject(**changes)

    def test_identity_drift(self):
        old = snapshot()
        for field in ('task_id', 'execution_instance_id', 'stream_id'):
            self.pair_rejected(old, next_snapshot(old, **{field: 'changed'}))

    def test_explicit_consumer_identity(self):
        validator = Validator({'stream_id': 'expected'})
        with self.assertRaises(ProgressError): validator.accept(snapshot())

    def test_large_filetime_exact(self):
        identity = {'kind': 'WINDOWS_FILETIME', 'value': '134337832703165233'}
        value = snapshot(application_process_id=123, application_creation_identity=identity)
        self.assertEqual(decode(encode(value))['application_creation_identity'], identity)
        changed = next_snapshot(value, application_creation_identity={**identity, 'value': '134337832703165234'})
        self.pair_rejected(value, changed)

    def test_invalid_creation_identity(self):
        self.reject(application_process_id=12)
        for bad in (134337832703165233, '01', '-1', '0', '1.0', str(2**64)):
            self.reject(application_process_id=12, application_creation_identity={'kind': 'WINDOWS_FILETIME', 'value': bad})

    def test_invalid_labels_states(self):
        for field in ('stage', 'substage', 'unit_name'):
            for bad in (1, [], '', '\x1b[31m'):
                self.reject(**{field: bad})
        self.reject(state='SUCCEEDED')

    def test_invalid_timestamps(self):
        for bad in ('yesterday', '2026-09-14', '2026-09-14T00:00:00+01:00', '2026-02-30T00:00:00Z'):
            self.reject(started_at=bad)

    def test_wall_clock_backward_is_audit_only(self):
        old = snapshot(); new = next_snapshot(old, heartbeat_at='2020-01-01T00:00:00Z', updated_at='2020-01-01T00:00:00Z')
        validator = Validator(); validator.accept(old); self.assertTrue(validator.accept(new))

    def test_monotonic_regression(self):
        old = snapshot(monotonic_elapsed_ns=10)
        self.pair_rejected(old, next_snapshot(old, monotonic_elapsed_ns=9))

    def test_safe_details_guards(self):
        recursive = {}; recursive['loop'] = recursive
        for bad in (recursive, {'x': b'bytes'}, {'x': object()}, {'x': 'a' * 257},
                    {'x': [[[[[1]]]]]}, {f'k{i}': i for i in range(17)}, {'x': list(range(17))}):
            with self.subTest(kind=type(bad).__name__):
                with self.assertRaises(ProgressError): safe_details(bad)
        self.assertEqual(safe_details({'ok': [None, True, 1, 1.5, 'small']}), {'ok': [None, True, 1, 1.5, 'small']})

    def test_no_arbitrary_repr(self):
        class Trap:
            def __repr__(self): raise AssertionError('repr must never run')
        with self.assertRaises(ProgressError): safe_details({'x': Trap()})

    def test_nan_infinity(self):
        for number in (float('nan'), float('inf'), float('-inf')):
            self.reject(safe_details={'x': number})
        with self.assertRaises(ProgressError): decode(encode(snapshot()).replace(b'"completed_units":0', b'"completed_units":NaN'))

    def test_partial_duplicate_oversized(self):
        for raw in (b'{', b'\xff', b' ' * 16385, b'{"x":1,"x":2}'):
            with self.assertRaises(ProgressError): decode(raw)

    def test_terminal_combinations_and_finality(self):
        self.reject(state='TERMINAL')
        self.reject(terminal_state='SUCCEEDED')
        self.reject(state='TERMINAL', terminal_state='SUCCEEDED')
        old = snapshot(); terminal = next_snapshot(old, progress=True, completed_units=10, state='TERMINAL', terminal_state='SUCCEEDED')
        validator = Validator(); validator.accept(old); self.assertTrue(validator.accept(terminal))
        with self.assertRaises(ProgressError): validator.accept(next_snapshot(terminal))


class ConsumerTests(unittest.TestCase):
    def setUp(self):
        self.clock = Clock(); self.consumer = Consumer(clock=self.clock)
        self.first = snapshot(); self.consumer.observe(encode(self.first), process_state='ALIVE')

    def send(self, value, seconds=1, **kw):
        self.clock.step(seconds)
        return self.consumer.observe(encode(value) if value is not None else None, **kw)

    def test_restart_does_not_fake_freshness(self):
        consumer = Consumer(clock=self.clock)
        result = consumer.observe(encode(self.first), process_state='ALIVE')
        self.assertEqual(result['freshness'], 'UNKNOWN')
        self.clock.step(21)
        self.assertEqual(consumer.observe(encode(self.first))['freshness'], 'PROGRESS_STALE')

    def test_heartbeat_fresh_no_progress_warning(self):
        value = self.first
        for _ in range(25):
            value = next_snapshot(value)
            result = self.send(value, 5, process_state='ALIVE')
        self.assertEqual(result['freshness'], 'ALIVE_NO_APPLICATION_PROGRESS')
        self.assertNotIn('DEADLOCK', json.dumps(result))

    def test_publication_stale_despite_layer1_alive(self):
        self.assertEqual(self.send(self.first, 21, process_state='ALIVE')['freshness'], 'PROGRESS_STALE')

    def test_layer1_exited_old_snapshot(self):
        self.assertEqual(self.send(self.first, 30, process_state='PROCESS_EXITED')['freshness'], 'PROCESS_EXITED')

    def test_known_percent_rate_eta(self):
        new = next_snapshot(self.first, progress=True, completed_units=2, monotonic_elapsed_ns=2_000_000_000)
        result = self.send(new, 2)
        self.assertEqual(result['percent'], 0.2)
        self.assertEqual(result['rate_per_second'], 1)
        self.assertEqual(result['eta_seconds'], 8)
        self.assertEqual(result['freshness'], 'ACTIVE_PROGRESS')

    def test_unknown_denominator(self):
        consumer = Consumer(clock=self.clock)
        old = snapshot(total_units=None); consumer.observe(encode(old)); self.clock.step()
        result = consumer.observe(encode(next_snapshot(old, progress=True, completed_units=2)))
        self.assertIsNone(result['percent']); self.assertIsNone(result['eta_seconds'])

    def test_cross_scope_eta_forbidden(self):
        new = next_snapshot(self.first, progress=True, completed_units=3, progress_scope_id='new')
        result = self.send(new)
        self.assertIsNone(result['rate_per_second']); self.assertIsNone(result['eta_seconds'])

    def test_equal_monotonic_ticks_no_rate(self):
        new = next_snapshot(self.first, progress=True, completed_units=1, monotonic_elapsed_ns=0)
        result = self.send(new)
        self.assertEqual(result['freshness'], 'ACTIVE_PROGRESS')
        self.assertIsNone(result['rate_per_second']); self.assertIsNone(result['eta_seconds'])

    def test_heartbeat_has_no_new_rate(self):
        new = next_snapshot(self.first, progress=True, completed_units=1)
        self.send(new)
        self.assertIsNone(self.send(next_snapshot(new))['rate_per_second'])

    def test_invalid_snapshot_control_failure(self):
        result = self.consumer.observe(b'{', process_state='ALIVE')
        self.assertEqual(result['freshness'], 'CONTROL_FAILURE')
        self.assertIsNone(result['percent'])
        self.assertEqual(self.consumer.validator.previous, self.first)

    def test_terminal_does_not_validate_artifact(self):
        new = next_snapshot(self.first, progress=True, completed_units=10, state='TERMINAL', terminal_state='SUCCEEDED')
        result = self.send(new)
        self.assertEqual(result['snapshot']['terminal_state'], 'SUCCEEDED')
        self.assertNotIn('artifact_validated', result)

    def test_missing_then_stale(self):
        consumer = Consumer(clock=self.clock)
        self.assertEqual(consumer.observe(None)['availability'], 'NOT_AVAILABLE')
        self.assertEqual(self.send(None, 21)['freshness'], 'PROGRESS_STALE')


class FileTests(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / 'tests/.runtime-layer2'
        self.root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=self.root)
        self.directory = Path(self.temp.name)
        self.path = self.directory / 'latest.json'

    def tearDown(self):
        self.assertTrue(self.directory.resolve().is_relative_to(self.root.resolve()))
        self.temp.cleanup()

    def publisher(self, **kw):
        return Publisher(self.path, task_id='test', execution_instance_id='one', stream_id='one', **kw)

    def test_publisher_progress_and_heartbeat(self):
        clock = Clock()
        with self.publisher(clock=clock, completed_units=0, total_units=10, unit_name='items') as publisher:
            clock.step(5); self.assertTrue(publisher.heartbeat())
            self.assertEqual(decode(self.path.read_bytes())['progress_sequence'], 0)
            clock.step(); publisher.advance(1)
            value = decode(self.path.read_bytes())
            self.assertEqual((value['publication_sequence'], value['progress_sequence']), (2, 1))
            clock.step(); self.assertFalse(publisher.heartbeat())

    def test_coalescing_and_immediate_transitions(self):
        clock = Clock()
        with self.publisher(clock=clock, completed_units=0, total_units=10, unit_name='items') as publisher:
            for count in (1, 2, 3):
                clock.step(.1); self.assertFalse(publisher.advance(count))
            self.assertEqual(decode(self.path.read_bytes())['completed_units'], 0)
            clock.step(.7); self.assertTrue(publisher.heartbeat())
            self.assertEqual(decode(self.path.read_bytes())['progress_sequence'], 3)
            clock.step(.001); publisher.transition(stage='WRITE_OUTPUT', scope='output')
            clock.step(.001); publisher.finish()
            self.assertEqual(decode(self.path.read_bytes())['terminal_state'], 'SUCCEEDED')

    def test_repeated_stage_is_not_progress(self):
        clock = Clock()
        with self.publisher(clock=clock, stage='PROCESS') as publisher:
            clock.step()
            with self.assertRaises(ProgressError): publisher.transition(stage='PROCESS', scope='initial')
            with self.assertRaises(ProgressError): publisher.advance()
            self.assertEqual(decode(self.path.read_bytes())['progress_sequence'], 0)

    def test_single_writer_and_existing_snapshot(self):
        with self.publisher():
            with self.assertRaises(PublisherError): self.publisher()
        with self.assertRaises(PublisherError): self.publisher()

    def test_invalid_transition_preserves_pending_state(self):
        clock = Clock()
        with self.publisher(clock=clock, completed_units=5, total_units=10, unit_name='items') as publisher:
            clock.step()
            with self.assertRaises(ProgressError):
                publisher.transition(stage='WRITE_OUTPUT', scope='initial', completed_units=0, total_units=10, unit_name='items')
            self.assertEqual(publisher.current['completed_units'], 5)
            clock.step(5); self.assertTrue(publisher.heartbeat())

    def test_explicit_milestone_not_repeated_observation(self):
        clock = Clock()
        with self.publisher(clock=clock) as publisher:
            clock.step(); publisher.advance(milestone='header_written')
            clock.step()
            with self.assertRaises(ProgressError): publisher.advance(milestone='header_written')
            self.assertEqual(publisher.current['progress_sequence'], 1)

    def test_persistent_bridge_fresh_then_stale(self):
        atomic_publish(self.path, snapshot())
        bridge = subprocess.Popen([sys.executable, '-B', '-u', str(ROOT/'scripts/progress_bridge.py')],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, encoding='utf-8')
        try:
            bridge.stdin.write(json.dumps({'path':str(self.path),'stale_seconds':.1,'no_progress_seconds':.05}) + '\n')
            bridge.stdin.flush(); self.assertTrue(json.loads(bridge.stdout.readline())['ready'])
            def observe():
                bridge.stdin.write('observe\n'); bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())
            self.assertEqual(observe()['freshness'], 'UNKNOWN')
            atomic_publish(self.path, next_snapshot(snapshot(), progress=True, completed_units=1))
            self.assertEqual(observe()['freshness'], 'ACTIVE_PROGRESS')
            time.sleep(.13)
            self.assertEqual(observe()['freshness'], 'PROGRESS_STALE')
            bridge.stdin.close(); bridge.wait(3)
            self.assertEqual(bridge.returncode, 0)
        finally:
            if bridge.poll() is None: bridge.terminate(); bridge.wait(3)
            bridge.stdout.close(); bridge.stderr.close()

    def test_failed_replace_preserves_latest(self):
        atomic_publish(self.path, snapshot()); before = self.path.read_bytes()
        with mock.patch('progress_publisher.os.replace', side_effect=PermissionError()):
            with self.assertRaises(PublisherError): atomic_publish(self.path, next_snapshot(snapshot()))
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(list(self.directory.glob('*.tmp')), [])

    def test_fsync_failure_preserves_latest(self):
        atomic_publish(self.path, snapshot()); before = self.path.read_bytes()
        with mock.patch('progress_publisher.os.fsync', side_effect=OSError(5, 'I/O')):
            with self.assertRaises(PublisherError): atomic_publish(self.path, next_snapshot(snapshot()))
        self.assertEqual(self.path.read_bytes(), before)

    def test_failed_publish_does_not_consume_publication_sequence(self):
        clock = Clock()
        with self.publisher(clock=clock) as publisher:
            clock.step(5)
            with mock.patch('progress_publisher.os.replace', side_effect=PermissionError()):
                with self.assertRaises(PublisherError): publisher.heartbeat()
            self.assertEqual(publisher.validator.previous['publication_sequence'], 0)
            clock.step(); publisher.heartbeat()
            self.assertEqual(decode(self.path.read_bytes())['publication_sequence'], 1)

    def test_atomic_reader_during_replace(self):
        atomic_publish(self.path, snapshot()); stop = threading.Event(); errors = []; observed = []
        def read():
            while not stop.is_set():
                try: observed.append(decode(read_latest(self.path))['publication_sequence'])
                except OSError: pass  # Windows sharing contention is unavailable, not partial success.
                except BaseException as exc: errors.append(exc)
        thread = threading.Thread(target=read); thread.start()
        published = 0
        try:
            for count in range(1, 100):
                try: atomic_publish(self.path, snapshot(publication_sequence=count)); published += 1
                except PublisherError: pass
        finally:
            stop.set(); thread.join(3)
        self.assertFalse(errors); self.assertTrue(observed); self.assertGreater(published, 0)

    def test_interrupted_publisher(self):
        atomic_publish(self.path, snapshot()); before = self.path.read_bytes()
        script = self.directory / 'interrupt.py'
        script.write_text('import sys,time\nfrom pathlib import Path\nsys.path.insert(0,sys.argv[1])\n'
            'import progress_publisher as p\nfrom progress_protocol import decode\n'
            'path=Path(sys.argv[2])\ns=decode(path.read_bytes());s["publication_sequence"]+=1\n'
            'def blocked(*args):\n Path(sys.argv[3]).write_text("ready")\n time.sleep(60)\n'
            'p.os.replace=blocked\np.atomic_publish(path,s)\n', encoding='utf-8')
        marker = self.directory / 'ready'
        child = subprocess.Popen([sys.executable, '-B', str(script), str(ROOT/'scripts'), str(self.path), str(marker)])
        try:
            deadline = time.monotonic() + 5
            while not marker.exists() and time.monotonic() < deadline: time.sleep(.02)
            self.assertTrue(marker.exists()); child.terminate(); child.wait(5)
            self.assertEqual(self.path.read_bytes(), before)
            self.assertTrue(list(self.directory.glob('*.tmp')))
        finally:
            if child.poll() is None: child.terminate(); child.wait(5)

    def run_demo(self, stall=0):
        directory = self.directory / 'demo'
        command = [sys.executable, '-B', str(ROOT/'scripts/demo_progress.py'), '--directory', str(directory),
                   '--step-seconds', '.035', '--heartbeat-seconds', '.025', '--hold-seconds', '.15',
                   '--stall-seconds', str(stall)]
        child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        consumer = Consumer(stale_seconds=.15, no_progress_seconds=.10)
        states = set(); stages = set(); saw_heartbeat = False; prior = None
        try:
            deadline = time.monotonic() + 8
            while child.poll() is None and time.monotonic() < deadline:
                try: raw = read_latest(directory/'progress.json')
                except OSError: time.sleep(.01); continue
                value = decode(raw); stages.add(value['stage'])
                if prior and value['publication_sequence'] > prior['publication_sequence'] and value['progress_sequence'] == prior['progress_sequence']:
                    saw_heartbeat = True
                prior = value
                states.add(consumer.observe(raw, process_state='ALIVE')['freshness'])
                time.sleep(.01)
            out, err = child.communicate(timeout=2)
            self.assertEqual(child.returncode, 0, err.decode())
            final = decode((directory/'progress.json').read_bytes())
            self.assertEqual(final['terminal_state'], 'SUCCEEDED')
            status = json.loads((directory/'status.json').read_bytes())
            self.assertTrue(status['artifact_validated'])
            self.assertTrue(saw_heartbeat)
            self.assertTrue({'PREPARE', 'PROCESS', 'WRITE_OUTPUT'} <= stages)
            return states
        finally:
            if child.poll() is None: child.terminate(); child.wait(5)

    def test_harmless_live_integration(self):
        self.assertIn('ACTIVE_PROGRESS', self.run_demo())

    def test_stalled_live_integration(self):
        self.assertIn('ALIVE_NO_APPLICATION_PROGRESS', self.run_demo(.3))

    @unittest.skipUnless(os.name == 'nt', 'Windows exact process query')
    def test_windows_self_identity_and_mismatch(self):
        process_id, identity = own_identity()
        self.assertEqual(query_windows(process_id, identity)[1], 'ALIVE')
        self.assertEqual(query_windows(process_id, {'kind':'WINDOWS_FILETIME','value':'1'})[1], 'PROCESS_EXITED')


if __name__ == '__main__':
    unittest.main(verbosity=2)
