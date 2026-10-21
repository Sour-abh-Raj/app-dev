"""Fails CI if logic/validator coverage drops below the target (default 80%).

Logic = lib/domain/**, lib/data/** (minus the Firebase adapter, which is
covered by the emulator suites), lib/core/{clock,errors}.dart and the photo
pipeline. Usage: python3 tool/coverage_gate.py app/coverage/lcov.info [80]
"""

import sys

EXCLUDE = {"lib/data/remote/remote.dart"}
EXTRA = {"lib/core/clock.dart", "lib/core/errors.dart", "lib/services/photo_service.dart"}


def main() -> int:
    path = sys.argv[1]
    target = float(sys.argv[2]) if len(sys.argv) > 2 else 80.0
    hit = total = 0
    cur = None
    for line in open(path):
        if line.startswith("SF:"):
            f = line[3:].strip()
            cur = f if ((f.startswith("lib/domain/") or f.startswith("lib/data/") or f in EXTRA)
                        and f not in EXCLUDE) else None
        elif line.startswith("DA:") and cur:
            total += 1
            hit += int(line[3:].split(",")[1]) > 0
    pct = 100 * hit / total if total else 0
    print(f"logic/validator coverage: {pct:.1f}% ({hit}/{total}), target {target}%")
    return 0 if pct >= target else 1


if __name__ == "__main__":
    sys.exit(main())
