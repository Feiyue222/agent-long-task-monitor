"""Observational progress state; no task launch, restart or termination authority."""
import copy
import time

from progress_protocol import ProgressError, Validator, decode, require

APPLICATION_HEARTBEAT_SECONDS = 5
PROGRESS_STALE_SECONDS = 20
NO_PROGRESS_WARNING_SECONDS = 120


class Consumer:
    def __init__(self, *, expected_identity=None, heartbeat_seconds=APPLICATION_HEARTBEAT_SECONDS,
                 stale_seconds=PROGRESS_STALE_SECONDS,
                 no_progress_seconds=NO_PROGRESS_WARNING_SECONDS, clock=time.monotonic_ns):
        require(type(stale_seconds) in (int, float) and 0 < stale_seconds <= 86400, 'stale_policy_invalid')
        require(type(heartbeat_seconds) in (int, float) and 0 < heartbeat_seconds <= 3600, 'heartbeat_policy_invalid')
        require(type(no_progress_seconds) in (int, float) and 0 < no_progress_seconds <= 86400, 'warning_policy_invalid')
        self.validator = Validator(expected_identity)
        self.clock = clock
        self.stale_ns = int(stale_seconds * 1e9)
        self.warning_ns = int(no_progress_seconds * 1e9)
        self.heartbeat_seconds = heartbeat_seconds
        self.first_seen = self.last_publication = self.last_progress = None
        self.advanced_publication = False
        self.advanced_progress = False
        self.rate = self.eta = None
        self.error = None
        self.last_clock = None

    def observe(self, raw, *, process_state='UNKNOWN', control_failure=False):
        require(process_state in ('ALIVE', 'PROCESS_EXITED', 'UNKNOWN'), 'process_state_invalid')
        now = self.clock()
        if self.last_clock is not None and now < self.last_clock:
            control_failure = True
        self.last_clock = now
        self.error = None
        if raw is not None:
            try:
                s = decode(raw)
                old = copy.deepcopy(self.validator.previous)
                changed = self.validator.accept(s)
                if self.first_seen is None:
                    self.first_seen = self.last_publication = self.last_progress = now
                elif changed:
                    self.last_publication = now
                    self.advanced_publication = True
                    if s['progress_sequence'] > old['progress_sequence']:
                        self.last_progress = now
                        self.advanced_progress = True
                    self.rate = self.eta = None
                    if (s['progress_sequence'] > old['progress_sequence']
                        and s['progress_scope_id'] == old['progress_scope_id']
                        and s['unit_name'] == old['unit_name']
                        and s['total_units'] is not None and s['total_units'] == old['total_units']
                        and s['completed_units'] is not None and old['completed_units'] is not None):
                        delta = s['completed_units'] - old['completed_units']
                        interval = s['monotonic_elapsed_ns'] - old['monotonic_elapsed_ns']
                        if delta > 0 and interval > 0:
                            self.rate = delta * 1e9 / interval
                            self.eta = (s['total_units'] - s['completed_units']) / self.rate
            except ProgressError as exc:
                self.error = str(exc)
                control_failure = True
        s = self.validator.previous
        publication_age = None if self.last_publication is None else max(0, now - self.last_publication)
        progress_age = None if self.last_progress is None else max(0, now - self.last_progress)
        if control_failure:
            state = 'CONTROL_FAILURE'
        elif process_state == 'PROCESS_EXITED':
            state = 'PROCESS_EXITED'
        elif s is None:
            state = 'UNKNOWN'
        elif publication_age >= self.stale_ns:
            state = 'PROGRESS_STALE'
        elif not self.advanced_publication:
            state = 'UNKNOWN'
        elif progress_age >= self.warning_ns:
            state = 'ALIVE_NO_APPLICATION_PROGRESS'
        elif self.advanced_progress:
            state = 'ACTIVE_PROGRESS'
        else:
            state = 'UNKNOWN'
        # Terminal remains separate and never certifies an artifact. Stop projecting
        # a current rate when heartbeat-only, stale, control-failed or process-exited.
        valid = state not in ('CONTROL_FAILURE', 'PROCESS_EXITED', 'PROGRESS_STALE', 'UNKNOWN')
        percent = None
        if s is not None and s['completed_units'] is not None and s['total_units'] is not None:
            percent = s['completed_units'] / s['total_units']
        return {'availability': 'NOT_AVAILABLE' if s is None and not control_failure else 'AVAILABLE',
                'application': 'BOUND_STREAM' if s is not None else 'UNKNOWN',
                'freshness': state, 'process_state': process_state,
                'snapshot': copy.deepcopy(s), 'percent': None if control_failure else percent,
                'rate_per_second': self.rate if valid else None,
                'eta_seconds': self.eta if valid else None,
                'publication_age_seconds': None if publication_age is None else publication_age / 1e9,
                'observed_no_progress_seconds': None if progress_age is None else progress_age / 1e9,
                'heartbeat_advanced_since_monitor_start': self.advanced_publication,
                'heartbeat_expected_seconds': self.heartbeat_seconds,
                'error': self.error}
