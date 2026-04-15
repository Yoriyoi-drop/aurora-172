`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Performance Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Performance Profiler v2
// Module Name: perf_profiler_v2
//
// Description:
//   Performance Profiler v2 - Comprehensive performance monitoring
//   - IPC (Instructions Per Cycle) calculation
//   - CPI (Cycles Per Instruction) breakdown
//   - Per-core utilization % (G-Core, A-Core, NPU)
//   - Queue depth over time (not just peak)
//   - Average wait time per queue
//   - Throughput (ops/cycle)
//   - Enhanced stall decomposition
//   - Bottleneck identification
//
// Target: Provide complete visibility for scheduler optimization
//////////////////////////////////////////////////////////////////////////////////

module perf_profiler_v2 #(
    parameter NUM_G_CORES   = 1,
    parameter NUM_A_CORES   = 1,
    parameter NUM_NPU       = 1,
    parameter QUEUE_DEPTH   = 8,
    parameter HISTORY_LEN   = 64          // Queue depth history samples
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // ─────────────────────────────────────────────────────────
    // Core activity signals (per-core utilization tracking)
    // ─────────────────────────────────────────────────────────
    // G-Core activity
    input  wire                         g_core_busy [0:NUM_G_CORES-1],
    input  wire [31:0]                  g_core_ops_completed [0:NUM_G_CORES-1],
    input  wire [31:0]                  g_core_cycles_active [0:NUM_G_CORES-1],

    // A-Core activity
    input  wire                         a_core_busy [0:NUM_A_CORES-1],
    input  wire [31:0]                  a_core_ops_completed [0:NUM_A_CORES-1],
    input  wire [31:0]                  a_core_cycles_active [0:NUM_A_CORES-1],

    // NPU activity
    input  wire                         npu_busy [0:NUM_NPU-1],
    input  wire [31:0]                  npu_ops_completed [0:NUM_NPU-1],
    input  wire [31:0]                  npu_cycles_active [0:NUM_NPU-1],

    // ─────────────────────────────────────────────────────────
    // Scheduler metrics
    // ─────────────────────────────────────────────────────────
    input  wire [31:0]                  scheduler_tasks_dispatched,
    input  wire [31:0]                  scheduler_tasks_completed,
    input  wire [31:0]                  scheduler_total_stall_cycles,
    input  wire [31:0]                  scheduler_resource_wait,
    input  wire [31:0]                  scheduler_queue_contention,
    input  wire [31:0]                  scheduler_resource_conflicts,
    input  wire [7:0]                   scheduler_current_queue_depth,
    input  wire [7:0]                   scheduler_peak_queue_depth,

    // ─────────────────────────────────────────────────────────
    // Cache metrics (from cache_profiler)
    // ─────────────────────────────────────────────────────────
    input  wire [31:0]                  cache_l1_hits,
    input  wire [31:0]                  cache_l1_misses,
    input  wire [31:0]                  cache_l2_hits,
    input  wire [31:0]                  cache_l2_misses,
    input  wire [7:0]                   cache_l1_hit_rate_pct,
    input  wire [7:0]                   cache_l2_hit_rate_pct,

    // ─────────────────────────────────────────────────────────
    // NoC metrics (from noc_monitor)
    // ─────────────────────────────────────────────────────────
    input  wire [31:0]                  noc_packets_routed,
    input  wire [31:0]                  noc_contention_cycles,
    input  wire [7:0]                   noc_congestion_level,

    // ─────────────────────────────────────────────────────────
    // Global cycle counter
    // ─────────────────────────────────────────────────────────
    input  wire [63:0]                  global_cycle_count,

    // ─────────────────────────────────────────────────────────
    // Output: IPC / CPI metrics
    // ─────────────────────────────────────────────────────────
    output reg [31:0]                   profiler_total_instructions,
    output reg [31:0]                   profiler_total_cycles,
    output reg [31:0]                   profiler_ipc_x100,         // IPC * 100 (fixed point)
    output reg [31:0]                   profiler_cpi_x100,         // CPI * 100 (fixed point)

    // ─────────────────────────────────────────────────────────
    // Output: Per-core utilization %
    // ─────────────────────────────────────────────────────────
    output reg [7:0]                    g_core_utilization_pct,
    output reg [7:0]                    a_core_utilization_pct,
    output reg [7:0]                    npu_utilization_pct,
    output reg [7:0]                    overall_utilization_pct,

    // ─────────────────────────────────────────────────────────
    // Output: Queue metrics
    // ─────────────────────────────────────────────────────────
    output reg [31:0]                   queue_avg_depth,
    output reg [31:0]                   queue_peak_depth,
    output reg [31:0]                   queue_avg_wait_time,
    output reg [31:0]                   queue_history [0:HISTORY_LEN-1],

    // ─────────────────────────────────────────────────────────
    // Output: Throughput
    // ─────────────────────────────────────────────────────────
    output reg [31:0]                   throughput_ops,
    output reg [31:0]                   throughput_cycles,
    output reg [31:0]                   throughput_ops_per_cycle_x1000,  // * 1000

    // ─────────────────────────────────────────────────────────
    // Output: Enhanced stall decomposition
    // ─────────────────────────────────────────────────────────
    output reg [31:0]                   stall_resource_wait,
    output reg [31:0]                   stall_queue_contention,
    output reg [31:0]                   stall_cache_misses,
    output reg [31:0]                   stall_noc_congestion,
    output reg [31:0]                   stall_total,
    output reg [7:0]                    stall_resource_wait_pct,
    output reg [7:0]                    stall_queue_contention_pct,
    output reg [7:0]                    stall_cache_misses_pct,
    output reg [7:0]                    stall_noc_congestion_pct,

    // ─────────────────────────────────────────────────────────
    // Output: Bottleneck identification
    // ─────────────────────────────────────────────────────────
    output reg [1:0]                    primary_bottleneck,  // 0=Compute, 1=Memory, 2=Interconnect, 3=Scheduler
    output reg [31:0]                   bottleneck_stall_cycles,

    // ─────────────────────────────────────────────────────────
    // Print trigger
    // ─────────────────────────────────────────────────────────
    input  wire                         trigger_print,
    output reg                          print_done
);

    // ─────────────────────────────────────────────────────────
    // Internal tracking
    // ─────────────────────────────────────────────────────────
    reg [31:0]                          total_g_ops;
    reg [31:0]                          total_a_ops;
    reg [31:0]                          total_npu_ops;
    reg [31:0]                          total_g_cycles;
    reg [31:0]                          total_a_cycles;
    reg [31:0]                          total_npu_cycles;
    reg [31:0]                          history_idx;

    integer i;

    // ─────────────────────────────────────────────────────────
    // Main profiler logic
    // ─────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            profiler_total_instructions <= 32'h0;
            profiler_total_cycles <= 32'h0;
            profiler_ipc_x100 <= 32'h0;
            profiler_cpi_x100 <= 32'h0;
            g_core_utilization_pct <= 8'h0;
            a_core_utilization_pct <= 8'h0;
            npu_utilization_pct <= 8'h0;
            overall_utilization_pct <= 8'h0;
            queue_avg_depth <= 32'h0;
            queue_peak_depth <= 32'h0;
            queue_avg_wait_time <= 32'h0;
            throughput_ops <= 32'h0;
            throughput_cycles <= 32'h0;
            throughput_ops_per_cycle_x1000 <= 32'h0;
            stall_resource_wait <= 32'h0;
            stall_queue_contention <= 32'h0;
            stall_cache_misses <= 32'h0;
            stall_noc_congestion <= 32'h0;
            stall_total <= 32'h0;
            stall_resource_wait_pct <= 8'h0;
            stall_queue_contention_pct <= 8'h0;
            stall_cache_misses_pct <= 8'h0;
            stall_noc_congestion_pct <= 8'h0;
            primary_bottleneck <= 2'b0;
            bottleneck_stall_cycles <= 32'h0;
            print_done <= 1'b0;
            history_idx <= 32'h0;
            total_g_ops <= 32'h0;
            total_a_ops <= 32'h0;
            total_npu_ops <= 32'h0;
            total_g_cycles <= 32'h0;
            total_a_cycles <= 32'h0;
            total_npu_cycles <= 32'h0;

            for (i = 0; i < HISTORY_LEN; i = i + 1) begin
                queue_history[i] <= 32'h0;
            end
        end else begin
            // ─────────────────────────────────────────────
            // Aggregate core operations
            // ─────────────────────────────────────────────
            integer g;
            integer a;
            integer n;
            total_g_ops = 0;
            total_a_ops = 0;
            total_npu_ops = 0;
            total_g_cycles = 0;
            total_a_cycles = 0;
            total_npu_cycles = 0;

            for (g = 0; g < NUM_G_CORES; g = g + 1) begin
                total_g_ops = total_g_ops + g_core_ops_completed[g];
                total_g_cycles = total_g_cycles + g_core_cycles_active[g];
            end
            for (a = 0; a < NUM_A_CORES; a = a + 1) begin
                total_a_ops = total_a_ops + a_core_ops_completed[a];
                total_a_cycles = total_a_cycles + a_core_cycles_active[a];
            end
            for (n = 0; n < NUM_NPU; n = n + 1) begin
                total_npu_ops = total_npu_ops + npu_ops_completed[n];
                total_npu_cycles = total_npu_cycles + npu_cycles_active[n];
            end

            // ─────────────────────────────────────────────
            // IPC / CPI calculation
            // ─────────────────────────────────────────────
            profiler_total_instructions <= total_g_ops + total_a_ops + total_npu_ops;
            profiler_total_cycles <= global_cycle_count[31:0];

            if (global_cycle_count[31:0] > 0) begin
                // IPC = Total Instructions / Total Cycles
                profiler_ipc_x100 <= ((total_g_ops + total_a_ops + total_npu_ops) * 100) / 
                                      global_cycle_count[31:0];
                
                // CPI = Total Cycles / Total Instructions
                if ((total_g_ops + total_a_ops + total_npu_ops) > 0) begin
                    profiler_cpi_x100 <= (global_cycle_count[31:0] * 100) / 
                                          (total_g_ops + total_a_ops + total_npu_ops);
                end
            end

            // ─────────────────────────────────────────────
            // Per-core utilization %
            // ─────────────────────────────────────────────
            if (global_cycle_count[31:0] > 0) begin
                g_core_utilization_pct <= (total_g_cycles * 100) / global_cycle_count[31:0];
                a_core_utilization_pct <= (total_a_cycles * 100) / global_cycle_count[31:0];
                npu_utilization_pct <= (total_npu_cycles * 100) / global_cycle_count[31:0];
                
                // Overall utilization (average across all cores)
                overall_utilization_pct <= (g_core_utilization_pct + 
                                            a_core_utilization_pct + 
                                            npu_utilization_pct) / 3;
            end

            // ─────────────────────────────────────────────
            // Queue depth tracking
            // ─────────────────────────────────────────────
            queue_peak_depth <= scheduler_peak_queue_depth;
            
            // Sample queue depth into history buffer
            if (history_idx < HISTORY_LEN) begin
                queue_history[history_idx] <= scheduler_current_queue_depth;
                history_idx <= history_idx + 1;
                
                // Calculate running average
                if (history_idx > 0) begin
                    integer sum;
                    sum = 0;
                    for (i = 0; i < history_idx; i = i + 1) begin
                        sum = sum + queue_history[i];
                    end
                    queue_avg_depth <= sum / history_idx;
                end
            end

            // Queue wait time (estimated from stall cycles / tasks)
            if (scheduler_tasks_completed > 0) begin
                queue_avg_wait_time <= scheduler_total_stall_cycles / scheduler_tasks_completed;
            end

            // ─────────────────────────────────────────────
            // Throughput calculation
            // ─────────────────────────────────────────────
            throughput_ops <= total_g_ops + total_a_ops + total_npu_ops;
            throughput_cycles <= global_cycle_count[31:0];
            
            if (global_cycle_count[31:0] > 0) begin
                throughput_ops_per_cycle_x1000 <= ((total_g_ops + total_a_ops + total_npu_ops) * 1000) / 
                                                    global_cycle_count[31:0];
            end

            // ─────────────────────────────────────────────
            // Enhanced stall decomposition
            // ─────────────────────────────────────────────
            stall_resource_wait <= scheduler_resource_wait;
            stall_queue_contention <= scheduler_queue_contention;
            stall_cache_misses <= cache_l1_misses + cache_l2_misses;
            stall_noc_congestion <= noc_contention_cycles;
            
            stall_total <= stall_resource_wait + 
                           stall_queue_contention + 
                           stall_cache_misses + 
                           stall_noc_congestion;

            // Calculate percentages
            if (stall_total > 0) begin
                stall_resource_wait_pct <= (stall_resource_wait * 100) / stall_total;
                stall_queue_contention_pct <= (stall_queue_contention * 100) / stall_total;
                stall_cache_misses_pct <= (stall_cache_misses * 100) / stall_total;
                stall_noc_congestion_pct <= (stall_noc_congestion * 100) / stall_total;
            end

            // ─────────────────────────────────────────────
            // Bottleneck identification
            // ─────────────────────────────────────────────
            // Find largest stall contributor
            if (stall_resource_wait >= stall_queue_contention && 
                stall_resource_wait >= stall_cache_misses &&
                stall_resource_wait >= stall_noc_congestion) begin
                primary_bottleneck <= 2'b00;  // Compute-bound
                bottleneck_stall_cycles <= stall_resource_wait;
            end else if (stall_cache_misses >= stall_queue_contention && 
                         stall_cache_misses >= stall_noc_congestion) begin
                primary_bottleneck <= 2'b01;  // Memory-bound
                bottleneck_stall_cycles <= stall_cache_misses;
            end else if (stall_noc_congestion >= stall_queue_contention) begin
                primary_bottleneck <= 2'b10;  // Interconnect-bound
                bottleneck_stall_cycles <= stall_noc_congestion;
            end else begin
                primary_bottleneck <= 2'b11;  // Scheduler-bound
                bottleneck_stall_cycles <= stall_queue_contention;
            end

            // ─────────────────────────────────────────────
            // Print trigger
            // ─────────────────────────────────────────────
            if (trigger_print) begin
                print_perf_report();
                print_done <= 1'b1;
            end else begin
                print_done <= 1'b0;
            end
        end
    end

    // ─────────────────────────────────────────────────────────
    // Print comprehensive performance report
    // ─────────────────────────────────────────────────────────
    task automatic print_perf_report;
        begin
            $display("\n╔══════════════════════════════════════════════════════════╗");
            $display("║     AURORA-172 Performance Profiler v2 Report             ║");
            $display("╚══════════════════════════════════════════════════════════╝");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  IPC / CPI METRICS                                      │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  Total Instructions:        %0d", profiler_total_instructions);
            $display("│  Total Cycles:              %0d", profiler_total_cycles);
            $display("│  IPC (Instructions/Cycle):  %0d.%02d", 
                     profiler_ipc_x100 / 100, profiler_ipc_x100 % 100);
            $display("│  CPI (Cycles/Instruction):  %0d.%02d", 
                     profiler_cpi_x100 / 100, profiler_cpi_x100 % 100);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  PER-CORE UTILIZATION                                   │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  G-Core Utilization:        %0d%%", g_core_utilization_pct);
            $display("│  A-Core Utilization:        %0d%%", a_core_utilization_pct);
            $display("│  NPU Utilization:           %0d%%", npu_utilization_pct);
            $display("│  Overall Utilization:       %0d%%", overall_utilization_pct);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  QUEUE METRICS                                          │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  Queue Depth (Average):     %0d", queue_avg_depth);
            $display("│  Queue Depth (Peak):        %0d", queue_peak_depth);
            $display("│  Avg Wait Time per Task:    %0d cycles", queue_avg_wait_time);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  THROUGHPUT                                             │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  Total Operations:          %0d", throughput_ops);
            $display("│  Total Cycles:              %0d", throughput_cycles);
            $display("│  Throughput:                %0d.%03d ops/cycle", 
                     throughput_ops_per_cycle_x1000 / 1000, 
                     throughput_ops_per_cycle_x1000 % 1000);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  ENHANCED STALL DECOMPOSITION                           │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  Resource Wait (Compute):   %0d cycles (%0d%%)", 
                     stall_resource_wait, stall_resource_wait_pct);
            $display("│  Queue Contention:          %0d cycles (%0d%%)", 
                     stall_queue_contention, stall_queue_contention_pct);
            $display("│  Cache Misses:              %0d cycles (%0d%%)", 
                     stall_cache_misses, stall_cache_misses_pct);
            $display("│  NoC Congestion:            %0d cycles (%0d%%)", 
                     stall_noc_congestion, stall_noc_congestion_pct);
            $display("│  ─────────────────────────────────────────              │");
            $display("│  TOTAL STALL:                 %0d cycles", stall_total);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  BOTTLENECK IDENTIFICATION                              │");
            $display("├─────────────────────────────────────────────────────────┤");
            case (primary_bottleneck)
                2'b00: $display("│  ⚠️  PRIMARY BOTTLENECK: COMPUTE-BOUND                │");
                2'b01: $display("│  ⚠️  PRIMARY BOTTLENECK: MEMORY-BOUND                 │");
                2'b10: $display("│  ⚠️  PRIMARY BOTTLENECK: INTERCONNECT-BOUND           │");
                2'b11: $display("│  ⚠️  PRIMARY BOTTLENECK: SCHEDULER-BOUND              │");
            endcase
            $display("│  Stall Cycles from Bottleneck: %0d", bottleneck_stall_cycles);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  CACHE PERFORMANCE                                      │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  L1 Hits:                   %0d", cache_l1_hits);
            $display("│  L1 Misses:                 %0d", cache_l1_misses);
            $display("│  L1 Hit Rate:               %0d%%", cache_l1_hit_rate_pct);
            $display("│  L2 Hits:                   %0d", cache_l2_hits);
            $display("│  L2 Misses:                 %0d", cache_l2_misses);
            $display("│  L2 Hit Rate (of L1 miss):  %0d%%", cache_l2_hit_rate_pct);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  INTERCONNECT (NoC) PERFORMANCE                         │");
            $display("├─────────────────────────────────────────────────────────┤");
            $display("│  Packets Routed:            %0d", noc_packets_routed);
            $display("│  Contention Cycles:         %0d", noc_contention_cycles);
            $display("│  Congestion Level:          %0d / 256", noc_congestion_level);
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
            
            // Recommendations
            $display("┌─────────────────────────────────────────────────────────┐");
            $display("│  OPTIMIZATION RECOMMENDATIONS                           │");
            $display("├─────────────────────────────────────────────────────────┤");
            
            if (stall_queue_contention_pct > 40) begin
                $display("│  🔴 HIGH queue contention - Consider:                    │");
                $display("│     • Dynamic priority scheduling                       │");
                $display("│     • Load balancing across cores                       │");
                $display("│     • Queue-aware dispatch                              │");
            end
            
            if (stall_cache_misses_pct > 30) begin
                $display("│  🟡 High cache miss rate - Consider:                     │");
                $display("│     • Increase L1/L2 cache size                         │");
                $display("│     • Improve data locality                             │");
                $display("│     • Prefetching                                       │");
            end
            
            if (overall_utilization_pct < 50) begin
                $display("│  🟡 Low core utilization - Consider:                     │");
                $display("│     • Better work distribution                          │");
                $display("│     • Activate more cores                               │");
                $display("│     • Reduce idle time                                  │");
            end
            
            if (primary_bottleneck == 2'b11) begin
                $display("│  🔴 Scheduler is bottleneck - UPGRADE to v2:             │");
                $display("│     • Aging mechanism (prevent starvation)              │");
                $display("│     • Round-robin within priority classes               │");
                $display("│     • Dependency-aware scheduling                       │");
            end
            
            $display("└─────────────────────────────────────────────────────────┘");
            $display("");
        end
    endtask

endmodule
