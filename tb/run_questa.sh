#!/bin/bash
# Functional test of the standalone APMU bundle in Questa.
#   - builds tb/fw (RV32IMC firmware for the APMU Ibex)
#   - compiles ONLY apmu_sim.f (bundle RTL) + tb/tb_apmu.sv
#   - runs tb_apmu; exits 0 only if the sim prints "RESULT: PASS" and no Questa Error/Fatal
#
# Environment options:
#   SRC=bundle   (default) RTL from apmu_standalone/rtl via apmu_sim.f
#   SRC=orig     same file list/order, but every file taken from he-soc/hardware/ip_list (via
#                .provenance.json) -- used to prove a behaviour is identical in the original sources
#   RVFI=1       additionally recompile ibex_pmu/rtl/ibex_core.sv with +define+RVFI=true, mirroring
#                he-soc/hardware/compile.tcl, which compiles that file a second time with RVFI=true
#   WAVES=1      log all signals to <build>/tb_apmu.wlf
#   SIM_ARGS=... extra vsim plusargs, e.g. "+APMU_TRACE" or "+APMU_CYC_FROM=2250 +APMU_CYC_TO=2300"
# Build products: build/tb_questa/<SRC>[_rvfi]/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HESOC_HW="${HESOC_HW:-$(cd "$ROOT/../he-soc/hardware" 2>/dev/null && pwd || true)}"
SRC="${SRC:-bundle}"
B="$ROOT/build/tb_questa/${SRC}${RVFI:+_rvfi}"
QUESTA_BIN="${QUESTA_BIN:-/tools/questasim/bin}"
export PATH="$QUESTA_BIN:$PATH"

mkdir -p "$B"
"$ROOT/tb/fw/build_fw.sh" "$B/fw"

case "$SRC" in
  bundle) FLIST=(-F "$ROOT/apmu_sim.f")   # -F: relative paths resolved against the .f location
          RTL_DIR="$ROOT/rtl";;
  orig)   python3 "$ROOT/tb/orig_filelist.py" "$ROOT" "$HESOC_HW" "$ROOT/apmu_sim.f" "$B/orig_sim.f"
          FLIST=(-f "$B/orig_sim.f")
          RTL_DIR="$HESOC_HW/ip_list";;
  *)      echo "unknown SRC=$SRC"; exit 2;;
esac

cd "$B"   # vsim transcript / wlf land here, never in the bundle root
rm -rf work
vlib work > /dev/null

DEFS="+define+COMMON_CELLS_ASSERTS_OFF +define+TARGET_VSIM +define+TARGET_RTL +define+TARGET_SIMULATION"
vlog -sv -work work -timescale 1ns/1ps $DEFS -suppress 2583 -suppress 13314 \
     "${FLIST[@]}" -l vlog_rtl.log > /dev/null
if [ -n "${RVFI:-}" ]; then
  vlog -sv -work work -timescale 1ns/1ps $DEFS +define+RVFI=true -suppress 2583 -suppress 13314 \
       +incdir+"$RTL_DIR/ibex_pmu/rtl" +incdir+"$RTL_DIR/ibex_pmu/vendor/lowrisc_ip/ip/prim/rtl" \
       "$RTL_DIR/ibex_pmu/rtl/ibex_core.sv" -l vlog_rvfi.log > /dev/null
fi
vlog -sv -work work -timescale 1ns/1ps $DEFS \
     +incdir+"$RTL_DIR/axi/include" +incdir+"$RTL_DIR/common_cells/include" \
     "$ROOT/tb/tb_apmu.sv" -l vlog_tb.log > /dev/null
echo "vlog rtl: $(grep -h '^Errors:' vlog_rtl.log)"
echo "vlog tb : $(grep -h '^Errors:' vlog_tb.log)"

ACC=""; DO="run -all; quit -f"
if [ -n "${WAVES:-}" ]; then ACC="+acc"; DO="log -r /*; run -all; quit -f"; fi
vopt -work work tb_apmu -o tb_apmu_opt $ACC -l vopt.log > /dev/null
echo "vopt    : $(grep -h '^Errors:' vopt.log)"

set +e
vsim -c -work work tb_apmu_opt -wlf tb_apmu.wlf \
     +TEXT_HEX="$B/fw/ispm.hex" +DATA_HEX="$B/fw/dspm.hex" ${SIM_ARGS:-} \
     -do "$DO" -l sim.log > /dev/null
set -e
grep -E "^# (\[CHECK|\[TB\]|\[SYSMEM\]|\*\* (Error|Fatal|Warning))|never served" sim.log || true
if grep -q "RESULT: PASS" sim.log && ! grep -qE "^# \*\* (Error|Fatal)" sim.log; then
  echo "tb_apmu[$SRC${RVFI:+,RVFI}]: PASS  (log: $B/sim.log)"
  exit 0
else
  echo "tb_apmu[$SRC${RVFI:+,RVFI}]: FAIL  (log: $B/sim.log)"
  exit 1
fi
