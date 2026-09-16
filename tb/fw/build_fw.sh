#!/bin/bash
# Build the APMU test firmware and emit 32-bit word hex images for the ISPM and DSPM.
# Usage: build_fw.sh <out_dir>
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:?usage: build_fw.sh <out_dir>}"
mkdir -p "$OUT"

RISCV_PREFIX="${RISCV_PREFIX:-/opt/riscv/bin/riscv64-unknown-elf-}"
CC="${RISCV_PREFIX}gcc"; OBJCOPY="${RISCV_PREFIX}objcopy"; OBJDUMP="${RISCV_PREFIX}objdump"; NM="${RISCV_PREFIX}nm"

# ibex_pmu_core in pmu_core.sv: RV32E=0, RV32M=RV32MFast (default), compressed always on -> rv32imc
CFLAGS="-march=rv32imc -mabi=ilp32 -mcmodel=medlow -msmall-data-limit=0 -O2 -g \
        -ffreestanding -fno-builtin -nostdlib -nostartfiles -static -Wall -Wextra -I$HERE"

"$CC" $CFLAGS -T "$HERE/link.ld" "$HERE/crt0.S" "$HERE/main.c" -Wl,-Map,"$OUT/apmu_fw.map" -o "$OUT/apmu_fw.elf"
"$OBJDUMP" -d -h "$OUT/apmu_fw.elf" > "$OUT/apmu_fw.dis"

"$OBJCOPY" -O binary --only-section=.text "$OUT/apmu_fw.elf" "$OUT/ispm.bin"
"$OBJCOPY" -O binary --only-section=.dspm_hdr --only-section=.rodata --only-section=.data \
           "$OUT/apmu_fw.elf" "$OUT/dspm.bin"

to_hex() {  # pad to a multiple of 4 bytes, dump little-endian 32-bit words one per line
  local bin="$1" hex="$2" sz
  sz=$(stat -c %s "$bin"); truncate -s $(( (sz + 3) / 4 * 4 )) "$bin"
  od -An -v -tx4 -w4 "$bin" | tr -d ' ' > "$hex"
}
to_hex "$OUT/ispm.bin" "$OUT/ispm.hex"
to_hex "$OUT/dspm.bin" "$OUT/dspm.hex"

# Sanity: load addresses assumed by tb_apmu.sv
sym() { "$NM" "$OUT/apmu_fw.elf" | awk -v s="$1" '$3==s{print $1}'; }
[ "$(sym _start)"      = "10427000" ] || { echo "ERROR: _start not at ISPM base";            exit 1; }
[ "$(sym trap_vector)" = "10427100" ] || { echo "ERROR: trap_vector not at ISPM base+0x100"; exit 1; }
TEXT_VMA=$("$OBJDUMP" -h "$OUT/apmu_fw.elf" | awk '$2==".text"{print $4}')
[ "$TEXT_VMA" = "10426ffc" ] || { echo "ERROR: .text not linked at ISPM base-4 ($TEXT_VMA)"; exit 1; }
DSPM_VMA=$("$OBJDUMP" -h "$OUT/apmu_fw.elf" | awk '$2==".dspm_hdr"{print $4}')
[ "$DSPM_VMA" = "10428200" ] || { echo "ERROR: .dspm_hdr not at DSPM base+0x200 ($DSPM_VMA)"; exit 1; }

echo "FW: ispm.hex $(wc -l < "$OUT/ispm.hex") words, dspm.hex $(wc -l < "$OUT/dspm.hex") words"
