// Shared constants between the APMU test firmware (fw/main.c) and tb_apmu.sv.
// Address map is the he-soc default pmu_top parameters (APMU_BASE_ADDR / ISPM_BASE_ADDR /
// DSPM_BASE_ADDR defaults, MEMORY_BASE_ADDR = 0x1060_6000 from host_domain.sv).
#ifndef APMU_FW_H
#define APMU_FW_H

// ---- APMU register space (pmu_top: APMU_BASE_ADDR = 0x1040_5000) ----
#define APMU_TIMER_LO        0x10405000u
#define APMU_PERIOD_LO       0x10405008u
#define APMU_STATUS          0x10406000u   // bit0 = stall PMU core (reset 1)
#define APMU_BOOT_ADDR       0x10406004u
#define APMU_CNT_BASE        0x10407000u   // counter bundle i at +i*0x1000
#define APMU_CNT_BUNDLE      0x1000u
#define CNT_REG(i)           (APMU_CNT_BASE + (i) * APMU_CNT_BUNDLE + 0x0u)
#define EVSEL_REG(i)         (APMU_CNT_BASE + (i) * APMU_CNT_BUNDLE + 0x4u)
#define EVINFO_REG(i)        (APMU_CNT_BASE + (i) * APMU_CNT_BUNDLE + 0x8u)
#define BUDGET_REG(i)        (APMU_CNT_BASE + (i) * APMU_CNT_BUNDLE + 0xCu)

// ---- SPMs ----
#define ISPM_BASE            0x10427000u
#define DSPM_BASE            0x10428000u

// ---- System memory window behind master_req_o (MEMORY_BASE_ADDR/LENGTH) ----
#define SYSMEM_BASE          0x10606000u
#define SYSMEM_RD_ADDR       (SYSMEM_BASE + 0x00u)   // TB slave returns SYSMEM_RD_VALUE
#define SYSMEM_WR_ADDR0      (SYSMEM_BASE + 0x10u)
#define SYSMEM_WR_ADDR1      (SYSMEM_BASE + 0x14u)
#define SYSMEM_RD_VALUE      0x5A5A1234u
#define SYSMEM_WR_VALUE0     0xDEADBEEFu

// ---- DSPM mailbox (firmware -> TB results, TB -> firmware command) ----
#define MB_STATUS            (DSPM_BASE + 0x00u)
#define MB_SIGNATURE         (DSPM_BASE + 0x04u)
#define MB_ARITH             (DSPM_BASE + 0x08u)
#define MB_DATA_SUM          (DSPM_BASE + 0x0Cu)
#define MB_SYSMEM_RD         (DSPM_BASE + 0x10u)
#define MB_CNT4_RD           (DSPM_BASE + 0x14u)
#define MB_WFP_MASK          (DSPM_BASE + 0x18u)
#define MB_CNT2_RD           (DSPM_BASE + 0x1Cu)
#define MB_EVSEL1_RD         (DSPM_BASE + 0x20u)
#define MB_TIMER_T1          (DSPM_BASE + 0x24u)
#define MB_TIMER_T2          (DSPM_BASE + 0x28u)
#define MB_BOOT_PC           (DSPM_BASE + 0x2Cu)   // auipc at _start
#define MB_TRAP_MCAUSE       (DSPM_BASE + 0x30u)
#define MB_TRAP_MEPC         (DSPM_BASE + 0x34u)
#define MB_TRAP_MTVAL        (DSPM_BASE + 0x38u)
#define MB_CMD               (DSPM_BASE + 0x80u)

#define ST_BOOTED            0xB0070001u
#define ST_WAIT_CMD          0xB0070002u
#define ST_WAIT_EVENTS       0xB0070003u
#define ST_DONE              0xB00700DDu
#define ST_TRAP              0xDEAD0000u
#define CMD_GO               0x000000FFu

#define FW_SIGNATURE         0xA9B0C0DEu

// Firmware-side counter operations
#define FW_CNT4_VALUE        0x00ABCDEFu   // cnt_wr(4, ...)
#define FW_CNT7_VALUE        0x40000000u   // cnt_wr(7, ...) -> overflow bit -> intr_o[7]
#define FW_BUDGET8_VALUE     0x00001234u   // written to BUDGET_REG(8) through the core's data port
#define WFP_COUNTER          2u

#endif
