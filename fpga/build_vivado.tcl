#!/usr/bin/env -S vivado -mode batch -source
###############################################################################
# AURORA-172 FPGA Build Script
# Target: Xilinx Versal ACAP (VP1802)
# Tool: Vivado 2024.1+
#
# Usage:
#   vivado -mode batch -source fpga/build_vivado.tcl
#   or
#   source fpga/build_vivado.tcl
#
# Output:
#   - Bitstream: build/fpga/aurora_172.bit
#   - Checkpoint: build/fpga/aurora_172.dcp
#   - Reports: build/fpga/reports/
###############################################################################

# ===========================================================================
# 1. Project Setup
# ===========================================================================
set project_name "aurora_172"
set part_name "xcvp1802-ffvc1760-2-e"
set output_dir "build/fpga"
set reports_dir "${output_dir}/reports"

# Create output directories
file mkdir ${output_dir}
file mkdir ${reports_dir}

puts "=================================================================="
puts "AURORA-172 FPGA Build"
puts "Target Part: ${part_name}"
puts "=================================================================="

# Create project
create_project ${project_name} ${output_dir} -part ${part_name} -force

# Set project properties
set_property target_language SystemVerilog [current_project]
set_property simulator_language Mixed [current_project]
set_property enable_vhdl_2008 true [current_project]

# ===========================================================================
# 2. Add Source Files
# ===========================================================================
puts "\n[INFO] Adding source files..."

# RTL source files
set rtl_files [list \
    "top.sv" \
    "g_core/g_core.sv" \
    "g_core/ai_branch_predictor.sv" \
    "h_core/h_core.sv" \
    "a_core/a_core.sv" \
    "npu/npu_cluster.sv" \
    "rt_engine/rt_engine.sv" \
    "memory_fabric/memory_fabric.sv" \
    "memory_fabric/cache_coherency.sv" \
    "memory_fabric/power_management.sv" \
    "memory_fabric/dma_engine.sv" \
    "interconnect/aurora_fabric.sv" \
]

# FPGA-specific files
set fpga_files [list \
    "fpga/fpga_clock_distribution.sv" \
    "fpga/fpga_io_wrapper.sv" \
    "fpga/cdc_lib.sv" \
    "fpga/aurora_172_fpga_top.sv" \
]

# Add RTL files
foreach file ${rtl_files} {
    if {[file exists ${file}]} {
        add_files -norecurse ${file}
        puts "  [OK] ${file}"
    } else {
        puts "  [ERROR] File not found: ${file}"
    }
}

# Add FPGA files
foreach file ${fpga_files} {
    if {[file exists ${file}]} {
        add_files -norecurse ${file}
        puts "  [OK] ${file}"
    } else {
        puts "  [ERROR] File not found: ${file}"
    }
}

# ===========================================================================
# 3. Add Constraint Files
# ===========================================================================
puts "\n[INFO] Adding constraint files..."

# XDC constraints file
set xdc_file "fpga/aurora_172_versal.xdc"
if {[file exists ${xdc_file}]} {
    add_files -norecurse -fileset constrs_1 ${xdc_file}
    puts "  [OK] ${xdc_file}"
} else {
    puts "  [WARNING] XDC file not found: ${xdc_file}"
}

# ===========================================================================
# 4. Set Top Module
# ===========================================================================
puts "\n[INFO] Setting top module..."
set_property top aurora_172_fpga_top [current_fileset]

# ===========================================================================
# 5. Elaboration & Synthesis
# ===========================================================================
puts "\n[INFO] Starting synthesis..."

launch_runs synth_1 -jobs 8
wait_on_run synth_1

# Check synthesis results
set synth_status [get_property STATUS [get_runs synth_1]]
puts "[INFO] Synthesis status: ${synth_status}"

if {[string compare ${synth_status} "synth_design complete!"] != 0} {
    puts "[ERROR] Synthesis failed!"
    exit 1
}

# Open synthesis checkpoint
open_run synth_1

# ===========================================================================
# 6. Synthesis Reports
# ===========================================================================
puts "\n[INFO] Generating synthesis reports..."

# Timing report
report_timing -max_paths 20 -nworst 20 \
    -file "${reports_dir}/timing_synth.rpt"
puts "  [OK] Timing report: ${reports_dir}/timing_synth.rpt"

# Utilization report
report_utilization -file "${reports_dir}/utilization_synth.rpt"
puts "  [OK] Utilization report: ${reports_dir}/utilization_synth.rpt"

# Power report
report_power -file "${reports_dir}/power_synth.rpt"
puts "  [OK] Power report: ${reports_dir}/power_synth.rpt"

# DRC report
report_drc -file "${reports_dir}/drc_synth.rpt"
puts "  [OK] DRC report: ${reports_dir}/drc_synth.rpt"

# ===========================================================================
# 7. Implementation
# ===========================================================================
puts "\n[INFO] Starting implementation..."

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

# Check implementation status
set impl_status [get_property STATUS [get_runs impl_1]]
puts "[INFO] Implementation status: ${impl_status}"

if {[string compare ${impl_status} "write_bitstream complete!"] != 0} {
    puts "[ERROR] Implementation failed!"
    exit 1
}

# Open implementation checkpoint
open_run impl_1

# ===========================================================================
# 8. Implementation Reports
# ===========================================================================
puts "\n[INFO] Generating implementation reports..."

# Timing report
report_timing -max_paths 50 -nworst 50 \
    -file "${reports_dir}/timing_impl.rpt"
puts "  [OK] Timing report: ${reports_dir}/timing_impl.rpt"

# Utilization report
report_utilization -file "${reports_dir}/utilization_impl.rpt"
puts "  [OK] Utilization report: ${reports_dir}/utilization_impl.rpt"

# Power report
report_power -file "${reports_dir}/power_impl.rpt"
puts "  [OK] Power report: ${reports_dir}/power_impl.rpt"

# DRC report
report_drc -file "${reports_dir}/drc_impl.rpt"
puts "  [OK] DRC report: ${reports_dir}/drc_impl.rpt"

# CDC report
report_cdc -file "${reports_dir}/cdc.rpt"
puts "  [OK] CDC report: ${reports_dir}/cdc.rpt"

# ===========================================================================
# 9. Bitstream Generation
# ===========================================================================
puts "\n[INFO] Bitstream generation complete!"

# Copy bitstream to output directory
file copy -force "${output_dir}/${project_name}.runs/impl_1/aurora_172_fpga_top.bit" \
    "${output_dir}/aurora_172.bit"

puts "[OK] Bitstream: ${output_dir}/aurora_172.bit"

# ===========================================================================
# 10. Summary
# ===========================================================================
puts "\n=================================================================="
puts "AURORA-172 FPGA Build Complete!"
puts "=================================================================="
puts "Output files:"
puts "  Bitstream:    ${output_dir}/aurora_172.bit"
puts "  Checkpoint:   ${output_dir}/${project_name}.runs/impl_1/aurora_172_fpga_top.dcp"
puts "  Reports:      ${reports_dir}/"
puts "=================================================================="

# Close project
close_project

exit 0
