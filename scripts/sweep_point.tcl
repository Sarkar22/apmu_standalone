# One frequency-sweep point: re-implement the synthesized apmu_hesoc_top at a given clock period.
# Synthesis is untimed in impl_vivado.tcl (clock applied after synth_design), so every point reuses
# build/vivado_impl/post_synth.dcp. Place/route flow matches he-soc's run.tcl (default directives,
# post-route phys_opt only if setup is violated).
# Usage: vivado -mode batch -nojournal -source scripts/sweep_point.tcl -tclargs <period_ns> <out_dir>
set PERIOD [lindex $argv 0]
set OUT    [lindex $argv 1]
file mkdir $OUT
set_param general.maxThreads 4
set t0 [clock seconds]
open_checkpoint build/vivado_impl/post_synth.dcp
create_clock -name soc_clk -period $PERIOD [get_ports clk_i]
opt_design
place_design
route_design
set physopt 0
if {[get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]] < 0} { phys_opt_design; set physopt 1 }
report_timing_summary -max_paths 10 -file $OUT/timing_summary.rpt
report_route_status   -file $OUT/route_status.rpt
check_timing          -file $OUT/check_timing.rpt
write_checkpoint -force $OUT/post_route.dcp
set sp [get_timing_paths -max_paths 1 -nworst 1 -setup]
set hp [get_timing_paths -max_paths 1 -nworst 1 -hold]
set wns [get_property SLACK $sp]; set whs [get_property SLACK $hp]
set nfail_s [llength [get_timing_paths -max_paths 100000 -slack_lesser_than 0 -setup -quiet]]
set nfail_h [llength [get_timing_paths -max_paths 100000 -slack_lesser_than 0 -hold -quiet]]
set rerr [llength [get_nets -hier -quiet -filter {ROUTE_STATUS == CONFLICTS || ROUTE_STATUS == UNROUTED || ROUTE_STATUS == PARTIAL}]]
set fh [open $OUT/result.txt w]
puts $fh [format "period_ns=%s target_MHz=%.2f WNS=%.3f WHS=%.3f fail_setup=%d fail_hold=%d route_problem_nets=%d phys_opt=%d achieved_fmax_MHz=%.2f runtime_s=%d crit_src=%s crit_dst=%s" \
  $PERIOD [expr {1000.0/$PERIOD}] $wns $whs $nfail_s $nfail_h $rerr $physopt [expr {1000.0/($PERIOD-$wns)}] [expr {[clock seconds]-$t0}] \
  [get_property STARTPOINT_PIN $sp] [get_property ENDPOINT_PIN $sp]]
close $fh
puts "SWEEP_POINT_DONE $PERIOD"
