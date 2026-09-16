# Out-of-context Vivado implementation of apmu_hesoc_top (pmu_top in the he-soc configuration).
# Mirrors he-soc's FPGA flow: VCU118 part, he-soc FPGA defines, FPGA tech-cells variant (apmu_fpga.f),
# 20 MHz SoC clock, synth -> opt -> place -> route, phys_opt only if setup is violated.
# Usage (from apmu_standalone/):  vivado -mode batch -nojournal -log build/vivado_impl/vivado.log -source scripts/impl_vivado.tcl
set TOP          apmu_hesoc_top
set PART         xcvu9p-flga2104-2L-e
set CLK_PERIOD   50.0
set OUT          build/vivado_impl
file mkdir $OUT
set_param general.maxThreads 8

# he-soc/hardware/fpga/alsaqr/tcl/generated/compile.tcl verilog_define list
set DEFINES {AIA_EMBEDDED COMMON_CELLS_ASSERTS_OFF EXCLUDE_CLUSTER FPGA_EMUL FPGA_TARGET_XILINX MSI_MODE
             PULP_FPGA_EMUL QUAD_CORE SIMPLE_PADFRAME TARGET_AIA_EMBEDDED TARGET_AIA_MSI
             TARGET_CV64A6_IMAFDC_SV39_WB TARGET_CVA6 TARGET_DDR TARGET_FPGA TARGET_RTL
             TARGET_SCM_USE_LATCH_SCM TARGET_SYNTHESIS TARGET_TECH_CELLS_GENERIC_INCLUDE_XILINX_XPM
             TARGET_USE_IDMA TARGET_VIVADO TARGET_XILINX USE_IDMA WT_DCACHE XILINX_DDR}

set incdirs {}; set files {}
set fh [open apmu_fpga.f r]
foreach line [split [read $fh] "\n"] {
  set l [string trim $line]
  if {$l eq "" || [string match "//*" $l]} continue
  if {[string match "+incdir+*" $l]} { lappend incdirs [string range $l 8 end] } else { lappend files $l }
}
close $fh
puts "INFO: [llength $files] source files, include dirs: $incdirs"

read_verilog -sv $files
set t0 [clock seconds]
synth_design -top $TOP -part $PART -mode out_of_context -include_dirs $incdirs -verilog_define $DEFINES
create_clock -name soc_clk -period $CLK_PERIOD [get_ports clk_i]
write_checkpoint -force $OUT/post_synth.dcp
report_utilization -file $OUT/post_synth_util.rpt
report_utilization -hierarchical -file $OUT/post_synth_util_hier.rpt
report_timing_summary -file $OUT/post_synth_timing_summary.rpt

opt_design
place_design
write_checkpoint -force $OUT/post_place.dcp
report_utilization -file $OUT/post_place_util.rpt
report_timing_summary -file $OUT/post_place_timing_summary.rpt

route_design
report_timing_summary -file $OUT/post_route_preopt_timing_summary.rpt
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} {
  puts "INFO: setup violated after route => running phys_opt_design"
  phys_opt_design
}
write_checkpoint -force $OUT/post_route.dcp
report_route_status              -file $OUT/post_route_status.rpt
report_timing_summary -max_paths 10 -file $OUT/post_route_timing_summary.rpt
report_utilization               -file $OUT/post_route_util.rpt
report_utilization -hierarchical -file $OUT/post_route_util_hier.rpt
report_drc                       -file $OUT/post_route_drc.rpt
report_power                     -file $OUT/post_route_power.rpt
report_clock_utilization         -file $OUT/post_route_clock_util.rpt

set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
# Counts come from report_utilization so they match post_route_util.rpt exactly.
proc util_used {rpt row} {
  foreach line [split $rpt "\n"] {
    if {[regexp "^\\|\\s*${row}\\s*\\|\\s*(\[0-9.\]+)" $line -> v]} { return $v }
  }
  return NA
}
set u [report_utilization -return_string]
set fh [open $OUT/SUMMARY.txt w]
puts $fh "top=$TOP part=$PART clk_period_ns=$CLK_PERIOD"
puts $fh "setup_WNS_ns=$wns hold_WHS_ns=$whs"
puts $fh "worst_path_fmax_MHz=[format %.1f [expr {1000.0/($CLK_PERIOD - $wns)}]] (reg-to-reg at this constraint; see freq_sweep for achievable fmax)"
puts $fh "LUT=[util_used $u {CLB LUTs}] FF=[util_used $u {Register as Flip Flop}] latches=[util_used $u {Register as Latch}]"
puts $fh "RAMB36=[util_used $u {RAMB36/FIFO\\*}] RAMB18=[util_used $u RAMB18] URAM=[util_used $u URAM] DSP=[util_used $u DSPs]"
puts $fh "runtime_s=[expr {[clock seconds]-$t0}]"
close $fh
puts "APMU_IMPL_DONE"
