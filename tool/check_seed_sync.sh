#!/usr/bin/env bash
# The app bundles a copy of the shared exercise seed; they must not drift.
set -euo pipefail
cd "$(dirname "$0")/.."
cmp seed/exercises.json app/assets/seed/exercises.json || {
  echo "app/assets/seed/exercises.json differs from seed/exercises.json — copy it over." >&2
  exit 1
}
echo "seed in sync"
