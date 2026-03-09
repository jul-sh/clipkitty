#!/usr/bin/env python3

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-path", required=True)
    parser.add_argument("--channel", choices=["stable", "beta"], required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True)
    parser.add_argument("--published-at")
    parser.add_argument("--minimum-autoupdate-version")
    args = parser.parse_args()

    state_path = Path(args.state_path)
    if state_path.exists():
        state = json.loads(state_path.read_text())
    else:
        state = {}

    state[args.channel] = {
        "version": args.version,
        "url": args.url,
        "signature": args.signature,
        "length": int(args.length),
        "published_at": args.published_at or datetime.now(timezone.utc).isoformat(),
    }

    if args.minimum_autoupdate_version:
        state[args.channel]["minimum_autoupdate_version"] = args.minimum_autoupdate_version

    state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
