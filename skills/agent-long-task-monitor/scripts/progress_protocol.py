"""Strict, standard-library agent-long-task-progress-v1 wire validation."""
import copy
from datetime import datetime
import json
import math
import os
import re

PROTOCOL = 'agent-long-task-progress-v1'
MAX_PAYLOAD_BYTES = 16384
MAX_INTEGER = 2**53 - 1
MAX_SEQUENCE = 2**63 - 1
FIELDS = frozenset('protocol_version task_id execution_instance_id stream_id '
    'application_process_id application_creation_identity publication_sequence '
    'progress_sequence progress_scope_id stage substage state completed_units '
    'total_units unit_name heartbeat_at last_progress_at started_at updated_at '
    'monotonic_elapsed_ns durability_kind terminal_state safe_details'.split())
IDENTITY_FIELDS = ('task_id', 'execution_instance_id', 'stream_id',
                   'application_process_id', 'application_creation_identity', 'started_at')
HEARTBEAT_FIELDS = frozenset(('publication_sequence', 'heartbeat_at', 'updated_at', 'monotonic_elapsed_ns'))


class ProgressError(ValueError):
    """Bounded error codes only: never include rejected payload content."""


def require(condition, code):
    if not condition:
        raise ProgressError(code)


def integer(value, maximum=MAX_INTEGER):
    return type(value) is int and 0 <= value <= maximum


def label(value, nullable=False):
    return (nullable and value is None) or (type(value) is str and 0 < len(value) <= 128
        and all(ord(c) >= 32 and ord(c) != 127 for c in value))


def safe_details(value):
    """Closed JSON values: 4 levels, 64 nodes, 16 children, 256-char strings."""
    require(type(value) is dict, 'details_map_required')
    seen = set()
    nodes = 0

    def walk(item, depth):
        nonlocal nodes
        nodes += 1
        require(nodes <= 64 and depth <= 4, 'details_budget_exceeded')
        kind = type(item)
        if item is None or kind is bool:
            return
        if kind is str:
            require(len(item) <= 256 and all(ord(c) >= 32 and ord(c) != 127 for c in item), 'details_string_invalid')
        elif kind is int:
            require(abs(item) <= MAX_INTEGER, 'details_integer_invalid')
        elif kind is float:
            require(math.isfinite(item) and abs(item) <= MAX_INTEGER, 'details_number_invalid')
        elif kind in (dict, list):
            require(id(item) not in seen, 'details_recursive')
            require(len(item) <= 16, 'details_children_exceeded')
            seen.add(id(item))
            if kind is dict:
                for key, child in item.items():
                    require(type(key) is str and re.fullmatch(r'[A-Za-z][A-Za-z0-9_]{0,47}', key) is not None,
                            'details_key_invalid')
                    walk(child, depth + 1)
            else:
                for child in item:
                    walk(child, depth + 1)
            seen.remove(id(item))
        else:
            raise ProgressError('details_type_forbidden')
    walk(value, 0)
    return copy.deepcopy(value)


def timestamp(value, nullable=False):
    if nullable and value is None:
        return None
    require(type(value) is str and len(value) <= 40 and re.fullmatch(
        r'\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,7})?(?:Z|\+00:00)', value) is not None,
        'timestamp_invalid')
    try:
        return datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError:
        raise ProgressError('timestamp_invalid') from None


def validate(snapshot):
    require(type(snapshot) is dict and set(snapshot) == FIELDS, 'snapshot_fields_invalid')
    s = snapshot
    require(s['protocol_version'] == PROTOCOL, 'protocol_invalid')
    for key in ('task_id', 'execution_instance_id', 'stream_id', 'progress_scope_id'):
        require(label(s[key]), 'identity_or_scope_invalid')
    for key in ('stage', 'substage', 'unit_name'):
        require(label(s[key], True), 'label_invalid')
    pid, identity = s['application_process_id'], s['application_creation_identity']
    require((pid is None) == (identity is None), 'partial_application_identity')
    if pid is not None:
        require(integer(pid, 2**32 - 1) and pid > 0, 'pid_invalid')
        require(type(identity) is dict and set(identity) == {'kind', 'value'}, 'creation_identity_invalid')
        require(identity['kind'] in ('WINDOWS_FILETIME', 'OPAQUE_STRING'), 'creation_identity_kind_invalid')
        require(label(identity['value']), 'creation_identity_value_invalid')
        if identity['kind'] == 'WINDOWS_FILETIME':
            require(re.fullmatch(r'[1-9][0-9]{0,19}', identity['value']) is not None
                    and int(identity['value']) <= 2**64 - 1, 'filetime_invalid')
    for key in ('publication_sequence', 'progress_sequence', 'monotonic_elapsed_ns'):
        require(integer(s[key], MAX_SEQUENCE), 'sequence_or_monotonic_invalid')
    require(s['state'] in ('RUNNING', 'PAUSED', 'UNKNOWN', 'TERMINAL'), 'state_invalid')
    require(s['terminal_state'] in (None, 'SUCCEEDED', 'FAILED', 'CANCELLED'), 'terminal_invalid')
    require((s['state'] == 'TERMINAL') == (s['terminal_state'] is not None), 'terminal_combination_invalid')
    require(s['durability_kind'] == 'ATOMIC_LATEST_SNAPSHOT', 'durability_invalid')
    completed, total = s['completed_units'], s['total_units']
    require(completed is None or integer(completed), 'completed_invalid')
    require(total is None or (integer(total) and total > 0), 'total_invalid')
    if total is not None:
        require(completed is not None and completed <= total, 'counter_range_invalid')
        if s['terminal_state'] == 'SUCCEEDED':
            require(completed == total, 'successful_scope_incomplete')
    require((completed is None and total is None) or s['unit_name'] is not None, 'counter_unit_required')
    for key in ('heartbeat_at', 'started_at', 'updated_at'):
        timestamp(s[key])
    timestamp(s['last_progress_at'], True)
    require(s['heartbeat_at'] == s['updated_at'], 'publication_time_mismatch')
    require(s['progress_sequence'] == 0 or s['last_progress_at'] is not None, 'progress_time_required')
    safe_details(s['safe_details'])
    try:
        raw = json.dumps(s, ensure_ascii=False, allow_nan=False, sort_keys=True,
                         separators=(',', ':')).encode('utf-8')
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise ProgressError('serialization_invalid') from None
    require(len(raw) + 1 <= MAX_PAYLOAD_BYTES, 'payload_oversized')
    return copy.deepcopy(s)


