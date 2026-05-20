`timescale 1ns / 1ps

// Import global package for parameters
// Import global package for parameters
`include "interfaces/aurora_params.svh"
import aurora_global_pkg::*;

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Performance Analysis Team
//
// Create Date: 18 April 2026
// Design Name: AURORA-172 Performance Profiler v2
// Module Name: perf_profiler_v2
//
// Description:
//   Performance Profiler v2 untuk AURORA-172 processor
//   - Real-time performance monitoring
//   - Core utilization tracking
//   - Memory access profiling
//   - Cache hit rate analysis
//   - Power consumption monitoring
//////////////////////////////////////////////////////////////////////////////////

module perf_profiler_v2 #(
    parameter CLK_PERIOD = 10,  // 100MHz simulation clock
    parameter SAMPLE_WINDOW = 1024,  // OPTIMIZED: 256->1024 (more representative sampling)
    parameter NUM_CORES = AURORA_NUM_G_CORES + AURORA_NUM_H_CORES + AURORA_NUM_A_CORES + AURORA_NUM_NPU_CLUSTERS  // FIXED: Include NPU clusters
)(
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Core status inputs (FIXED: Include NPU cluster status)
    input  wire [AURORA_NUM_G_CORES-1:0]     g_core_busy,
    input  wire [AURORA_NUM_A_CORES-1:0]     a_core_busy,
    input  wire [AURORA_NUM_H_CORES-1:0]     h_core_busy,
    input  wire [AURORA_NUM_NPU_CLUSTERS-1:0] npu_busy,
    
    // Memory interface monitoring
    input  wire                         mem_rd_en,
    input  wire                         mem_wr_en,
    input  wire                         mem_ready,
    
    // Cache performance
    input  wire                         l1_hit,
    input  wire                         l2_hit,
    input  wire                         l3_hit,
    
    // Performance counters outputs
    output reg [31:0]                  total_cycles,
    output reg [31:0]                  busy_cycles,
    output reg [31:0]                  idle_cycles,
    output reg [31:0]                  mem_access_count,
    output reg [31:0]                  cache_hit_count,
    output reg [31:0]                  cache_miss_count,
    output reg [7:0]                    utilization_pct,
    output reg [7:0]                    cache_hit_rate_pct
);

    // Internal counters
    reg [31:0]                          cycle_counter;
    reg [31:0]                          sample_counter;
    reg [31:0]                          mem_access_counter;
    reg [31:0]                          cache_hit_counter;
    reg [31:0]                          cache_miss_counter;
    reg [31:0]                          busy_cycle_counter;
    
    // Enhanced core utilization tracking (FIXED: Include all core types)
    reg [NUM_CORES-1:0]                 core_busy_mask;
    reg [15:0]                          current_utilization;
    reg [7:0]                            g_core_utilization;
    reg [7:0]                            a_core_utilization;
    reg [7:0]                            h_core_utilization;
    reg [7:0]                            npu_utilization;
    
    // Sample window control
    reg sample_window_active;
    
    // Include timing and system constants
    `include "interfaces/aurora_timing_constants.svh"
    `include "interfaces/aurora_constants.svh"

    // Performance profiler constants
    localparam PERF_CYCLES_ZERO = 32'd0;
    localparam PERF_UTILIZATION_ZERO = 16'd0;
    localparam PERF_UTILIZATION_FULL = 8'd100;
    localparam PERF_SAMPLE_WINDOW = 32'd1000;
    localparam PERF_CORE_MASK_ALL_ONES = {NUM_CORES{1'b1}};
    localparam PERF_CORE_MASK_ALL_ZEROS = {NUM_CORES{1'b0}};

    // =========================================================================
    // Main counter logic (FIXED: Single always block to prevent race)
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycle_counter <= PERF_CYCLES_ZERO;
            sample_counter <= PERF_CYCLES_ZERO;
            mem_access_counter <= PERF_CYCLES_ZERO;
            cache_hit_counter <= PERF_CYCLES_ZERO;
            cache_miss_counter <= PERF_CYCLES_ZERO;
            busy_cycle_counter <= PERF_CYCLES_ZERO;
            sample_window_active <= 1'b0;
            core_busy_mask <= PERF_CORE_MASK_ALL_ZEROS;
            current_utilization <= 16'd0;
            total_cycles <= PERF_CYCLES_ZERO;
            busy_cycles <= PERF_CYCLES_ZERO;
            idle_cycles <= PERF_CYCLES_ZERO;
            mem_access_count <= PERF_CYCLES_ZERO;
            cache_hit_count <= PERF_CYCLES_ZERO;
            cache_miss_count <= PERF_CYCLES_ZERO;
            utilization_pct <= PERF_UTILIZATION_ZERO;
            cache_hit_rate_pct <= PERF_UTILIZATION_ZERO;
        end else begin
            cycle_counter <= cycle_counter + 1;
            
            // Sample window management using defined constants
            if (sample_counter >= SAMPLE_WINDOW) begin
                sample_counter <= PERF_CYCLES_ZERO;
                sample_window_active <= 1'b1;
            end else begin
                sample_counter <= sample_counter + 1;
                sample_window_active <= 1'b0;
            end
            
            // Memory access counting
            if (mem_rd_en || mem_wr_en) begin
                mem_access_counter <= mem_access_counter + 1;
            end
            
            // Cache performance counting
            if (l1_hit || l2_hit || l3_hit) begin
                cache_hit_counter <= cache_hit_counter + 1;
            end else if (mem_rd_en && !mem_ready) begin
                cache_miss_counter <= cache_miss_counter + 1;
            end
            
            // Enhanced core utilization tracking with individual core metrics
            core_busy_mask <= {g_core_busy, a_core_busy, h_core_busy, npu_busy};
            
            // Calculate individual core utilization using defined constants
            g_core_utilization <= (|g_core_busy) ? PERF_UTILIZATION_FULL : PERF_UTILIZATION_ZERO;
            a_core_utilization <= (|a_core_busy) ? PERF_UTILIZATION_FULL : PERF_UTILIZATION_ZERO;
            h_core_utilization <= (|h_core_busy) ? PERF_UTILIZATION_FULL : PERF_UTILIZATION_ZERO;
            npu_utilization <= (|npu_busy) ? PERF_UTILIZATION_FULL : PERF_UTILIZATION_ZERO;
            
            if (|core_busy_mask) begin
                busy_cycle_counter <= busy_cycle_counter + 1;
            end

            // Update performance metrics at end of sample window
            if (sample_window_active) begin
                total_cycles <= cycle_counter;
                busy_cycles <= busy_cycle_counter;
                idle_cycles <= cycle_counter - busy_cycle_counter;
                mem_access_count <= mem_access_counter;
                cache_hit_count <= cache_hit_counter;
                cache_miss_count <= cache_miss_counter;
                
                if (cycle_counter > 0) begin
                    utilization_pct <= (busy_cycle_counter * 100) / cycle_counter;
                end else begin
                    utilization_pct <= PERF_UTILIZATION_ZERO;
                end
                
                if ((cache_hit_counter + cache_miss_counter) > PERF_CYCLES_ZERO) begin
                    cache_hit_rate_pct <= (cache_hit_counter * PERF_UTILIZATION_FULL) / (cache_hit_counter + cache_miss_counter);
                end else begin
                    cache_hit_rate_pct <= PERF_UTILIZATION_ZERO;
                end
            end
        end
    end
    
    // =========================================================================
    // Debug output (conditional)
    // =========================================================================
    `ifdef AURORA_DEBUG_PERF
        always @(posedge clk) begin
            if (sample_window_active) begin
                $display("[%0t] [PERF-PROFILER] Window Complete:", $time);
                $display("  Total Cycles: %0d", cycle_counter);
                $display("  Busy Cycles: %0d (%d%%)", busy_cycle_counter, utilization_pct);
                $display("  Memory Accesses: %0d", mem_access_counter);
                $display("  Cache Hit Rate: %d%%", cache_hit_rate_pct);
            end
        end
    `endif

endmodule
