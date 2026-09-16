# APMU standalone bundle

The APMU (`pmu_top`) and every RTL file it depends on, copied out of he-soc so it can be simulated,
linted and implemented without the he-soc tree. The default top, `apmu_hesoc_top`, is `pmu_top` in
exactly the configuration he-soc instantiates.

## Contents

| Path | What it is |
|---|---|
| `rtl/apmu/src/` | APMU RTL: `pmu_pkg`, `pmu_top`, `pmu_core`, `pmu_port(_wrap)`, `pmu_counter`, `pmu_ispm`, `pmu_dspm` |
| `rtl/ibex_pmu/` | The APMU's Ibex (`ibex_pmu_core`, `apmu_ibex_*`), plus its vendored `prim_assert` headers |
| `rtl/axi/` | pulp `axi`: `axi_pkg`, `axi_lite_{xbar,demux,mux,regs,from_mem,to_axi}`, `axi_err_slv`, `axi_atop_filter`, `include/axi/*.svh` |
| `rtl/common_cells/` | pulp `common_cells` modules used by the above, `include/common_cells/*.svh` |
| `rtl/tech_cells_generic/` | `src/rtl/{tc_sram,tc_clk}.sv` (simulation), `src/fpga/{tc_sram_xilinx,tc_clk_xilinx}.sv` (FPGA) |
| `rtl/hesoc_cfg/apmu_hesoc_top.sv` | **Written for this bundle, not copied.** Fixes `pmu_top` to the he-soc configuration. |
| `apmu_sim.f`, `apmu_fpga.f` | Ordered file lists with `+incdir+` lines; paths relative to this directory |
| `.provenance.json` | `[he-soc/hardware path, bundle path]` for every copied file |
| `scripts/` | Elaboration, lint, Vivado implementation and frequency-sweep scripts |
| `tb/` | Self-checking functional testbench (`tb_apmu.sv`), RV32 test firmware (`fw/`), run scripts |
| `build/` | Tool output only; safe to delete |

Every directory keeps the path it had under `he-soc/hardware/ip_list/`, so includes resolve the same way.

## Provenance

- Copied from he-soc branch `es/opendram-16x-timing`, commit `682d6682`. All 69 copied files are
  byte-identical to that commit (no uncommitted edits).
- `ip_list/` is vendored into the he-soc repo, and the APMU carries he-soc-local changes (last:
  `e602d924`, "APMU grant fix"). Upstream pins do not describe these sources: `hardware/Bender.yml`
  pins apmu `1fa3c20` while `Bender.lock` still records `f8d57d3`. Do not re-resolve dependencies from
  `ip_list/apmu/Bender.yml` either; it pins older axi/common_cells than he-soc builds.
- Resolved versions of the other IPs (`hardware/Bender.lock`): axi `39f5f2d` (0.39.6), common_cells
  `c27bce3` (1.37.0), tech_cells_generic `7968dd6` (0.2.13), ibex_pmu `a6dfcb42`.
- **Ibex:** only the `ip_list/ibex_pmu` copy is used. he-soc also contains an unrelated Ibex under
  `ip_list/opentitan/hw/ip/lowrisc_ibex`; it is not part of this bundle.
- **Licenses:** axi, common_cells, tech_cells_generic are Solderpad 0.51 and ibex_pmu is Apache-2.0
  (`LICENSE` in each directory). The APMU sources have no license file or headers in he-soc.

## he-soc configuration

From `he-soc/hardware/host/host_domain.sv` (`i_pmu_top`, quad-core, `APMU_IP` defined):

| Parameter | he-soc value | `pmu_top` default |
|---|---|---|
| `NUM_PORT` | 9 (`NumCVA6*2+1`) | 5 |
| `NUM_COUNTER` | 32 | 32 |
| `APMU_BASE_ADDR` / `ISPM_BASE_ADDR` / `DSPM_BASE_ADDR` | 0x1040_5000 / 0x1042_7000 / 0x1042_8000 (not overridden) | same |
| `ISPM_NUM_WORDS` / `DSPM_NUM_WORDS` | 1024 / 32768 | 1024 / 8192 |
| `MEMORY_BASE_ADDR` / `MEMORY_LENGTH` | 0x1060_6000 / 0x100 | 0x8000_0000 / 0x400_0000 |
| AXI-lite types | `ariane_axi_soc::*_lite_t` | `pmu_pkg::*_lite_t` |

