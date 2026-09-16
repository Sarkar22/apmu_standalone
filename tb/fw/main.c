// APMU functional-test firmware (runs on the APMU's ibex_pmu_core, loaded into the ISPM by tb_apmu).
// Every step leaves an externally checkable effect: DSPM mailbox words, AXI-lite transactions on
// master_req_o, APMU counter/register values readable over conf_req_i, and intr_o bits.
#include <stdint.h>
#include "apmu_fw.h"

#define WR32(a, v) (*(volatile uint32_t *)(uintptr_t)(a) = (uint32_t)(v))
#define RD32(a)    (*(volatile uint32_t *)(uintptr_t)(a))

extern uint32_t cnt_rd(uint32_t idx);
extern void     cnt_wr(uint32_t idx, uint32_t value);
extern uint32_t cnt_wfp(uint32_t mask);

// Initialised data: lives in the DSPM (.data), loaded there by the TB over AXI-lite exactly like
// the SoC software memcpy()s data_rodata_bss.bin to DSPM_BASE + 0x200. volatile => real loads.
volatile uint32_t data_table[8] = {
  0x12345678u, 16u, 0xCAFEBABEu, 0x0BADF00Du, 0x13579BDFu, 0x2468ACE0u, 0xFFFFFFFFu, 0x00000001u
};

// Uninitialised data (must be zeroed by crt0 .bss loop)
uint32_t bss_scratch[4];

// Exercises RV32M (mul, unsigned/signed div/rem) with loop bounds taken from DSPM memory.
static uint32_t arith_kernel(void) {
  uint32_t acc = data_table[0];
  uint32_t n   = data_table[1];
  for (uint32_t i = 1; i <= n; i++) {
    acc = acc * 1103515245u + 12345u;
    acc ^= (acc / (i + 3u)) + (acc % (i + 7u));
  }
  int32_t s = (int32_t)acc;
  acc ^= (uint32_t)(s / -7) + (uint32_t)(s % 13);
  return acc;
}

int main(void) {
  WR32(MB_STATUS, ST_BOOTED);
  WR32(MB_SIGNATURE, FW_SIGNATURE);

  uint32_t arith = arith_kernel();
  WR32(MB_ARITH, arith);

  uint32_t sum = 0;
  for (uint32_t i = 0; i < 8; i++) sum += data_table[i];
  sum += bss_scratch[0] | bss_scratch[1] | bss_scratch[2] | bss_scratch[3];  // must be 0
  WR32(MB_DATA_SUM, sum);

  // Core data port -> axi_lite_from_mem -> xbar -> master_req_o (system memory window)
  WR32(SYSMEM_WR_ADDR0, SYSMEM_WR_VALUE0);
  WR32(SYSMEM_WR_ADDR1, FW_SIGNATURE ^ arith);
  WR32(MB_SYSMEM_RD, RD32(SYSMEM_RD_ADDR));

  // Custom counter instructions
  cnt_wr(4, FW_CNT4_VALUE);
  WR32(MB_CNT4_RD, cnt_rd(4));
  cnt_wr(7, FW_CNT7_VALUE);

  // Core data port -> xbar -> APMU axi_lite_regs (PMU_REG target)
  WR32(MB_EVSEL1_RD, RD32(EVSEL_REG(1)));
  WR32(BUDGET_REG(8), FW_BUDGET8_VALUE);
  WR32(MB_TIMER_T1, RD32(APMU_TIMER_LO));
  for (volatile uint32_t d = 0; d < 20; d++) ;
  WR32(MB_TIMER_T2, RD32(APMU_TIMER_LO));

  // Handshake with the TB through the DSPM (TB writes MB_CMD over conf AXI-lite)
  WR32(MB_STATUS, ST_WAIT_CMD);
  while (RD32(MB_CMD) != CMD_GO) ;

  // Block in WFP until the TB drives events that set the pending bit of counter 2
  WR32(MB_STATUS, ST_WAIT_EVENTS);
  uint32_t mask = cnt_wfp(1u << WFP_COUNTER);
  WR32(MB_WFP_MASK, mask);
  WR32(MB_CNT2_RD, cnt_rd(WFP_COUNTER));

  WR32(MB_STATUS, ST_DONE);
  for (;;) ;
  return 0;
}
