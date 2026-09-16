// Bare-metal startup for the APMU Ibex (ibex_pmu_core, RV32IMC).
//
// Boot: the modified core fetches from {boot_addr[31:8], 8'h00} (ibex_if_stage PC_BOOT) = ISPM_BASE.
//
// FETCH SKEW (RTL behaviour of pmu_ispm + Ibex prefetch buffer, identical in the he-soc sources):
// during the reset-time boot fetch pmu_ispm asserts pmc_instr_gnt_o in its response cycle while the
// Ibex is requesting the next word; that request is counted as granted but never answered. From then
// on every instruction word is paired with the PC of the previous word, i.e. PC(software) =
// physical address - 4, and the first word fetched after any PC change is discarded. Control flow
// therefore stays correct if the image is LINKED 4 bytes below where it is LOADED, with a sacrificial
// first word. The he-soc PMU firmware does the same (ISPM ORIGIN ending in ...FFC + leading NOPs).
// link.ld places .text at ISPM_BASE-4; tb_apmu loads the image at ISPM_BASE.
#include "apmu_fw.h"

    .section .text.pad, "ax"
    .word 0x00000013            // link ISPM_BASE-4 / physical ISPM_BASE: discarded by the fetch skew

    .section .text.init, "ax"
    .globl _start
_start:
    auipc t2, 0                 // PC as seen by software (expected ISPM_BASE, see above)
    la    sp, _stack_end
    la    t0, _bss_start
    la    t1, _bss_end
1:  bgeu  t0, t1, 2f
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     1b
2:  li    t0, MB_BOOT_PC
    sw    t2, 0(t0)
    la    t0, trap_vector
    csrw  mtvec, t0
    call  main
hang:
    j     hang

// ---------------------------------------------------------------------------------------------
// APMU custom counter instructions (major opcode 0x07, decoded in ibex_decoder OPCODE_COUNTER):
//   funct3=000  counter read : rd  = counter[rs1 + rs2]      (PMC_REQ, we=0)
//   funct3=001  counter write: counter[rs1 + imm_S] = rs2     (PMC_REQ, we=1)
//   funct3=010, funct7=0 WFP : rd  = pending & (rs1 + rs2), blocks until non-zero, clears pending
// ---------------------------------------------------------------------------------------------
    .section .text, "ax"
    .globl cnt_rd
cnt_rd:                         // a0 = idx  -> a0 = counter value (31 bits, pending excluded)
    .word 0x00050507            // rd=a0 rs1=a0 rs2=x0 funct3=000 opcode=0x07
    ret

    .globl cnt_wr
cnt_wr:                         // a0 = idx, a1 = value
    .word 0x00B51007            // rs2=a1 rs1=a0 funct3=001 imm=0 opcode=0x07
    ret

    .globl cnt_wfp
cnt_wfp:                        // a0 = counter mask -> a0 = pending mask
    .word 0x00052507            // rd=a0 rs1=a0 rs2=x0 funct3=010 funct7=0 opcode=0x07
    ret

// ---------------------------------------------------------------------------------------------
// Trap handler (mtvec is always vectored with a 256-byte aligned base; exceptions enter at base).
// Records cause/epc/tval in the DSPM mailbox and hangs. The TB flags this as FAIL.
// ---------------------------------------------------------------------------------------------
    .section .text.trap, "ax"
    .globl trap_vector
trap_vector:
    li    t0, MB_TRAP_MCAUSE
    csrr  t1, mcause
    sw    t1, 0(t0)
    li    t0, MB_TRAP_MEPC
    csrr  t1, mepc
    sw    t1, 0(t0)
    li    t0, MB_TRAP_MTVAL
    csrr  t1, mtval
    sw    t1, 0(t0)
    li    t0, MB_STATUS
    li    t1, ST_TRAP
    sw    t1, 0(t0)
trap_hang:
    j     trap_hang