The two AXI-lite type sets are field-for-field identical (32-bit addr/data, 4-bit strb, same order;
`req_lite_t` 111 bits, `resp_lite_t` 41 bits), so `apmu_hesoc_top` uses `pmu_pkg`'s.

`port_i` is `pmu_pkg::pmu_event_t [NUM_PORT-1:0]`, 25 bits per port: `{e_id[24:21], e_info[20:4], s_id[3:0]}`.
There is no valid bit (`e_id == 0` means no event) and ports are sampled every clock edge. In he-soc,
ports 0-3 come from the CVA6 perf-counter EVUs, 4-7 from the per-core SPUs, and 8 from the LLC/memory SPU.

## Variants

| | `apmu_sim.f` | `apmu_fpga.f` |
|---|---|---|
| Memory / clock-gate cells | behavioural `tc_sram`, `tc_clk` | `tc_sram_xilinx` (uses `xpm_memory_spram`), `tc_clk_xilinx` |
| Extra library | none | Xilinx XPM: automatic in Vivado; `-L xpm` in xsim; a black-box stub for Verilator lint (`scripts/stubs/`) |

Both lists also compile `ibex_register_file_fpga.sv` and `ibex_register_file_latch.sv`; they are unused
(`ibex_pmu_core` always selects the FF register file). Always name the top explicitly: the axi sources
also define `*_intf` wrappers whose interfaces are not bundled.

## How to run

All commands run from this directory.

| What | Command | Result at bundle creation |
|---|---|---|
| Questa elaboration | `scripts/elab_questa.sh` | 0 errors |
| Questa functional test | `tb/run_questa.sh` | PASS, 83 checks |
| Same test on the he-soc originals | `SRC=orig tb/run_questa.sh` | PASS, 83 checks |
| xsim functional test | `tb/run_xsim.sh` | PASS, 83 checks, log lines identical to Questa |
| xsim elaboration | `scripts/elab_xsim.sh` | 0 errors |
| Verilator lint | `scripts/lint_verilator.sh` (`FLIST=apmu_fpga.f` for the FPGA list) | 0 errors, warnings only |
| Vivado implementation (OOC, 50 ns) | `vivado -mode batch -nojournal -source scripts/impl_vivado.tcl` | Timing met, 0 routing errors |
| Frequency sweep | `scripts/freq_sweep.sh <period_ns> ...` (needs `build/vivado_impl/post_synth.dcp`) | see below |

Tools used: Questa 2022.4, Vivado 2021.2, Verilator 4.110, and `riscv64-unknown-elf-gcc` for the
RV32 test firmware (`-march=rv32imc -mabi=ilp32`). `vlog`/`vopt`/`vivado`/`verilator` are taken from
`PATH`; the testbench scripts use these defaults, which can be overridden:

| Variable | Default |
|---|---|
| `QUESTA_BIN` | `/tools/questasim/bin` |
| `XILINX_BIN` | `/tools/Xilinx/Vivado/2021.2/bin` |
| `RISCV_PREFIX` | `/opt/riscv/bin/riscv64-unknown-elf-` |
| `HESOC_HW` (only for `SRC=orig`) | `../he-soc/hardware` next to this directory |

Testbench options: `RVFI=1` (see differences below), `WAVES=1`, `SIM_ARGS="+APMU_TRACE"`. If a Questa
run of the same variant exists, `tb/run_xsim.sh` also diffs its log against it.

### What the testbench checks

`tb_apmu` loads firmware into the ISPM/DSPM over `conf_req_i`, releases the core, and checks:
reset values and error responses; SPM load and readback; stall/boot; that the firmware runs (signature,
RV32M arithmetic, `.data` checksum); AXI-lite transactions on `master_req_o`; the core reading and writing
APMU registers; the custom counter instructions (read, write, wait-for-pending); event counting with
event-ID/source/port filtering; overflow interrupts on `intr_o`; MemGuard budget reload; and re-stall/re-boot.
Only the ADD event-info opcode and the wait-for-pending instruction are exercised.

