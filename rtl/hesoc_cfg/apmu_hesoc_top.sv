// apmu_hesoc_top: pmu_top fixed to the configuration he-soc instantiates.
//
// NOT copied from he-soc -- written for this standalone bundle. Values mirror
// he-soc/hardware/host/host_domain.sv (i_pmu_top) for the quad-core build with
// APMU_IP defined:
//   NUM_PORT         = ariane_soc::NumCVA6 * 2 + 1 = 4*2+1 = 9
//   NUM_COUNTER      = APMU_NUM_COUNTER            = 32
//   ISPM_NUM_WORDS   = 1024
//   DSPM_NUM_WORDS   = 32768
//   MEMORY_BASE_ADDR = 32'h1060_6000
//   MEMORY_LENGTH    = 32'h0000_0100
// APMU/ISPM/DSPM base addresses are not overridden by he-soc, so pmu_top's
// defaults apply; they are restated here so the full config is visible.
// he-soc passes ariane_axi_soc::*_lite_t; those are field-for-field identical
// to pmu_pkg::*_lite_t (32-bit addr, 32-bit data, 4-bit strb), which are used.
module apmu_hesoc_top import pmu_pkg::*; #(
  parameter int unsigned NUM_PORT    = 9,
  parameter int unsigned NUM_COUNTER = 32
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  pmu_event_t [NUM_PORT-1:0] port_i,
  output req_lite_t                 master_req_o,
  input  resp_lite_t                master_resp_i,
  input  req_lite_t                 conf_req_i,
  output resp_lite_t                conf_resp_o,
  output logic [NUM_COUNTER-1:0]    intr_o
);

  pmu_top #(
    .NUM_PORT         ( NUM_PORT       ),
    .NUM_COUNTER      ( NUM_COUNTER    ),
    .APMU_BASE_ADDR   ( 32'h1040_5000  ),
    .ISPM_BASE_ADDR   ( 32'h1042_7000  ),
    .DSPM_BASE_ADDR   ( 32'h1042_8000  ),
    .ISPM_NUM_WORDS   ( 1024           ),
    .DSPM_NUM_WORDS   ( 32768          ),
    .MEMORY_BASE_ADDR ( 32'h1060_6000  ),
    .MEMORY_LENGTH    ( 32'h0000_0100  ),
    .req_lite_t       ( req_lite_t     ),
    .resp_lite_t      ( resp_lite_t    ),
    .aw_chan_lite_t   ( aw_chan_lite_t ),
    .w_chan_lite_t    ( w_chan_lite_t  ),
    .b_chan_lite_t    ( b_chan_lite_t  ),
    .ar_chan_lite_t   ( ar_chan_lite_t ),
    .r_chan_lite_t    ( r_chan_lite_t  )
  ) i_pmu_top (
    .clk_i,
    .rst_ni,
    .port_i,
    .master_req_o,
    .master_resp_i,
    .conf_req_i,
    .conf_resp_o,
    .intr_o
  );

endmodule
