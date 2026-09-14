"""Single-writer atomic operational progress publisher (Python 3.10+)."""
import copy
from datetime import datetime, timezone
import errno
import json
import os
from pathlib import Path
import tempfile
import time

from progress_protocol import PROTOCOL, ProgressError, Validator, encode, require, safe_details

HEARTBEAT_INTERVAL_SECONDS = 5
PROGRESS_PUBLICATION_MAX_RATE_HZ = 1


class PublisherError(RuntimeError):
    pass


def atomic_publish(path, snapshot):
    """On pre-replace failure the previous latest remains byte-identical."""
    path = Path(path)
    raw = encode(snapshot)
    temporary = None
    try:
        fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', suffix='.tmp', dir=path.parent)
        with os.fdopen(fd, 'wb') as handle:
            handle.write(raw)
            handle.flush()
            try:
                os.fsync(handle.fileno())
            except OSError as exc:
                if exc.errno not in (errno.EINVAL, errno.ENOSYS, errno.ENOTSUP):
                    raise
        # Windows filesystem filters can briefly deny replacement even when
        # cooperating readers share DELETE. Retry the same closed temp at most
        # five times; this never truncates latest or creates another work event.
        for attempt in range(5):
            try:
                os.replace(temporary, path)
                break
            except OSError as exc:
                if getattr(exc, 'winerror', None) not in (5, 32, 33) or attempt == 4:
                    raise
                time.sleep(.01)
        temporary = None
    except OSError as exc:
        raise PublisherError('atomic_publication_failed_errno_{}_winerror_{}'.format(
            exc.errno, getattr(exc, 'winerror', None))) from None
    finally:
        if temporary is not None:
            try:
                os.unlink(temporary)
            except OSError:
                pass  # Orphan temp is never a latest snapshot or resume authority.


