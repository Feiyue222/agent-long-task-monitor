"""JSON-lines publisher adapter used by the PowerShell application example."""
import json
import sys

from progress_publisher import Publisher, PublisherError
from progress_protocol import ProgressError


def main():
    sys.stdin.reconfigure(encoding='utf-8-sig')
    sys.stdout.reconfigure(encoding='utf-8')
    publisher = None
    try:
        options = json.loads(sys.stdin.readline(16385))
        publisher = Publisher(**options)
        print('{"ok":true}', flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            action = request.pop('action')
            if action not in ('advance', 'transition', 'heartbeat', 'finish'):
                raise ProgressError('emitter_action_invalid')
            published = getattr(publisher, action)(**request)
            print(json.dumps({'ok': True, 'published': published}), flush=True)
    except (ValueError, TypeError, KeyError, PublisherError, ProgressError, OSError):
        print('{"ok":false,"error":"emitter_request_failed"}', flush=True)
        return 1
    finally:
        if publisher is not None:
            publisher.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
