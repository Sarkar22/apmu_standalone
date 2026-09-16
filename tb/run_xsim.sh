#!/bin/bash
# Functional test of the standalone APMU bundle in the Vivado simulator (xvlog / xelab / xsim).
#
# Runs the SAME testbench and firmware as tb/run_questa.sh:
#   - tb/tb_apmu.sv is compiled unmodified (no xsim-specific edits)
#   - tb/fw is built with the same tb/fw/build_fw.sh (same ispm.hex / dspm.hex)
#   - RTL is ONLY the apmu_sim.f file list (bundle copies under rtl/), in apmu_sim.f order
# Exits 0 only if the log contains "RESULT: PASS" and no xsim Error/Fatal and no tool ERROR.
# (xsim itself exits 0 even after $error/$fatal, so the verdict is taken from the log.)
#
# Tool-dialect workaround (Vivado 2021.2), applied by default, XSIM_FIX=0 turns it off:
#   xelab aborts on the SVA "default disable iff (...)" declaration:
#     ERROR: [XSIM 43-3980] File ".../axi/src/axi_lite_xbar.sv" Line 117 : The SystemVerilog feature
#            "Default Disable iff declaration" is not supported yet for simulation.
#   xsim ignores "// pragma translate_off", and these pulp axi files guard their assertion blocks only
#   with `ifndef VERILATOR (no `ifndef XSIM). The five files that contain such a declaration are
#   compiled with -d VERILATOR. In these five files VERILATOR removes only the translate_off
#   assertion blocks (assert/assume property, "default disable iff", initial parameter asserts).
#   Checked with Questa "vlog -E" with and without VERILATOR: the only lines that differ are removed
#   lines, all of them assertion code. The RTL logic is unchanged. Each of the five files, left
#   without VERILATOR on its own, gives the same xelab error, both in the bundle and in the original
#   he-soc sources (SRC=orig XSIM_FIX=0 shows the first one). The Questa run keeps these axi
#   assertions active.
#
# Environment options:
#   SRC=bundle     (default) RTL from apmu_standalone/rtl via apmu_sim.f
#   SRC=orig       same list and order, every file taken from he-soc/hardware/ip_list through
#                  .provenance.json (tb/orig_filelist.py, which also byte-compares them)
#   RVFI=1         also recompile ibex_pmu/rtl/ibex_core.sv with RVFI=true (as he-soc compile.tcl)
#   TARGET_VSIM=1  also define TARGET_VSIM, i.e. exactly the Questa define set. By default it is
#                  left out: it selects a Questa-bug workaround typedef in axi_lite_demux.sv, and
#                  non-Questa tools use the struct typedef branch.
#   XSIM_FIX=0     compile everything without the VERILATOR workaround (shows the xelab error)
#   WAVES=1        elaborate with --debug typical and log all signals to <build>/tb_apmu.wdb
#   SIM_ARGS=...   TB plusargs in Questa form, e.g. "+APMU_TRACE" or "+APMU_CYC_FROM=2250 +APMU_CYC_TO=2300"
#                  (passed to xsim as --testplusarg)
# Build products: build/tb_xsim/<SRC>[_rvfi][_vsimdefs][_nofix][_waves]/
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HESOC_HW="${HESOC_HW:-$(cd "$ROOT/../he-soc/hardware" 2>/dev/null && pwd || true)}"
SRC="${SRC:-bundle}"
XSIM_FIX="${XSIM_FIX:-1}"
VARIANT="${SRC}${RVFI:+_rvfi}"
[ -n "${TARGET_VSIM:-}" ] && VARIANT="${VARIANT}_vsimdefs"
[ "$XSIM_FIX" = 0 ] && VARIANT="${VARIANT}_nofix"
[ -n "${WAVES:-}" ] && VARIANT="${VARIANT}_waves"
B="$ROOT/build/tb_xsim/$VARIANT"
XILINX_BIN="${XILINX_BIN:-/tools/Xilinx/Vivado/2021.2/bin}"
XVLOG="$XILINX_BIN/xvlog"; XELAB="$XILINX_BIN/xelab"; XSIM="$XILINX_BIN/xsim"

# Files whose `ifndef VERILATOR assertion blocks contain "default disable iff" (XSIM 43-3980).
XSIM_FIX_FILES=(axi/src/axi_lite_demux.sv axi/src/axi_lite_from_mem.sv axi/src/axi_lite_regs.sv
                axi/src/axi_err_slv.sv axi/src/axi_lite_xbar.sv)

mkdir -p "$B"
"$ROOT/tb/fw/build_fw.sh" "$B/fw"

case "$SRC" in
  bundle) FLIST="$ROOT/apmu_sim.f"; RTL_DIR="$ROOT/rtl";;
  orig)   python3 "$ROOT/tb/orig_filelist.py" "$ROOT" "$HESOC_HW" "$ROOT/apmu_sim.f" "$B/orig_sim.f"
          FLIST="$B/orig_sim.f"; RTL_DIR="$HESOC_HW/ip_list";;
  *)      echo "unknown SRC=$SRC"; exit 2;;
esac

cd "$B"   # xsim.dir, .Xil, journals and logs land here, never in the bundle root
rm -rf xsim.dir .Xil xvlog*.log xelab.log sim.log tb_apmu.wdb