class Publisher:
    """Application calls heartbeat regularly; no worker or monitoring thread is created.

    One publisher object, called serially by its owning application thread.
    Internal advance events may coalesce; transition/finish bypass the rate cap.
    """
    def __init__(self, path, *, task_id, execution_instance_id, stream_id,
                 application_process_id=None, application_creation_identity=None,
                 progress_scope_id='initial', stage=None, substage=None,
                 completed_units=None, total_units=None, unit_name=None,
                 details=None, heartbeat_seconds=HEARTBEAT_INTERVAL_SECONDS,
                 max_rate_hz=PROGRESS_PUBLICATION_MAX_RATE_HZ,
                 clock=time.monotonic_ns, wall_clock=None):
        require(type(heartbeat_seconds) in (int, float) and 0 < heartbeat_seconds <= 3600, 'heartbeat_policy_invalid')
        require(type(max_rate_hz) in (int, float) and 0 < max_rate_hz <= 1000, 'rate_policy_invalid')
        self.path = Path(path)
        self.clock = clock
        self.wall_clock = wall_clock or (lambda: datetime.now(timezone.utc).isoformat())
        self.origin = clock()
        self.last_published_ns = None
        self.heartbeat_ns = int(heartbeat_seconds * 1e9)
        self.rate_ns = int(1e9 / max_rate_hz)
        self.validator = Validator()
        self.closed = False
        stamp = self.wall_clock()
        self.current = dict(protocol_version=PROTOCOL, task_id=task_id,
            execution_instance_id=execution_instance_id, stream_id=stream_id,
            application_process_id=application_process_id,
            application_creation_identity=application_creation_identity,
            publication_sequence=0, progress_sequence=0, progress_scope_id=progress_scope_id,
            stage=stage, substage=substage, state='RUNNING', completed_units=completed_units,
            total_units=total_units, unit_name=unit_name, heartbeat_at=stamp,
            last_progress_at=None, started_at=stamp, updated_at=stamp,
            monotonic_elapsed_ns=0, durability_kind='ATOMIC_LATEST_SNAPSHOT',
            terminal_state=None, safe_details=safe_details(details if details is not None else {}))
        encode(self.current)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = self.path.with_name(self.path.name + '.writer.lock')
        try:
            self.lock_fd = os.open(self.lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        except OSError:
            raise PublisherError('single_writer_claim_failed') from None
        try:
            if self.path.exists():
                raise PublisherError('existing_stream_requires_explicit_consumer_policy')
            self.publish(force=True)
        except BaseException:
            self.close()
            raise

    def publish(self, force=False):
        require(not self.closed, 'publisher_closed')
        now = self.clock()
        elapsed = now - self.origin
        require(elapsed >= 0, 'publisher_clock_regression')
        old = self.validator.previous
        pending = old is None or self.current['progress_sequence'] != old['progress_sequence']
        if old is not None:
            require(elapsed >= old['monotonic_elapsed_ns'], 'publisher_clock_regression')
            since = now - self.last_published_ns
            if not force and since < (self.rate_ns if pending else self.heartbeat_ns):
                return False
        candidate = copy.deepcopy(self.current)
        candidate['publication_sequence'] = 0 if old is None else old['publication_sequence'] + 1
        candidate['heartbeat_at'] = candidate['updated_at'] = self.wall_clock()
        candidate['monotonic_elapsed_ns'] = elapsed
        trial = copy.deepcopy(self.validator)
        trial.accept(candidate)
        atomic_publish(self.path, candidate)
        self.current = candidate
        self.validator = trial
        self.last_published_ns = now
        return True

    def heartbeat(self):
        return self.publish()

    def _apply(self, candidate, force=False):
        previous = self.current
        self.current = candidate
        try:
            return self.publish(force=force)
        except ProgressError:
            self.current = previous  # Invalid API input must not poison pending state.
            raise

    def advance(self, completed_units=None, *, milestone=None):
        require(self.current['terminal_state'] is None, 'terminal_is_final')
        candidate = copy.deepcopy(self.current)
        if completed_units is not None:
            require(type(completed_units) is int and completed_units > 0 and (candidate['completed_units'] is None
                or completed_units > candidate['completed_units']), 'advance_requires_work')
            candidate['completed_units'] = completed_units
        else:
            require(type(milestone) is str and bool(milestone), 'advance_requires_work')
            require(milestone != candidate['safe_details'].get('milestone'), 'repeated_milestone')
        if milestone is not None:
            candidate['safe_details'] = safe_details({**candidate['safe_details'], 'milestone': milestone})
        candidate['progress_sequence'] += 1
        candidate['last_progress_at'] = self.wall_clock()
        encode(candidate)
        return self._apply(candidate)

    def transition(self, *, stage, scope, completed_units=None, total_units=None,
                   unit_name=None, substage=None):
        require(self.current['terminal_state'] is None, 'terminal_is_final')
        candidate = copy.deepcopy(self.current)
        candidate.update(stage=stage, substage=substage, progress_scope_id=scope,
                         completed_units=completed_units, total_units=total_units, unit_name=unit_name)
        require(any(candidate[k] != self.current[k] for k in
                    ('stage', 'substage', 'progress_scope_id')), 'transition_requires_milestone')
        candidate['progress_sequence'] += 1
        candidate['last_progress_at'] = self.wall_clock()
        encode(candidate)
        return self._apply(candidate, force=True)

    def finish(self, terminal_state='SUCCEEDED'):
        require(self.current['terminal_state'] is None, 'terminal_is_final')
        candidate = copy.deepcopy(self.current)
        candidate.update(state='TERMINAL', terminal_state=terminal_state,
                         progress_sequence=candidate['progress_sequence'] + 1,
                         last_progress_at=self.wall_clock())
        encode(candidate)
        return self._apply(candidate, force=True)

    def close(self):
        if not self.closed:
            self.closed = True
            os.close(self.lock_fd)
            self.lock.unlink()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