def encode(snapshot):
    return (json.dumps(validate(snapshot), ensure_ascii=False, allow_nan=False,
                       sort_keys=True, separators=(',', ':')) + '\n').encode('utf-8')


def decode(raw):
    require(type(raw) is bytes and len(raw) <= MAX_PAYLOAD_BYTES, 'payload_oversized_or_wrong_type')
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate_key')
            result[key] = value
        return result
    def invalid_constant(_):
        raise ProgressError('nonfinite_number')
    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=pairs, parse_constant=invalid_constant)
    except (ValueError, UnicodeError, RecursionError):
        raise ProgressError('json_invalid') from None
    return validate(value)


def read_latest(path):
    """Bounded read; Windows readers share DELETE so os.replace is not blocked."""
    if os.name != 'nt':
        with open(path, 'rb') as handle:
            return handle.read(MAX_PAYLOAD_BYTES + 1)
    import ctypes as ct
    from ctypes import wintypes as wt
    import msvcrt
    api = ct.WinDLL('kernel32', use_last_error=True)
    api.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ct.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE]
    api.CreateFileW.restype = wt.HANDLE
    handle = api.CreateFileW(os.fspath(path), 0x80000000, 0x1 | 0x2 | 0x4, None, 3, 0x80, None)
    if handle == ct.c_void_p(-1).value:
        error = ct.get_last_error()
        if error in (2, 3):
            raise FileNotFoundError('progress_snapshot_missing')
        raise OSError('progress_snapshot_unreadable')
    try:
        fd = msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_BINARY)
    except BaseException:
        api.CloseHandle.argtypes = [wt.HANDLE]
        api.CloseHandle(handle)
        raise
    with os.fdopen(fd, 'rb') as stream:
        return stream.read(MAX_PAYLOAD_BYTES + 1)


class Validator:
    """Pins one stream, retains scope history; rejected input never changes state."""
    def __init__(self, expected_identity=None):
        self.previous = None
        self.scopes = {}
        self.expected_identity = copy.deepcopy(expected_identity)

    def accept(self, snapshot):
        s = validate(snapshot)
        if self.expected_identity is not None:
            require(all(s.get(k) == v for k, v in self.expected_identity.items()), 'expected_identity_mismatch')
        old = self.previous
        if old is not None:
            require(all(s[k] == old[k] for k in IDENTITY_FIELDS), 'identity_drift')
            require(s['publication_sequence'] >= old['publication_sequence'], 'publication_regression')
            require(s['progress_sequence'] >= old['progress_sequence'], 'progress_regression')
            if s['publication_sequence'] == old['publication_sequence']:
                require(s == old, 'same_publication_conflict')
                return False
            require(old['terminal_state'] is None, 'terminal_is_final')
            require(s['monotonic_elapsed_ns'] >= old['monotonic_elapsed_ns'], 'monotonic_regression')
            if s['progress_sequence'] == old['progress_sequence']:
                require(all(s[k] == old[k] for k in FIELDS - HEARTBEAT_FIELDS), 'same_progress_conflict')
        scope = s['progress_scope_id']
        if scope in self.scopes:
            prior = self.scopes[scope]
            if prior['completed_units'] is not None:
                require(s['completed_units'] is not None and s['completed_units'] >= prior['completed_units'], 'counter_regression')
            if prior['total_units'] is not None:
                require(s['total_units'] == prior['total_units'], 'total_mutation')
            if prior['unit_name'] is not None:
                require(s['unit_name'] == prior['unit_name'], 'unit_mutation')
        else:
            require(len(self.scopes) < 1024, 'scope_budget_exceeded')
        self.previous = s
        self.scopes[scope] = s
        return True
