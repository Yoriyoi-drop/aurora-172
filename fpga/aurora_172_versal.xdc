###############################################################################
# AURORA-172 FPGA Constraints File
# Target: Xilinx Versal ACAP (VP1802)
# Tool: Vivado 2024.1+
# 
# This file contains all timing, placement, and I/O constraints for
# FPGA prototyping of the AURORA-172 heterogeneous processor.
###############################################################################

###############################################################################
# 1. CLOCK DEFINITIONS
###############################################################################

# Primary system clock (500 MHz from external oscillator)
create_clock -period 2.000 -name sys_clk [get_ports sys_clk_p]
create_clock -period 2.000 -name sys_clk_n [get_ports sys_clk_n]

# Derived clocks for different domains
# G-Core domain: 500 MHz (target 6GHz scaled down for FPGA)
create_generated_clock -name g_core_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 1 \
    [get_pins clk_wizard_0/inst/clk_out1]

# H-Core domain: 250 MHz (efficiency cores)
create_generated_clock -name h_core_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 2 \
    [get_pins clk_wizard_0/inst/clk_out2]

# A-Core/NPU domain: 125 MHz (AI tensor cores)
create_generated_clock -name ai_core_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 4 \
    [get_pins clk_wizard_0/inst/clk_out3]

# Memory fabric: 333 MHz (172-bit bus @ 57.7 GB/s)
create_generated_clock -name mem_fabric_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 1.5 \
    [get_pins clk_wizard_0/inst/clk_out4]

# Interconnect: 250 MHz (Aurora Fabric)
create_generated_clock -name interconnect_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 2 \
    [get_pins clk_wizard_0/inst/clk_out5]

# Debug/trace clock
create_generated_clock -name debug_clk \
    -source [get_ports sys_clk_p] \
    -divide_by 10 \
    [get_pins clk_wizard_0/inst/clk_out6]

###############################################################################
# 2. CLOCK UNCERTAINTY & JITTER
###############################################################################

# Input clock jitter (assuming 50ps jitter on 500 MHz clock)
set_clock_uncertainty -setup 0.100 [get_clocks sys_clk]
set_clock_uncertainty -hold 0.050 [get_clocks sys_clk]

# PLL-generated clocks (typical Versal MMCM/PLL jitter)
set_clock_uncertainty -setup 0.080 [get_clocks g_core_clk]
set_clock_uncertainty -hold 0.040 [get_clocks g_core_clk]

set_clock_uncertainty -setup 0.100 [get_clocks h_core_clk]
set_clock_uncertainty -hold 0.050 [get_clocks h_core_clk]

set_clock_uncertainty -setup 0.120 [get_clocks ai_core_clk]
set_clock_uncertainty -hold 0.060 [get_clocks ai_core_clk]

set_clock_uncertainty -setup 0.090 [get_clocks mem_fabric_clk]
set_clock_uncertainty -hold 0.045 [get_clocks mem_fabric_clk]

set_clock_uncertainty -setup 0.100 [get_clocks interconnect_clk]
set_clock_uncertainty -hold 0.050 [get_clocks interconnect_clk]

###############################################################################
# 3. CLOCK DOMAIN CROSSING (CDC) CONSTRAINTS
###############################################################################

# False paths between asynchronous clock domains
set_clock_groups -asynchronous \
    -group [get_clocks g_core_clk] \
    -group [get_clocks h_core_clk] \
    -group [get_clocks ai_core_clk] \
    -group [get_clocks mem_fabric_clk] \
    -group [get_clocks interconnect_clk]

# Synchronizer registers for CDC (mark as safe)
set_max_delay -datapath_only -from [get_cells -hierarchical -filter {NAME =~ *cdc_sync*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *cdc_sync_dest*}] 2.000

###############################################################################
# 4. I/O CONSTRAINTS - Memory Interface (172-bit DDR/HBM)
###############################################################################

# DDR4/5 memory interface constraints
set_property IOSTANDARD SSTL12 [get_ports {ddr4_dq[*]}]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {ddr4_dqs_p[*] ddr4_dqs_n[*]}]
set_property IOSTANDARD DIFF_SSTL12 [get_ports {ddr4_addr[*] ddr4_ba[*] ddr4_cke[*]}]