## Vivado results (xcvu9p-flga2104-2L-e, out-of-context)

Flow mirrors he-soc's `run.tcl`: he-soc FPGA defines, `apmu_fpga.f`, synth → opt → place → route,
`phys_opt_design` only if setup fails after routing, default directives.

At 50 ns (he-soc's 20 MHz): setup WNS +32.621 ns, hold WHS +0.021 ns, 0 routing errors, 0 DRC errors.

| Resource | Used |
|---|---|
| LUTs | 35,106 (`axi_lite_regs` ~14.4k, Ibex ~7.8k, `axi_lite_xbar` ~6.9k) |
| Flip-flops | 9,173 |
| Latches | 0 |
| RAMB36 | 128 (DSPM) |
| URAM | 1 (ISPM) |
| DSP | 1 |

Frequency sweep (each point re-implements the same synthesized netlist at a tighter clock):

| Target | Period (ns) | Setup WNS (ns) | Failing setup paths | Hold | `phys_opt` ran | Result |
|---|---|---|---|---|---|---|
| 50.0 MHz | 20 | +5.769 | 0 | met | no | met |
| 66.7 MHz | 15 | +1.822 | 0 | met | no | met |
| 80.0 MHz | 12.5 | +1.299 | 0 | met | no | met |
| 100.0 MHz | 10 | +0.153 | 0 | met | no | met |
| 120.0 MHz | 8.333 | +0.103 | 0 | met | no | met |
| 125.0 MHz | 8.0 | +0.062 | 0 | met | no | met |
| 128.0 MHz | 7.8125 | +0.004 | 0 | met | no | met (edge) |
| 130.0 MHz | 7.692 | -0.118 | 105 | met | yes | failed |
| 133.3 MHz | 7.5 | -0.470 | 2,748 | met | yes | failed |
| 136.4 MHz | 7.333 | -0.923 | 9,658 | met | yes | failed |
| 140.0 MHz | 7.143 | -0.617 | 6,717 | met | yes | failed |

Highest frequency that closed: **128 MHz**, with only +0.004 ns of slack; **125 MHz** (+0.062 ns) is the
first point with margin. 130 MHz and above fail even after `phys_opt_design`. Between 100 and 128 MHz the
critical path is inside the Ibex (fetched instruction to load/store address and DSPM BRAM enable); at
140 MHz it moves to register writes in `axi_lite_regs`.

Out-of-context timing only covers paths between the APMU's own registers, not paths through its ports
into the rest of the SoC. Results within ~0.1 ns of zero slack can move between placement runs.

## RTL behaviour worth knowing

These are properties of the he-soc APMU sources, reproduced identically on the originals.

- **Instruction fetch skew.** `pmu_ispm` grants one extra instruction request right after reset that it
  never serves. From then on the PC the software sees is the physical address minus 4, and the first word
  after a load is discarded. Firmware works if `.text` is linked at `ISPM_BASE - 4` with a dummy first word
  and loaded at `ISPM_BASE` (see `tb/fw/link.ld`, `tb/fw/crt0.S`). he-soc's PMU firmware linker scripts
  use a mix of ISPM origins (`0x10425FFC` and `0x10427000`); ones linked at `0x10427000` get PC-relative
  addresses 4 bytes low. `tb_apmu` checks for the skew, so an RTL fix will show up as a test failure.
- **Scratchpads are 4× their nominal size.** `pmu_ispm`/`pmu_dspm` pass a byte count to `tc_sram` as the
  number of 32-bit words. With he-soc parameters that is 4096 and 131,072 words, which is why the DSPM
  takes 128 BRAMs. Only word-aligned 32-bit access is consistent.
- **Undriven inputs.** `external_perf_i` and `debug_req_i` inside `pmu_core` are not driven (Synth 8-3848).
- **Parameter limits** (not checked at elaboration): `APMU_BASE_ADDR[19:0]` must be `0x05000`;
  `NUM_COUNTER` at most 32 with the default bases; `NUM_PORT` at most 15. The he-soc configuration is
  within all of them.

## Programming model (he-soc configuration)

Address map of the internal crossbar (anything else returns DECERR):

| Target | Range |
|---|---|
| APMU registers | 0x1040_5000 – 0x1042_7000 |
| ISPM | 0x1042_7000 – 0x1042_8000 |
| DSPM | 0x1042_8000 – 0x1044_8000 |
| System memory via `master_req_o` | 0x1060_6000 – 0x1060_6100 |

| Address | Register |
|---|---|
| 0x1040_5000 | TIMER (64-bit, read-only). Counts while PERIOD != 0; each wrap reloads every counter from its budget |
| 0x1040_5008 | PERIOD (64-bit) |
| 0x1040_6000 | STATUS, bit 0 = stall the APMU core (reset 1) |
| 0x1040_6004 | BOOT_ADDR (reset `ISPM_BASE_ADDR`) |
| 0x1040_7000 + i·0x1000 | COUNTER[i]: bit 31 pending, bit 30 overflow |
| +0x4 | EVENT_SEL[i]: `{pad8, port_val4, port_mask4, src_val4, src_mask4, eid_val4, eid_mask4}`; `eid_val = 0` disables |
| +0x8 | EVENT_INFO[i]: `{pad7, ovf_intr_en, event_info_en, val_u4, val_l4, opcode5, eisf_end5, eisf_start5}` |
| +0xC | INIT_BUDGET[i] |

Host bring-up (as in `he-soc/software/march18_pmu_test_sim` and `tb_apmu`): write STATUS=1, set PERIOD,
copy `.text` to the ISPM and data to DSPM+0x200, write BOOT_ADDR, write STATUS=0. Every release of the
stall restarts the core at BOOT_ADDR.

The APMU core is RV32IMC. Custom instructions use major opcode `0x07`: funct3=000 reads a counter,
001 writes one, 010 with funct7=0 waits for pending events (returns the mask), 010 with funct7=1 waits
for overflow. `tb/fw/apmu_fw.h` has the register and instruction macros.

## Differences from the he-soc builds

- **RVFI (simulation only).** he-soc's `hardware/compile.tcl` compiles `ibex_core.sv` a second time with
  `+define+RVFI=true`, which adds unconnected `rvfi_*` outputs. The bundle matches the FPGA build (no RVFI).
  `RVFI=1 tb/run_questa.sh` reproduces the SoC-sim build and passes.
- **`prim_assert.sv`.** he-soc's simulation picks up OpenTitan's copy because of include-path order; the FPGA
  build and the bundle use the vendored `ibex_pmu` copy. The macros the Ibex files use expand identically.

## Intentionally excluded

| Item | Why |
|---|---|
| `ibex_icache`, `ibex_branch_predict`, `ibex_dummy_instr`, `prim_secded_*` | Only reachable with ICache / BranchPredictor / SecureIbex, which `pmu_core.sv` hardcodes to 0 |
| `formal_tb_frag.svh` | Only under `FORMAL` + `YOSYS` |
| `xpm_memory_spram`, `xpm_memory_tdpram`, `BUFGMUX` | Xilinx library cells, supplied by Vivado |
| `ibex_tracer*`, `ibex_core_tracing.sv`, `pmu_gnt_to_axi_lite.sv` | Compiled by he-soc but never instantiated under `pmu_top` |

## Tool notes

Each of these reproduces on the unmodified he-soc sources.

- **Vivado 2021.2 xsim** rejects `default disable iff` (XSIM 43-3980). The run scripts compile the five
  affected `rtl/axi/src` files with `-d VERILATOR`, which only removes assertion code there.
- **Verilator 4.110** needs `ulimit -s unlimited` for the 32768-word DSPM, and `-Wno-BLKANDNBLK` for the
  `latency` shift register in `pmu_ispm`/`pmu_dspm`. Only linting has been done.
- **Questa `-G`** cannot override type parameters; use `apmu_hesoc_top` or your own wrapper.
