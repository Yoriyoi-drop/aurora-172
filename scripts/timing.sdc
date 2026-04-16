################################################################################
# AURORA-172 Timing Constraints
# Synopsys Design Constraints (SDC)
#
# Target: 6 GHz clock (production)
# Simulasi: 100 MHz (untuk testing)
################################################################################

# =========================================================================
# Clock definition
# =========================================================================
# Primary clock (simulasi: 100 MHz, target: 6 GHz = 0.167ns)
create_clock -period 10.000 -name clk [get_ports clk]

# CRITICAL FIX: Multi-clock domain constraints untuk heterogenous cores
# G-Core domain (target: 6GHz)
create_clock -period 0.167 -name g_core_clk -waveform {0.000 0.084} [get_ports clk]
set_clock_uncertainty -rise 0.017 [get_clocks g_core_clk]
set_clock_uncertainty -fall 0.017 [get_clocks g_core_clk]

# A-Core domain (target: 3GHz)
create_clock -period 0.333 -name a_core_clk -waveform {0.000 0.167} [get_ports clk]
set_clock_uncertainty -rise 0.033 [get_clocks a_core_clk]
set_clock_uncertainty -fall 0.033 [get_clocks a_core_clk]

# H-Core domain (target: 2GHz)
create_clock -period 0.500 -name h_core_clk -waveform {0.000 0.250} [get_ports clk]
set_clock_uncertainty -rise 0.050 [get_clocks h_core_clk]
set_clock_uncertainty -fall 0.050 [get_clocks h_core_clk]

# NPU domain (target: 1.5GHz)
create_clock -period 0.667 -name npu_clk -waveform {0.000 0.334} [get_ports clk]
set_clock_uncertainty -rise 0.067 [get_clocks npu_clk]
set_clock_uncertainty -fall 0.067 [get_clocks npu_clk]

# Clock latency (realistic untuk 6GHz)
set_clock_latency -source_max 0.050 [get_clocks clk]  # 50ps source latency
set_clock_latency -max 0.080 [get_clocks clk]          # 80ps total latency

# =========================================================================
# Reset
# =========================================================================
set_input_delay -clock clk -max 1.000 [get_ports rst_n]
set_input_delay -clock clk -min 0.500 [get_ports rst_n]

# =========================================================================
# Gaming interface timing
# =========================================================================
# Input delays
set_input_delay -clock clk -max 1.500 [get_ports game_cmd_addr*]
set_input_delay -clock clk -max 1.500 [get_ports game_cmd_data]
set_input_delay -clock clk -max 1.500 [get_ports game_cmd_valid]

# Output delays
set_output_delay -clock clk -max 2.000 [get_ports game_result*]
set_output_delay -clock clk -max 2.000 [get_ports game_result_valid]
set_output_delay -clock clk -max 1.000 [get_ports game_cmd_ready]

# =========================================================================
# AI interface timing
# =========================================================================
# Input delays
set_input_delay -clock clk -max 1.500 [get_ports ai_cmd_addr*]
set_input_delay -clock clk -max 1.500 [get_ports ai_cmd_data]
set_input_delay -clock clk -max 1.500 [get_ports ai_cmd_valid]

# Output delays
set_output_delay -clock clk -max 2.000 [get_ports ai_result*]
set_output_delay -clock clk -max 2.000 [get_ports ai_result_valid]
set_output_delay -clock clk -max 1.000 [get_ports ai_cmd_ready]

# =========================================================================
# System interface timing
# =========================================================================
set_input_delay -clock clk -max 1.000 [get_ports sys_interrupt]
set_input_delay -clock clk -max 1.000 [get_ports sys_power_mode*]

set_output_delay -clock clk -max 1.500 [get_ports sys_status*]

# =========================================================================
# Memory interface timing (172-bit bus)
# =========================================================================
# Output ke memory
set_output_delay -clock clk -max 2.000 [get_ports mem_addr*]
set_output_delay -clock clk -max 2.000 [get_ports mem_rd_en]
set_output_delay -clock clk -max 2.000 [get_ports mem_wr_en]
set_output_delay -clock clk -max 2.000 [get_ports mem_wr_data*]

# Input dari memory
set_input_delay -clock clk -max 2.500 [get_ports mem_rd_data*]
set_input_delay -clock clk -max 2.500 [get_ports mem_ready]

# =========================================================================
# Performance counters
# =========================================================================
set_output_delay -clock clk -max 1.500 [get_ports perf_counter_g*]
set_output_delay -clock clk -max 1.500 [get_ports perf_counter_a*]
set_output_delay -clock clk -max 1.500 [get_ports perf_counter_npu*]

# =========================================================================
# Drive strength
# =========================================================================
set_driving_cell -lib_cell INVX1 [all_inputs]
set_load 0.050 [all_outputs]

# =========================================================================
# Operating conditions
# =========================================================================
set_operating_conditions -max {typical} -analysis_type bcwc

# =========================================================================
# False paths (untuk interface yang tidak critical)
# =========================================================================
set_false_path -from [get_ports rst_n]

# =========================================================================
# Multi-cycle paths (untuk compute-heavy operations)
# =========================================================================
# A-Core matrix multiplication butuh multiple cycles
set_multicycle_path -setup -from [get_pins a_core*/compute_stage*] 16
set_multicycle_path -hold -from [get_pins a_core*/compute_stage*] 15

# NPU inference butuh multiple cycles
set_multicycle_path -setup -from [get_pins npu_cluster*/pe_index*] 8
set_multicycle_path -hold -from [get_pins npu_cluster*/pe_index*] 7

# RT Engine traversal
set_multicycle_path -setup -from [get_pins rt_engine*/bvh_level*] 32
set_multicycle_path -hold -from [get_pins rt_engine*/bvh_level*] 31

# =========================================================================
# Case analysis (untuk power modes)
# =========================================================================
# Mode 0: Gaming mode (G-Core active)
# Mode 1: AI mode (A-Core active)
# Mode 2: Mixed mode
# Mode 3: Power saving

# =========================================================================
# Design rules
# =========================================================================
set_max_fanout 16.0 [current_design]
set_max_transition 0.500 [current_design]

# =========================================================================
# Power constraints
# =========================================================================
set_max_total_power 400000  # 400W max TDP
