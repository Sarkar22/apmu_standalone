// Functional testbench for the standalone APMU bundle (pmu_top at the he-soc quad-core configuration).
//
// What it does (mirrors how he-soc CVA6 software drives the APMU):
//   1. Reset; checks reset values of STATUS (stall=1) and BOOT_ADDR (ISPM base).
//   2. Loads firmware .text into the ISPM and .data into DSPM+0x200 over conf_req_i AXI-lite,
//      reads both back.
//   3. Configures counters (event select / event info / overflow-irq) and the timer period.
//   4. Verifies the core stays stalled, then writes BOOT_ADDR and clears STATUS.stall.
//   5. Firmware (tb/fw/main.c) runs on the APMU Ibex and reports into a DSPM mailbox; it also
//      issues AXI-lite transactions on master_req_o (checked by the slave model below), reads and
//      writes APMU registers through its data port, and uses the custom counter instructions
//      (cnt_wr / cnt_rd / WFP).
//   6. TB drives port_i events and checks counter values over conf AXI-lite, event/port/source
//      filtering, event_info ADD, overflow -> intr_o.
//   7. Firmware blocks in WFP until TB events set counter 2's pending bit.
//   8. MemGuard period reload of initial budgets (incl. one written by the firmware).
//   9. Re-stall / re-boot of the APMU core.
// The firmware is linked 4 bytes below its load address because of an RTL-level fetch skew in
// pmu_ispm + Ibex prefetch buffer (explained in tb/fw/crt0.S; he-soc PMU firmware does the same).
// The TB checks that skew explicitly (MB_BOOT_PC and the phantom-grant monitor).
//
// Plusargs: +TEXT_HEX=<ispm.hex> +DATA_HEX=<dspm.hex> [+APMU_TRACE] [+APMU_CYC_FROM=n +APMU_CYC_TO=m]
`timescale 1ns/1ps

module tb_apmu;
  import pmu_pkg::*;

  // ---------------------------------------------------------------------------------------------
  // DUT configuration: he-soc host_domain.sv values (NumCVA6 = 4)
  // ---------------------------------------------------------------------------------------------
  localparam int unsigned NUM_PORT         = 9;       // NumCVA6*2+1
  localparam int unsigned NUM_COUNTER      = 32;      // APMU_NUM_COUNTER
  localparam int unsigned ISPM_NUM_WORDS   = 1024;
  localparam int unsigned DSPM_NUM_WORDS   = 32768;
  localparam logic [31:0] MEMORY_BASE_ADDR = 32'h1060_6000;
  localparam logic [31:0] MEMORY_LENGTH    = 32'h0000_0100;

  // ---------------------------------------------------------------------------------------------
  // Address map / mailbox -- must match tb/fw/apmu_fw.h
  // ---------------------------------------------------------------------------------------------
  localparam logic [31:0] APMU_TIMER_LO   = 32'h1040_5000;
  localparam logic [31:0] APMU_PERIOD_LO  = 32'h1040_5008;
  localparam logic [31:0] APMU_PERIOD_HI  = 32'h1040_500C;
  localparam logic [31:0] APMU_STATUS     = 32'h1040_6000;
  localparam logic [31:0] APMU_BOOT_ADDR  = 32'h1040_6004;
  localparam logic [31:0] APMU_CNT_BASE   = 32'h1040_7000;
  localparam logic [31:0] ISPM_BASE       = 32'h1042_7000;
  localparam logic [31:0] DSPM_BASE       = 32'h1042_8000;
  localparam logic [31:0] DSPM_LOAD_BASE  = DSPM_BASE + 32'h200;

  localparam logic [31:0] SYSMEM_RD_ADDR   = MEMORY_BASE_ADDR + 32'h00;
  localparam logic [31:0] SYSMEM_WR_ADDR0  = MEMORY_BASE_ADDR + 32'h10;
  localparam logic [31:0] SYSMEM_WR_ADDR1  = MEMORY_BASE_ADDR + 32'h14;
  localparam logic [31:0] SYSMEM_RD_VALUE  = 32'h5A5A_1234;
  localparam logic [31:0] SYSMEM_WR_VALUE0 = 32'hDEAD_BEEF;

  localparam logic [31:0] MB_STATUS      = DSPM_BASE + 32'h00;
  localparam logic [31:0] MB_SIGNATURE   = DSPM_BASE + 32'h04;
  localparam logic [31:0] MB_ARITH       = DSPM_BASE + 32'h08;
  localparam logic [31:0] MB_DATA_SUM    = DSPM_BASE + 32'h0C;
  localparam logic [31:0] MB_SYSMEM_RD   = DSPM_BASE + 32'h10;
  localparam logic [31:0] MB_CNT4_RD     = DSPM_BASE + 32'h14;
  localparam logic [31:0] MB_WFP_MASK    = DSPM_BASE + 32'h18;
  localparam logic [31:0] MB_CNT2_RD     = DSPM_BASE + 32'h1C;
  localparam logic [31:0] MB_EVSEL1_RD   = DSPM_BASE + 32'h20;
  localparam logic [31:0] MB_TIMER_T1    = DSPM_BASE + 32'h24;
  localparam logic [31:0] MB_TIMER_T2    = DSPM_BASE + 32'h28;
  localparam logic [31:0] MB_BOOT_PC     = DSPM_BASE + 32'h2C;
  localparam logic [31:0] MB_TRAP_MCAUSE = DSPM_BASE + 32'h30;
  localparam logic [31:0] MB_TRAP_MEPC   = DSPM_BASE + 32'h34;
  localparam logic [31:0] MB_TRAP_MTVAL  = DSPM_BASE + 32'h38;
  localparam logic [31:0] MB_CMD         = DSPM_BASE + 32'h80;

  localparam logic [31:0] ST_BOOTED      = 32'hB007_0001;
  localparam logic [31:0] ST_WAIT_CMD    = 32'hB007_0002;
  localparam logic [31:0] ST_WAIT_EVENTS = 32'hB007_0003;
  localparam logic [31:0] ST_DONE        = 32'hB007_00DD;
  localparam logic [31:0] ST_TRAP        = 32'hDEAD_0000;
  localparam logic [31:0] CMD_GO         = 32'h0000_00FF;
  localparam logic [31:0] FW_SIGNATURE   = 32'hA9B0_C0DE;
  localparam logic [31:0] FW_CNT4_VALUE  = 32'h00AB_CDEF;
  localparam logic [31:0] FW_CNT7_VALUE  = 32'h4000_0000;
  localparam logic [31:0] FW_BUDGET8     = 32'h0000_1234;
  localparam logic [31:0] DSPM_HDR_MAGIC = 32'h0DA7_A5EC;
  // APMU fetch skew (RTL behaviour, see tb/fw/crt0.S): software PC = physical fetch address - 4.
  // The .text image is linked at ISPM_BASE-4 and loaded at ISPM_BASE; _start is physically at
  // ISPM_BASE+4 and observes PC == ISPM_BASE.
  localparam logic [31:0] FETCH_SKEW     = 32'd4;
  // .data table of the firmware (fw/main.c data_table[])
  localparam logic [31:0] FW_DATA [8] = '{32'h12345678, 32'd16, 32'hCAFEBABE, 32'h0BADF00D,
                                          32'h13579BDF, 32'h2468ACE0, 32'hFFFFFFFF, 32'h00000001};

  function automatic logic [31:0] cnt_reg   (int unsigned i); return APMU_CNT_BASE + i*32'h1000 + 32'h0; endfunction
  function automatic logic [31:0] evsel_reg (int unsigned i); return APMU_CNT_BASE + i*32'h1000 + 32'h4; endfunction
  function automatic logic [31:0] evinfo_reg(int unsigned i); return APMU_CNT_BASE + i*32'h1000 + 32'h8; endfunction
  function automatic logic [31:0] budget_reg(int unsigned i); return APMU_CNT_BASE + i*32'h1000 + 32'hC; endfunction

  // event_sel_cfg_t : {pad[31:24], port_val[23:20], port_mask[19:16], src_val[15:12], src_mask[11:8],
  //                    eid_val[7:4], eid_mask[3:0]}
  function automatic logic [31:0] evsel(logic [3:0] port_val, logic [3:0] port_mask,
                                        logic [3:0] src_val,  logic [3:0] src_mask,
                                        logic [3:0] eid_val,  logic [3:0] eid_mask);
    return {8'h00, port_val, port_mask, src_val, src_mask, eid_val, eid_mask};
  endfunction
  // event_info_cfg_t: {pad[31:25], ovf_intr_en[24], event_info_en[23], val_u[22:19], val_l[18:15],
  //                    opcode[14:10], eisf_end[9:5], eisf_start[4:0]}
  localparam logic [31:0] EVINFO_OVF_INTR_EN = 32'h0100_0000;
  localparam logic [31:0] EVINFO_ADD_7_0     = 32'h0080_0000 | (32'd7 << 5); // en, opcode ADD, [7:0]

  // ---------------------------------------------------------------------------------------------
  // Clock, reset, DUT
  // ---------------------------------------------------------------------------------------------
  localparam time CLK_PERIOD = 10ns;
  localparam time TA         = 1ns;   // application delay after posedge
  localparam time TT         = 9ns;   // sample time after posedge
  localparam int unsigned AXI_TIMEOUT_CYCLES = 2000;
  localparam longint unsigned SIM_TIMEOUT_CYCLES = 400_000;

  logic clk = 1'b0;
  logic rst_n;
  always #(CLK_PERIOD/2) clk = ~clk;

  pmu_event_t [NUM_PORT-1:0] port;
  req_lite_t                 conf_req;
  resp_lite_t                conf_resp;
  req_lite_t                 master_req;
  resp_lite_t                master_resp;
  logic [NUM_COUNTER-1:0]    intr;

  // DUT: pmu_top in the he-soc configuration, through the bundle's apmu_hesoc_top wrapper.
  apmu_hesoc_top i_top (
    .clk_i         ( clk         ),
    .rst_ni        ( rst_n       ),
    .port_i        ( port        ),
    .master_req_o  ( master_req  ),
    .master_resp_i ( master_resp ),
    .conf_req_i    ( conf_req    ),
    .conf_resp_o   ( conf_resp   ),
    .intr_o        ( intr        )
  );

  // The TB's address/size constants must describe the configuration the wrapper applies.
  initial begin
    if (i_top.i_pmu_top.NUM_PORT != NUM_PORT || i_top.i_pmu_top.NUM_COUNTER != NUM_COUNTER ||
        i_top.i_pmu_top.ISPM_NUM_WORDS != ISPM_NUM_WORDS || i_top.i_pmu_top.DSPM_NUM_WORDS != DSPM_NUM_WORDS ||
        i_top.i_pmu_top.MEMORY_BASE_ADDR != MEMORY_BASE_ADDR || i_top.i_pmu_top.MEMORY_LENGTH != MEMORY_LENGTH)
      $fatal(1, "[TB] tb_apmu constants do not match apmu_hesoc_top configuration");
  end

  longint unsigned cycle = 0;
  always @(posedge clk) cycle <= cycle + 1;

  int unsigned n_errors = 0;
  int unsigned n_checks = 0;

  task automatic check_eq(string what, logic [31:0] got, logic [31:0] exp);
    n_checks++;
    if (got !== exp) begin
      n_errors++;
      $error("[CHECK FAIL] %s: got 0x%08h expected 0x%08h", what, got, exp);
    end else begin
      $display("[CHECK  OK ] %-58s = 0x%08h", what, got);
    end
  endtask

  task automatic check_true(string what, bit cond);
    n_checks++;
    if (!cond) begin
      n_errors++;
      $error("[CHECK FAIL] %s", what);
    end else begin
      $display("[CHECK  OK ] %s", what);
    end
  endtask

  task automatic wait_cycles(int unsigned n);
    repeat (n) @(posedge clk);
  endtask

  // ---------------------------------------------------------------------------------------------
  // AXI4-Lite master on conf_req_i (single-threaded: only the main initial block calls these)
  // ---------------------------------------------------------------------------------------------
  task automatic axi_write(input logic [31:0] addr, input logic [31:0] data,
                           output axi_pkg::resp_t resp);
    bit aw_done = 0, w_done = 0;
    int unsigned n = 0;
    @(posedge clk); #TA;
    conf_req.aw.addr  = addr;
    conf_req.aw.prot  = '0;
    conf_req.aw_valid = 1'b1;
    conf_req.w.data   = data;
    conf_req.w.strb   = 4'hF;
    conf_req.w_valid  = 1'b1;
    conf_req.b_ready  = 1'b0;
    while (!(aw_done && w_done)) begin
      #(TT - TA);
      if (conf_req.aw_valid && conf_resp.aw_ready) aw_done = 1;
      if (conf_req.w_valid  && conf_resp.w_ready)  w_done  = 1;
      @(posedge clk); #TA;
      if (aw_done) conf_req.aw_valid = 1'b0;
      if (w_done)  conf_req.w_valid  = 1'b0;
      if (++n > AXI_TIMEOUT_CYCLES) $fatal(1, "AXI write 0x%08h: AW/W handshake timeout", addr);
    end
    conf_req.b_ready = 1'b1;
    n = 0;
    forever begin
      #(TT - TA);
      if (conf_resp.b_valid) begin
        resp = conf_resp.b.resp;
        @(posedge clk); #TA;
        break;
      end
      @(posedge clk); #TA;
      if (++n > AXI_TIMEOUT_CYCLES) $fatal(1, "AXI write 0x%08h: B timeout", addr);
    end
    conf_req.b_ready = 1'b0;
  endtask

  task automatic axi_read(input logic [31:0] addr, output logic [31:0] data,
                          output axi_pkg::resp_t resp);
    int unsigned n = 0;
    @(posedge clk); #TA;
    conf_req.ar.addr  = addr;
    conf_req.ar.prot  = '0;
    conf_req.ar_valid = 1'b1;
    conf_req.r_ready  = 1'b0;
    forever begin
      #(TT - TA);
      if (conf_resp.ar_ready) begin
        @(posedge clk); #TA;
        break;
      end
      @(posedge clk); #TA;
      if (++n > AXI_TIMEOUT_CYCLES) $fatal(1, "AXI read 0x%08h: AR timeout", addr);
    end
    conf_req.ar_valid = 1'b0;
    conf_req.r_ready  = 1'b1;
    n = 0;
    forever begin
      #(TT - TA);
      if (conf_resp.r_valid) begin
        data = conf_resp.r.data;
        resp = conf_resp.r.resp;
        @(posedge clk); #TA;
        break;
      end
      @(posedge clk); #TA;
      if (++n > AXI_TIMEOUT_CYCLES) $fatal(1, "AXI read 0x%08h: R timeout", addr);
    end
    conf_req.r_ready = 1'b0;
  endtask

  task automatic wr32(input logic [31:0] addr, input logic [31:0] data);
    axi_pkg::resp_t resp;
    axi_write(addr, data, resp);
    if (resp != axi_pkg::RESP_OKAY) begin
      n_errors++;
      $error("AXI write 0x%08h <= 0x%08h returned resp=%0d", addr, data, resp);
    end
  endtask

  task automatic rd32(input logic [31:0] addr, output logic [31:0] data);
    axi_pkg::resp_t resp;
    axi_read(addr, data, resp);
    if (resp != axi_pkg::RESP_OKAY) begin
      n_errors++;
      $error("AXI read 0x%08h returned resp=%0d", addr, resp);
    end
  endtask

  task automatic rd_check(string what, input logic [31:0] addr, input logic [31:0] exp);
    logic [31:0] v;
    rd32(addr, v);
    check_eq(what, v, exp);
  endtask

  // ---------------------------------------------------------------------------------------------
  // AXI4-Lite slave model on master_req_o / master_resp_i (the "system memory" window)
  // ---------------------------------------------------------------------------------------------
  typedef enum logic [1:0] {S_IDLE, S_ACC, S_RESP} slv_state_e;
  slv_state_e  sw_state, sr_state;
  logic [31:0] sysmem [logic [31:0]];
  logic [31:0] sys_wr_addr_q [$];
  logic [31:0] sys_wr_data_q [$];
  logic [31:0] sys_rd_addr_q [$];
  int unsigned sys_protocol_errors = 0;

  function automatic bit in_sysmem(logic [31:0] a);
    return (a >= MEMORY_BASE_ADDR) && (a < MEMORY_BASE_ADDR + MEMORY_LENGTH);
  endfunction

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      master_resp <= '0;
      sw_state    <= S_IDLE;
      sr_state    <= S_IDLE;
      sysmem[SYSMEM_RD_ADDR] = SYSMEM_RD_VALUE;   // value the firmware reads back
    end else begin
      // ---- write channel ----
      unique case (sw_state)
        S_IDLE: if (master_req.aw_valid && master_req.w_valid) begin
          master_resp.aw_ready <= 1'b1;
          master_resp.w_ready  <= 1'b1;
          sw_state             <= S_ACC;
        end
        S_ACC: begin  // AW and W handshakes complete in this cycle
          master_resp.aw_ready <= 1'b0;
          master_resp.w_ready  <= 1'b0;
          if (!(master_req.aw_valid && master_req.w_valid)) begin
            sys_protocol_errors++;
            $error("[SYSMEM] AW/W valid dropped before handshake");
          end
          $display("[SYSMEM] %0t write addr=0x%08h data=0x%08h strb=%b",
                   $time, master_req.aw.addr, master_req.w.data, master_req.w.strb);
          sys_wr_addr_q.push_back(master_req.aw.addr);
          sys_wr_data_q.push_back(master_req.w.data);
          sysmem[master_req.aw.addr] = master_req.w.data;
          master_resp.b.resp   <= in_sysmem(master_req.aw.addr) ? axi_pkg::RESP_OKAY
                                                                : axi_pkg::RESP_DECERR;
          master_resp.b_valid  <= 1'b1;
          sw_state             <= S_RESP;
        end
        S_RESP: if (master_req.b_ready) begin
          master_resp.b_valid  <= 1'b0;
          sw_state             <= S_IDLE;
        end
        default: sw_state <= S_IDLE;
      endcase
      // ---- read channel ----
      unique case (sr_state)
        S_IDLE: if (master_req.ar_valid) begin
          master_resp.ar_ready <= 1'b1;
          sr_state             <= S_ACC;
        end
        S_ACC: begin
          master_resp.ar_ready <= 1'b0;
          if (!master_req.ar_valid) begin
            sys_protocol_errors++;
            $error("[SYSMEM] AR valid dropped before handshake");
          end
          $display("[SYSMEM] %0t read  addr=0x%08h", $time, master_req.ar.addr);
          sys_rd_addr_q.push_back(master_req.ar.addr);
          master_resp.r.data   <= sysmem.exists(master_req.ar.addr) ? sysmem[master_req.ar.addr]
                                                                    : 32'hBADC0FFE;
          master_resp.r.resp   <= in_sysmem(master_req.ar.addr) ? axi_pkg::RESP_OKAY
                                                                : axi_pkg::RESP_DECERR;
          master_resp.r_valid  <= 1'b1;
          sr_state             <= S_RESP;
        end
        S_RESP: if (master_req.r_ready) begin
          master_resp.r_valid  <= 1'b0;
          sr_state             <= S_IDLE;
        end
        default: sr_state <= S_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------------------------------------
  // Event stimulus on port_i
  // ---------------------------------------------------------------------------------------------
  function automatic pmu_event_t mk_ev(logic [3:0] eid, logic [16:0] info = '0, logic [3:0] sid = '0);
    pmu_event_t e;
    e.e_id = eid; e.e_info = info; e.s_id = sid;
    return e;
  endfunction

  // Drive one cycle of events (index = port index, PORT_ID = index+1), then idle.
  task automatic pulse(input pmu_event_t [NUM_PORT-1:0] ev);
    @(posedge clk); #TA;
    port = ev;
    @(posedge clk); #TA;
    port = '0;
    wait_cycles(4);   // port_wrap register + event_info register + axi_lite_regs load
  endtask

  task automatic pulse_one(int unsigned idx, pmu_event_t e);
    pmu_event_t [NUM_PORT-1:0] ev = '0;
    ev[idx] = e;
    pulse(ev);
  endtask

  // ---------------------------------------------------------------------------------------------
  // Firmware image loading
  // ---------------------------------------------------------------------------------------------
  task automatic read_hex(string fname, ref logic [31:0] words[$]);
    int fd, rc;
    logic [31:0] w;
    fd = $fopen(fname, "r");
    if (fd == 0) $fatal(1, "Cannot open firmware hex '%s'", fname);
    while (!$feof(fd)) begin
      rc = $fscanf(fd, "%h\n", w);
      if (rc == 1) words.push_back(w);
    end
    $fclose(fd);
    if (words.size() == 0) $fatal(1, "Firmware hex '%s' is empty", fname);
  endtask

  task automatic load_and_verify(string what, logic [31:0] base, logic [31:0] words[$]);
    logic [31:0] v;
    int unsigned mism = 0;
    foreach (words[i]) wr32(base + 4*i, words[i]);
    foreach (words[i]) begin
      rd32(base + 4*i, v);
      if (v !== words[i]) begin
        mism++;
        if (mism < 8) $error("%s readback @0x%08h: got 0x%08h expected 0x%08h", what, base + 4*i, v, words[i]);
      end
    end
    n_checks++;
    if (mism != 0) begin
      n_errors++;
      $error("[CHECK FAIL] %s: %0d/%0d words mismatch after load", what, mism, words.size());
    end else begin
      $display("[CHECK  OK ] %s: %0d words written at 0x%08h and read back", what, words.size(), base);
    end
  endtask

  // Wait until MB_STATUS == exp, polling over AXI (like CVA6 software). Detect firmware traps.
  task automatic wait_status(logic [31:0] exp, int unsigned max_polls = 5000);
    logic [31:0] st, c, e, t;
    for (int unsigned i = 0; i < max_polls; i++) begin
      rd32(MB_STATUS, st);
      if (st == exp) begin
        $display("[TB] %0t cycle %0d: firmware status 0x%08h", $time, cycle, st);
        return;
      end
      if (st == ST_TRAP) begin
        rd32(MB_TRAP_MCAUSE, c); rd32(MB_TRAP_MEPC, e); rd32(MB_TRAP_MTVAL, t);
        $fatal(1, "FAIL: firmware trapped: mcause=0x%08h mepc=0x%08h mtval=0x%08h", c, e, t);
      end
    end
    $fatal(1, "FAIL: timeout waiting for firmware status 0x%08h (last 0x%08h)", exp, st);
  endtask

  // Expected result of fw/main.c arith_kernel()
  function automatic logic [31:0] exp_arith();
    logic [31:0] acc = FW_DATA[0];
    int signed   s;
    for (logic [31:0] i = 1; i <= FW_DATA[1]; i++) begin
      acc = acc * 32'd1103515245 + 32'd12345;
      acc = acc ^ ((acc / (i + 32'd3)) + (acc % (i + 32'd7)));
    end
    s   = signed'(acc);
    acc = acc ^ (32'(s / -7) + 32'(s % 13));
    return acc;
  endfunction

  // ---------------------------------------------------------------------------------------------
  // Optional bus trace of the APMU Ibex (+APMU_TRACE); also counts activity for the final report
  // ---------------------------------------------------------------------------------------------
  bit          trace_en;
  int unsigned n_fetch = 0, n_data_req = 0, n_cnt_ops = 0;
  // Instruction requests granted by pmu_ispm in the cycle it answers a previous core fetch
  // (axi_fsm_cs == READ): the ISPM never serves these, which creates the fetch skew.
  int unsigned n_phantom_gnt = 0;
  initial trace_en = $test$plusargs("APMU_TRACE");

  always @(posedge clk) if (rst_n) begin
    if (i_top.i_pmu_top.i_pmu_core.core_instr_req && i_top.i_pmu_top.i_pmu_core.core_instr_gnt &&
        i_top.i_pmu_top.i_pmu_core.i_pmu_ispm.axi_fsm_cs.name() == "READ") begin
      n_phantom_gnt++;
      $display("[IBEX] %0t cycle %0d: ISPM granted fetch of 0x%08h in its READ/response cycle (never served)",
               $time, cycle, i_top.i_pmu_top.i_pmu_core.core_instr_addr);
    end
    if (i_top.i_pmu_top.i_pmu_core.core_instr_rvalid) begin
      n_fetch++;
      if (trace_en) $display("[IBEX] %0t fetch  rdata=0x%08h err=%0b (req addr=0x%08h)", $time,
                             i_top.i_pmu_top.i_pmu_core.core_instr_rdata, i_top.i_pmu_top.i_pmu_core.core_instr_err,
                             i_top.i_pmu_top.i_pmu_core.core_instr_addr);
    end
    if (i_top.i_pmu_top.i_pmu_core.core_data_req && i_top.i_pmu_top.i_pmu_core.core_data_gnt) begin
      n_data_req++;
      if (trace_en) $display("[IBEX] %0t data   %s addr=0x%08h wdata=0x%08h be=%b", $time,
                             i_top.i_pmu_top.i_pmu_core.core_data_we ? "WR" : "RD",
                             i_top.i_pmu_top.i_pmu_core.core_data_addr, i_top.i_pmu_top.i_pmu_core.core_data_wdata,
                             i_top.i_pmu_top.i_pmu_core.core_data_be);
    end
    if (i_top.i_pmu_top.i_pmu_core.core_data_rvalid && trace_en)
      $display("[IBEX] %0t data   rvalid rdata=0x%08h err=%0b", $time,
               i_top.i_pmu_top.i_pmu_core.core_data_rdata, i_top.i_pmu_top.i_pmu_core.core_data_err);
    if (i_top.i_pmu_top.core_counter_op != apmu_ibex_pkg::PMC_IDLE && i_top.i_pmu_top.core_counter_gnt_q) begin
      n_cnt_ops++;
      if (trace_en) $display("[IBEX] %0t cntop  op=%s addr=0x%08h we=%0b wdata=0x%08h", $time,
                             i_top.i_pmu_top.core_counter_op.name(), i_top.i_pmu_top.core_counter_addr,
                             i_top.i_pmu_top.core_counter_we, i_top.i_pmu_top.core_counter_wdata);
    end
  end

  // Cycle-accurate fetch/ID trace in a cycle window: +APMU_CYC_FROM=<n> +APMU_CYC_TO=<m>
  longint unsigned cyc_from = 0, cyc_to = 0;
  initial begin
    void'($value$plusargs("APMU_CYC_FROM=%d", cyc_from));
    void'($value$plusargs("APMU_CYC_TO=%d", cyc_to));
  end
  always @(posedge clk) if (rst_n && cycle >= cyc_from && cycle < cyc_to) begin
    $display("[CYC %0d] stall=%0b fsm=%s | ireq=%0b iaddr=%08h gnt=%0b rvalid=%0b rdata=%08h | pc_set=%0b pc_if=%08h | id_valid=%0b pc_id=%08h instr_id=%08h",
      cycle, i_top.i_pmu_top.stall_core,
      i_top.i_pmu_top.i_pmu_core.i_ibex_pmu_core.id_stage_i.controller_i.ctrl_fsm_cs.name(),
      i_top.i_pmu_top.i_pmu_core.core_instr_req, i_top.i_pmu_top.i_pmu_core.core_instr_addr,
      i_top.i_pmu_top.i_pmu_core.core_instr_gnt, i_top.i_pmu_top.i_pmu_core.core_instr_rvalid,
      i_top.i_pmu_top.i_pmu_core.core_instr_rdata,
      i_top.i_pmu_top.i_pmu_core.i_ibex_pmu_core.if_stage_i.pc_set_i,
      i_top.i_pmu_top.i_pmu_core.i_ibex_pmu_core.if_stage_i.pc_if_o,
      i_top.i_pmu_top.i_pmu_core.i_ibex_pmu_core.instr_valid_id,
      i_top.i_pmu_top.i_pmu_core.i_ibex_pmu_core.pc_id,
      i_top.i_pmu_top.i_pmu_core.i_ibex_pmu_core.instr_rdata_id);
  end

  // ---------------------------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------------------------
  initial begin : watchdog
    wait (cycle > SIM_TIMEOUT_CYCLES);
    $fatal(1, "FAIL: global simulation timeout (%0d cycles)", SIM_TIMEOUT_CYCLES);
  end

  initial begin : main_seq
    string       text_hex, data_hex;
    logic [31:0] text_words[$], data_words[$];
    logic [31:0] v, v2, arith, sum;
    logic [31:0] exp_cnt [NUM_COUNTER];
    axi_pkg::resp_t resp;

    if (!$value$plusargs("TEXT_HEX=%s", text_hex)) text_hex = "fw/ispm.hex";
    if (!$value$plusargs("DATA_HEX=%s", data_hex)) data_hex = "fw/dspm.hex";
    read_hex(text_hex, text_words);
    read_hex(data_hex, data_words);

    conf_req = '0;
    port     = '0;
    rst_n    = 1'b0;
    wait_cycles(5);
    #TA rst_n = 1'b1;
    wait_cycles(5);

    // ------------------------------------------------------------------ reset state
    $display("\n[TB] ===== Phase 1: reset values =====");
    rd_check("STATUS reset (core stalled)", APMU_STATUS, 32'h1);
    rd_check("BOOT_ADDR reset (ISPM_BASE_ADDR)", APMU_BOOT_ADDR, ISPM_BASE);
    check_eq("intr_o after reset", intr, '0);
    axi_read(32'h1050_0000, v, resp);
    check_true("unmapped conf address -> DECERR (xbar error slave)", resp == axi_pkg::RESP_DECERR);
    axi_write(APMU_TIMER_LO, 32'h1234, resp);   // TIMER bytes are AxiReadOnly in axi_lite_regs
    check_true("write to read-only TIMER returns SLVERR", resp == axi_pkg::RESP_SLVERR);
    rd_check("TIMER unchanged by rejected write (period=0 -> frozen at 0)", APMU_TIMER_LO, 32'h0);

    // ------------------------------------------------------------------ firmware load
    $display("\n[TB] ===== Phase 2: load firmware over conf AXI-lite =====");
    check_eq("DSPM image header magic", data_words[0], DSPM_HDR_MAGIC);
    load_and_verify("ISPM .text", ISPM_BASE, text_words);
    load_and_verify("DSPM .data", DSPM_LOAD_BASE, data_words);

    // ------------------------------------------------------------------ counter configuration
    $display("\n[TB] ===== Phase 3: configure counters / timer =====");
    wr32(evsel_reg(0), evsel(4'h0, 4'h0, 4'h0, 4'h0, 4'h1, 4'hF));   // eid 1, any port/src
    wr32(evsel_reg(1), evsel(4'h3, 4'hF, 4'h0, 4'h0, 4'h2, 4'hF));   // eid 2, only PORT_ID 3
    wr32(evsel_reg(2), evsel(4'h0, 4'h0, 4'h0, 4'h0, 4'h3, 4'hF));   // eid 3 (firmware WFP)
    wr32(evsel_reg(3), evsel(4'h0, 4'h0, 4'h0, 4'h0, 4'h4, 4'hF));   // eid 4, event_info ADD
    wr32(evinfo_reg(3), EVINFO_ADD_7_0);
    wr32(evsel_reg(5), evsel(4'h0, 4'h0, 4'h0, 4'h0, 4'h6, 4'hF));   // eid 6, overflow irq
    wr32(evinfo_reg(5), EVINFO_OVF_INTR_EN);
    wr32(cnt_reg(5), 32'h3FFF_FFFF);
    wr32(evsel_reg(6), evsel(4'h0, 4'h0, 4'hA, 4'hF, 4'h5, 4'hF));   // eid 5, only source 0xA
    wr32(evinfo_reg(7), EVINFO_OVF_INTR_EN);                          // firmware overflows cnt 7
    rd_check("EVSEL[1] readback", evsel_reg(1), 32'h003F_002F);
    rd_check("EVINFO[3] readback", evinfo_reg(3), EVINFO_ADD_7_0);
    rd_check("COUNTER[5] preload readback", cnt_reg(5), 32'h3FFF_FFFF);
    wr32(APMU_PERIOD_LO, 32'hFFFF_FFFF);   // run the timer, MemGuard period effectively infinite
    wr32(APMU_PERIOD_LO + 4, 32'hFFFF_FFFF);
    rd32(APMU_TIMER_LO, v);  wait_cycles(50);  rd32(APMU_TIMER_LO, v2);
    check_true($sformatf("APMU timer advances (0x%08h -> 0x%08h)", v, v2), v2 > v + 32'd50);

    // ------------------------------------------------------------------ stall holds the core
    $display("\n[TB] ===== Phase 4: core held in stall, then released =====");
    wait_cycles(300);
    rd_check("DSPM mailbox untouched while STATUS.stall=1", MB_STATUS, 32'h0);
    wr32(APMU_BOOT_ADDR, ISPM_BASE);
    wr32(APMU_STATUS, 32'h0);
    rd_check("STATUS after release", APMU_STATUS, 32'h0);
    $display("[TB] %0t cycle %0d: APMU core released", $time, cycle);

    // ------------------------------------------------------------------ firmware results
    $display("\n[TB] ===== Phase 5: firmware execution results =====");
    wait_status(ST_WAIT_CMD);
    arith = exp_arith();
    sum   = 0;
    foreach (FW_DATA[i]) sum += FW_DATA[i];
    rd_check("FW signature in DSPM", MB_SIGNATURE, FW_SIGNATURE);
    rd_check("FW PC at _start (loaded at ISPM_BASE+4) = physical - FETCH_SKEW", MB_BOOT_PC, ISPM_BASE + 32'd4 - FETCH_SKEW);
    check_eq("phantom ISPM fetch grants (fetch skew origin), expected 1", n_phantom_gnt, 1);
    rd_check("FW RV32M arith kernel result", MB_ARITH, arith);
    rd_check("FW sum of .data table (DSPM load + .bss clear)", MB_DATA_SUM, sum);
    rd_check("FW read of system memory via master_req_o", MB_SYSMEM_RD, SYSMEM_RD_VALUE);
    rd_check("FW cnt_rd(4) after cnt_wr(4)", MB_CNT4_RD, FW_CNT4_VALUE);
    rd_check("FW read of EVSEL[1] via core data port (PMU_REG)", MB_EVSEL1_RD, 32'h003F_002F);
    rd32(MB_TIMER_T1, v); rd32(MB_TIMER_T2, v2);
    check_true($sformatf("FW timer reads via data port advance (0x%08h -> 0x%08h)", v, v2), v2 > v);

    check_eq("master_req_o write count", sys_wr_addr_q.size(), 2);
    if (sys_wr_addr_q.size() == 2) begin
      check_eq("master_req_o write[0] addr", sys_wr_addr_q[0], SYSMEM_WR_ADDR0);
      check_eq("master_req_o write[0] data", sys_wr_data_q[0], SYSMEM_WR_VALUE0);
      check_eq("master_req_o write[1] addr", sys_wr_addr_q[1], SYSMEM_WR_ADDR1);
      check_eq("master_req_o write[1] data", sys_wr_data_q[1], FW_SIGNATURE ^ arith);
    end
    check_eq("master_req_o read count", sys_rd_addr_q.size(), 1);
    if (sys_rd_addr_q.size() == 1) check_eq("master_req_o read[0] addr", sys_rd_addr_q[0], SYSMEM_RD_ADDR);
    check_eq("master port protocol errors", sys_protocol_errors, 0);

    rd_check("COUNTER[4] written by FW cnt_wr (conf read)", cnt_reg(4), FW_CNT4_VALUE);
    rd_check("COUNTER[7] written by FW cnt_wr (conf read)", cnt_reg(7), FW_CNT7_VALUE);
    rd_check("BUDGET[8] written by FW via data port", budget_reg(8), FW_BUDGET8);
    wait_cycles(2);
    check_eq("intr_o after FW overflowed counter 7", intr, 32'h0000_0080);

    // ------------------------------------------------------------------ event counting
    $display("\n[TB] ===== Phase 6: port_i events -> counters =====");
    begin
      pmu_event_t [NUM_PORT-1:0] all9;
      for (int i = 0; i < NUM_PORT; i++) all9[i] = mk_ev(4'h1);
      pulse(all9);                                    // 9 simultaneous events
    end
    pulse_one(0, mk_ev(4'h1));
    pulse_one(4, mk_ev(4'h1));
    pulse_one(8, mk_ev(4'h1));                        // counter 0: 9 + 3 = 12
    pulse_one(0, mk_ev(4'h2));                        // PORT_ID 1: filtered
    pulse_one(2, mk_ev(4'h2));                        // PORT_ID 3: counts
    pulse_one(8, mk_ev(4'h2));                        // PORT_ID 9: filtered
    pulse_one(2, mk_ev(4'h2));                        // counter 1: 2
    pulse_one(1, mk_ev(4'h4, 17'd10));
    pulse_one(5, mk_ev(4'h4, 17'd20));
    pulse_one(7, mk_ev(4'h4, 17'h1FF05));             // counter 3: 10 + 20 + 0x05 = 35
    pulse_one(3, mk_ev(4'h5, '0, 4'hA));
    pulse_one(6, mk_ev(4'h5, '0, 4'hB));              // filtered by source
    pulse_one(6, mk_ev(4'h5, '0, 4'h2));              // filtered by source
    pulse_one(1, mk_ev(4'h5, '0, 4'hA));              // counter 6: 2
    pulse_one(4, mk_ev(4'h6));                        // counter 5: 0x3FFFFFFF + 1 -> overflow
    pulse_one(4, mk_ev(4'h0));                        // e_id 0 never counts
    pulse_one(4, mk_ev(4'h7));                        // unselected event id

    foreach (exp_cnt[i]) exp_cnt[i] = 32'h0;
    exp_cnt[0] = 32'h8000_000C;   // pending bit (31) set by event increments
    exp_cnt[1] = 32'h8000_0002;
    exp_cnt[3] = 32'h8000_0023;
    exp_cnt[4] = FW_CNT4_VALUE;   // firmware writes do not set pending
    exp_cnt[5] = 32'hC000_0000;   // pending + overflow (bit 30)
    exp_cnt[6] = 32'h8000_0002;
    exp_cnt[7] = FW_CNT7_VALUE;
    for (int i = 0; i < NUM_COUNTER; i++)
      rd_check($sformatf("COUNTER[%0d] over conf AXI-lite", i), cnt_reg(i), exp_cnt[i]);
    check_eq("intr_o (counter 5 event overflow, counter 7 FW overflow)", intr, 32'h0000_00A0);

    // ------------------------------------------------------------------ WFP handshake
    $display("\n[TB] ===== Phase 7: firmware WFP woken by port_i events =====");
    wr32(MB_CMD, CMD_GO);
    wait_status(ST_WAIT_EVENTS);
    wait_cycles(300);
    rd_check("FW still blocked in WFP (no counter-2 events yet)", MB_STATUS, ST_WAIT_EVENTS);
    begin
      automatic pmu_event_t [NUM_PORT-1:0] ev = '0;
      ev[0] = mk_ev(4'h3); ev[3] = mk_ev(4'h3); ev[6] = mk_ev(4'h3); ev[8] = mk_ev(4'h3);
      pulse(ev);                                      // counter 2: +4 atomically, pending set
    end
    wait_status(ST_DONE);
    rd_check("FW WFP returned pending mask", MB_WFP_MASK, 32'h0000_0004);
    rd_check("FW cnt_rd(2) after WFP", MB_CNT2_RD, 32'h0000_0004);
    rd_check("COUNTER[2] value with pending cleared by WFP", cnt_reg(2), 32'h0000_0004);

    // ------------------------------------------------------------------ MemGuard reload
    $display("\n[TB] ===== Phase 8: MemGuard period reload of initial budgets =====");
    wr32(APMU_PERIOD_HI, 32'h0);
    wr32(APMU_PERIOD_LO, 32'd200);
    wait_cycles(450);
    rd_check("COUNTER[8] reloaded from FW-written BUDGET[8] (+pending)", cnt_reg(8), 32'h8000_0000 | FW_BUDGET8);
    rd_check("COUNTER[0] reloaded from BUDGET[0]=0 (+pending)", cnt_reg(0), 32'h8000_0000);
    rd32(APMU_TIMER_LO, v);
    check_true($sformatf("timer wraps within period (timer=%0d < 200)", v), v < 32'd200);
    check_eq("intr_o after reload cleared overflow bits", intr, 32'h0);
    rd_check("FW final status", MB_STATUS, ST_DONE);

    // ------------------------------------------------------------------ re-stall and re-boot
    $display("\n[TB] ===== Phase 9: re-stall, clear mailbox, re-boot the APMU core =====");
    wr32(APMU_PERIOD_LO, 32'd0);           // MemGuard off again
    wr32(APMU_STATUS, 32'h1);
    wait_cycles(20);
    wr32(MB_STATUS, 32'h0);
    wr32(MB_SIGNATURE, 32'h0);
    wr32(MB_ARITH, 32'h0);
    wr32(MB_BOOT_PC, 32'h0);
    wr32(MB_CMD, 32'h0);
    wait_cycles(50);
    rd_check("mailbox stays clear while re-stalled", MB_STATUS, 32'h0);
    wr32(APMU_STATUS, 32'h0);
    wait_status(ST_WAIT_CMD);
    rd_check("re-boot: FW signature", MB_SIGNATURE, FW_SIGNATURE);
    rd_check("re-boot: FW RV32M arith kernel result", MB_ARITH, arith);
    rd_check("re-boot: FW PC at _start (skew unchanged)", MB_BOOT_PC, ISPM_BASE + 32'd4 - FETCH_SKEW);
    check_eq("re-boot: phantom ISPM fetch grants still 1", n_phantom_gnt, 1);
    wr32(MB_CMD, CMD_GO);
    wait_status(ST_WAIT_EVENTS);

    // ------------------------------------------------------------------ verdict
    $display("\n[TB] APMU Ibex activity: %0d instruction fetches, %0d data-port requests, %0d counter ops",
             n_fetch, n_data_req, n_cnt_ops);
    $display("[TB] %0d checks, %0d errors, %0d cycles", n_checks, n_errors, cycle);
    if (n_errors == 0) begin
      $display("[TB] RESULT: PASS -- tb_apmu (APMU standalone bundle functional test)");
      $finish;
    end else begin
      $display("[TB] RESULT: FAIL -- tb_apmu (%0d errors)", n_errors);
      $fatal(1, "tb_apmu FAILED");
    end
  end

endmodule
