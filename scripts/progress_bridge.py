"""Persistent private renderer helper. JSON lines on stdio; no file writes."""
import json
from pathlib import Path
import sys

from progress_consumer import Consumer
from progress_identity import query_windows
from progress_protocol import ProgressError, decode, read_latest


def main():
    # .NET Framework's redirected stdin may begin with a UTF-8 BOM. This is
    # private transport framing; the snapshot wire decoder remains strict UTF-8.
    sys.stdin.reconfigure(encoding='utf-8-sig')
    sys.stdout.reconfigure(encoding='utf-8')
    request = json.loads(sys.stdin.readline(4096))
    path = Path(request['path'])
    consumer = Consumer(heartbeat_seconds=request.get('heartbeat_seconds', 5),
                        stale_seconds=request['stale_seconds'], no_progress_seconds=request['no_progress_seconds'])
    print('{"ready":true}', flush=True)
    for command in sys.stdin:
        if command.strip() == 'close':
            return
        failed = False
        process = 'UNKNOWN'
        try:
            raw = read_latest(path)
            snapshot = decode(raw)
            creation = snapshot['application_creation_identity']
            if creation is not None and creation['kind'] == 'WINDOWS_FILETIME':
                _, process = query_windows(snapshot['application_process_id'], creation)
        except FileNotFoundError:
            raw = None
        except (OSError, ProgressError):
            raw = None
            failed = True
        observation = consumer.observe(raw, process_state=process, control_failure=failed)
        print(json.dumps(observation, allow_nan=False, separators=(',', ':')), flush=True)


if __name__ == '__main__':
    main()