# HBM2E interface (if using Versal HBM variant)
set_property IOSTANDARD LVCMOS18 [get_ports {hbi_addr[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hbi_cmd[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hbi_data[*]}]

# Memory bus timing (172-bit @ 333 MHz = 57.7 GB/s)
set_output_delay -clock mem_fabric_clk -max 1.500 [get_ports {mem_data_out[*]}]
set_output_delay -clock mem_fabric_clk -min 0.500 [get_ports {mem_data_out[*]}]
set_input_delay -clock mem_fabric_clk -max 1.200 [get_ports {mem_data_in[*]}]
set_input_delay -clock mem_fabric_clk -min 0.600 [get_ports {mem_data_in[*]}]

###############################################################################
# 5. I/O CONSTRAINTS - External Interfaces
###############################################################################

# PCIe Gen5 interface (x16 lanes)
set_property IOSTANDARD LVCMOS18 [get_ports {pcie_tx[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports {pcie_rx[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pcie_perst_n]
set_property IOSTANDARD LVCMOS18 [get_ports pcie_clk_p]
set_property IOSTANDARD LVCMOS18 [get_ports pcie_clk_n]

# Debug JTAG interface
set_property IOSTANDARD LVCMOS18 [get_ports jtag_tck]
set_property IOSTANDARD LVCMOS18 [get_ports jtag_tms]
set_property IOSTANDARD LVCMOS18 [get_ports jtag_tdi]
set_property IOSTANDARD LVCMOS18 [get_ports jtag_tdo]
set_property IOSTANDARD LVCMOS18 [get_ports jtag_trst_n]

# GPIO/Status LEDs
set_property IOSTANDARD LVCMOS18 [get_ports {led_status[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports gpio_int_n]

# UART for console/debug
set_property IOSTANDARD LVCMOS18 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS18 [get_ports uart_rx]

###############################################################################
# 6. TIMING EXCEPTIONS - Critical Paths
###############################################################################

# G-Core critical paths (aggressive timing)
set_max_delay 1.800 -from [get_cells -hierarchical -filter {NAME =~ *g_core*/*exec_pipe*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *g_core*/*exec_pipe*}]

# AI Branch predictor paths
set_max_delay 1.900 -from [get_cells -hierarchical -filter {NAME =~ *g_core*/*ai_bp*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *g_core*/*fetch*}]

# Memory fabric arbitration
set_max_delay 2.000 -from [get_cells -hierarchical -filter {NAME =~ *memory_fabric*/*arbiter*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *memory_fabric*/*cache*}]

# Aurora Fabric mesh routing
set_max_delay 2.000 -from [get_cells -hierarchical -filter {NAME =~ *aurora_fabric*/*router*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *aurora_fabric*/*input_fifo*}]

###############################################################################
# 7. MULTICYCLE PATHS
###############################################################################

# DMA engine transfer control (multi-cycle OK)
set_multicycle_path -setup 4 -from [get_cells -hierarchical -filter {NAME =~ *dma_engine*/*ch[*]/control*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *dma_engine*/*ch[*]/status*}]
set_multicycle_path -hold 3 -from [get_cells -hierarchical -filter {NAME =~ *dma_engine*/*ch[*]/control*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *dma_engine*/*ch[*]/status*}]

# Cache coherency directory updates (multi-cycle OK)
set_multicycle_path -setup 3 -from [get_cells -hierarchical -filter {NAME =~ *cache_coherency*/*directory*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *cache_coherency*/*snoop*}]
set_multicycle_path -hold 2 -from [get_cells -hierarchical -filter {NAME =~ *cache_coherency*/*directory*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *cache_coherency*/*snoop*}]

# Power management state machine (slow updates OK)
set_multicycle_path -setup 10 -from [get_cells -hierarchical -filter {NAME =~ *power_mgmt*/*fsm*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *power_mgmt*/*control*}]
set_multicycle_path -hold 9 -from [get_cells -hierarchical -filter {NAME =~ *power_mgmt*/*fsm*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *power_mgmt*/*control*}]

# NPU weight loading (multi-cycle OK)
set_multicycle_path -setup 8 -from [get_cells -hierarchical -filter {NAME =~ *npu_cluster*/*pe[*]/weight_buf*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *npu_cluster*/*pe[*]/mac*}]
set_multicycle_path -hold 7 -from [get_cells -hierarchical -filter {NAME =~ *npu_cluster*/*pe[*]/weight_buf*}] \
    -to [get_cells -hierarchical -filter {NAME =~ *npu_cluster*/*pe[*]/mac*}]

###############################################################################
# 8. FALSE PATHS
###############################################################################

# Reset paths (not timing critical)
set_false_path -from [get_ports rst_n]
set_false_path -to [get_ports rst_n]

# Debug/trace paths (can be ignored for timing)
set_false_path -from [get_cells -hierarchical -filter {NAME =~ *debug_ctrl*}]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *debug_ctrl*}]

# Test mode signals
set_false_path -from [get_ports test_mode_en]
set_false_path -to [get_cells -hierarchical -filter {NAME =~ *test_mode*}]

###############################################################################
# 9. PHYSICAL CONSTRAINTS - Placement
###############################################################################

# Floorplanning: Group cores by type into SLRs (Super Logic Regions)
# SLR 0: G-Cores (Gaming) + RT Engine
create_pblock g_core_region
add_cells_to_pblock g_core_region [get_cells -hierarchical -filter {NAME =~ *g_core[*]}]
resize_pblock g_core_region -add {SLICE_X0Y0:SLICE_X79Y199 DSP_X0Y0:DSP_X19Y199}

# SLR 1: H-Cores (General Purpose)
create_pblock h_core_region
add_cells_to_pblock h_core_region [get_cells -hierarchical -filter {NAME =~ *h_core[*]}]
resize_pblock h_core_region -add {SLICE_X80Y0:SLICE_X159Y199 DSP_X20Y0:DSP_X39Y199}

# SLR 2: A-Cores + NPU (AI/Tensor)
create_pblock ai_core_region
add_cells_to_pblock ai_core_region [get_cells -hierarchical -filter {NAME =~ *a_core[*] npu_cluster[*]}]
resize_pblock ai_core_region -add {SLICE_X0Y200:SLICE_X159Y399 DSP_X0Y200:DSP_X39Y399}

# Memory Fabric: Center placement for optimal routing
create_pblock mem_fabric_region
add_cells_to_pblock mem_fabric_region [get_cells -hierarchical -filter {NAME =~ *memory_fabric[*]}]
resize_pblock mem_fabric_region -add {SLICE_X80Y200:SLICE_X159Y299}

# Interconnect: Distributed across SLRs
create_pblock interconnect_region
add_cells_to_pblock interconnect_region [get_cells -hierarchical -filter {NAME =~ *aurora_fabric[*]}]

# RT Engine: Near G-Cores for low latency
create_pblock rt_engine_region
add_cells_to_pblock rt_engine_region [get_cells -hierarchical -filter {NAME =~ *rt_engine[*]}]
resize_pblock rt_engine_region -add {SLICE_X0Y200:SLICE_X39Y299}

###############################################################################
# 10. DSP & BRAM USAGE CONSTRAINTS
###############################################################################

# Max DSP utilization (target <85% for timing closure)
set_property MAX_DSP_UTILIZATION 85 [current_design]

# BRAM allocation for caches
set_property BRAM_SITES 2048 [current_design]

# DSP usage for MAC operations (A-Cores, NPU, RT)
set_property DSP_BALANCING true [current_design]

###############################################################################
# 11. POWER CONSTRAINTS
###############################################################################

# Target power envelope (Versal VP1802: ~50W typical)
set_power_supplies -voltage 0.85 -name vccint
set_power_supplies -voltage 1.80 -name vcco
set_operating_conditions -max 85.0 -min 0.0

# Power estimation modes
set_power_analysis_mode -effort high

###############################################################################
# 12. SIMULATION & DEBUG CONSTRAINTS
###############################################################################

# ILA (Integrated Logic Analyzer) probe placement
# Mark critical signals for debug
set_property MARK_DEBUG true [get_nets {g_core[0]/pc_reg[*]}]
set_property MARK_DEBUG true [get_nets {g_core[0]/exec_pipe/alu_result[*]}]
set_property MARK_DEBUG true [get_nets {memory_fabric/mem_req_valid}]
set_property MARK_DEBUG true [get_nets {memory_fabric/mem_rsp_ready}]
set_property MARK_DEBUG true [get_nets {aurora_fabric/mesh_packet_valid}]

# VIO (Virtual I/O) for runtime control
set_property MARK_DEBUG true [get_nets {dvfs_freq_sel[*]}]
set_property MARK_DEBUG true [get_nets {power_gate_en[*]}]

###############################################################################
# 13. CONFIGURATION CONSTRAINTS
###############################################################################

# Bitstream generation settings
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 66 [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

# Enable partial reconfiguration (for runtime core swapping)
set_property PR_CONFIGURATION ADVANCED [current_design]

###############################################################################
# END OF CONSTRAINTS
###############################################################################
