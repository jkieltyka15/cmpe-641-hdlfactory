# unified_synopsys_flow.tcl
# One-file DC + ICC2 lab flow, adapted from the uploaded practice/lab scripts.
#
# Recommended run method for the UMBC launch scripts: pass configuration as
# environment variables. This avoids problems where launch_synopsys_* splits
# Synopsys -x strings into separate positional arguments.
#
# DC example:
#   env FLOW=dc RTL_FILE=verilog/adder32_draft.v TOP=adder32 CLK_PORT=clk CLK_PER=1.0 \
#   /umbc/software/scripts/launch_synopsys_dc.sh \
#     -f unified_synopsys_flow.tcl -o dc_out.log
#
# ICC2 example, after DC finishes:
#   env FLOW=icc2 RTL_FILE=verilog/adder32_draft.v TOP=adder32 CLK_PORT=clk CLK_PER=1.0 \
#   /umbc/software/scripts/launch_synopsys_icc2_shell.sh \
#     -f unified_synopsys_flow.tcl -o icc2_out.log
#
# Optional argv style, if your launcher really preserves arguments after "--":
#   ... -f unified_synopsys_flow.tcl -o dc_out.log -- -flow dc -rtl verilog/top.v -top top -clk clk -period 1.0

################################################################################
# Argument parsing / defaults
################################################################################
# Some Synopsys shells/launchers do not define argv when -f is used.
if {![info exists argv]} { set argv {} }

proc arg_value {flag default} {
    global argv
    set idx [lsearch -exact $argv $flag]
    if {$idx >= 0 && [expr {$idx + 1}] < [llength $argv]} {
        return [lindex $argv [expr {$idx + 1}]]
    }
    return $default
}

