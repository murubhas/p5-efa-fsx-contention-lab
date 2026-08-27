"""Summarize before/after EFA hardware-counter deltas for one benchmark run."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def parse_counter_file(path: Path) -> dict[str, dict[str, int]]:
    counters: dict[str, dict[str, int]] = {}
    device: str | None = None

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("[") and line.endswith("]"):
            device = line[1:-1]
            counters[device] = {}
        elif device and "=" in line:
            name, value = line.split("=", 1)
            try:
                counters[device][name] = int(value)
            except ValueError:
                continue

    return counters


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("result_dir", type=Path)
    args = parser.parse_args()

    before_files = sorted(args.result_dir.glob("efa-hw-counters-*-before.txt"))
    if not before_files:
        raise SystemExit(f"No EFA before-counter files found in {args.result_dir}")

    aggregate: defaultdict[str, int] = defaultdict(int)
    per_host: dict[str, dict[str, int]] = {}
    negative_deltas: list[dict[str, object]] = []

    for before_path in before_files:
        host = before_path.name.removeprefix("efa-hw-counters-").removesuffix("-before.txt")
        after_path = args.result_dir / f"efa-hw-counters-{host}-after.txt"
        if not after_path.exists():
            raise SystemExit(f"Missing after-counter file for {host}: {after_path}")

        before = parse_counter_file(before_path)
        after = parse_counter_file(after_path)
        host_totals: defaultdict[str, int] = defaultdict(int)

        for device in sorted(set(before) & set(after)):
            for counter in sorted(set(before[device]) & set(after[device])):
                delta = after[device][counter] - before[device][counter]
                if delta < 0:
                    negative_deltas.append(
                        {"host": host, "device": device, "counter": counter, "delta": delta}
                    )
                    continue
                host_totals[counter] += delta
                aggregate[counter] += delta

        per_host[host] = dict(sorted(host_totals.items()))

    result = {
        "result_dir": str(args.result_dir),
        "hosts": len(per_host),
        "per_host": per_host,
        "aggregate": dict(sorted(aggregate.items())),
        "negative_deltas": negative_deltas,
    }
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
