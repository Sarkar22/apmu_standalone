#!/bin/bash
# Compile apmu_sim.f with the Vivado simulator (xvlog) and elaborate apmu_hesoc_top (xelab).
# Outputs go to build/xsim_elab/.
#
# Vivado 2021.2 xsim does not support `default disable iff` (XSIM 43-3980) and ignores
# `// pragma translate_off`. The pulp axi sources guard those assertion blocks only with
# `ifndef VERILATOR, so the rtl/axi/src files are compiled with -d VERILATOR. There it removes
# assertion code only; the same error occurs on the unmodified he-soc sources.
set -eo pipefail
XILINX_BIN=${XILINX_BIN:-/tools/Xilinx/Vivado/2021.2/bin}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/xsim_elab"
rm -rf "$OUT"; mkdir -p "$OUT"; cd "$OUT"

# Translate the .f: +incdir+DIR -> -i DIR, relative paths -> absolute, drop comments.
awk -v R="$ROOT" '
  { sub(/\/\/.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "") }
  $0 == "" { next }
  /^\+incdir\+/ { print "-i " R "/" substr($0, 9); next }
  { print R "/" $0 }
' "$ROOT/apmu_sim.f" > xvlog_args.f

# Compile in file order, as contiguous groups: rtl/axi/src files get -d VERILATOR, the rest do not.
grep '^-i ' xvlog_args.f > inc.f
grep -v '^-i ' xvlog_args.f | awk -v A="$ROOT/rtl/axi/src/" '
  { a = (index($0, A) == 1); if (NR == 1 || a != prev) { n++; prev = a; print n, a > "groups.txt" }
    print > ("grp" n ".f") }'
while read -r n axi; do
  D=(); [ "$axi" = 1 ] && D=(-d VERILATOR)
  "$XILINX_BIN/xvlog" --sv --work work=xsim.dir/work -d COMMON_CELLS_ASSERTS_OFF "${D[@]}" \
      -f inc.f -f "grp$n.f" --log "xvlog_$n.log" > /dev/null
done < groups.txt
cat xvlog_[0-9]*.log > xvlog.log

"$XILINX_BIN/xelab" work.apmu_hesoc_top -s apmu_hesoc_top_snap --debug typical --timescale 1ns/1ps \
    --log xelab.log > /dev/null
grep -hE "^(ERROR|CRITICAL WARNING)" xvlog.log xelab.log || true
echo "xvlog/xelab OK: $(grep -c '^Compiling module' xelab.log) module specializations"