# Questa-style .f -> xvlog arguments: +incdir+DIR -> "-i DIR"; relative paths are resolved
# against the .f location (like vlog -F); comments and blank lines are dropped.
FDIR="$(cd "$(dirname "$FLIST")" && pwd)"
INCS=(); FILES=(); FIX=()
while IFS= read -r line; do
  line="${line%%//*}"; line="$(echo "$line" | xargs)"
  [ -z "$line" ] && continue
  if [[ "$line" == +incdir+* ]]; then
    d="${line#+incdir+}"; [[ "$d" = /* ]] || d="$FDIR/$d"; INCS+=(-i "$d")
    continue
  fi
  f="$line"; [[ "$f" = /* ]] || f="$FDIR/$f"
  [ -f "$f" ] || { echo "ERROR: file from $FLIST not found: $f"; exit 1; }
  fix=0
  if [ "$XSIM_FIX" != 0 ]; then
    for x in "${XSIM_FIX_FILES[@]}"; do [[ "$f" == */"$x" ]] && fix=1; done
  fi
  if [ "$fix" = 1 ]; then FIX+=("$f"); else FILES+=("$f"); fi
done < "$FLIST"
if [ "$XSIM_FIX" != 0 ] && [ "${#FIX[@]}" != "${#XSIM_FIX_FILES[@]}" ]; then
  echo "ERROR: expected ${#XSIM_FIX_FILES[@]} XSIM_FIX files in $FLIST, found ${#FIX[@]}"; exit 1
fi

DEFS=(-d COMMON_CELLS_ASSERTS_OFF -d TARGET_RTL -d TARGET_SIMULATION)
[ -n "${TARGET_VSIM:-}" ] && DEFS+=(-d TARGET_VSIM)

step() {  # step <log> <cmd...>: run a tool, print its errors and stop on failure
  local log="$1"; shift
  if ! "$@" --log "$log" > /dev/null; then
    grep -hE "^(ERROR|CRITICAL WARNING)" "$log" || true
    echo "tb_apmu[xsim,$VARIANT]: FAIL at $(basename "$1") (log: $B/$log)"
    exit 1
  fi
}
summ() { printf "%-26s errors: %s, warnings: %s\n" "$1" \
           "$(grep -c '^ERROR' "$2" || true)" "$(grep -c '^WARNING' "$2" || true)"; }

step xvlog_rtl.log "$XVLOG" --sv "${DEFS[@]}" "${INCS[@]}" "${FILES[@]}"
summ "xvlog rtl (${#FILES[@]} files)" xvlog_rtl.log
if [ "${#FIX[@]}" -gt 0 ]; then
  step xvlog_rtl_xsimfix.log "$XVLOG" --sv "${DEFS[@]}" -d VERILATOR "${INCS[@]}" "${FIX[@]}"
  summ "xvlog rtl VERILATOR (${#FIX[@]})" xvlog_rtl_xsimfix.log
fi
if [ -n "${RVFI:-}" ]; then
  step xvlog_rvfi.log "$XVLOG" --sv "${DEFS[@]}" -d RVFI=true \
       -i "$RTL_DIR/ibex_pmu/rtl" -i "$RTL_DIR/ibex_pmu/vendor/lowrisc_ip/ip/prim/rtl" \
       "$RTL_DIR/ibex_pmu/rtl/ibex_core.sv"
  summ "xvlog ibex_core RVFI=true" xvlog_rvfi.log
fi
step xvlog_tb.log "$XVLOG" --sv "${DEFS[@]}" -i "$RTL_DIR/axi/include" -i "$RTL_DIR/common_cells/include" \
     "$ROOT/tb/tb_apmu.sv"
summ "xvlog tb" xvlog_tb.log

DEBUG=(); [ -n "${WAVES:-}" ] && DEBUG=(--debug typical)
step xelab.log "$XELAB" work.tb_apmu -s tb_apmu_snap --timescale 1ns/1ps "${DEBUG[@]}"
summ "xelab" xelab.log
grep -hE "^WARNING" xvlog*.log xelab.log | sed 's/^/  /' || true

PLUS=(--testplusarg "TEXT_HEX=$B/fw/ispm.hex" --testplusarg "DATA_HEX=$B/fw/dspm.hex")
for a in ${SIM_ARGS:-}; do PLUS+=(--testplusarg "${a#+}"); done
if [ -n "${WAVES:-}" ]; then
  printf 'log_wave -recursive *\nrun all\nquit\n' > waves.tcl
  RUN=(--tclbatch waves.tcl --wdb tb_apmu.wdb)
else
  RUN=(-R)
fi
set +e
"$XSIM" tb_apmu_snap "${RUN[@]}" "${PLUS[@]}" --log sim.log > /dev/null
XSIM_RC=$?
set -e
grep -E "^(\[CHECK|\[TB\]|\[SYSMEM\]|Error:|Fatal:|ERROR:|FATAL)|never served" sim.log || true

# Optional cross-simulator comparison with the Questa log of the same variant (informational).
QLOG="$ROOT/build/tb_questa/${SRC}${RVFI:+_rvfi}/sim.log"
if [ -f "$QLOG" ]; then
  norm() { grep -E "^(# )?\[(CHECK|TB|SYSMEM|IBEX)" "$1" | sed -E 's/^# //; s/ +/ /g' || true; }
  if diff <(norm "$QLOG") <(norm sim.log) > questa_vs_xsim.diff; then
    echo "cross-check: [CHECK]/[TB]/[SYSMEM]/[IBEX] lines identical to Questa log $QLOG (whitespace-normalised)"
  else
    echo "cross-check: differences vs Questa log $QLOG -> $B/questa_vs_xsim.diff"
  fi
fi

if [ "$XSIM_RC" = 0 ] && grep -q "RESULT: PASS" sim.log && ! grep -qE "^(Error|Fatal|ERROR|FATAL)" sim.log; then
  echo "tb_apmu[xsim,$VARIANT]: PASS  (log: $B/sim.log)"
  exit 0
else
  echo "tb_apmu[xsim,$VARIANT]: FAIL  (xsim rc=$XSIM_RC, log: $B/sim.log)"
  exit 1
fi
