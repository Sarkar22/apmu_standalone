#!/bin/bash
# Compile apmu_sim.f and elaborate apmu_hesoc_top (pmu_top in the he-soc configuration) with Questa.
set -e
cd "$(dirname "$0")/.."
B=build/questa; rm -rf $B; mkdir -p $B
vlib $B/work >/dev/null
vlog -sv -work $B/work -timescale 1ns/1ps +define+COMMON_CELLS_ASSERTS_OFF +define+TARGET_VSIM \
     -suppress 2583 -suppress 13314 -f apmu_sim.f 2>&1 | tee $B/vlog.log
vopt -work $B/work apmu_hesoc_top -o apmu_hesoc_top_opt +acc=npr 2>&1 | tee $B/vopt.log