proc env_or_arg {varname flag default} {
    global env
    if {[uplevel #0 [list info exists $varname]]} {
        return [uplevel #0 [list set $varname]]
    }
    if {[info exists env($varname)]} {
        return $env($varname)
    }
    return [arg_value $flag $default]
}

proc arg_present {flag} {
    global argv
    return [expr {[lsearch -exact $argv $flag] >= 0}]
}

set IP [pwd]

set FLOW     [env_or_arg FLOW     -flow   "auto"]
set RTL_FILE [env_or_arg RTL_FILE -rtl    ""]
set TOP      [env_or_arg TOP      -top    ""]
set CLK_PORT [env_or_arg CLK_PORT -clk    "clk"]
set CLK_PER  [env_or_arg CLK_PER  -period "1.0"]

# Positional fallback: first non-flag argument can be the RTL file.
if {$RTL_FILE eq ""} {
    foreach a $argv {
        if {![string match -* $a]} {
            set RTL_FILE $a
            break
        }
    }
}

if {$RTL_FILE eq ""} {
    puts "ERROR: Give the RTL file with -rtl ./path/to/file.v, or set RTL_FILE before sourcing."
    exit 1
}

if {$TOP eq ""} {
    set TOP [file rootname [file tail $RTL_FILE]]
}

set DESIGN $TOP
set top_mod $TOP
set RTL_SOURCE_FILES [list $RTL_FILE]

if {$FLOW eq "auto"} {
    if {[llength [info commands compile_ultra]] > 0} { set FLOW "dc" }
    if {[llength [info commands create_lib]] > 0}     { set FLOW "icc2" }
}

file mkdir ${IP}/asic
file mkdir ${IP}/asic/reports
file mkdir ${IP}/asic/work
file mkdir ${IP}/gate

puts "============================================================"
puts "Unified Synopsys flow"
puts "FLOW       = $FLOW"
puts "RTL_FILE   = $RTL_FILE"
puts "TOP/DESIGN = $DESIGN"
puts "CLK_PORT   = $CLK_PORT"
puts "CLK_PER    = $CLK_PER ns"
puts "RUN DIR    = $IP"
puts "============================================================"

################################################################################
# Technology/library setup embedded from common_setup.tcl
################################################################################
set DESIGN_REF_PATH              "/umbc/software/design_kits/SAED14nm"
set DESIGN_REF_TECH_PATH         "${DESIGN_REF_PATH}/tech"

set ADDITIONAL_SEARCH_PATH      " \
        ${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs \
        ${DESIGN_REF_PATH}/lib/stdcell_hvt/db_ccs \
        ${DESIGN_REF_PATH}/lib/stdcell_lvt/db_ccs \
        ${DESIGN_REF_PATH}/lib/sram_lp/logic_synth/singlelp \
        ${DESIGN_REF_PATH}/lib/io_std/db_ccs "

set LINK_LIBRARY_FILES   "* \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_dlvl_ss0p72v125c_i0p72v.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_dlvl_ss0p6v125c_i0p6v.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_pg_ss0p72v125c.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_ss0p72v125c.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_ulvl_ss0p72v125c_i0p72v.db \
${DESIGN_REF_PATH}/lib/sram/logic_synth/single/saed14sram_ss0p72v125c.db "

set TARGET_LIBRARY_FILES   " \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_dlvl_ss0p72v125c_i0p72v.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_dlvl_ss0p6v125c_i0p6v.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_pg_ss0p72v125c.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_ss0p72v125c.db \
${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_ulvl_ss0p72v125c_i0p72v.db \
${DESIGN_REF_PATH}/lib/sram/logic_synth/single/saed14sram_ss0p72v125c.db "

set NDM_REFERENCE_LIB_DIRS  " \
        ${DESIGN_REF_PATH}/lib/stdcell_rvt/ndm/saed14rvt_frame_timing_ccs.ndm \
        ${DESIGN_REF_PATH}/lib/sram/ndm/saed14_sram_1rw_frame_only.ndm "

set TECH_FILE                     "${DESIGN_REF_PATH}/tech/milkyway/saed14nm_1p9m_mw.tf"
set MAP_FILE                      "${DESIGN_REF_PATH}/tech/star_rc/saed14nm_tf_itf_tluplus.map"
set TLUPLUS_MAX_FILE              "${DESIGN_REF_PATH}/tech/star_rc/max/saed14nm_1p9m_Cmax.tluplus"
set TLUPLUS_MIN_FILE              "${DESIGN_REF_PATH}/tech/star_rc/min/saed14nm_1p9m_Cmin.tluplus"
set GDS_MAP_FILE                  "${DESIGN_REF_PATH}/tech/milkyway/saed14nm_1p9m_gdsout_mw.map"
set STD_CELL_GDS                  "${DESIGN_REF_PATH}/lib/stdcell_rvt/gds/saed14rvt.gds"
set SRAMLP_SINGLELP_GDS           "${DESIGN_REF_PATH}/lib/sram_lp/gds/singlelp.gds"

set NDM_POWER_NET                 "VDD"
set NDM_POWER_PORT                "VDD"
set NDM_GROUND_NET                "VSS"
set NDM_GROUND_PORT               "VSS"
set MIN_ROUTING_LAYER             "M2"
set MAX_ROUTING_LAYER             "M8"

################################################################################
# Metric helpers
################################################################################
proc slurp {fname} {
    if {![file exists $fname]} { return "" }
    set f [open $fname r]
    set data [read $f]
    close $f
    return $data
}

proc first_regex {text regex default} {
    if {[regexp -nocase -line -- $regex $text -> val unit]} {
        if {$unit ne ""} { return "$val $unit" }
        return $val
    }
    if {[regexp -nocase -line -- $regex $text -> val]} { return $val }
    return $default
}

proc to_uW {val unit} {
    set u [string tolower $unit]
    if {$u eq "pw"} { return [expr {$val / 1000000.0}] }
    if {$u eq "nw"} { return [expr {$val / 1000.0}] }
    if {$u eq "uw"} { return [expr {$val}] }
    if {$u eq "mw"} { return [expr {$val * 1000.0}] }
    if {$u eq "w"}  { return [expr {$val * 1000000.0}] }
    return $val
}

proc parse_power_summary {power_file} {
    set txt [slurp $power_file]
    set dyn "N/A"
    set leak "N/A"
    set total "N/A"

    if {[regexp -nocase {Total Dynamic Power\s*=\s*([0-9.eE+-]+)\s*([a-zA-Z]+)} $txt -> dv du]} {
        set dyn "$dv $du"
        set dyn_uW [to_uW $dv $du]
    }
    if {[regexp -nocase {Cell Leakage Power\s*=\s*([0-9.eE+-]+)\s*([a-zA-Z]+)} $txt -> lv lu]} {
        set leak "$lv $lu"
        set leak_uW [to_uW $lv $lu]
    }
    if {[info exists dyn_uW] && [info exists leak_uW]} {
        set total [format "%.6g uW" [expr {$dyn_uW + $leak_uW}]]
    }
    return [list $dyn $leak $total]
}

proc parse_dc_area {area_file} {
    set txt [slurp $area_file]
    set total_cell "N/A"
    set total "N/A"
    if {[regexp -nocase {Total cell area:\s*([0-9.eE+-]+)} $txt -> a]} { set total_cell $a }
    if {[regexp -nocase {^Total area:\s*([0-9.eE+-]+)} $txt -> a]} { set total $a }
    return [list "N/A: DC is pre-floorplan" $total]
}

proc parse_icc2_area {util_file} {
    set txt [slurp $util_file]
    set core "N/A"
    set total_cells "N/A"
    if {[regexp -nocase {Total Area:\s*([0-9.eE+-]+)} $txt -> a]} { set core $a }
    if {[regexp -nocase {Total Area of cells:\s*([0-9.eE+-]+)} $txt -> a]} { set total_cells $a }
    return [list $core $total_cells]
}

proc parse_clock_skew {skew_file} {
    set txt [slurp $skew_file]
    set skew "N/A"
    foreach line [split $txt "\n"] {
        # Grab numeric skew from data rows in report_clock_timing -type skew.
        if {[regexp {\s+[A-Za-z0-9_\[\]/!.]+\s+[-0-9.eE+]+\s+([-0-9.eE+]+)\s+} $line -> s]} {
            set skew $s
        }
    }
    return $skew
}

proc parse_voltage_drop {fname} {
    set txt [slurp $fname]
    if {$txt eq ""} { return "N/A" }
    set best "N/A"
    foreach line [split $txt "\n"] {
        if {[regexp -nocase {VDD.*(drop|ir).*?([0-9.eE+-]+)} $line -> dummy val]} { set best $val }
        if {[regexp -nocase {(max).*?(drop|ir).*?([0-9.eE+-]+)} $line -> a b val]} { set best $val }
    }
    return $best
}

proc print_dc_metrics {} {
    global IP DESIGN
    set area_vals [parse_dc_area ${IP}/asic/reports/dc_area.rpt]
    set pwr_vals  [parse_power_summary ${IP}/asic/reports/dc_power.rpt]
    puts ""
    puts "==================== FINAL DC METRICS ===================="
    puts [format "%-35s %s" "Core area:"          [lindex $area_vals 0]]
    puts [format "%-35s %s" "Total area:"         [lindex $area_vals 1]]
    puts [format "%-35s %s" "Dynamic power:"      [lindex $pwr_vals 0]]
    puts [format "%-35s %s" "Leakage power:"      [lindex $pwr_vals 1]]
    puts [format "%-35s %s" "Total power:"        [lindex $pwr_vals 2]]
    puts [format "%-35s %s" "Clock skew:"         "N/A: CTS is done in ICC2, not DC"]
    puts [format "%-35s %s" "Max VDD voltage drop:" "N/A: no routed PG rail in DC"]
    puts "Reports: ${IP}/asic/reports"
    puts "=========================================================="
}

proc print_icc2_metrics {} {
    global IP DESIGN
    set area_vals [parse_icc2_area ${IP}/asic/reports/icc2_utilization.rpt]
    set pwr_vals  [parse_power_summary ${IP}/asic/reports/icc2_power.rpt]
    set skew      [parse_clock_skew ${IP}/asic/reports/icc2_clock_skew.rpt]
    set vdrop     [parse_voltage_drop ${IP}/asic/reports/icc2_vdd_voltage_drop.rpt]
    puts ""
    puts "=================== FINAL ICC2 METRICS ==================="
    puts [format "%-35s %s" "Core area:"          [lindex $area_vals 0]]
    puts [format "%-35s %s" "Total area of cells:" [lindex $area_vals 1]]
    puts [format "%-35s %s" "Dynamic power:"      [lindex $pwr_vals 0]]
    puts [format "%-35s %s" "Leakage power:"      [lindex $pwr_vals 1]]
    puts [format "%-35s %s" "Total power:"        [lindex $pwr_vals 2]]
    puts [format "%-35s %s" "Clock skew:"         $skew]
    puts [format "%-35s %s" "Max VDD voltage drop:" $vdrop]
    puts "Reports: ${IP}/asic/reports"
    puts "=========================================================="
}

################################################################################
# DC flow
################################################################################
proc run_dc {} {
    global IP DESIGN top_mod RTL_SOURCE_FILES CLK_PORT CLK_PER DESIGN_REF_PATH
    global search_path link_library target_library

    set_svf "${IP}/asic/${DESIGN}.svf"

    if {![info exists search_path]} { set search_path "." }
    set search_path "$search_path ${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs ${DESIGN_REF_PATH}/lib/stdcell_rvt"

    set rvt_library "${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_tt0p8v25c.db \
                     ${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_ss0p72v125c.db \
                     ${DESIGN_REF_PATH}/lib/stdcell_rvt/db_ccs/saed14rvt_ss0p6v125c.db"

    set link_library   "$rvt_library"
    set target_library "$rvt_library"

    if {[file exists prototype_$DESIGN]} {
        file delete -force prototype_$DESIGN
    }

    create_mw_lib prototype_$DESIGN \
        -technology ${DESIGN_REF_PATH}/tech/milkyway/saed14nm_1p9m_mw.tf \
        -mw_reference_library [list ${DESIGN_REF_PATH}/lib/stdcell_rvt/milkyway/saed14nm_rvt_1p9m]
    open_mw_lib prototype_$DESIGN

    set_host_options -max_cores 16
    define_design_lib work -path ${IP}/asic/work

    analyze -define {ASIC=1} -f sverilog -library work $RTL_SOURCE_FILES
    elaborate -library work ${DESIGN}
    current_design ${DESIGN}
    link

    if {[sizeof_collection [get_ports -quiet $CLK_PORT]] > 0} {
        create_clock -name $CLK_PORT -period $CLK_PER [get_ports $CLK_PORT]
    } else {
        puts "WARNING: Clock port '$CLK_PORT' not found; skipping create_clock. Use -clk <port> if needed."
    }

    compile_ultra
    uniquify
    change_names -rules verilog -hierarchy

    write -hierarchy -format verilog -output ${IP}/asic/${DESIGN}_icc.v ${DESIGN}
    write_sdc ${IP}/asic/${DESIGN}.sdc
    write_sdf -significant_digits 13 ${IP}/asic/${DESIGN}.sdf

    redirect ${IP}/asic/reports/dc_area.rpt   { report_area }
    redirect ${IP}/asic/reports/dc_power.rpt  { report_power -analysis_effort medium }
    redirect ${IP}/asic/reports/dc_timing.rpt { report_timing -max_paths 10 }
    redirect ${IP}/asic/reports/dc_qor.rpt    { report_qor }

    print_dc_metrics
}

################################################################################
# ICC2 MCMM setup embedded from mcmm.tcl
################################################################################
proc setup_mcmm {} {
    global IP DESIGN TLUPLUS_MAX_FILE TLUPLUS_MIN_FILE MAP_FILE
    set Constraints_file "${IP}/asic/${DESIGN}.sdc"

    remove_corners -all
    remove_modes -all
    remove_scenarios -all

    create_corner slow
    create_corner fast

    read_parasitic_tech -tlup $TLUPLUS_MAX_FILE -layermap $MAP_FILE -name tlup_max
    read_parasitic_tech -tlup $TLUPLUS_MIN_FILE -layermap $MAP_FILE -name tlup_min

    set_parasitics_parameters -early_spec tlup_min -late_spec tlup_min -corners {fast}
    set_parasitics_parameters -early_spec tlup_max -late_spec tlup_max -corners {slow}

    create_mode func
    current_mode func
    create_scenario -mode func -corner fast -name func_fast
    create_scenario -mode func -corner slow -name func_slow

    current_scenario func_fast
    read_sdc $Constraints_file
    current_scenario func_slow
    read_sdc $Constraints_file
}

proc maybe_report_vdd_drop {} {
    global IP DESIGN NDM_POWER_NET
    set out ${IP}/asic/reports/icc2_vdd_voltage_drop.rpt
    set f [open $out w]
    puts $f "Voltage-drop report attempt for $NDM_POWER_NET"
    close $f

    # ICC2 installations differ: many academic flows do not include PrimeRail/rail analysis.
    # This tries common report names without stopping the main P&R flow.
    if {[llength [info commands report_rail_result]] > 0} {
        catch {redirect -append $out {report_rail_result -type effective_voltage_drop -nets VDD}} msg
        return
    }
    if {[llength [info commands report_power_rail_results]] > 0} {
        catch {redirect -append $out {report_power_rail_results -nets VDD}} msg
        return
    }
    set f [open $out a]
    puts $f "N/A: rail voltage-drop reporting command is not available in this ICC2 shell/license."
    puts $f "Use PrimeRail/RedHawk/signoff rail analysis for a real max VDD IR-drop number."
    close $f
}

################################################################################
# ICC2 flow
################################################################################
proc safe_clock_opt {} {
    global IP
    set rpt "${IP}/asic/reports/icc2_clock_opt_status.rpt"
    set fh [open $rpt w]
    puts $fh "Running clock_opt..."
    close $fh

    # On this ICC2 build, clock_opt can stop Tcl with message "Error: 0" after
    # FLW-8004/FLW-8001. Catch it so the lab flow can continue to route/report.
    set rc [catch {clock_opt} msg opts]
    set fh [open $rpt a]
    if {$rc} {
        puts $fh "clock_opt returned Tcl error code $rc"
        puts $fh "message: $msg"
        if {[dict exists $opts -errorinfo]} {
            puts $fh "errorinfo:"
            puts $fh [dict get $opts -errorinfo]
        }
        puts "WARNING: clock_opt did not complete cleanly; continuing. See $rpt"
    } else {
        puts $fh "clock_opt completed without Tcl error."
        puts "INFO: clock_opt completed."
    }
    close $fh
    return
}


proc safe_redirect_report {outfile body} {
    # Run a report command, but do not stop the full ICC2 flow if the report
    # is unavailable. This is useful for small/combinational designs where CTS
    # never initializes, so clock QoR/skew reports can throw errors.
    set rc [catch {redirect $outfile $body} msg opts]
    if {$rc} {
        set fh [open $outfile w]
        puts $fh "N/A: report command failed, so this metric is not available for this run."
        puts $fh "message: $msg"
        if {[dict exists $opts -errorinfo]} {
            puts $fh "errorinfo:"
            puts $fh [dict get $opts -errorinfo]
        }
        close $fh
        puts "WARNING: Report failed but flow is continuing. See $outfile"
    }
    return
}

proc run_icc2 {} {
    global IP DESIGN CLK_PORT CLK_PER LINK_LIBRARY_FILES TARGET_LIBRARY_FILES NDM_REFERENCE_LIB_DIRS TECH_FILE
    global TLUPLUS_MAX_FILE TLUPLUS_MIN_FILE MAP_FILE NDM_POWER_NET NDM_GROUND_NET
    global MIN_ROUTING_LAYER MAX_ROUTING_LAYER GDS_MAP_FILE STD_CELL_GDS SRAMLP_SINGLELP_GDS

    set_host_options -max_cores 16
    set link_library   $LINK_LIBRARY_FILES
    set target_library $TARGET_LIBRARY_FILES

    set lib_path ${IP}/asic/work/${DESIGN}
    if {[file exists $lib_path]} { file delete -force $lib_path }
    create_lib -ref_libs $NDM_REFERENCE_LIB_DIRS -technology $TECH_FILE $lib_path

    read_parasitic_tech -tlup $TLUPLUS_MAX_FILE -layermap $MAP_FILE
    read_parasitic_tech -tlup $TLUPLUS_MIN_FILE -layermap $MAP_FILE

    set gate_verilog "${IP}/asic/${DESIGN}_icc.v"
    if {![file exists $gate_verilog]} {
        puts "ERROR: $gate_verilog not found. Run this same script in DC first."
        exit 1
    }

    read_verilog -top $DESIGN $gate_verilog
    current_design $DESIGN

    if {[file exists ${IP}/asic/${DESIGN}.sdc]} {
        read_sdc ${IP}/asic/${DESIGN}.sdc
    } elseif {[sizeof_collection [get_ports -quiet $CLK_PORT]] > 0} {
        create_clock -name $CLK_PORT -period $CLK_PER [get_ports $CLK_PORT]
    }

    setup_mcmm

    set_attribute [get_layers M1] routing_direction vertical
    set_attribute [get_layers M2] routing_direction horizontal
    set_attribute [get_layers M3] routing_direction vertical
    set_attribute [get_layers M4] routing_direction horizontal
    set_attribute [get_layers M5] routing_direction vertical
    set_attribute [get_layers M6] routing_direction horizontal
    set_attribute [get_layers M7] routing_direction vertical
    set_attribute [get_layers M8] routing_direction horizontal
    set_attribute [get_layers M9] routing_direction vertical
    set_attribute [get_layers MRDL] routing_direction horizontal

    set_wire_track_pattern -site_def unit -layer M1 -mode uniform \
        -mask_constraint {mask_two mask_one} -coord 0.037 -space 0.074 -direction vertical

    initialize_floorplan -core_utilization 0.60 -side_ratio {15 33} -core_offset {10 10 10 10}
    place_pins -ports [get_ports *]

    create_net -power $NDM_POWER_NET
    create_net -ground $NDM_GROUND_NET
    connect_pg_net -net $NDM_POWER_NET [get_pins -hierarchical "*/VDD"]
    connect_pg_net -net $NDM_GROUND_NET [get_pins -hierarchical "*/VSS"]

    create_placement -floorplan -timing_driven
    legalize_placement

    remove_pg_via_master_rules -all
    remove_pg_patterns -all
    remove_pg_strategies -all
    remove_pg_strategy_via_rules -all

    set top_ring_width 5
    set top_offset 2
    set top_ring_spacing 5
    set hm_top M6
    set vm_top M5

    create_pg_region top_power_ring_region -core -expand_by_edge \
        "{{side: 1} {offset: $top_offset}} {{side: 2} {offset: $top_offset}} {{side: 3} {offset: $top_offset}} {{side: 4} {offset: $top_offset}}"

    create_pg_ring_pattern ring \
        -horizontal_layer $hm_top -vertical_layer $vm_top \
        -horizontal_width $top_ring_width -vertical_width $top_ring_width \
        -horizontal_spacing $top_ring_spacing -vertical_spacing $top_ring_spacing

    set_pg_strategy ring -pg_regions {top_power_ring_region} -pattern {{name: ring} {nets: "VSS VDD"}}
    compile_pg -strategies ring

    create_pg_mesh_pattern P_top_two \
        -layers { \
            { {horizontal_layer: M7} {width: 0.2} {spacing: interleaving} {pitch: 30} {offset: 0.856} {trim : true} } \
            { {vertical_layer: M6}   {width: 0.2} {spacing: interleaving} {pitch: 30} {offset: 6.08}  {trim : true} } \
        }

    set_pg_strategy S_default_vddvss \
        -core \
        -pattern { {name: P_top_two} {nets:{VSS VDD}} } \
        -extension { {{stop:design_boundary_and_generate_pin}} }
    compile_pg -strategies {S_default_vddvss}

    create_pg_std_cell_conn_pattern std_rail_conn1 -rail_width 0.094 -layers M1
    set_pg_strategy std_rail_1 -pattern {{name : std_rail_conn1} {nets: "VDD VSS"}} -core
    compile_pg -strategies std_rail_1

    redirect ${IP}/asic/reports/icc2_pg_drc.rpt { check_pg_drc }

    set_app_options -name time.disable_recovery_removal_checks -value false
    set_app_options -name time.disable_case_analysis -value false
    set_app_options -name place.coarse.continue_on_missing_scandef -value true
    set_app_options -name opt.common.user_instance_name_prefix -value place

    place_opt
    legalize_placement
    redirect ${IP}/asic/reports/icc2_check_legality.rpt { check_legality -verbose }

    create_routing_rule ROUTE_RULES_1 -widths {M3 0.2 M4 0.2} -spacings {M3 0.42 M4 0.63}
    set_clock_routing_rules -default_rule -min_routing_layer M2 -max_routing_layer M4
    set_clock_tree_options -target_latency 0.000 -target_skew 0.000

    safe_clock_opt
    write_verilog ${IP}/asic/work/${DESIGN}.cts.gate.v
    safe_redirect_report ${IP}/asic/reports/icc2_clock_qor.rpt  { report_clock_qor }
    safe_redirect_report ${IP}/asic/reports/icc2_clock_skew.rpt { report_clock_timing -type skew -nworst 1 -setup }

    remove_ignored_layers -all
    set_ignored_layers -min_routing_layer $MIN_ROUTING_LAYER -max_routing_layer $MAX_ROUTING_LAYER

    route_auto
    route_opt
    redirect ${IP}/asic/reports/icc2_routability.rpt { check_routability }

    set pnr_std_fillers "SAEDRVT14_FILL*"
    set std_fillers ""
    foreach filler $pnr_std_fillers { lappend std_fillers "*/${filler}" }
    create_stdcell_filler -lib_cell $std_fillers

    connect_pg_net -net $NDM_POWER_NET [get_pins -hierarchical "*/VDD"]
    connect_pg_net -net $NDM_GROUND_NET [get_pins -hierarchical "*/VSS"]

    write_verilog ${IP}/asic/work/${DESIGN}.icc2.gate.v

    redirect ${IP}/asic/reports/icc2_timing.rpt      { report_timing -max_paths 10 }
    redirect ${IP}/asic/reports/icc2_power.rpt       { report_power -significant_digits 4 }
    redirect ${IP}/asic/reports/icc2_qor.rpt         { report_qor }
    redirect ${IP}/asic/reports/icc2_utilization.rpt { report_utilization }

    maybe_report_vdd_drop

    save_block -as ${DESIGN}_7_finished

    change_names -rules verilog -verbose
    write_verilog -include {pg_netlist unconnected_ports} ${IP}/asic/${DESIGN}_pnr.v

    write_gds -design ${DESIGN}_7_finished \
        -layer_map $GDS_MAP_FILE \
        -keep_data_type \
        -fill include \
        -output_pin all \
        -merge_files "$STD_CELL_GDS $SRAMLP_SINGLELP_GDS" \
        -long_names \
        ${IP}/asic/${DESIGN}_pnr.gds

    write_parasitics -output ${IP}/asic/${DESIGN}_pnr.spf

    print_icc2_metrics
}

################################################################################
# Main
################################################################################
if {$FLOW eq "dc"} {
    run_dc
    quit
} elseif {$FLOW eq "icc2"} {
    run_icc2
    exit
} else {
    puts "ERROR: Unknown FLOW '$FLOW'. Use -flow dc or -flow icc2."
    exit 1
}
