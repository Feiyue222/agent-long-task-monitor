"""Harmless staged file-generation application, optionally stalled but heartbeating."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import uuid

from progress_identity import own_identity
from progress_publisher import Publisher


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--step-seconds', type=float, default=0.5)
    parser.add_argument('--heartbeat-seconds', type=float, default=5)
    parser.add_argument('--hold-seconds', type=float, default=6)
    parser.add_argument('--stall-seconds', type=float, default=0)
    args = parser.parse_args()
    if not all(0 <= n <= 86400 for n in (args.step_seconds, args.hold_seconds, args.stall_seconds)):
        parser.error('durations must be bounded nonnegative seconds')
    args.directory.mkdir(parents=True, exist_ok=True)
    process_id, identity = own_identity()
    task = 'harmless-file-demo'
    status = dict(contract_version='agent-long-task-status-v1', task=task, stage='PREPARE',
                  state='RUNNING', processed=None, total=None, unit=None,
                  target_process_id=process_id, supervisor_process_id=None,
                  checkpoint_state='UNAVAILABLE', artifact_state='PENDING', artifact_validated=False,
                  last_error=None)

    def status_write():
        fd, temporary = tempfile.mkstemp(dir=args.directory, prefix='.status-')
        with os.fdopen(fd, 'w', encoding='utf-8') as handle:
            json.dump(status, handle)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, args.directory / 'status.json')

    with Publisher(args.directory / 'progress.json', task_id=task,
                   execution_instance_id=str(uuid.uuid4()), stream_id=str(uuid.uuid4()),
                   application_process_id=process_id, application_creation_identity=identity,
                   stage='PREPARE', progress_scope_id='prepare',
                   heartbeat_seconds=args.heartbeat_seconds) as publisher:
        status['started_at'] = publisher.current['started_at']
        status_write()

        def wait(seconds):
            until = time.monotonic() + seconds
            while time.monotonic() < until:
                time.sleep(min(0.02, max(0, until - time.monotonic())))
                publisher.heartbeat()

        wait(args.hold_seconds)
        publisher.transition(stage='PROCESS', scope='items', completed_units=0, total_units=8, unit_name='items')
        status['stage'] = 'PROCESS'
        status_write()
        wait(args.stall_seconds)
        lines = []
        for index in range(8):
            wait(args.step_seconds)
            lines.append(hashlib.sha256(str(index).encode('ascii')).hexdigest())
            publisher.advance(index + 1)
        publisher.transition(stage='WRITE_OUTPUT', scope='output')
        status['stage'] = 'WRITE_OUTPUT'
        status_write()
        wait(args.step_seconds)
        result = ('\n'.join(lines) + '\n').encode('ascii')
        artifact = args.directory / 'result.txt'
        artifact.write_bytes(result)
        publisher.finish()
        # Separate Layer-1 artifact evidence, never inferred from terminal_state.
        status.update(state='COMPLETED', artifact_state='VALIDATED', artifact_validated=artifact.read_bytes() == result)
        status_write()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
