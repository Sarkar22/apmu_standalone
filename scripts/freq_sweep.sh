#!/bin/bash
# Parallel frequency sweep over clock periods (ns). Usage: scripts/freq_sweep.sh 20 15 12.5 10 ...
cd "$(dirname "$0")/.."
JOBS=${JOBS:-6}
printf '%s\n' "$@" | xargs -P "$JOBS" -I{} bash -c '
  d=build/freq_sweep/p_{}; mkdir -p $d
  vivado -mode batch -nojournal -log $d/vivado.log -source scripts/sweep_point.tcl -tclargs {} $d > $d/stdout.log 2>&1
  echo "done {} exit=$?"'
echo "=== sweep results ==="
for f in build/freq_sweep/p_*/result.txt; do cat "$f"; done | sort -t= -k2 -g -r | cut -d' ' -f1-10
