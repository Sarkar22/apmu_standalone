#!/bin/bash
# Verilator lint of apmu_hesoc_top. Outputs go to build/verilator_lint/.
#   ulimit -s unlimited : Verilator 4.110 overflows the default 8 MB stack on the 32768-word DSPM.
#   -Wno-BLKANDNBLK     : pmu_ispm/pmu_dspm mix = and <= on `latency`; Verilator treats it as an error.
# Both reproduce on the unmodified he-soc sources. Lints the sim variant (apmu_sim.f); for apmu_fpga.f
# add scripts/stubs/xpm_memory_spram_stub.sv (black box for the Vivado library cell).
set -u
cd "$(dirname "$0")/.."
OUT=build/verilator_lint; mkdir -p $OUT
ulimit -s unlimited
FLIST=${FLIST:-apmu_sim.f}
grep -v '^//' $FLIST | grep -v '^\s*$' > $OUT/flist.f
EXTRA=(); [ "$FLIST" = apmu_fpga.f ] && EXTRA=(scripts/stubs/xpm_memory_spram_stub.sv)
verilator --lint-only -Wno-fatal -Wno-BLKANDNBLK --top-module apmu_hesoc_top -sv --Mdir $OUT/obj \
  +define+COMMON_CELLS_ASSERTS_OFF "${EXTRA[@]}" -f $OUT/flist.f > $OUT/lint.log 2>&1
rc=$?
grep -oE '^%(Warning|Error)-?[A-Z_]*' $OUT/lint.log | sort | uniq -c
echo "verilator exit=$rc"
exit $rc
