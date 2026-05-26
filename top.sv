`timescale 1ns / 1ps

// verilator lint_off DECLFILENAME
// verilator lint_off PINCONNECTEMPTY

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

// ========================================================================
// AURORA Interfaces and Assertions
// Note: Files are included via iv_compile.f file list
// ========================================================================

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Top-Level Processor
// Module Name: aurora_172_top
// 
// Description:
//   Top-level module untuk AURORA-172 Hybrid Compute Architecture
//   Mengintegrasikan G-Core, H-Core, A-Core, NPU, Memory Fabric, dan Interconnect
//
// Target Devices: FPGA (prototype) / ASIC (production)
// Tool Versions: Vivado 2025.2 / Verilator 5.0+
//////////////////////////////////////////////////////////////////////////////////

module aurora_172_top #(
    parameter DATA_WIDTH        = `AURORA_DATA_WIDTH,
    parameter ADDR_WIDTH        = `AURORA_ADDR_WIDTH,
    parameter INST_WIDTH        = `AURORA_INST_WIDTH,
    parameter NUM_G_CORES       = `AURORA_NUM_G_CORES,
    parameter NUM_H_CORES       = 32,
    parameter NUM_A_CORES       = 64,
    parameter NUM_NPU_CLUSTERS  = 8,
    parameter CACHE_LINE_WIDTH  = 512,  // UPGRADED: 256→512 bit memory bus (2x bandwidth)
    parameter MAX_CLOCK_FREQ    = 6000  // 6 GHz target
)(
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Gaming interface
    input  wire [DATA_WIDTH-1:0]        game_cmd_addr,
    input  wire [31:0]                  game_cmd_data,
    input  wire                         game_cmd_valid,
    output wire                         game_cmd_ready,
    output wire [DATA_WIDTH-1:0]        game_result,
    output wire                         game_result_valid,
    
    // AI interface
    input  wire [DATA_WIDTH-1:0]        ai_cmd_addr,
    input  wire [63:0]                  ai_cmd_data,
    input  wire                         ai_cmd_valid,
    output wire                         ai_cmd_ready,
    output wire [DATA_WIDTH-1:0]        ai_result,
    output wire                         ai_result_valid,
    input  wire                         ai_result_ready,  // CRITICAL: Add ready signal for handshake
    
    // System interface
    input  wire                         sys_interrupt,
    input  wire [15:0]                  sys_power_mode,
    output wire [31:0]                  sys_status,
    
    // Memory interface (172-bit bus)
    output wire [CACHE_LINE_WIDTH-1:0]  mem_addr,
    output wire                         mem_rd_en,
    output wire                         mem_wr_en,
    input  wire [CACHE_LINE_WIDTH-1:0]  mem_rd_data,
    output wire [CACHE_LINE_WIDTH-1:0]  mem_wr_data,
    input  wire                         mem_ready,
    
    // Debug interface
    output wire [63:0]                  perf_counter_g,
    output wire [63:0]                  perf_counter_a,
    output wire [63:0]                  perf_counter_npu,

    // Scheduler debug interface
    output wire [63:0]                  sched_total_dispatched,
    output wire [63:0]                  sched_total_completed,
    output wire [63:0]                  sched_total_stalled,
    output wire [63:0]                  sched_stall_resource_wait,
    output wire [63:0]                  sched_stall_queue_contention,
    output wire [31:0]                  sched_queue_depth,
    output wire [31:0]                  sched_max_queue_depth,
    output wire [31:0]                  sched_conflict_count,
    output wire [7:0]                   sched_gaming_priority,
    output wire [7:0]                   sched_ai_priority,
    output wire [7:0]                   sched_npu_priority,
    output wire [31:0]                  sched_aging_tasks,
    output wire [31:0]                  sched_rr_rotations,
    output wire [31:0]                  sched_queue_avoidance,
    output wire [31:0]                  sched_watchdog_resets,

    // FAIRNESS: Task distribution monitoring
    output wire [31:0]                  sched_g_tasks_completed,
    output wire [31:0]                  sched_a_tasks_completed,
    output wire [31:0]                  sched_npu_tasks_completed,
    output wire [31:0]                  sched_fairness_violations,

    // Ring bus interface untuk scheduler load balancing
    output wire [31:0]                  ring_bus_g_packets,
    output wire [31:0]                  ring_bus_a_packets,
    output wire [31:0]                  ring_bus_contention,
    output wire                         ring_bus_congested,

    // Back-pressure monitoring (v3)
    output wire [31:0]                  sched_bp_queue_full_rejections,
    output wire [31:0]                  sched_bp_timeout_stalls,
    output wire [31:0]                  sched_bp_actual_accepts,
    
    // ADMISSION CONTROL (NEW)
    output wire [31:0]                  sched_admission_rejections,

    // FIX: Hazard classification counters (NEW)
    output wire [31:0]                  sched_hazard_raw,         // RAW hazards
    output wire [31:0]                  sched_hazard_war,         // WAR hazards
    output wire [31:0]                  sched_hazard_waw,         // WAW hazards
    output wire [31:0]                  sched_hazard_structural,  // Structural hazards
    output wire [31:0]                  sched_hazard_dependency,  // Data dependency waits
    output wire [31:0]                  sched_hazard_dependency_stalls,  // NEW: Actual stall count
    
    // NEW: Per-core utilization
    output wire [31:0]                  sched_g_core_busy_cycles,
    output wire [31:0]                  sched_a_core_busy_cycles,
    output wire [31:0]                  sched_n_core_busy_cycles,
    output wire [31:0]                  sched_total_sim_cycles,

    // Debug: Core busy signals
    output wire                         g_core_busy,
    output wire                         a_core_busy,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: Power Monitor (Intel RAPL) debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire [63:0]                  pm_energy_g_core_uj,
    output wire [63:0]                  pm_energy_a_core_uj,
    output wire [63:0]                  pm_energy_npu_uj,  // NEW: NPU energy output
    output wire [63:0]                  pm_energy_total_uj,
    output wire [DATA_WIDTH-1:0]        pm_avg_g_power_mw,
    output wire [DATA_WIDTH-1:0]        pm_avg_a_power_mw,
    output wire [DATA_WIDTH-1:0]        pm_avg_npu_power_mw,  // NEW: NPU power output
    output wire [DATA_WIDTH-1:0]        pm_avg_total_power_mw,
    output wire                         pm_pl1_exceeded,
    output wire                         pm_pl2_exceeded,
    output wire                         pm_throttle_req,
    output wire [31:0]                  pm_pl1_violations,
    output wire [31:0]                  pm_pl2_violations,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: V-Cache debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire                         vc_hit,
    output wire                         vc_miss,
    output wire [7:0]                   vc_latency,
    output wire [31:0]                  vc_hits,
    output wire [31:0]                  vc_misses,
    output wire [31:0]                  vc_evictions,
    output wire [31:0]                  vc_promotions,
    output wire [7:0]                   vc_hit_rate_pct,
    output wire [31:0]                  vc_capacity_used_mb,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: Speed Shift / HWP (Intel) debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire [3:0]                   hwp_g_p_state,
    output wire [3:0]                   hwp_a_p_state,
    output wire [3:0]                   hwp_h_p_state,
    output wire [3:0]                   hwp_npu_p_state,
    output wire [DATA_WIDTH-1:0]        hwp_g_freq_mhz,
    output wire [DATA_WIDTH-1:0]        hwp_a_freq_mhz,
    output wire [DATA_WIDTH-1:0]        hwp_h_freq_mhz,
    output wire [DATA_WIDTH-1:0]        hwp_npu_freq_mhz,
    output wire                         hwp_active,
    output wire                         hwp_sw_override,
    output wire [31:0]                  hwp_transitions,
    output wire [31:0]                  hwp_sw_overrides,
    output wire [31:0]                  hwp_thermal_limits,
    output wire [31:0]                  hwp_response_cycles,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: Hardware Prefetcher (Intel) debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire [3:0]                   pf_stream_active,
    output wire [15:0]                  pf_stream0_stride,
    output wire [15:0]                  pf_stream1_stride,
    output wire [15:0]                  pf_stream2_stride,
    output wire [15:0]                  pf_stream3_stride,
    output wire [31:0]                  pf_total_requests,
    output wire [31:0]                  pf_useful_count,
    output wire [31:0]                  pf_useless_count,
    output wire [31:0]                  pf_coverage,
    output wire [31:0]                  pf_alloc_streams,
    output wire [31:0]                  pf_dealloc_streams,
    output wire [7:0]                   pf_utilization_pct,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: MOESIX-GA Coherency debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire [31:0]                  mesi_invalidations,
    output wire [31:0]                  mesi_upgrades,
    output wire [31:0]                  mesi_writebacks,
    output wire [31:0]                  mesi_shared_grants,
    output wire [31:0]                  mesi_forwards_served,
    output wire [31:0]                  mesi_gaming_hits,
    output wire [31:0]                  mesi_ai_prefetches,
    output wire [31:0]                  mesi_owned_trans,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: CET Anti-Cheat (Intel) debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire                         cet_violation,
    output wire [3:0]                   cet_violation_type,
    output wire [ADDR_WIDTH-1:0]        cet_violation_pc,
    output wire                         cet_shadow_active,
    output wire [7:0]                   cet_shadow_depth,
    output wire                         cet_state_integrity_ok,
    output wire [31:0]                   cet_branch_checks,
    output wire [31:0]                   cet_return_checks,
    output wire [31:0]                   cet_rop_violations,
    output wire [31:0]                   cet_jop_violations,
    output wire [31:0]                   cet_state_violations,

    // ─────────────────────────────────────────────────────────────
    // ATM FEATURES: Ring Bus + Chiplet (AMD) debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire [31:0]                  ring_g_packets,
    output wire [31:0]                  ring_a_packets,
    output wire [31:0]                  ring_h_packets,
    output wire [31:0]                  ring_npu_packets,
    output wire [31:0]                  chiplet_total_packets,
    output wire [31:0]                  chiplet_local_hits,

    // A/B Test: SQ vs MQ comparison outputs
    output wire [63:0]                  sq_sched_dispatched_out,
    output wire [63:0]                  sq_sched_completed_out,
    output wire [63:0]                  sq_sched_total_stalled_out,
    output wire [31:0]                  sq_sched_queue_depth_out,
    output wire [31:0]                  sq_sched_bp_actual_accepts_out,
    output wire [31:0]                  mq_sched_dispatched_out,
    output wire [63:0]                  mq_sched_completed_out,
    output wire [63:0]                  mq_sched_total_stalled_out,
    output wire [31:0]                  mq_sched_queue_depth_out,
    output wire [31:0]                  mq_sched_bp_actual_accepts_out,
    output wire                         sched_select_out,
    
    // NEW: Hybrid Queue stage counters (v4.0)
    output wire [31:0]                  mq_sched_hq_fq_enqueued_out,
    output wire [31:0]                  mq_sched_hq_dq_decoded_out,
    output wire [31:0]                  mq_sched_hq_eq_dispatched_out,
    output wire [31:0]                  mq_sched_hq_rq_committed_out,
    output wire [31:0]                  mq_sched_hq_cq_completed_out
);

    // Internal signals - G-Core interface
    wire [NUM_G_CORES-1:0]              g_core_busy_internal;
    wire [NUM_G_CORES-1:0]              g_core_complete;
    wire [DATA_WIDTH*NUM_G_CORES-1:0]   g_core_result;

    // Internal signals - H-Core interface
    wire [NUM_H_CORES-1:0]              h_core_busy;
    wire [NUM_H_CORES-1:0]              h_core_busy_internal;
    wire [NUM_H_CORES-1:0]              h_core_complete;

    // Internal signals - A-Core interface
    wire [NUM_A_CORES-1:0]              a_core_busy_internal;
    wire [NUM_A_CORES-1:0]              a_core_complete;
    wire [DATA_WIDTH*NUM_A_CORES-1:0]   a_core_result;
    wire [NUM_A_CORES-1:0]              a_core_result_valid;
    wire [NUM_A_CORES-1:0]              a_core_cmd_ready;
    wire                                a_core_result_ready_int;
    
    // Internal signals - NPU interface
    wire [NUM_NPU_CLUSTERS-1:0]         npu_busy;
    wire [NUM_NPU_CLUSTERS-1:0]         npu_busy_internal;
    wire [NUM_NPU_CLUSTERS-1:0]         npu_complete;
    wire [DATA_WIDTH*NUM_NPU_CLUSTERS-1:0] npu_result;
    
    // Internal signals - RT Engine
    wire                                rt_busy;
    wire                                rt_complete;
    wire [DATA_WIDTH-1:0]               rt_result;
    
    // Per-module fabric request signals for arbiter
    wire [ADDR_WIDTH-1:0]               fabric_addr_a  [0:NUM_A_CORES-1];
    wire                                fabric_rd_en_a [0:NUM_A_CORES-1];
    wire                                fabric_wr_en_a [0:NUM_A_CORES-1];
    wire [CACHE_LINE_WIDTH-1:0]         fabric_wr_data_a [0:NUM_A_CORES-1];

    wire [ADDR_WIDTH-1:0]               fabric_addr_h  [0:NUM_H_CORES-1];
    wire                                fabric_rd_en_h [0:NUM_H_CORES-1];
    wire                                fabric_wr_en_h [0:NUM_H_CORES-1];
    wire [CACHE_LINE_WIDTH-1:0]         fabric_wr_data_h [0:NUM_H_CORES-1];

    wire [ADDR_WIDTH-1:0]               fabric_addr_n  [0:NUM_NPU_CLUSTERS-1];
    wire                                fabric_rd_en_n [0:NUM_NPU_CLUSTERS-1];
    wire                                fabric_wr_en_n [0:NUM_NPU_CLUSTERS-1];
    wire [CACHE_LINE_WIDTH-1:0]         fabric_wr_data_n [0:NUM_NPU_CLUSTERS-1];

    wire [ADDR_WIDTH-1:0]               fabric_addr_r  [0:NUM_RT_ENGINES-1];
    wire                                fabric_rd_en_r [0:NUM_RT_ENGINES-1];
    wire                                fabric_wr_en_r [0:NUM_RT_ENGINES-1];
    wire [CACHE_LINE_WIDTH-1:0]         fabric_wr_data_r [0:NUM_RT_ENGINES-1];

    // Resolved fabric bus (single driver from arbiter)
    logic [ADDR_WIDTH-1:0]               fabric_addr;
    logic                                fabric_rd_en;
    logic                                fabric_wr_en;
    logic [CACHE_LINE_WIDTH-1:0]         fabric_wr_data;
    wire [CACHE_LINE_WIDTH-1:0]          fabric_rd_data;
    wire                                 fabric_ready;

    // ─────────────────────────────────────────────────────────────
    // Cache Hierarchy signals (L1 → L2 → Memory Fabric) - 512-BIT BUS
    // ─────────────────────────────────────────────────────────────
    // G-Core L1 → L2 interface (FIXED: Add per-core signals to prevent multi-driver conflict)
    wire [ADDR_WIDTH-1:0]               g_l1_l2_addr [0:NUM_G_CORES-1];
    wire [CACHE_LINE_WIDTH-1:0]         g_l1_l2_wr_data [0:NUM_G_CORES-1];
    wire                                g_l1_l2_rd_en [0:NUM_G_CORES-1];
    wire                                g_l1_l2_wr_en [0:NUM_G_CORES-1];
    wire [CACHE_LINE_WIDTH-1:0]         g_l1_l2_rd_data [0:NUM_G_CORES-1];  // Output to cores
    wire                                g_l1_l2_ready [0:NUM_G_CORES-1];     // Output to cores
    
    // Multiplexed L2 interface (connected to cache_hierarchy/L2 banks)
    wire [ADDR_WIDTH-1:0]               g_l1_l2_addr_mux;
    wire [CACHE_LINE_WIDTH-1:0]         g_l1_l2_wr_data_mux;
    wire                                g_l1_l2_rd_en_mux;
    wire                                g_l1_l2_wr_en_mux;
    wire [CACHE_LINE_WIDTH-1:0]         g_l1_l2_rd_data_mux;  // Driven by L2 bank
    wire                                g_l1_l2_ready_mux;    // Driven by L2 bank
    logic                               g_l1_l2_ready_any;    // Any G-Core L1/L2 ready (OR of all)

    // A-Core L1 → L2 interface
    wire [ADDR_WIDTH-1:0]               a_l1_l2_addr;
    wire [CACHE_LINE_WIDTH-1:0]         a_l1_l2_wr_data;   // 512-bit
    wire                                a_l1_l2_rd_en;
    wire                                a_l1_l2_wr_en;
    wire [CACHE_LINE_WIDTH-1:0]         a_l1_l2_rd_data;   // 512-bit
    wire                                a_l1_l2_ready;

    // A-Core L2 bank read data/ready (port 1 of each L2 bank for A-core path)
    localparam NUM_L2_BANKS = 4;
    wire [NUM_L2_BANKS*CACHE_LINE_WIDTH-1:0] a_l2_bank_rd_data;
    wire [NUM_L2_BANKS-1:0]                  a_l2_bank_ready;

    // Per-bank memory fabric request signals (resolves MULTIDRIVEN via mux)
    wire [ADDR_WIDTH-1:0]               l2_bank_mem_addr [0:NUM_L2_BANKS-1];
    wire [CACHE_LINE_WIDTH-1:0]         l2_bank_mem_wr_data [0:NUM_L2_BANKS-1];

    // L2 → Memory Fabric interface (muxed from per-bank signals)
    wire [ADDR_WIDTH-1:0]               l2_mem_addr;
    wire [CACHE_LINE_WIDTH-1:0]         l2_mem_wr_data;    // 512-bit
    wire                                l2_mem_rd_en;
    wire                                l2_mem_wr_en;
    wire [CACHE_LINE_WIDTH-1:0]         l2_mem_rd_data;    // 512-bit
    wire                                l2_mem_ready;

    // =========================================================================
    // Internal signals and registers
    // =========================================================================
    
    // Clock and reset
    wire clk_internal;
    wire rst_n_internal;
    
    // CRITICAL FIX: Reset synchronization to prevent metastability (2-flop synchronizer)
    reg rst_sync_1, rst_sync_2;
    wire rst_n_sync;
    
    // 2-flop reset synchronizer: deasserts synchronously, asserts asynchronously
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_sync_1 <= 1'b0;
            rst_sync_2 <= 1'b0;
        end else begin
            rst_sync_1 <= 1'b1;
            rst_sync_2 <= rst_sync_1;
        end
    end
    assign rst_n_sync = rst_sync_2;
    
    // ========================================================================
    // CLOCK DOMAIN CROSSING (CDC) SYNCHRONIZERS
    // ========================================================================
    
    // CDC bypass: all signals are in the same clock domain (no CDC needed)
    // (sync signals removed — unused)

    // ========================================================================
    // AURORA Interface Instances
    // ========================================================================
    
    // Memory interface untuk memory fabric monitoring
    // Note: Interface instances declared for future use
    // Currently using direct signal connections for assertions
    
    
    // ========================================================================
    // Memory Assertions Instance
    // ========================================================================
    
    // Cache hierarchy signals untuk assertions
    wire [1:0]                       mesi_state;
    wire                             l1_hit, l2_hit, l3_hit;
    wire [31:0]                      total_requests, cache_hits, cache_misses;
    
    // ========================================================================
    // Cache Signal Monitoring untuk Assertions
    // ========================================================================
    
    // Simple cache hit detection (L1/L2 ready indicates hit)
    assign l1_hit = g_l1_l2_ready_any || a_l1_l2_ready;
    assign l2_hit = l2_mem_ready;  // L2 ready indicates L2 hit
    assign l3_hit = 1'b0;          // No L3 cache in this design
    
    // MESI state machine: Invalid(00)→Exclusive(10) on read miss, Exclusive→Modified(11) on write hit
    localparam MESI_INVALID    = 2'b00;
    localparam MESI_SHARED     = 2'b01;
    localparam MESI_EXCLUSIVE  = 2'b10;
    localparam MESI_MODIFIED   = 2'b11;
    reg [1:0]                       mesi_state_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mesi_state_reg <= MESI_INVALID;
        end else begin
            unique case (mesi_state_reg)
                MESI_INVALID: begin
                    if (l2_mem_rd_en && l2_mem_ready)
                        mesi_state_reg <= MESI_EXCLUSIVE;  // Read miss → Exclusive
                    else if (l2_mem_wr_en && l2_mem_ready)
                        mesi_state_reg <= MESI_MODIFIED;   // Write miss → Modified
                end
                MESI_EXCLUSIVE: begin
                    if (l2_mem_wr_en && l2_mem_ready)
                        mesi_state_reg <= MESI_MODIFIED;   // Write hit → Modified
                    else if (l2_mem_rd_en && !l2_mem_ready)
                        mesi_state_reg <= MESI_SHARED;     // Snoop read → Shared
                end
                MESI_SHARED: begin
                    if (l2_mem_wr_en && l2_mem_ready)
                        mesi_state_reg <= MESI_MODIFIED;   // Write hit → Modified
                end
                MESI_MODIFIED: begin
                    if (l2_mem_rd_en && l2_mem_ready && !l2_mem_wr_en)
                        mesi_state_reg <= MESI_SHARED;     // Snoop read → Shared
                end
                default: mesi_state_reg <= MESI_INVALID;
            endcase
        end
    end
    assign mesi_state = mesi_state_reg;
    
    // Performance counters
    reg [31:0]                      total_requests_reg;
    reg [31:0]                      cache_hits_reg;
    reg [31:0]                      cache_misses_reg;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_requests_reg <= 32'b0;
            cache_hits_reg <= 32'b0;
            cache_misses_reg <= 32'b0;
        end else begin
            // Count total requests
            if (l2_mem_rd_en || l2_mem_wr_en) begin
                total_requests_reg <= total_requests_reg + 1;
            end
            
            // Count hits (L1/L2 hits) or misses exclusively — never both
            if ((l2_mem_rd_en || l2_mem_wr_en)) begin
                if (l1_hit || l2_hit) begin
                    cache_hits_reg <= cache_hits_reg + 1;
                end else begin
                    cache_misses_reg <= cache_misses_reg + 1;
                end
            end
        end
    end
    
    assign total_requests = total_requests_reg;
    assign cache_hits = cache_hits_reg;
    assign cache_misses = cache_misses_reg;
    
    // Memory assertions untuk memory fabric verification
    memory_assertions #(
        .DATA_WIDTH(CACHE_LINE_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_LINE_WIDTH(CACHE_LINE_WIDTH)
    ) u_memory_assertions (
        .clk(clk),
        .rst_n(rst_n_sync),
        
        // Memory interface signals
        .mem_addr(l2_mem_addr),
        .mem_rd_en(l2_mem_rd_en),
        .mem_wr_en(l2_mem_wr_en),
        .mem_wr_data(l2_mem_wr_data),
        .mem_ready(l2_mem_ready),
        
        // Cache signals (simplified for top-level)
        .l1_hit(l1_hit),
        .l2_hit(l2_hit),
        .l3_hit(l3_hit),
        .cache_state(mesi_state),
        
        // Performance signals
        .total_requests(total_requests),
        .cache_hits(cache_hits),
        .cache_misses(cache_misses)
    );

    // ─────────────────────────────────────────────────────────────
    // Global Scheduler signals (MQ = active scheduler by default)
    // ─────────────────────────────────────────────────────────────
    // MQ internal signals
    wire [ADDR_WIDTH-1:0]               mq_g_core_cmd_addr;
    wire [31:0]                         mq_g_core_cmd_data;
    wire                                mq_g_core_cmd_valid;
    wire                                mq_g_core_cmd_ready;
    wire [ADDR_WIDTH-1:0]               mq_a_core_cmd_addr;
    wire [63:0]                         mq_a_core_cmd_data;
    wire                                mq_a_core_cmd_valid;
    wire                                mq_a_core_cmd_ready;
    wire                                mq_npu_dispatch_valid;
    wire                                mq_npu_dispatch_ready;
    wire                                mq_g_task_ready;
    wire [DATA_WIDTH-1:0]               mq_g_task_result;
    wire                                mq_g_task_result_valid;
    wire                                mq_a_task_ready;
    wire [DATA_WIDTH-1:0]               mq_a_task_result;
    wire                                mq_a_task_result_valid;
    wire                                mq_npu_task_ready;
    wire [DATA_WIDTH-1:0]               mq_npu_task_result;
    wire                                mq_npu_task_result_valid;
    wire [63:0]                         mq_sched_dispatched;
    wire [63:0]                         mq_sched_completed;
    wire [63:0]                         mq_sched_total_stalled;
    wire [63:0]                         mq_sched_stall_resource_wait;
    wire [63:0]                         mq_sched_stall_queue_contention;
    wire [31:0]                         mq_sched_queue_depth;
    wire [31:0]                         mq_sched_max_queue_depth;
    wire [31:0]                         mq_sched_conflict_count;
    wire [7:0]                          mq_sched_gaming_priority;
    wire [7:0]                          mq_sched_ai_priority;
    wire [7:0]                          mq_sched_npu_priority;
    wire [31:0]                         mq_sched_aging_tasks;
    wire [31:0]                         mq_sched_rr_rotations;
    wire [31:0]                         mq_sched_queue_avoidance;
    wire [31:0]                         mq_sched_watchdog_resets;
    wire [31:0]                         mq_sched_bp_queue_full_rejections;
    wire [31:0]                         mq_sched_bp_timeout_stalls;
    wire [31:0]                         mq_sched_bp_actual_accepts;
    wire [31:0]                         mq_sched_admission_rejections;
    wire [31:0]                         sq_sched_hazard_raw;
    wire [31:0]                         sq_sched_hazard_war;
    wire [31:0]                         sq_sched_hazard_waw;
    
    // FAIRNESS: Task distribution monitoring
    wire [31:0]                         sq_sched_g_tasks_completed;
    wire [31:0]                         sq_sched_a_tasks_completed;
    wire [31:0]                         sq_sched_npu_tasks_completed;
    wire [31:0]                         sq_sched_fairness_violations;
    wire [31:0]                         mq_sched_hazard_structural;
    wire [31:0]                         mq_sched_hazard_dependency;
    wire [31:0]                         mq_sched_hazard_dependency_stalls;
    wire [31:0]                         mq_sched_g_core_busy_cycles;
    wire [31:0]                         mq_sched_a_core_busy_cycles;
    wire [31:0]                         mq_sched_n_core_busy_cycles;
    wire [31:0]                         mq_sched_total_sim_cycles;
    
    // NEW: Hybrid Queue stage counters (v4.0)
    wire [31:0]                         mq_sched_hq_fq_enqueued;
    wire [31:0]                         mq_sched_hq_dq_decoded;
    wire [31:0]                         mq_sched_hq_eq_dispatched;
    wire [31:0]                         mq_sched_hq_rq_committed;
    wire [31:0]                         mq_sched_hq_cq_completed;

    // MQ hazard and control wires
    wire                                mq_a_core_result_ready;
    wire [31:0]                         mq_sched_hazard_raw;
    wire [31:0]                         mq_sched_hazard_war;
    wire [31:0]                         mq_sched_hazard_waw;

    // MUX output: selected scheduler signals (based on sched_select)
    wire [ADDR_WIDTH-1:0]               sched_g_core_cmd_addr;
    wire [31:0]                         sched_g_core_cmd_data;
    wire                                sched_g_core_cmd_valid;
    wire                                sched_g_core_cmd_ready;
    wire [ADDR_WIDTH-1:0]               sched_a_core_cmd_addr;
    wire [63:0]                         sched_a_core_cmd_data;
    wire                                sched_a_core_cmd_valid;
    wire                                sched_a_core_cmd_ready;
    wire                                sched_npu_dispatch_valid;

    // Task ready MUX internal signals (need declaration)
    wire                                g_task_ready_int;
    wire                                a_task_ready_int;
    wire                                npu_task_ready_int;

    // Note: sched_total_dispatched, sched_total_completed, etc. are module output ports (declared above)

    // =========================================================================
    // G-CORE Array (16 cores untuk Gaming)
    // =========================================================================
    wire                        g0_cmd_ready;
    wire                        g0_busy;
    wire                        g0_complete;
    wire [DATA_WIDTH-1:0]       g0_result;
    wire                        g0_error_flag;    // NEW: Error flag
    wire [7:0]                  g0_error_code;    // NEW: Error code
    wire                        g0_error_valid;   // NEW: Error valid pulse

    // G-Core scheduler control signals (MOVED UP)
    reg [3:0] g_core_rr_index;  // Round-robin pointer
    reg g_dispatch_active;           // Dispatch is active (only asserted for 1 cycle)

    // G-Core #1 (parallel instance for throughput)
    wire [ADDR_WIDTH-1:0]       g1_cmd_addr;
    wire [31:0]                 g1_cmd_data;
    wire                        g1_cmd_valid;
    wire                        g1_cmd_ready;
    wire [DATA_WIDTH-1:0]       g1_result;
    wire                        g1_complete;
    wire                        g1_busy;
    wire                        g1_error_flag;
    wire [7:0]                  g1_error_code;
    wire                        g1_error_valid;

    // G-Core #0 (master - uses edge-triggered dispatch)
    g_core #(
        .CORE_ID(0),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .INST_WIDTH(INST_WIDTH)
    ) u_g_core_0 (
        .clk(clk),
        .rst_n(rst_n_sync),
        // COMPLETE FIX: Only receives command if selected AND on first dispatch cycle
        .cmd_addr(sched_g_core_cmd_addr),
        .cmd_data(sched_g_core_cmd_data),
        .cmd_valid((g_core_selected_idx == 0) && g_core_selected_valid),
        .cmd_ready(sched_g_core_cmd_ready),
        .result(g0_result),
        .result_valid(g0_complete),
        .busy(g0_busy),
        .error_flag(g0_error_flag),
        .error_code(g0_error_code),
        .error_valid(g0_error_valid),
        .l2_addr(g_l1_l2_addr[0]),
        .l2_wr_data(g_l1_l2_wr_data[0]),
        .l2_rd_en(g_l1_l2_rd_en[0]),
        .l2_wr_en(g_l1_l2_wr_en[0]),
        .l2_rd_data(g_l1_l2_rd_data[0]),
        .l2_ready(g_l1_l2_ready[0]),
        // Fabric interface (unused, tied off in G-Core)
        .fabric_addr(),
        .fabric_rd_en(),
        .fabric_wr_en(),
        .fabric_rd_data(),
        .fabric_wr_data(),
        .fabric_ready()
    );

    // G-Core #1 (parallel instance - same command, load balanced)
    g_core #(
        .CORE_ID(1),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .INST_WIDTH(INST_WIDTH)
    ) u_g_core_1 (
        .clk(clk),
        .rst_n(rst_n_sync),
        .cmd_addr(g1_cmd_addr),
        .cmd_data(g1_cmd_data),
        .cmd_valid(g1_cmd_valid),
        .cmd_ready(g1_cmd_ready),
        .result(g1_result),
        .result_valid(g1_complete),
        .busy(g1_busy),
        // Error/Exception interface (NEW)
        .error_flag(g1_error_flag),
        .error_code(g1_error_code),
        .error_valid(g1_error_valid),
        // Expose L1→L2 interface
        .l2_addr(g_l1_l2_addr[1]),
        .l2_wr_data(g_l1_l2_wr_data[1]),
        .l2_rd_en(g_l1_l2_rd_en[1]),
        .l2_wr_en(g_l1_l2_wr_en[1]),
        .l2_rd_data(g_l1_l2_rd_data[1]),
        .l2_ready(g_l1_l2_ready[1]),
        // Fabric interface (unused, tied off in G-Core)
        .fabric_addr(),
        .fabric_rd_en(),
        .fabric_wr_en(),
        .fabric_rd_data(),
        .fabric_wr_data(),
        .fabric_ready()
    );

    // Load Balancer: G1 ENABLED with edge-triggered dispatch
    // FIX: Edge-triggered dispatch latch prevents both cores receiving same command
    // when sched_g_core_cmd_valid is held >1 cycle
    //
    // Solution: g_dispatch_active signal fires only on rising edge of sched_g_core_cmd_valid
    // and stays low until sched_g_core_cmd_valid goes low again
    //
    // G-Core selection logic (line 784) now uses g_dispatch_active to ensure
    // only one dispatch occurs per command, preventing race condition
    //
    // Load Balancer: G1 - signals assigned at line ~944 with RR selector
    // G1 ready comes from G-Core module (line ~708)

    // A-Core result: Direct route ke testbench (bypass scheduler)
    // Karena A-Core command sudah direct-connect (MUX), result juga harus langsung
    // FIX: Route a0_result langsung ke ai_result output
    wire [DATA_WIDTH-1:0] ai_result_direct;
    wire ai_result_valid_direct;
    wire [DATA_WIDTH-1:0] a0_result;
    wire a0_busy;
    wire a0_complete;
    wire a0_result_valid;  // NEW: Separate result valid from completion
    assign ai_result_direct = a0_result;
    assign ai_result_valid_direct = a0_complete;

    // Scheduler AI task ready signal - a_task_ready_int declared above (line 357)

    // FIX: ai_cmd_ready assigned at line 775 (from scheduler, not direct A-Core)
    // REMOVED: assign ai_cmd_ready = a0_cmd_ready; (was conflicting with scheduler path)

    // G-Core #1 to #15 (workers) - FIXED MULTI-DRIVER IMPLEMENTATION
    wire [NUM_G_CORES-1:0] g_core_cmd_ready;
    
    // G-Core command arbitration - FIXED: No multi-driver
    reg [ADDR_WIDTH-1:0]    g_core_selected_addr;
    reg [31:0]              g_core_selected_data;
    reg                     g_core_selected_valid;
    reg [$clog2(NUM_G_CORES)-1:0] g_core_selected_idx;
    
    // Command selection logic - only ONE core gets command
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_core_selected_addr <= {ADDR_WIDTH{1'b0}};
            g_core_selected_data <= 32'b0;
            g_core_selected_valid <= 1'b0;
            g_core_selected_idx <= 0;
        end else begin
            // Find next available core using round-robin
            // FIX: Use g_dispatch_edge (combinational, same-cycle) instead of g_dispatch_active (registered, one-cycle lag)
            if (sched_g_core_cmd_valid && !g_core_selected_valid && g_dispatch_edge) begin
                integer found_core;
                found_core = -1;

                // Search for available core starting from current index
                for (int i = 0; i < NUM_G_CORES && found_core == -1; i++) begin
                    integer candidate;
                    candidate = (g_core_rr_index + i) % NUM_G_CORES;
                    if (!g_core_busy_internal[candidate]) begin
                        found_core = candidate;
                    end
                end

                if (found_core != -1) begin
                    g_core_selected_addr <= sched_g_core_cmd_addr;
                    g_core_selected_data <= sched_g_core_cmd_data;
                    g_core_selected_valid <= 1'b1;
                    g_core_selected_idx <= found_core;
                    g_core_rr_index <= (found_core + 1) % NUM_G_CORES;
                end
            end else begin
                g_core_selected_valid <= 1'b0;
            end
        end
    end

    genvar g_idx;
    generate
        // FIXED: Each core gets command ONLY when selected
        for (g_idx = 2; g_idx < NUM_G_CORES; g_idx = g_idx + 1) begin : g_core_array
            // CRITICAL FIX: Only selected core receives command
            wire g_core_per_core_valid = (g_idx == g_core_selected_idx) &&
                                         g_core_selected_valid;
            
            g_core #(
                .CORE_ID(g_idx),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .INST_WIDTH(INST_WIDTH)
            ) u_g_core (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Command interface - only if this core is selected
                .cmd_addr(g_core_selected_addr),
                .cmd_data(g_core_selected_data),
                .cmd_valid(g_core_per_core_valid),
                .cmd_ready(g_core_cmd_ready[g_idx]),
                .result(g_core_result[DATA_WIDTH*(g_idx+1)-1:DATA_WIDTH*g_idx]),
                .result_valid(g_core_complete[g_idx]),
                .busy(g_core_busy_internal[g_idx]),
                // Error/Exception interface
                .error_flag(),
                .error_code(),
                .error_valid(),
                // Expose L1→L2 interface (FIXED: Use per-core signals)
                .l2_addr(g_l1_l2_addr[g_idx]),
                .l2_wr_data(g_l1_l2_wr_data[g_idx]),
                .l2_rd_en(g_l1_l2_rd_en[g_idx]),
                .l2_wr_en(g_l1_l2_wr_en[g_idx]),
                .l2_rd_data(g_l1_l2_rd_data[g_idx]),
                .l2_ready(g_l1_l2_ready[g_idx]),
                // Fabric interface (unused, tied off in G-Core)
                .fabric_addr(),
                .fabric_rd_en(),
                .fabric_wr_en(),
                .fabric_rd_data(),
                .fabric_wr_data(),
                .fabric_ready()
            );
        end
    endgenerate

    // FINAL FIX: Use direct G-Core connection (Ring Bus disabled)
    assign g_core_result[DATA_WIDTH-1:0] = g0_result;
    assign g_core_busy_internal[0] = g0_busy;
    assign g_core_complete[0] = g0_complete;

    // FIX #1a: Connect G1 busy/complete signals to internal arrays
    // This ensures RR selector can see G1's status properly
    assign g_core_busy_internal[1] = g1_busy;
    assign g_core_complete[1] = g1_complete;
    assign g_core_result[DATA_WIDTH*2-1:DATA_WIDTH] = g1_result;
    
    // G-Core command routing: Round-robin dispatch to idle cores
    // FIX: Edge-triggered dispatch prevents multi-cycle broadcast race condition
    //
    // PROBLEM: sched_g_core_cmd_valid stays high for 2+ cycles
    // - Cycle 1: G0 accepts, busy updates (registered, visible next cycle)
    // - Cycle 2: G0_busy still 0 (not yet visible) -> G0 accepts SAME command again!
    //
    // SOLUTION: Dispatch latch fires ONLY on first cycle, then locks out until cmd_valid deasserts

    // g_core_rr_index moved higher up
    reg [3:0] g_core_last_selected;  // Last selected core (for uop_cache and prefetcher)

    // EDGE-TRIGGERED DISPATCH LATCH
    // Fires only on rising edge of sched_g_core_cmd_valid
    // Stays low until sched_g_core_cmd_valid goes low again
    reg g_dispatch_latched;          // Has dispatch been latched?
    // g_dispatch_active moved higher up
    reg sched_g_cmd_valid_prev;      // Previous cycle valid signal

    wire g_dispatch_edge = sched_g_core_cmd_valid && !sched_g_cmd_valid_prev;  // Rising edge

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_core_rr_index <= 4'd0;
            g_core_last_selected <= 4'd0;
            g_dispatch_latched <= 1'b0;
            g_dispatch_active <= 1'b0;
            sched_g_cmd_valid_prev <= 1'b0;
        end else begin
            // Track previous valid for edge detection
            sched_g_cmd_valid_prev <= sched_g_core_cmd_valid;

            // Reset latch when cmd_valid goes low
            if (!sched_g_core_cmd_valid) begin
                g_dispatch_latched <= 1'b0;
                g_dispatch_active <= 1'b0;
            end
            // Fire only ONCE on rising edge
            else if (g_dispatch_edge && !g_dispatch_latched) begin
                g_dispatch_latched <= 1'b1;
                g_dispatch_active <= 1'b1;  // Active for THIS cycle only

                // Store current RR index for this dispatch
                g_core_last_selected <= g_core_rr_index;

                // Find next idle core and update RR for NEXT dispatch
                // CRITICAL FIX #2: Use current (non-updated) g_core_rr_index to find next core
                // Prevents skipping cores during round-robin selection
                begin
                    integer search_i;
                    integer core_idx;
                    for (search_i = 0; search_i < NUM_G_CORES; search_i = search_i + 1) begin
                        core_idx = (g_core_rr_index + search_i) % NUM_G_CORES;
                        if (!g_core_busy_internal[core_idx]) begin
                            g_core_rr_index <= (core_idx[3:0] + 1) % NUM_G_CORES;
                            search_i = NUM_G_CORES;  // Break
                        end
                    end
                end
            end else begin
                // After first cycle, deactivate dispatch even if cmd_valid still high
                // This prevents multi-cycle broadcast of the same command
                g_dispatch_active <= 1'b0;
            end
        end
    end

    // FIXED: G0 and G1 use same arbitration logic as array
    wire [ADDR_WIDTH-1:0] g0_cmd_addr;
    wire [DATA_WIDTH-1:0] g0_cmd_data;
    wire g0_cmd_valid;
    
    assign g0_cmd_addr = g_core_selected_addr;
    assign g0_cmd_data = g_core_selected_data;
    assign g0_cmd_valid = (g_core_selected_idx == 0) && g_core_selected_valid;
    
    assign g1_cmd_addr = g_core_selected_addr;
    assign g1_cmd_data = g_core_selected_data;
    assign g1_cmd_valid = (g_core_selected_idx == 1) && g_core_selected_valid;
    
    // Combined G-Core signals for scheduler - ALL CORES
    wire combined_g_result_valid = g0_complete || g1_complete || |g_core_complete[NUM_G_CORES-1:1];
    wire [DATA_WIDTH-1:0] combined_g_result = g0_complete ? g0_result :
                                              g1_complete ? g1_result :
                                              (NUM_G_CORES > 2 && g_core_complete[2]) ? g_core_result[DATA_WIDTH*3-1:DATA_WIDTH*2] :
                                              (NUM_G_CORES > 3 && g_core_complete[3]) ? g_core_result[DATA_WIDTH*4-1:DATA_WIDTH*3] :
                                              g0_result;

    // FIXED: Scheduler sees "busy" if ANY core is busy
    // Now includes ALL G-Cores (0..NUM_G_CORES-1)
    wire combined_g_busy = |g_core_busy_internal;
    wire combined_g_complete = |g_core_complete;
    
    // =========================================================================
    // H-CORE Array (32 cores untuk General Purpose) — MULTI-INSTANCE BY DESIGN
    // Setiap H-Core menerima command dari broadcast bus, accept jika idle
    // =========================================================================
    // Internal signals - H-Core interface
    wire [NUM_H_CORES-1:0]              h_core_cmd_ready;
    wire [NUM_H_CORES-1:0]              h_core_error_flag;
    wire [NUM_H_CORES*8-1:0]                h_core_error_code;
    wire [NUM_H_CORES-1:0]              h_core_error_valid;
    wire [DATA_WIDTH*NUM_H_CORES-1:0]   h_core_result;
    wire [NUM_H_CORES-1:0]              h_core_result_valid;

    // A-Core L2 interface signals (additional to existing declarations)
    wire [NUM_A_CORES*48-1:0]            a_core_l2_addr;
    wire [NUM_A_CORES*512-1:0]           a_core_l2_wr_data;
    wire [NUM_A_CORES-1:0]               a_core_l2_rd_en;
    wire [NUM_A_CORES-1:0]               a_core_l2_wr_en;
    wire [NUM_A_CORES*CACHE_LINE_WIDTH-1:0] a_worker_l2_rd_data;
    wire [NUM_A_CORES-1:0]                  a_worker_l2_ready;

    // H-Core command broadcast bus
    wire [ADDR_WIDTH-1:0]   h_core_broadcast_addr;
    wire [DATA_WIDTH-1:0]   h_core_broadcast_data;
    wire                    h_core_broadcast_valid;

    // H-Core dispatch: Round-robin pointer
    reg [4:0] h_core_rr_index;
    reg [4:0] h_core_last_selected;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_core_rr_index <= 5'b00001;
            h_core_last_selected <= 5'b00000;
        end else if (h_core_dispatch_req) begin
            integer h_core_found;
            integer h_core_sel_idx;
            h_core_found = 0;
            h_core_sel_idx = 0;
            for (int i = 0; i < NUM_H_CORES && !h_core_found; i = i + 1) begin
                h_core_sel_idx = (h_core_rr_index + i) % NUM_H_CORES;
                if (!h_core_busy[h_core_sel_idx]) begin
                    h_core_last_selected <= h_core_sel_idx[4:0];
                    h_core_rr_index <= (h_core_sel_idx[4:0] + 1) % NUM_H_CORES;
                    h_core_found = 1;
                end
            end
        end
    end

    // H-Core dispatch request (from testbench or system tasks)
    // CRITICAL FIX #4: H-Core dispatch request needs edge detection
    // sys_power_mode[0] is level signal, not pulse
    // We convert level to edge to prevent repeated dispatches
    reg h_core_dispatch_req_prev;
    wire h_core_dispatch_req_edge;
    wire h_core_dispatch_req;
    reg a_core_found;
    reg [5:0] a_core_sel_idx;
    integer h_core_rr_i;
    
    // A-Core dispatch round-robin state (used by disabled dispatch logic)
    reg [5:0] a_core_rr_index;
    reg [5:0] a_core_last_selected;

    assign h_core_dispatch_req_edge = sys_power_mode[0] && !h_core_dispatch_req_prev;
    assign h_core_dispatch_req = h_core_dispatch_req_edge;  // Pulse on rising edge only

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            h_core_dispatch_req_prev <= 1'b0;
        end else begin
            h_core_dispatch_req_prev <= sys_power_mode[0];
        end
    end

    // FIX #5: NPU dispatch also needs edge detection (same as H-Core)
    // Prevents repeated dispatches from level-triggered sys_power_mode[1]
    reg npu_dispatch_req_prev;
    wire npu_dispatch_req_edge = sys_power_mode[1] && !npu_dispatch_req_prev;
    wire npu_dispatch_req = npu_dispatch_req_edge;  // Pulse on rising edge only

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_dispatch_req_prev <= 1'b0;
        end else begin
            npu_dispatch_req_prev <= sys_power_mode[1];
        end
    end
    
    // CRITICAL FIX #6: H-Core opcode validation (UNIFIED: opcode at [31:24])
    // H-Core only accepts opcodes 0x00-0x0A (NOP, ADD, SUB, MUL, DIV, AND, OR, XOR, LOAD, STORE, BRANCH)
    // Prevents invalid opcode 0xFF from being dispatched to H-Core
    wire [7:0] h_cmd_opcode = game_cmd_data[31:24];
    wire h_valid_opcode = (h_cmd_opcode <= 8'h0A);
    
    // If invalid opcode detected, prevent dispatch
    // Note: This is a safety guard - testbench should not send invalid opcodes
    
    // Broadcast command to all H-Cores (they decide based on busy status)
    assign h_core_broadcast_addr = (h_core_dispatch_req && h_valid_opcode) ? game_cmd_addr : {ADDR_WIDTH{1'b0}};
    assign h_core_broadcast_data = (h_core_dispatch_req && h_valid_opcode) ? {32'b0, game_cmd_data} : {DATA_WIDTH{1'b0}};
    assign h_core_broadcast_valid = h_core_dispatch_req && h_valid_opcode;

    // Combined H-Core signals
    wire combined_h_busy = |h_core_busy;
    wire combined_h_complete = |h_core_complete;
    wire combined_h_result_valid = |h_core_result_valid;

    genvar h_idx;
    generate
        for (h_idx = 0; h_idx < NUM_H_CORES; h_idx = h_idx + 1) begin : h_core_array
            h_core #(
                .CORE_ID(h_idx),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH)
            ) u_h_core (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Command interface from broadcast bus
                .cmd_addr(h_core_broadcast_addr),
                .cmd_data(h_core_broadcast_data),
                .cmd_valid(h_core_broadcast_valid && !h_core_busy[h_idx]),
                .cmd_ready(h_core_cmd_ready[h_idx]),
                // Result interface
                .result(h_core_result[DATA_WIDTH*(h_idx+1)-1:DATA_WIDTH*h_idx]),
                .result_valid(h_core_result_valid[h_idx]),
                // Status
                .busy(h_core_busy[h_idx]),
                .complete(h_core_complete[h_idx]),
                // Error interface
                .error_flag(h_core_error_flag[h_idx]),
                .error_code(h_core_error_code[h_idx*8+:8]),
                .error_valid(h_core_error_valid[h_idx]),
                // Memory fabric interface (per-instance array for arbiter)
                .fabric_addr(fabric_addr_h[h_idx]),
                .fabric_rd_en(fabric_rd_en_h[h_idx]),
                .fabric_wr_en(fabric_wr_en_h[h_idx]),
                .fabric_rd_data(fabric_rd_data),
                .fabric_wr_data(fabric_wr_data_h[h_idx]),
                .fabric_ready(fabric_ready)
            );
        end
    endgenerate
    
    // =========================================================================
    // A-CORE Array (64 cores untuk AI/Tensor Compute)
    // =========================================================================
    wire                        a0_cmd_ready;  // FIX: A-Core ready signal for backpressure
    
    // DEBUG: Track a0_busy
    reg a0_busy_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a0_busy_prev <= 1'b0;
        end else begin
            a0_busy_prev <= a0_busy;
            if (a0_busy && !a0_busy_prev) begin
                $display("[%0t] [TOP] a0_busy went HIGH (A-Core started)", $time);
            end
            if (!a0_busy && a0_busy_prev) begin
                $display("[%0t] [TOP] a0_busy went LOW (A-Core finished)", $time);
            end
        end
    end

    // NPU busy logging
    reg npu_busy_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_busy_prev <= 1'b0;
        end else begin
            npu_busy_prev <= |npu_busy;
            if (|npu_busy && !npu_busy_prev) begin
                $display("[%0t] [TOP] npu_busy went HIGH (NPU started)", $time);
            end
            if (!(|npu_busy) && npu_busy_prev) begin
                $display("[%0t] [TOP] npu_busy went LOW (NPU finished)", $time);
            end
        end
    end

    // FIX: a0_result_ready driven dari a_core_result_ready_int (deklarasi forward-ref)
    // Dipakai di debug display baris 937. Sebelumnya undriven → ready=z di log.
    wire                        a0_result_ready;  // Phase 3: Scheduler pull signal

    // A-Core #0 (master - direct connect from testbench, bypass scheduler)
    // MUX: scheduler vs direct testbench
    // FIX: A-Core ONLY receives from scheduler to prevent double dispatch
    // Testbench commands go to scheduler first, then scheduler dispatches to A-Core
    wire a_core_cmd_valid_mux;
    wire [ADDR_WIDTH-1:0] a_core_cmd_addr_mux;
    wire [63:0] a_core_cmd_data_mux;

    // FIX: A-Core receives ONLY from scheduler (no direct testbench path)
    // Ini mencegah double execution yang menyebabkan watchdog timeout
    assign a_core_cmd_valid_mux = sched_a_core_cmd_valid;
    assign a_core_cmd_addr_mux  = sched_a_core_cmd_addr;
    assign a_core_cmd_data_mux  = sched_a_core_cmd_data;
    
    // DEBUG: Print when A-Core command is sent
    reg a_core_cmd_valid_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_core_cmd_valid_prev <= 1'b0;
        end else begin
            a_core_cmd_valid_prev <= a_core_cmd_valid_mux;
        end
    end
    
    wire a_core_cmd_valid_edge = a_core_cmd_valid_mux && !a_core_cmd_valid_prev;
    
    // FIX: cmd_ready goes to scheduler, testbench gets a_task_ready from scheduler
    assign ai_cmd_ready = a_task_ready_int;  // Route scheduler AI task ready signal - a_task_ready_int declared above (line 357)

    // CRITICAL FIX: Make ai_result_valid a LEVEL signal, not pulse
    // Testbench needs persistent valid until result is consumed
    reg a0_result_consumed;
    reg [DATA_WIDTH-1:0] a0_result_latched;
    reg a0_complete_prev;  // Previous value for edge detection
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a0_result_consumed <= 1'b0;
            a0_result_latched <= {DATA_WIDTH{1'b0}};
            a0_complete_prev <= 1'b0;
        end else begin
            // Latch new result when available
            if (a0_result_valid && !a0_result_consumed) begin
                a0_result_latched <= a0_result;
                a0_result_consumed <= 1'b0;  // Mark as not consumed yet
            end
            
            // Mark as consumed when testbench pulls result
            if (a_core_result_ready_int && a0_result_consumed == 1'b0) begin
                a0_result_consumed <= 1'b1;
            end
            
            // Update edge detection
            a0_complete_prev <= a0_complete;
        end
    end

    // CRITICAL FIX: Use external ai_result_ready for handshake
    assign ai_result_direct = a0_result_latched;
    assign ai_result_valid_direct = a0_result_valid && !a0_result_consumed;
    
    // Connect external ready signal to internal consumption logic
    assign a_core_result_ready_int = ai_result_ready;
    
    // DEBUG: Monitor result consumption
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // no state - debug only
        end else begin
        // if (a0_result_valid && !a0_result_consumed) begin
        //     $display("[%0t] [A-RSLT] RESULT_READY: data=0x%h, waiting_for_consumer", $time, a0_result);
        // end
        // if (a_core_result_ready_int && a0_result_consumed == 1'b0) begin
        //     $display("[%0t] [A-RSLT] RESULT_CONSUMED: data=0x%h", $time, a0_result_latched);
        // end
        
        // CRITICAL: Monitor ring bus response generation
        // if (u_ring_bus_a.node_resp_valid[2]) begin
        //     $display("[%0t] [RING-BUS] RESPONSE_GENERATED: Node 2, valid=1, ready=%b", $time, u_ring_bus_a.node_resp_ready[2]);
        // end
        // if (u_ring_bus_a.node_resp_valid[0]) begin
        //     $display("[%0t] [RING-BUS] RESPONSE_GENERATED: Node 0, valid=1, ready=%b", $time, u_ring_bus_a.node_resp_ready[0]);
        // end
        end
    end

    // DEBUG: Monitor A-Core result path (CRITICAL for backlog fix)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // no state - debug only
        end else begin
            if (a0_complete && !a0_complete_prev) begin
                $display("[%0t] [A-RSLT] COMPLETE_EDGE: result_ready=%b, fifo_drain=%b", 
                         $time, a0_result_ready, a_core_result_ready_int);
            end
            if (a0_busy && a0_result_valid && !a0_result_ready) begin
                $display("[%0t] [A-RSLT] STALL: result_valid=1 but ready=0 (FIFO will fill!)", $time);
            end
        end
    end

    a_core #(
        .CORE_ID(0),
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .RESULT_FIFO_DEPTH(4)  // Phase 3: Result FIFO
    ) u_a_core_0 (
        .clk(clk),
        .rst_n(rst_n_sync),
        .cmd_addr(a_core_cmd_addr_mux),
        .cmd_data(a_core_cmd_data_mux),
        .cmd_valid(a_core_cmd_valid_mux),
        .cmd_ready(a0_cmd_ready),  // FIX: Connect to scheduler for backpressure
        .result(a0_result),
        .result_valid(a0_result_valid),  // FIX: Separate from complete signal
        .busy(a0_busy),
        .result_ready(a_core_result_ready_int),  // HYBRID: MUX result ready dari MQ/SQ
        .complete(a0_complete),  // NEW: Completion signal to scheduler
        // Expose L1→L2 interface
        .l2_addr(a_l1_l2_addr),
        .l2_wr_data(a_l1_l2_wr_data),
        .l2_rd_en(a_l1_l2_rd_en),
        .l2_wr_en(a_l1_l2_wr_en),
        .l2_rd_data(a_l1_l2_rd_data),
        .l2_ready(a_l1_l2_ready),
        // FIFO metrics
        .fifo_occupancy(),
        .fifo_full_warn(),
        // Memory fabric interface (unused - using L1→L2)
        .fabric_addr(),
        .fabric_rd_en(),
        .fabric_wr_en(),
        .fabric_rd_data(),
        .fabric_wr_data(),
        .fabric_ready()
    );

    // FIX: a0_result_ready driven setelah a_core_result_ready_int ter-declare di baris 1344
    assign a0_result_ready = a_core_result_ready_int;
    
    // A-Core #1 to #63 (workers) - PROPER SINGLE-TARGET DISPATCH
    wire [NUM_A_CORES-1:0] a_core_cmd_accepted;  // Which core accepted the command
    
    // A-Core command arbitration - FIXED: No multi-driver
    reg [ADDR_WIDTH-1:0]    a_core_selected_addr;
    reg [63:0]              a_core_selected_data;
    reg                     a_core_selected_valid;
    reg [$clog2(NUM_A_CORES)-1:0] a_core_selected_idx;
    reg                     found_core;
    
    // Command selection logic - only ONE core gets command
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_core_selected_addr <= {ADDR_WIDTH{1'b0}};
            a_core_selected_data <= 64'b0;
            a_core_selected_valid <= 1'b0;
            a_core_selected_idx <= {$clog2(NUM_A_CORES){1'b0}};
            a_core_rr_index <= 6'd0;  // FIX: Initialize round-robin index
            a_core_last_selected <= 6'd0;  // FIX: Initialize last selected
            found_core <= 1'b0;  // FIX: Initialize found_core flag
        end else begin
            // Default: no command
            a_core_selected_valid <= 1'b0;
            
            // Find next available A-Core using round-robin
            if (sched_a_core_cmd_valid && !a_core_busy_internal[a_core_rr_index]) begin
                a_core_selected_addr <= sched_a_core_cmd_addr;
                a_core_selected_data <= sched_a_core_cmd_data;
                a_core_selected_valid <= 1'b1;
                a_core_selected_idx <= a_core_rr_index;
                
                // Update round-robin index for next command
                a_core_rr_index <= (a_core_rr_index + 1) % NUM_A_CORES;
            end else if (sched_a_core_cmd_valid) begin
                // Current core busy, try next core
                integer next_core;
                next_core = (a_core_rr_index + 1) % NUM_A_CORES;
                
                // Search for available core (limited search to prevent infinite loop) - OPTIMIZED: Early exit
                found_core <= 1'b0;
                for (integer i = 0; i < NUM_A_CORES && !found_core; i = i + 1) begin
                    if (!a_core_busy_internal[next_core] && !found_core) begin
                        a_core_selected_addr <= sched_a_core_cmd_addr;
                        a_core_selected_data <= sched_a_core_cmd_data;
                        a_core_selected_valid <= 1'b1;
                        a_core_selected_idx <= next_core;
                        a_core_rr_index <= (next_core + 1) % NUM_A_CORES;
                        found_core <= 1'b1;
                    end
                    next_core = (next_core + 1) % NUM_A_CORES;
                end
            end
        end
    end
    
    // A-Core FIFO full tracking for back-pressure
    reg [NUM_A_CORES-1:0] a_core_fifo_full;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_core_fifo_full <= {NUM_A_CORES{1'b0}};
        end else begin
            for (int ff = 0; ff < NUM_A_CORES; ff = ff + 1) begin
                if (a_core_result_valid[ff] && a_core_fifo_full[ff]) begin
                    a_core_fifo_full[ff] <= 1'b0;
                end else if (a_core_result_valid[ff]) begin
                    a_core_fifo_full[ff] <= 1'b1;
                end
            end
        end
    end

    // Generate per-core command signals using decoder logic
    reg [NUM_A_CORES-1:0] a_core_per_core_valid;
    
    // One-hot decoder for selected core
    integer i;
    always @(*) begin
        a_core_per_core_valid = {NUM_A_CORES{1'b0}};
        if (a_core_selected_valid) begin
            a_core_per_core_valid[a_core_selected_idx] = 1'b1;
        end
    end
    
    genvar a_idx;
    generate
        for (a_idx = 0; a_idx < NUM_A_CORES; a_idx = a_idx + 1) begin : a_core_array
            // Core #0 is special case - connected directly to scheduler
            if (a_idx == 0) begin : a_core_0
                // A-Core #0 already instantiated above (line ~1237)
                // FIXED: Removed duplicate assigns — a_core_cmd_*_mux already driven by scheduler (lines 1150-1152)
            end else begin : a_core_workers
                a_core #(
                    .CORE_ID(a_idx),
                    .DATA_WIDTH(DATA_WIDTH),
                    .ADDR_WIDTH(ADDR_WIDTH)
                ) u_a_core (
                    .clk(clk),
                    .rst_n(rst_n_sync),
                    // Single-target command dispatch
                    .cmd_addr(a_core_selected_addr),
                    .cmd_data(a_core_selected_data),
                    .cmd_valid(a_core_per_core_valid[a_idx]),
                    .cmd_ready(a_core_cmd_ready[a_idx]),
                    .result(a_core_result[DATA_WIDTH*(a_idx+1)-1:DATA_WIDTH*a_idx]),
                    .result_valid(a_core_result_valid[a_idx]),
                    .busy(a_core_busy_internal[a_idx]),
                    .result_ready(!a_core_fifo_full[a_idx]),
                    .complete(a_core_complete[a_idx]),
                    // L2 interface (properly tied off to internal signals)
                    // FIXED: Use part-select for packed arrays (a_core_l2_addr is packed [NUM_A_CORES*48-1:0])
                    .l2_addr(a_core_l2_addr[a_idx*48+:48]),
                    .l2_wr_data(a_core_l2_wr_data[a_idx*512+:512]),
                    .l2_rd_en(a_core_l2_rd_en[a_idx]),
                    .l2_wr_en(a_core_l2_wr_en[a_idx]),
                    .l2_rd_data(a_worker_l2_rd_data[a_idx*CACHE_LINE_WIDTH+:CACHE_LINE_WIDTH]),
                    .l2_ready(a_worker_l2_ready[a_idx]),
                    // FIFO metrics
                    .fifo_occupancy(),
                    .fifo_full_warn(),
                    // Memory fabric interface (per-instance array for arbiter)
                    .fabric_addr(fabric_addr_a[a_idx]),
                    .fabric_rd_en(fabric_rd_en_a[a_idx]),
                    .fabric_wr_en(fabric_wr_en_a[a_idx]),
                    .fabric_rd_data(fabric_rd_data),
                    .fabric_wr_data(fabric_wr_data_a[a_idx]),
                    .fabric_ready(fabric_ready)
                );
            end
        end
    endgenerate

    // Override A-Core 0 results (already handled above)
    assign a_core_result[DATA_WIDTH-1:0] = a0_result;
    assign a_core_busy_internal[0] = a0_busy;
    assign a_core_complete[0] = a0_complete;
    assign a_core_result_valid[0] = a0_result_valid;

    // Round-robin dispatch logic - PROPERLY IMPLEMENTED
    // Variables already declared at line ~714, 717
    
    // =========================================================================
    // NPU Cluster (8 clusters untuk AI Inference) - NOW WITH COMMAND INTERFACE
    // =========================================================================
    wire [NUM_NPU_CLUSTERS-1:0]  npu_cmd_ready;
    wire [ADDR_WIDTH-1:0]        npu_broadcast_addr;
    wire [DATA_WIDTH-1:0]        npu_broadcast_data;
    wire                         npu_broadcast_valid;
    
    genvar n_idx;
    generate
        for (n_idx = 0; n_idx < NUM_NPU_CLUSTERS; n_idx = n_idx + 1) begin : npu_array
            npu_cluster #(
                .CLUSTER_ID(n_idx),
                .DATA_WIDTH(DATA_WIDTH)
            ) u_npu (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Command interface (NEW)
                .cmd_addr(npu_broadcast_addr),
                .cmd_data(npu_broadcast_data),
                .cmd_valid(npu_broadcast_valid && !npu_busy[n_idx]),  // Only if not busy
                .cmd_ready(npu_cmd_ready[n_idx]),
                // Memory fabric interface (per-instance array for arbiter)
                .fabric_addr(fabric_addr_n[n_idx]),
                .fabric_rd_en(fabric_rd_en_n[n_idx]),
                .fabric_wr_en(fabric_wr_en_n[n_idx]),
                .fabric_rd_data(fabric_rd_data),
                .fabric_wr_data(fabric_wr_data_n[n_idx]),
                .fabric_ready(fabric_ready),
                .busy(npu_busy[n_idx]),
                .complete(npu_complete[n_idx]),
                .result(npu_result[DATA_WIDTH*(n_idx+1)-1:DATA_WIDTH*n_idx]),
                // Error interface
                .error_flag(),
                .error_code(),
                .error_valid()
            );
        end
    endgenerate
    
    // Combined NPU command ready: at least one NPU cluster is ready
    wire npu_cmd_ready_combined = |npu_cmd_ready;

    // NPU broadcast rising edge detector
    reg ai_cmd_valid_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ai_cmd_valid_d <= 1'b0;
        else ai_cmd_valid_d <= ai_cmd_valid;
    end
    wire ai_cmd_valid_rise = ai_cmd_valid && !ai_cmd_valid_d;

    // NPU command routing from scheduler
    assign npu_broadcast_addr = sched_a_core_cmd_addr;  // Reuse AI command path
    assign npu_broadcast_data = {{(DATA_WIDTH-128){1'b0}}, ai_cmd_data, 64'b0};  // Extend to DATA_WIDTH
    assign npu_broadcast_valid = ai_cmd_valid_rise && (ai_cmd_data[63:56] >= 8'h40 && ai_cmd_data[63:56] <= 8'h45);
    
    // =========================================================================
    // Global Scheduler A/B Test: SQ (Single Queue) vs MQ (Multi-Queue)
    // Both schedulers instantiated for side-by-side comparison
    // sched_select = 0 → use SQ, sched_select = 1 → use MQ
    // =========================================================================
    parameter SCHED_SELECT_DEFAULT = 1'b1;  // HYBRID: Default to MQ (multi-queue with fairness)
    reg sched_select = SCHED_SELECT_DEFAULT;

    // SQ internal signals
    wire                        sq_g_task_ready;
    wire [DATA_WIDTH-1:0]       sq_g_task_result;
    wire                        sq_g_task_result_valid;
    wire                        sq_a_task_ready;
    wire [DATA_WIDTH-1:0]       sq_a_task_result;
    wire                        sq_a_task_result_valid;
    wire                        sq_npu_task_ready;
    wire [DATA_WIDTH-1:0]       sq_npu_task_result;
    wire                        sq_npu_task_result_valid;
    wire [ADDR_WIDTH-1:0]       sq_g_core_cmd_addr;
    wire [31:0]                 sq_g_core_cmd_data;
    wire                        sq_g_core_cmd_valid;
    wire [ADDR_WIDTH-1:0]       sq_a_core_cmd_addr;
    wire [63:0]                 sq_a_core_cmd_data;
    wire                        sq_a_core_cmd_valid;
    wire                        sq_a_core_result_ready;  // NEW: Pull result from A-Core FIFO
    wire                        sq_npu_dispatch_valid;
    wire [63:0]                 sq_sched_dispatched;
    wire [63:0]                 sq_sched_completed;
    wire [63:0]                 sq_sched_total_stalled;
    wire [63:0]                 sq_sched_stall_resource_wait;
    wire [63:0]                 sq_sched_stall_queue_contention;
    wire [31:0]                 sq_sched_queue_depth;
    wire [31:0]                 sq_sched_max_queue_depth;
    wire [31:0]                 sq_sched_conflict_count;
    wire [31:0]                 sq_sched_bp_queue_full_rejections;
    wire [31:0]                 sq_sched_bp_timeout_stalls;
    wire [31:0]                 sq_sched_bp_actual_accepts;
    wire [31:0]                 sq_sched_admission_rejections;
    // wire [31:0]                 sq_sched_hazard_raw;
    // wire [31:0]                 sq_sched_hazard_war;
    // wire [31:0]                 sq_sched_hazard_waw;
    wire [31:0]                 sq_sched_hazard_structural;
    wire [31:0]                 sq_sched_hazard_dependency;

    wire                        npu_task_ready_dummy;
    wire [DATA_WIDTH-1:0]       npu_task_result_dummy;
    wire                        npu_task_result_valid_dummy;

    // ── Single Queue (SQ) Instance ──
    global_scheduler_sq #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .QUEUE_DEPTH(32)  // Same total depth as MQ (16G+16A = 32)
    ) u_scheduler_sq (
        .clk(clk),
        .rst_n(rst_n_sync),
        .g_task_addr(game_cmd_addr),
        .g_task_data({32'b0, game_cmd_data}),
        .g_task_valid(game_cmd_valid),
        .g_task_ready(sq_g_task_ready),
        .g_task_result(sq_g_task_result),
        .g_task_result_valid(sq_g_task_result_valid),
        .a_task_addr(ai_cmd_addr),
        .a_task_data(ai_cmd_data),
        .a_task_valid(ai_cmd_valid),
        .a_task_ready(sq_a_task_ready),
        .a_task_result(sq_a_task_result),
        .a_task_result_valid(sq_a_task_result_valid),
        .npu_task_valid(!sched_select ? (ai_cmd_valid && (ai_cmd_data[63:56] >= 8'h40 && ai_cmd_data[63:56] <= 8'h45)) : 1'b0),
        .npu_task_ready(sq_npu_task_ready),
        .npu_task_result(sq_npu_task_result),
        .npu_task_result_valid(sq_npu_task_result_valid),
        .g_core_cmd_addr(sq_g_core_cmd_addr),
        .g_core_cmd_data(sq_g_core_cmd_data),
        .g_core_cmd_valid(sq_g_core_cmd_valid),
        .g_core_cmd_ready(sched_g_core_cmd_ready),
        .g_core_busy(combined_g_busy),
        .g_core_complete(combined_g_complete),
        .g_core_result(combined_g_result),
        .g_core_error_flag(1'b0),
        .g_core_error_valid(g0_error_valid),
        .a_core_cmd_addr(sq_a_core_cmd_addr),
        .a_core_cmd_data(sq_a_core_cmd_data),
        .a_core_cmd_valid(sq_a_core_cmd_valid),
        .a_core_cmd_ready(sched_a_core_cmd_ready),
        .a_core_busy(a0_busy),
        .a_core_complete(a0_complete),  // Revert: Use level-triggered, scheduler does edge detection
        .a_core_result(a0_result),
        .a_core_result_ready(sq_a_core_result_ready),  // NEW: Pull result from A-Core FIFO
        .npu_dispatch_valid(sq_npu_dispatch_valid),
        .npu_dispatch_ready(npu_cmd_ready_combined),
        .npu_busy(|npu_busy),
        .npu_complete(|npu_complete),
        .npu_result(npu_result[DATA_WIDTH-1:0]),
        .sched_total_dispatched(sq_sched_dispatched),
        .sched_total_completed(sq_sched_completed),
        .sched_total_stalled(sq_sched_total_stalled),
        .sched_stall_resource_wait(sq_sched_stall_resource_wait),
        .sched_stall_queue_contention(sq_sched_stall_queue_contention),
        .sched_queue_depth(sq_sched_queue_depth),
        .sched_max_queue_depth(sq_sched_max_queue_depth),
        .sched_conflict_count(sq_sched_conflict_count),
        .sched_gaming_priority(),
        .sched_ai_priority(),
        .sched_npu_priority(),
        .sched_aging_tasks(),
        .sched_rr_rotations(),
        .sched_queue_avoidance(),
        .sched_watchdog_resets(),
        .sched_bp_queue_full_rejections(sq_sched_bp_queue_full_rejections),
        .sched_bp_timeout_stalls(sq_sched_bp_timeout_stalls),
        .sched_bp_actual_accepts(sq_sched_bp_actual_accepts),
        .sched_hazard_raw(sq_sched_hazard_raw),
        .sched_hazard_war(sq_sched_hazard_war),
        .sched_hazard_waw(sq_sched_hazard_waw),
        .sched_hazard_structural(sq_sched_hazard_structural),
        .sched_hazard_dependency(sq_sched_hazard_dependency),
        
        // FAIRNESS: Task distribution monitoring
        .sched_g_tasks_completed(sq_sched_g_tasks_completed),
        .sched_a_tasks_completed(sq_sched_a_tasks_completed),
        .sched_npu_tasks_completed(sq_sched_npu_tasks_completed),
        .sched_fairness_violations(sq_sched_fairness_violations)
    );

    // ── Multi Queue (MQ) Instance ──
    wire npu_task_valid_mq;
    assign npu_task_valid_mq = sched_select ? (ai_cmd_valid && (ai_cmd_data[63:56] >= 8'h40 && ai_cmd_data[63:56] <= 8'h45)) : 1'b0;
    
    global_scheduler_mq #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .G_QUEUE_DEPTH(16),
        .A_QUEUE_DEPTH(16),
        .N_QUEUE_DEPTH(8),
        .G_WEIGHT(8),
        .A_WEIGHT(8),
        .N_WEIGHT(2)
    ) u_scheduler_mq (
        .clk(clk),
        .rst_n(rst_n_sync),  // Use synchronized reset for MQ scheduler
        .g_task_addr(game_cmd_addr),
        .g_task_data({32'b0, game_cmd_data}),
        .g_task_valid(sched_select ? game_cmd_valid : 1'b0),  // FIX: Direct connection - same clock domain
        .g_task_ready(mq_g_task_ready),
        .g_task_result(mq_g_task_result),
        .g_task_result_valid(mq_g_task_result_valid),
        .a_task_addr(ai_cmd_addr),
        .a_task_data(ai_cmd_data),
        .a_task_valid(sched_select ? ai_cmd_valid : 1'b0),  // Disable MQ when SQ selected
        .a_task_ready(mq_a_task_ready),
        .a_task_result(mq_a_task_result),
        .a_task_result_valid(mq_a_task_result_valid),
        .npu_task_valid(npu_task_valid_mq),
        .npu_task_ready(mq_npu_task_ready),
        .npu_task_result(mq_npu_task_result),
        .npu_task_result_valid(mq_npu_task_result_valid),
        .g_core_cmd_addr(mq_g_core_cmd_addr),
        .g_core_cmd_data(mq_g_core_cmd_data),
        .g_core_cmd_valid(mq_g_core_cmd_valid),
        .g_core_cmd_ready(mq_g_core_cmd_ready),
        .g_core_busy(combined_g_busy),
        .g_core_complete(combined_g_complete),
        .g_core_result(combined_g_result),
        .g_core_error_valid(g0_error_valid),
        .a_core_cmd_addr(mq_a_core_cmd_addr),
        .a_core_cmd_data(mq_a_core_cmd_data),
        .a_core_cmd_valid(mq_a_core_cmd_valid),
        // Note: MQ does not have a_core_cmd_ready port (SQ has it)
        .a_core_busy(a0_busy),
        .a_core_complete(a0_complete),  // Revert: Use level-triggered, scheduler does edge detection
        .a_core_result(a0_result),
        .a_core_result_valid(a0_result_valid),  // CRITICAL FIX: Connect A-Core result valid
        .a_core_result_ready(mq_a_core_result_ready),  // CRITICAL FIX: Connect scheduler ready signal
        .npu_dispatch_valid(mq_npu_dispatch_valid),
        .npu_busy(|npu_busy),
        .npu_complete(|npu_complete),
        .npu_result(npu_result[DATA_WIDTH-1:0]),
        .sched_total_dispatched(mq_sched_dispatched),
        .sched_total_completed(mq_sched_completed),
        .sched_total_stalled(mq_sched_total_stalled),
        .sched_stall_resource_wait(mq_sched_stall_resource_wait),
        .sched_stall_queue_contention(mq_sched_stall_queue_contention),
        .sched_queue_depth(mq_sched_queue_depth),
        .sched_max_queue_depth(mq_sched_max_queue_depth),
        .sched_conflict_count(mq_sched_conflict_count),
        .sched_gaming_priority(mq_sched_gaming_priority),
        .sched_ai_priority(mq_sched_ai_priority),
        .sched_npu_priority(mq_sched_npu_priority),
        .sched_aging_tasks(mq_sched_aging_tasks),
        .sched_rr_rotations(mq_sched_rr_rotations),
        .sched_queue_avoidance(mq_sched_queue_avoidance),
        .sched_watchdog_resets(mq_sched_watchdog_resets),
        .sched_bp_queue_full_rejections(mq_sched_bp_queue_full_rejections),
        .sched_bp_timeout_stalls(mq_sched_bp_timeout_stalls),
        .sched_bp_actual_accepts(mq_sched_bp_actual_accepts),
        .sched_admission_rejections(mq_sched_admission_rejections),
        .sched_hazard_raw(mq_sched_hazard_raw),
        .sched_hazard_war(mq_sched_hazard_war),
        .sched_hazard_waw(mq_sched_hazard_waw),
        .sched_hazard_structural(mq_sched_hazard_structural),
        .sched_hazard_dependency(mq_sched_hazard_dependency),
        .sched_hazard_dependency_stalls(mq_sched_hazard_dependency_stalls),
        .sched_g_core_busy_cycles(mq_sched_g_core_busy_cycles),
        .sched_a_core_busy_cycles(mq_sched_a_core_busy_cycles),
        .sched_n_core_busy_cycles(mq_sched_n_core_busy_cycles),
        .sched_total_sim_cycles(mq_sched_total_sim_cycles),
        // NEW: Hybrid Queue stage counters (v4.0)
        .sched_hq_fq_enqueued(mq_sched_hq_fq_enqueued),
        .sched_hq_dq_decoded(mq_sched_hq_dq_decoded),
        .sched_hq_eq_dispatched(mq_sched_hq_eq_dispatched),
        .sched_hq_rq_committed(mq_sched_hq_rq_committed),
        .sched_hq_cq_completed(mq_sched_hq_cq_completed),

        // Ring bus interface for load balancing
        .ring_bus_g_packets(cg_packets),
        .ring_bus_a_packets(ca_packets),
        .ring_bus_contention(ring_bus_contention),
        .ring_bus_congested(ring_bus_congested)
    );

    // =========================================================================
    // SCHEDULER MUX: Route selected scheduler outputs to core interfaces
    // =========================================================================
    // G-Core dispatch MUX
    assign sched_g_core_cmd_addr  = (sched_select) ? mq_g_core_cmd_addr  : sq_g_core_cmd_addr;
    assign sched_g_core_cmd_data  = (sched_select) ? mq_g_core_cmd_data  : sq_g_core_cmd_data;
    assign sched_g_core_cmd_valid = (sched_select) ? mq_g_core_cmd_valid : sq_g_core_cmd_valid;

    // A-Core dispatch MUX
    assign sched_a_core_cmd_addr  = (sched_select) ? mq_a_core_cmd_addr  : sq_a_core_cmd_addr;
    assign sched_a_core_cmd_data  = (sched_select) ? mq_a_core_cmd_data  : sq_a_core_cmd_data;
    assign sched_a_core_cmd_valid = (sched_select) ? mq_a_core_cmd_valid : sq_a_core_cmd_valid;

    // NPU dispatch MUX
    assign sched_npu_dispatch_valid = (sched_select) ? mq_npu_dispatch_valid : sq_npu_dispatch_valid;

    // Task ready MUX (for backpressure to testbench)
    assign g_task_ready_int = (sched_select) ? mq_g_task_ready : sq_g_task_ready;
    assign a_task_ready_int = (sched_select) ? mq_a_task_ready : sq_a_task_ready;

    // FIX #1 (top.sv): mq_a_core_result_ready adalah OUTPUT dari MQ scheduler (line 112 MQ).
    // Jangan di-assign di top.sv — akan menyebabkan multi-driver conflict → x.
    // MQ scheduler men-drive sinyal ini via:
    //   assign a_core_result_ready = !pending_result_valid || (pending_result_type != TASK_AI);
    // Cukup deklarasi wire, biarkan MQ module yang drive.
    // mq_a_core_result_ready moved higher up
    
    assign a_core_result_ready_int = (sched_select) ? mq_a_core_result_ready : sq_a_core_result_ready;

    // CRITICAL FIX: Wire game_cmd_ready to scheduler ready signal
    // Previously unconnected, causing testbench to always timeout waiting for G-Core ready
    assign game_cmd_ready = g_task_ready_int;
    // ai_cmd_ready already assigned at line 775

    // G-Core command ready feedback to schedulers
    assign mq_g_core_cmd_ready = sched_g_core_cmd_ready;

    // A-Core command ready feedback to schedulers
    assign mq_a_core_cmd_ready = sched_a_core_cmd_ready;

    // Drive scheduler-ready signals from actual core ready outputs (ALL cores)
    assign sched_a_core_cmd_ready = a0_cmd_ready || |(~a_core_busy_internal[63:1]);

    // =========================================================================
    // A/B Test Output Assignments
    // =========================================================================
    assign sq_sched_dispatched_out      = sq_sched_dispatched;
    assign sq_sched_completed_out       = sq_sched_completed;
    assign sq_sched_total_stalled_out   = sq_sched_total_stalled;
    assign sq_sched_queue_depth_out     = sq_sched_queue_depth;
    assign sq_sched_bp_actual_accepts_out = sq_sched_bp_actual_accepts;

    assign mq_sched_dispatched_out      = mq_sched_dispatched;
    assign mq_sched_completed_out       = mq_sched_completed;
    assign mq_sched_total_stalled_out   = mq_sched_total_stalled;
    assign mq_sched_queue_depth_out     = mq_sched_queue_depth;
    assign mq_sched_bp_actual_accepts_out = mq_sched_bp_actual_accepts;
    assign sched_select_out             = sched_select;
    
    // NEW: Hybrid Queue stage counter outputs (v4.0)
    assign mq_sched_hq_fq_enqueued_out    = mq_sched_hq_fq_enqueued;
    assign mq_sched_hq_dq_decoded_out     = mq_sched_hq_dq_decoded;
    assign mq_sched_hq_eq_dispatched_out  = mq_sched_hq_eq_dispatched;
    assign mq_sched_hq_rq_committed_out   = mq_sched_hq_rq_committed;
    assign mq_sched_hq_cq_completed_out   = mq_sched_hq_cq_completed;

    // =========================================================================
    // FIX #1: Wire scheduler counters to top-level output ports
    // Previously these outputs were unconnected, causing metrics to show 0
    // =========================================================================
    // MUX: Select counter source based on active scheduler
    assign sched_total_dispatched       = (sched_select) ? mq_sched_dispatched : sq_sched_dispatched;
    assign sched_total_completed        = (sched_select) ? mq_sched_completed : sq_sched_completed;
    assign sched_total_stalled          = (sched_select) ? mq_sched_total_stalled : sq_sched_total_stalled;
    assign sched_stall_resource_wait    = (sched_select) ? mq_sched_stall_resource_wait : sq_sched_stall_resource_wait;
    assign sched_stall_queue_contention = (sched_select) ? mq_sched_stall_queue_contention : sq_sched_stall_queue_contention;
    assign sched_queue_depth            = (sched_select) ? mq_sched_queue_depth : sq_sched_queue_depth;
    assign sched_max_queue_depth        = (sched_select) ? mq_sched_max_queue_depth : sq_sched_max_queue_depth;
    assign sched_conflict_count         = (sched_select) ? mq_sched_conflict_count : sq_sched_conflict_count;
    assign sched_gaming_priority        = (sched_select) ? mq_sched_gaming_priority : 8'b0;
    assign sched_ai_priority            = (sched_select) ? mq_sched_ai_priority : 8'b0;
    assign sched_npu_priority           = (sched_select) ? mq_sched_npu_priority : 8'b0;
    assign sched_aging_tasks            = (sched_select) ? mq_sched_aging_tasks : 32'b0;
    assign sched_rr_rotations           = (sched_select) ? mq_sched_rr_rotations : 32'b0;
    assign sched_queue_avoidance        = (sched_select) ? mq_sched_queue_avoidance : 32'b0;
    assign sched_watchdog_resets        = (sched_select) ? mq_sched_watchdog_resets : 32'b0;

    // FAIRNESS: Connect task distribution monitoring
    assign sched_g_tasks_completed      = (sched_select) ? 32'b0 : sq_sched_g_tasks_completed;  // Only SQ has this
    assign sched_a_tasks_completed      = (sched_select) ? 32'b0 : sq_sched_a_tasks_completed;
    assign sched_npu_tasks_completed     = (sched_select) ? 32'b0 : sq_sched_npu_tasks_completed;
    assign sched_fairness_violations     = (sched_select) ? 32'b0 : sq_sched_fairness_violations;

    // FIX #3: Back-pressure counters - wire to output ports
    assign sched_bp_queue_full_rejections = (sched_select) ? mq_sched_bp_queue_full_rejections : sq_sched_bp_queue_full_rejections;
    assign sched_bp_timeout_stalls        = (sched_select) ? mq_sched_bp_timeout_stalls : sq_sched_bp_timeout_stalls;
    assign sched_bp_actual_accepts        = (sched_select) ? mq_sched_bp_actual_accepts : sq_sched_bp_actual_accepts;

    // Admission control & hazard counters
    assign sched_admission_rejections   = (sched_select) ? mq_sched_admission_rejections : sq_sched_admission_rejections;
    assign sched_hazard_raw             = (sched_select) ? mq_sched_hazard_raw : sq_sched_hazard_raw;
    assign sched_hazard_war             = (sched_select) ? mq_sched_hazard_war : sq_sched_hazard_war;
    assign sched_hazard_waw             = (sched_select) ? mq_sched_hazard_waw : sq_sched_hazard_waw;
    assign sched_hazard_structural      = (sched_select) ? mq_sched_hazard_structural : sq_sched_hazard_structural;
    assign sched_hazard_dependency      = (sched_select) ? mq_sched_hazard_dependency : sq_sched_hazard_dependency;
    assign sched_hazard_dependency_stalls = (sched_select) ? mq_sched_hazard_dependency_stalls : 32'b0;  // SQ doesn't have this port

    // Per-core utilization counters
    assign sched_g_core_busy_cycles     = (sched_select) ? mq_sched_g_core_busy_cycles : 32'b0;
    assign sched_a_core_busy_cycles     = (sched_select) ? mq_sched_a_core_busy_cycles : 32'b0;
    assign sched_n_core_busy_cycles     = (sched_select) ? mq_sched_n_core_busy_cycles : 32'b0;
    assign sched_total_sim_cycles       = (sched_select) ? mq_sched_total_sim_cycles : 32'b0;

    // =========================================================================
    // RT Engine Array (Multi-Instance Ray Tracing Hardware) — MULTI-INSTANCE BY DESIGN
    // NUM_RT_ENGINES engines untuk parallel ray tracing
    // =========================================================================
    localparam NUM_RT_ENGINES = 4;  // 4 RT engines for parallel workloads

    // RT Engine internal signals
    wire [NUM_RT_ENGINES-1:0]             rt_engine_busy;
    wire [NUM_RT_ENGINES-1:0]             rt_engine_complete;
    wire [NUM_RT_ENGINES-1:0]             rt_engine_error_flag;
    wire [NUM_RT_ENGINES-1:0]             rt_engine_error_valid;
    wire [DATA_WIDTH*NUM_RT_ENGINES-1:0]  rt_engine_result;
    wire [NUM_RT_ENGINES-1:0]             rt_engine_result_valid;
    wire [NUM_RT_ENGINES-1:0]             rt_engine_cmd_ready;

    // RT Engine broadcast bus
    wire [ADDR_WIDTH-1:0]   rt_broadcast_addr;
    wire [DATA_WIDTH-1:0]   rt_broadcast_data;
    wire                    rt_broadcast_valid;

    // RT Engine dispatch: Round-robin
    reg [1:0] rt_rr_index;
    reg [1:0] rt_last_selected;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rt_rr_index <= 2'b01;
            rt_last_selected <= 2'b00;
        end else if (rt_dispatch_req) begin
            integer rt_found;
            integer rt_sel_idx;
            rt_found = 0;
            rt_sel_idx = 0;
            for (int rt_i = 0; rt_i < NUM_RT_ENGINES && !rt_found; rt_i = rt_i + 1) begin
                rt_sel_idx = (rt_rr_index + rt_i) % NUM_RT_ENGINES;
                if (!rt_engine_busy[rt_sel_idx]) begin
                    rt_last_selected <= rt_sel_idx[1:0];
                    rt_rr_index <= (rt_sel_idx[1:0] + 1) % NUM_RT_ENGINES;
                    rt_found = 1;
                end
            end
        end
    end

    // RT dispatch request (triggered by RT commands)
    // FIX: Detect opcode 0x05 from testbench, convert to RT Engine opcode 0x60 (OP_TRACE)
    wire rt_dispatch_req = game_cmd_valid && (game_cmd_data[31:24] == 8'h05);  // OP_RAYTRACE from TB

    // Broadcast to all RT engines
    assign rt_broadcast_addr = game_cmd_addr;
    // FIXED: Use parameterized padding instead of hardcoded 96'b0
    // Convert opcode 0x05 -> 0x60 (OP_TRACE) for RT Engine
    // DATA_WIDTH must be >= 32 (8+24 bits for opcode+data)
    localparam RT_OPCODE_WIDTH = 8;
    localparam RT_DATA_WIDTH = 24;
    localparam RT_PAD_WIDTH = DATA_WIDTH - RT_OPCODE_WIDTH - RT_DATA_WIDTH;
    
    generate
        if (RT_PAD_WIDTH > 0) begin : rt_pad_gen
            assign rt_broadcast_data = {{RT_PAD_WIDTH{1'b0}}, 8'h60, game_cmd_data[23:0]};  // Map 0x05 to OP_TRACE (0x60)
        end else begin : rt_pad_else
            assign rt_broadcast_data = {8'h60, game_cmd_data[23:0]};  // Fallback if DATA_WIDTH is exactly 32
        end
    endgenerate
    assign rt_broadcast_valid = rt_dispatch_req;

    // Combined RT Engine signals
    wire rt_combined_busy = |rt_engine_busy;
    wire rt_combined_complete = |rt_engine_complete;
    wire rt_combined_result_valid = |rt_engine_result_valid;

    genvar rt_idx;
    generate
        for (rt_idx = 0; rt_idx < NUM_RT_ENGINES; rt_idx = rt_idx + 1) begin : rt_engine_array
            rt_engine #(
                .ENGINE_ID(rt_idx),
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH)
            ) u_rt_engine (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Command interface from broadcast bus
                .cmd_addr(rt_broadcast_addr),
                .cmd_data(rt_broadcast_data),
                .cmd_valid(rt_broadcast_valid && !rt_engine_busy[rt_idx]),
                .cmd_ready(rt_engine_cmd_ready[rt_idx]),
                // Result interface
                .result(rt_engine_result[DATA_WIDTH*(rt_idx+1)-1:DATA_WIDTH*rt_idx]),
                // Status
                .busy(rt_engine_busy[rt_idx]),
                .complete(rt_engine_complete[rt_idx]),
                // Error interface
                .error_flag(rt_engine_error_flag[rt_idx]),
                .error_code(),
                .error_valid(rt_engine_error_valid[rt_idx]),
                // Memory fabric interface (per-instance array for arbiter)
                .fabric_addr(fabric_addr_r[rt_idx]),
                .fabric_rd_en(fabric_rd_en_r[rt_idx]),
                .fabric_wr_en(fabric_wr_en_r[rt_idx]),
                .fabric_rd_data(fabric_rd_data),
                .fabric_wr_data(fabric_wr_data_r[rt_idx]),
                .fabric_ready(fabric_ready)
            );
        end
    endgenerate

    // Legacy RT output mapping (for backward compatibility)
    wire                        rt_busy_internal = rt_combined_busy;
    wire                        rt_result_valid_int = rt_combined_complete;
    wire [DATA_WIDTH-1:0]       rt_result_internal = rt_engine_result[DATA_WIDTH-1:0];

    assign rt_busy = rt_busy_internal;
    assign rt_complete = rt_result_valid_int;
    assign rt_result = rt_result_internal;

    // =========================================================================
    // Fabric Arbiter — resolves MULTIDRIVEN on fabric request bus
    // All H-Cores, NPU clusters, RT engines, and A-Core workers drive per-instance
    // fabric request signals. This arbiter selects one active requestor at a time
    // and drives the shared fabric_addr/rd_en/wr_en/wr_data wires.
    // Priority: A-Core > RT > NPU > H-Core (A-Core is primary compute).
    // The fabric response (fabric_rd_data/fabric_ready) is driven by l2_mem_*
    // via the memory_fabric (see ~line 2040).
    // =========================================================================
    integer fab_req_h, fab_req_n, fab_req_r, fab_req_a;
    integer fab_sel_h, fab_sel_n, fab_sel_r, fab_sel_a;
    always_comb begin
        // Default: no request
        fabric_addr   = {ADDR_WIDTH{1'b0}};
        fabric_rd_en  = 1'b0;
        fabric_wr_en  = 1'b0;
        fabric_wr_data = {CACHE_LINE_WIDTH{1'b0}};

        // TAPE-OUT FIX: Use first-match instead of last-match arbitration.
        // Original code overwrites on every iteration (last-requestor-wins),
        // causing priority inversion where worker N always beats worker 0.
        // Fix: double-check fab_sel is still -1 before assigning.
        
        // Priority: A-Core workers > RT engines > NPU clusters > H-Cores
        // Find first active A-Core worker (fab_sel_a stays -1 if none found)
        fab_sel_a = -1;
        for (fab_req_a = 0; fab_req_a < NUM_A_CORES; fab_req_a = fab_req_a + 1) begin
            if ((fabric_rd_en_a[fab_req_a] || fabric_wr_en_a[fab_req_a]) && fab_sel_a == -1) begin
                fab_sel_a = fab_req_a;
            end
        end
        if (fab_sel_a != -1) begin
            fabric_addr   = fabric_addr_a[fab_sel_a];
            fabric_rd_en  = fabric_rd_en_a[fab_sel_a];
            fabric_wr_en  = fabric_wr_en_a[fab_sel_a];
            fabric_wr_data = fabric_wr_data_a[fab_sel_a];
        end else begin
            // Find first active RT engine
            fab_sel_r = -1;
            for (fab_req_r = 0; fab_req_r < NUM_RT_ENGINES; fab_req_r = fab_req_r + 1) begin
                if ((fabric_rd_en_r[fab_req_r] || fabric_wr_en_r[fab_req_r]) && fab_sel_r == -1) begin
                    fab_sel_r = fab_req_r;
                end
            end
            if (fab_sel_r != -1) begin
                fabric_addr   = fabric_addr_r[fab_sel_r];
                fabric_rd_en  = fabric_rd_en_r[fab_sel_r];
                fabric_wr_en  = fabric_wr_en_r[fab_sel_r];
                fabric_wr_data = fabric_wr_data_r[fab_sel_r];
            end else begin
                // Find first active NPU cluster
                fab_sel_n = -1;
                for (fab_req_n = 0; fab_req_n < NUM_NPU_CLUSTERS; fab_req_n = fab_req_n + 1) begin
                    if ((fabric_rd_en_n[fab_req_n] || fabric_wr_en_n[fab_req_n]) && fab_sel_n == -1) begin
                        fab_sel_n = fab_req_n;
                    end
                end
                if (fab_sel_n != -1) begin
                    fabric_addr   = fabric_addr_n[fab_sel_n];
                    fabric_rd_en  = fabric_rd_en_n[fab_sel_n];
                    fabric_wr_en  = fabric_wr_en_n[fab_sel_n];
                    fabric_wr_data = fabric_wr_data_n[fab_sel_n];
                end else begin
                    // Find first active H-Core
                    fab_sel_h = -1;
                    for (fab_req_h = 0; fab_req_h < NUM_H_CORES; fab_req_h = fab_req_h + 1) begin
                        if ((fabric_rd_en_h[fab_req_h] || fabric_wr_en_h[fab_req_h]) && fab_sel_h == -1) begin
                            fab_sel_h = fab_req_h;
                        end
                    end
                    if (fab_sel_h != -1) begin
                        fabric_addr   = fabric_addr_h[fab_sel_h];
                        fabric_rd_en  = fabric_rd_en_h[fab_sel_h];
                        fabric_wr_en  = fabric_wr_en_h[fab_sel_h];
                        fabric_wr_data = fabric_wr_data_h[fab_sel_h];
                    end
                end
            end
        end
    end

    // =========================================================================
    // A-Core Worker L2 Arbiter — routes 64 worker L1 requests to 1 L2 port
    // =========================================================================
    reg [$clog2(NUM_A_CORES)-1:0] a_worker_l2_sel;
    reg a_worker_l2_valid;
    reg [ADDR_WIDTH-1:0] a_worker_l2_addr_reg;
    reg [CACHE_LINE_WIDTH-1:0] a_worker_l2_wr_data_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_worker_l2_sel <= 0;
            a_worker_l2_valid <= 1'b0;
            a_worker_l2_addr_reg <= {ADDR_WIDTH{1'b0}};
            a_worker_l2_wr_data_reg <= {CACHE_LINE_WIDTH{1'b0}};
        end else begin
            a_worker_l2_valid <= 1'b0;
            if (!a_l1_l2_rd_en && !a_l1_l2_wr_en) begin
                automatic bit a_worker_found = 1'b0;
                for (int w = 0; w < NUM_A_CORES && !a_worker_found; w = w + 1) begin
                    if (a_core_l2_rd_en[w] || a_core_l2_wr_en[w]) begin
                        a_worker_l2_sel <= w;
                        a_worker_l2_valid <= 1'b1;
                        a_worker_l2_addr_reg <= a_core_l2_addr[w*48+:48];
                        a_worker_l2_wr_data_reg <= a_core_l2_wr_data[w*512+:512];
                        a_worker_found = 1'b1;
                    end
                end
            end
        end
    end

    // Mux A-Core L2 port: use worker request when core #0 is idle
    wire [ADDR_WIDTH-1:0] a_l1_l2_addr_mux = a_worker_l2_valid ? a_worker_l2_addr_reg : a_l1_l2_addr;
    wire [CACHE_LINE_WIDTH-1:0] a_l1_l2_wr_data_mux = a_worker_l2_valid ? a_worker_l2_wr_data_reg : a_l1_l2_wr_data;
    wire a_l1_l2_rd_en_mux = a_worker_l2_valid ? 1'b1 : a_l1_l2_rd_en;
    wire a_l1_l2_wr_en_mux = a_worker_l2_valid ? 1'b1 : a_l1_l2_wr_en;

    // =========================================================================
    // L2 Cache — MULTI-BANK: 4 banks (2MB each = 8MB total)
    // =========================================================================
    // L2 Cache — MULTI-BANK: 4 banks (2MB each = 8MB total)
    // Address interleating: bank_id = addr[7:6] (stripe per cache line; addr[5:0] are 0 for cache-line-aligned)
    // Setiap bank independent → parallel access dari core yang berbeda
    // =========================================================================
    localparam L2_BANK_SIZE = 2 * 1024 * 1024;  // 2MB per bank (8MB total)

    // L2 Bank internal signals
    wire [NUM_L2_BANKS-1:0]               l2_bank_rd_en;
    wire [NUM_L2_BANKS-1:0]               l2_bank_wr_en;
    wire [NUM_L2_BANKS*512-1:0]           l2_bank_rd_data;
    wire [NUM_L2_BANKS-1:0]               l2_bank_ready;
    wire [NUM_L2_BANKS*32-1:0]            l2_bank_hits;
    wire [NUM_L2_BANKS*32-1:0]            l2_bank_misses;
    wire [NUM_L2_BANKS*32-1:0]            l2_bank_writebacks;
    wire [NUM_L2_BANKS*32-1:0]            l2_bank_evictions;

    // Bank select: hash address bits [1:0] → bank 0-3
    // FIX: Use correct signal names
    wire [1:0] l2_bank_select_g = g_l1_l2_addr_mux[1:0];  // G-Core bank hash
    wire [1:0] l2_bank_select_a = a_l1_l2_addr_mux[1:0];  // A-Core bank hash (muxed)

    // Aggregated L2 stats
    wire [31:0] l2_total_hits, l2_total_misses, l2_total_writebacks, l2_total_evictions;

    // L2 Bank arbitration: only one bank active per L1 request at a time
    reg  [1:0] l2_active_bank_g;  // Currently serving G-Core
    reg  [1:0] l2_active_bank_a;  // Currently serving A-Core

    genvar l2_idx;
    generate
        for (l2_idx = 0; l2_idx < NUM_L2_BANKS; l2_idx = l2_idx + 1) begin : l2_bank_array
            // Enable signals: only respond when bank matches
            wire g_bank_en = (l2_bank_select_g == l2_idx[1:0]);
            wire a_bank_en = (l2_bank_select_a == l2_idx[1:0]);

            l2_cache #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .CACHE_SIZE(L2_BANK_SIZE),  // 2MB per bank
                .ASSOCIATIVITY(8),
                .LINE_SIZE(64),
                .NUM_L1_PORTS(2)
            ) u_l2_bank (
                .clk(clk),
                .rst_n(rst_n_sync),

                // L1 port 0: G-Core (only active when bank matches)
                .l1_0_addr(g_l1_l2_addr_mux),
                .l1_0_wr_data(g_l1_l2_wr_data_mux),
                .l1_0_rd_en(g_l1_l2_rd_en_mux && g_bank_en),
                .l1_0_wr_en(g_l1_l2_wr_en_mux && g_bank_en),
                .l1_0_rd_data(l2_bank_rd_data[l2_idx*512+511-:512]),
                .l1_0_ready(l2_bank_ready[l2_idx]),

                // L1 port 1: A-Core (only active when bank matches)
                .l1_1_addr(a_l1_l2_addr),
                .l1_1_wr_data(a_l1_l2_wr_data),
                .l1_1_rd_en(a_l1_l2_rd_en && a_bank_en),
                .l1_1_wr_en(a_l1_l2_wr_en && a_bank_en),
                .l1_1_rd_data(a_l2_bank_rd_data[l2_idx*CACHE_LINE_WIDTH+:CACHE_LINE_WIDTH]),
                .l1_1_ready(a_l2_bank_ready[l2_idx]),

                // L1 port 2: Unused
                .l1_2_addr({ADDR_WIDTH{1'b0}}),
                .l1_2_wr_data({64{1'b0}}),
                .l1_2_rd_en(1'b0),
                .l1_2_wr_en(1'b0),
                .l1_2_rd_data(),
                .l1_2_ready(),

                // External memory interface (per-bank array for arbiter)
                .mem_addr(l2_bank_mem_addr[l2_idx]),
                .mem_wr_data(l2_bank_mem_wr_data[l2_idx]),
                .mem_rd_en(l2_bank_rd_en[l2_idx]),
                .mem_wr_en(l2_bank_wr_en[l2_idx]),
                .mem_rd_data(l2_mem_rd_data),
                .mem_ready(l2_mem_ready),

                // Snoop (not connected)
                .snoop_addr(),
                .snoop_invalidate(),
                .snoop_update(),

                // Performance counters
                .l2_hits(l2_bank_hits[l2_idx*32+:32]),
                .l2_misses(l2_bank_misses[l2_idx*32+:32]),
                .l2_writebacks(l2_bank_writebacks[l2_idx*32+:32]),
                .l2_evictions(l2_bank_evictions[l2_idx*32+:32]),
                .snoop_invalidations()
            );
        end
    endgenerate

    // FIXED: G-Core L2 response multiplexed from active L2 bank
    // Response goes to the G-Core that initiated the request (based on bank selection)
    assign g_l1_l2_ready_mux = l2_bank_ready[l2_bank_select_g];
    assign g_l1_l2_rd_data_mux = l2_bank_rd_data[l2_bank_select_g*512+511-:512];
    
    // Route response to the requesting G-Core (based on rr_index and bank select)
    // Each G-Core gets the response from the L2 bank it addressed
    genvar g_core_mux_idx;
    generate
        for (g_core_mux_idx = 0; g_core_mux_idx < NUM_G_CORES; g_core_mux_idx = g_core_mux_idx + 1) begin : g_core_l2_mux
            // Each core gets response when its bank is selected
            assign g_l1_l2_rd_data[g_core_mux_idx] = (l2_bank_select_g == (g_core_mux_idx % NUM_L2_BANKS)) ?
                                                      l2_bank_rd_data[l2_bank_select_g*512+511-:512] :
                                                      {CACHE_LINE_WIDTH{1'b0}};
            assign g_l1_l2_ready[g_core_mux_idx] = (l2_bank_select_g == (g_core_mux_idx % NUM_L2_BANKS)) ?
                                                    l2_bank_ready[l2_bank_select_g] :
                                                    1'b0;
        end
    endgenerate

    // A-Core L2 response routing (port 1 of each L2 bank)
    assign a_l1_l2_rd_data = a_l2_bank_rd_data[l2_bank_select_a*CACHE_LINE_WIDTH+:CACHE_LINE_WIDTH];
    assign a_l1_l2_ready = a_l2_bank_ready[l2_bank_select_a];

    // A-Core worker L2 response mux
    genvar a_core_mux_idx;
    generate
        for (a_core_mux_idx = 0; a_core_mux_idx < NUM_A_CORES; a_core_mux_idx = a_core_mux_idx + 1) begin : a_core_l2_mux
            assign a_worker_l2_rd_data[a_core_mux_idx*CACHE_LINE_WIDTH+:CACHE_LINE_WIDTH] =
                (l2_bank_select_a == (a_core_mux_idx % NUM_L2_BANKS)) ?
                a_l2_bank_rd_data[l2_bank_select_a*CACHE_LINE_WIDTH+:CACHE_LINE_WIDTH] : {CACHE_LINE_WIDTH{1'b0}};
            assign a_worker_l2_ready[a_core_mux_idx] =
                (l2_bank_select_a == (a_core_mux_idx % NUM_L2_BANKS)) ?
                a_l2_bank_ready[l2_bank_select_a] : 1'b0;
        end
    endgenerate

    // OR all G-Core L1/L2 ready signals
    always_comb begin
        g_l1_l2_ready_any = 1'b0;
        for (int g_i = 0; g_i < NUM_G_CORES; g_i++) begin
            g_l1_l2_ready_any = g_l1_l2_ready_any || g_l1_l2_ready[g_i];
        end
    end

    // Memory fabric request: OR all bank requests
    assign l2_mem_rd_en = |l2_bank_rd_en;
    assign l2_mem_wr_en = |l2_bank_wr_en;

    // Mux per-bank mem_addr/mem_wr_data — only the bank with active request drives the bus
    integer l2_bank_i;
    always_comb begin
        l2_mem_addr    = {ADDR_WIDTH{1'b0}};
        l2_mem_wr_data = {CACHE_LINE_WIDTH{1'b0}};
        for (l2_bank_i = 0; l2_bank_i < NUM_L2_BANKS; l2_bank_i = l2_bank_i + 1) begin
            if (l2_bank_rd_en[l2_bank_i] || l2_bank_wr_en[l2_bank_i]) begin
                l2_mem_addr    = l2_bank_mem_addr[l2_bank_i];
                l2_mem_wr_data = l2_bank_mem_wr_data[l2_bank_i];
            end
        end
    end

    // Aggregated L2 stats (sum all banks)
    assign l2_total_hits = l2_bank_hits[31:0] + l2_bank_hits[63:32] +
                           l2_bank_hits[95:64] + l2_bank_hits[127:96];
    assign l2_total_misses = l2_bank_misses[31:0] + l2_bank_misses[63:32] +
                             l2_bank_misses[95:64] + l2_bank_misses[127:96];
    assign l2_total_writebacks = l2_bank_writebacks[31:0] + l2_bank_writebacks[63:32] +
                                 l2_bank_writebacks[95:64] + l2_bank_writebacks[127:96];
    assign l2_total_evictions = l2_bank_evictions[31:0] + l2_bank_evictions[63:32] +
                                l2_bank_evictions[95:64] + l2_bank_evictions[127:96];

    // =========================================================================
    // Memory Fabric (172-bit unified bus)
    // =========================================================================
    memory_fabric #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_LINE_WIDTH(CACHE_LINE_WIDTH)
    ) u_memory_fabric (
        .clk(clk),
        .rst_n(rst_n_sync),
        .fabric_addr(l2_mem_addr),
        .fabric_rd_en(l2_mem_rd_en),
        .fabric_wr_en(l2_mem_wr_en),
        .fabric_rd_data(l2_mem_rd_data),
        .fabric_wr_data(l2_mem_wr_data),
        .fabric_ready(l2_mem_ready),
        .mem_addr(mem_addr),
        .mem_rd_en(mem_rd_en),
        .mem_wr_en(mem_wr_en),
        .mem_rd_data(mem_rd_data),
        .mem_wr_data(mem_wr_data),
        .mem_ready(mem_ready),
        // Performance counters
        .l2_hits(),
        .l2_misses(),
        .l2_writebacks(),
        .l2_evictions(),
        .l1_requests(),
        .l2_requests(),
        .mem_requests(),
        .total_read_bytes(),
        .total_write_bytes()
    );

    // Route memory fabric read data / ready back to core modules via shared bus
    // Core modules read fabric_rd_data/fabric_ready as inputs; memory_fabric
    // drives l2_mem_rd_data/l2_mem_ready — bridge the two domains here.
    assign fabric_rd_data = l2_mem_rd_data;
    assign fabric_ready   = l2_mem_ready;

    // =========================================================================
    // Output assignments
    // =========================================================================
    // Results: G-Core via scheduler, A-Core direct route (bypass scheduler)
    
    // FIX: Route G-Core result from scheduler to testbench output
    // Scheduler MUX selects between SQ and MQ results
    assign game_result = (sched_select) ? mq_g_task_result : sq_g_task_result;
    assign game_result_valid = (sched_select) ? mq_g_task_result_valid : sq_g_task_result_valid;
    
    // AI result driven directly from A-Core #0 (FIX: avoid 1-cycle pulse issue)
    assign ai_result = ai_result_direct;
    assign ai_result_valid = ai_result_valid_direct;

    assign sys_status = {
        8'b0,
        npu_complete[NUM_NPU_CLUSTERS-1:0],
        a_core_complete[7:0],
        h_core_complete[7:0],
        g_core_complete[3:0],
        rt_complete,
        sys_interrupt
    };

    // Performance counters - use scheduler stats (more accurate)
    assign perf_counter_g = sched_total_completed;
    assign perf_counter_a = sched_total_completed;  // Combined for now

    // FIX #6: NPU performance counter - use accumulating counter, not $countones
    // $countones only counts bits in current cycle, not cumulative
    reg [63:0] npu_op_accumulator;
    reg [NUM_NPU_CLUSTERS-1:0] npu_complete_prev;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            npu_op_accumulator <= 64'b0;
            npu_complete_prev <= {NUM_NPU_CLUSTERS{1'b0}};
        end else begin
            // Detect rising edge on each NPU complete signal
            for (integer npu_i = 0; npu_i < NUM_NPU_CLUSTERS; npu_i = npu_i + 1) begin
                if (npu_complete[npu_i] && !npu_complete_prev[npu_i]) begin
                    npu_op_accumulator <= npu_op_accumulator + 1;
                end
            end
            npu_complete_prev <= npu_complete;
        end
    end

    assign perf_counter_npu = npu_op_accumulator;

    // Scheduler debug outputs (port outputs, not internal wires)
    // Already declared in port list — direct assignment to ports

    // =========================================================================
    // ATM FEATURES: Intel + AMD Best Features Integration
    // =========================================================================

    // ─────────────────────────────────────────────────────────────
    // 1. SmartShift Power (AMD) - Dynamic power redistribution
    // ─────────────────────────────────────────────────────────────
    wire [DATA_WIDTH-1:0]   ss_g_budget, ss_a_budget, ss_h_budget, ss_npu_budget;
    wire                    ss_redist_active;
    wire [DATA_WIDTH-1:0]   ss_total_alloc, ss_surplus, ss_deficit;
    wire [31:0]             ss_redist_count, ss_g_boost_cnt, ss_a_boost_cnt, ss_tdp_hits;

    // Demand signals (simplified from core activity)
    wire [DATA_WIDTH-1:0] g_core_demand_mw = (g0_busy) ? 120000 : 40000;
    wire [DATA_WIDTH-1:0] a_core_demand_mw = (a0_busy) ? 150000 : 50000;
    wire [DATA_WIDTH-1:0] h_core_demand_mw = (|h_core_busy) ? 80000 : 30000;
    wire [DATA_WIDTH-1:0] npu_demand_mw = (|npu_busy) ? 30000 : 10000;

    // Mode detection (simplified)
    wire gaming_mode_active = game_cmd_valid && (game_cmd_data[31:24] <= 8'h07);
    wire ai_mode_active = ai_cmd_valid && (ai_cmd_data[63:56] >= 8'h20);
    wire mixed_mode_active = gaming_mode_active && ai_mode_active;
    wire gpu_bound_flag = game_cmd_data[15:0] > 16'h1000;
    wire [DATA_WIDTH-1:0] tdp_limit_mw = 250000;  // 250W default

    smartshift #(
        .DATA_WIDTH(DATA_WIDTH),
        .G_CORE_BASE_W(80),
        .A_CORE_BASE_W(100),
        .H_CORE_BASE_W(50),
        .NPU_BASE_W(20)
    ) u_smartshift (
        .clk(clk),
        .rst_n(rst_n_sync),
        .g_core_demand_mw(g_core_demand_mw),
        .a_core_demand_mw(a_core_demand_mw),
        .h_core_demand_mw(h_core_demand_mw),
        .npu_demand_mw(npu_demand_mw),
        .gaming_mode(gaming_mode_active),
        .ai_mode(ai_mode_active),
        .mixed_mode(mixed_mode_active),
        .gpu_bound(gpu_bound_flag),
        .tdp_limit_mw(tdp_limit_mw),
        .g_core_budget_mw(ss_g_budget),
        .a_core_budget_mw(ss_a_budget),
        .h_core_budget_mw(ss_h_budget),
        .npu_budget_mw(ss_npu_budget),
        .redistribution_active(ss_redist_active),
        .total_allocated_mw(ss_total_alloc),
        .power_surplus_mw(ss_surplus),
        .power_deficit_mw(ss_deficit),
        .redistribution_count(ss_redist_count),
        .g_core_boost_count(ss_g_boost_cnt),
        .a_core_boost_count(ss_a_boost_cnt),
        .tdp_limit_hit_count(ss_tdp_hits)
    );

    // ─────────────────────────────────────────────────────────────
    // 2. Turbo Boost Hybrid (Intel + AMD)
    // ─────────────────────────────────────────────────────────────
    wire [DATA_WIDTH-1:0]   tb_g_freq, tb_a_freq, tb_h_freq, tb_npu_freq;
    wire                    tb_active, tb_gaming, tb_ai, tb_throttle, tb_tdp_lim;
    wire [31:0]             tb_entry, tb_timeout_cnt, tb_throttle_cnt, tb_cooldown;

    // Simplified thermal model
    reg [7:0] current_temp_c;
    reg [DATA_WIDTH-1:0] current_power_mw;
    reg turbo_enable_flag;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            current_temp_c <= 8'd65;
            current_power_mw <= 200000;
            turbo_enable_flag <= 1'b1;
        end else begin
            // Temperature tracks power (simplified)
            if (current_power_mw > 250000) begin
                current_temp_c <= current_temp_c + 1;
            end else if (current_power_mw < 150000) begin
                current_temp_c <= (current_temp_c > 60) ? current_temp_c - 1 : current_temp_c;
            end
            current_power_mw <= g_core_demand_mw + a_core_demand_mw + h_core_demand_mw + npu_demand_mw;
            turbo_enable_flag <= (current_temp_c < 90);
        end
    end

    turbo_boost #(
        .DATA_WIDTH(DATA_WIDTH),
        .G_BASE_CLOCK_MHZ(6000),
        .G_TURBO_CLOCK_MHZ(6500),
        .A_BASE_CLOCK_MHZ(4000),
        .A_TURBO_CLOCK_MHZ(4500)
    ) u_turbo_boost (
        .clk(clk),
        .rst_n(rst_n_sync),
        .gaming_mode(gaming_mode_active),
        .ai_mode(ai_mode_active),
        .mixed_mode(mixed_mode_active),
        .gpu_bound(gpu_bound_flag),
        .current_temp_c(current_temp_c),
        .current_power_mw(current_power_mw),
        .tdp_limit_mw(tdp_limit_mw),
        .turbo_enable(turbo_enable_flag),
        .turbo_override(1'b0),
        .g_core_freq_mhz(tb_g_freq),
        .a_core_freq_mhz(tb_a_freq),
        .h_core_freq_mhz(tb_h_freq),
        .npu_freq_mhz(tb_npu_freq),
        .turbo_active(tb_active),
        .turbo_gaming(tb_gaming),
        .turbo_ai(tb_ai),
        .thermal_throttle(tb_throttle),
        .tdp_limited(tb_tdp_lim),
        .turbo_entry_count(tb_entry),
        .turbo_timeout_count(tb_timeout_cnt),
        .thermal_throttle_count(tb_throttle_cnt),
        .cooldown_count(tb_cooldown)
    );

    // Debug outputs untuk ATM features (bisa diakses testbench)
    wire [31:0] atm_smartshift_count = ss_redist_count;
    wire [31:0] atm_turbo_entry_count = tb_entry;
    wire [31:0] atm_turbo_timeout = tb_timeout_cnt;
    wire [31:0] atm_throttle_count = tb_throttle_cnt;
    wire        atm_turbo_active = tb_active;
    wire        atm_ss_active = ss_redist_active;

    // Debug: Connect core busy signals to output ports (use first core)
    assign g_core_busy = g_core_busy_internal[0];
    assign a_core_busy = a_core_busy_internal[0];

    // =========================================================================
    // ATM FEATURES: Additional Modules (Power Monitor, μop Cache, V-Cache)
    // =========================================================================

    // ─────────────────────────────────────────────────────────────
    // 3. Power Monitor (Intel RAPL) - Energy accounting + limits
    // ─────────────────────────────────────────────────────────────
    wire [63:0]                   pm_energy_g, pm_energy_a, pm_energy_h, pm_energy_npu;
    wire [DATA_WIDTH-1:0]        pm_avg_g, pm_avg_a, pm_avg_h, pm_avg_npu, pm_avg_total;
    wire                          pm_pl1_ex, pm_pl2_ex;
    wire [4:0]                    pm_dpl1_ex, pm_dpl2_ex;
    wire                          pm_throttle_req_int;
    wire [3:0]                    pm_throttle_domain;
    wire [31:0]                   pm_pl1_vcnt, pm_pl2_vcnt, pm_throttle_ecnt;

    power_monitor #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_DOMAINS(5),
        .ENERGY_UNIT_uJ(1),
        .POWER_AVG_WINDOW(1000)
    ) u_power_monitor (
        .clk(clk),
        .rst_n(rst_n_sync),

        // Instantaneous power input
        .g_core_power_mw(g_core_demand_mw),
        .a_core_power_mw(a_core_demand_mw),
        .h_core_power_mw(h_core_demand_mw),
        .npu_power_mw(npu_demand_mw),
        .memory_power_mw(10000),  // Fixed 10W memory estimate

        // PL1 limits (long-term TDP)
        .pl1_g_core_mw(80000),
        .pl1_a_core_mw(100000),
        .pl1_h_core_mw(50000),
        .pl1_npu_mw(20000),
        .pl1_total_mw(tdp_limit_mw),

        // PL2 limits (short-term turbo)
        .pl2_g_core_mw(120000),
        .pl2_a_core_mw(150000),
        .pl2_total_mw(tdp_limit_mw + 50000),
        .pl2_time_window_cycles(28000),

        // Control
        .enable_monitor(1'b1),
        .enable_limit_enforce(1'b1),

        // Energy counter output
        .energy_g_core_uj(pm_energy_g),
        .energy_a_core_uj(pm_energy_a),
        .energy_h_core_uj(pm_energy_h),
        .energy_npu_uj(pm_energy_npu),
        .energy_total_uj(pm_energy_total_uj),

        // Average power output
        .avg_g_core_power_mw(pm_avg_g),
        .avg_a_core_power_mw(pm_avg_a),
        .avg_h_core_power_mw(pm_avg_h),  // NEW
        .avg_npu_power_mw(pm_avg_npu),  // NEW
        .avg_total_power_mw(pm_avg_total),

        // Limit status
        .pl1_exceeded(pm_pl1_ex),
        .pl2_exceeded(pm_pl2_ex),
        .domain_pl1_exceeded(pm_dpl1_ex),
        .domain_pl2_exceeded(pm_dpl2_ex),

        // Throttle request
        .throttle_request(pm_throttle_req_int),
        .throttle_domain(pm_throttle_domain),

        // Debug counters
        .pl1_violation_count(pm_pl1_vcnt),
        .pl2_violation_count(pm_pl2_vcnt),
        .throttle_event_count(pm_throttle_ecnt)
    );

    // Route power monitor signals to output ports
    assign pm_energy_g_core_uj    = pm_energy_g;
    assign pm_energy_a_core_uj    = pm_energy_a;
    assign pm_energy_npu_uj       = pm_energy_npu;  // NEW: NPU energy
    assign pm_avg_g_power_mw      = pm_avg_g;
    assign pm_avg_a_power_mw      = pm_avg_a;
    assign pm_avg_npu_power_mw    = pm_avg_npu;  // NEW: NPU power
    assign pm_avg_total_power_mw  = pm_avg_total;
    assign pm_pl1_exceeded        = pm_pl1_ex;
    assign pm_pl2_exceeded        = pm_pl2_ex;
    assign pm_throttle_req        = pm_throttle_req_int;
    assign pm_pl1_violations      = pm_pl1_vcnt;
    assign pm_pl2_violations      = pm_pl2_vcnt;

    // ─────────────────────────────────────────────────────────────
    // 4. μop Cache (Intel) — MULTI-INSTANCE: Per G-Core (16 instances)
    // Setiap G-Core punya uop cache sendiri untuk decode bandwidth maksimal
    // ─────────────────────────────────────────────────────────────
    wire [NUM_G_CORES-1:0]              uop_hit;
    wire [NUM_G_CORES-1:0]              uop_ready;
    wire [NUM_G_CORES-1:0]              uop_decode_req;
    wire [NUM_G_CORES*32-1:0]           uop_hits, uop_misses, uop_evictions;
    wire [7:0]                          uop_hit_rates;

    // Aggregated uop cache stats
    wire [31:0] uop_total_hits, uop_total_misses, uop_total_evictions;
    wire [7:0]  uop_avg_hit_rate;

    genvar uoc_idx;
    generate
        for (uoc_idx = 0; uoc_idx < NUM_G_CORES; uoc_idx = uoc_idx + 1) begin : uop_cache_array
            uop_cache #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .INST_WIDTH(INST_WIDTH),
                .NUM_ENTRIES(512),
                .ASSOCIATIVITY(8),
                .NUM_SETS(64)
            ) u_uop_cache (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Fetch interface — each G-Core has its own uop cache
                // FIX: Use indexed access for array, not whole array
                .fetch_pc(g_core_busy_internal[uoc_idx] ? g_l1_l2_addr[uoc_idx] : sched_g_core_cmd_addr),
                // FIXED: Use parameterized padding based on INST_WIDTH
                .fetch_instruction({{(INST_WIDTH - 32){1'b0}}, sched_g_core_cmd_data}),
                .fetch_valid(sched_g_core_cmd_valid && (uoc_idx == g_core_last_selected || uoc_idx == 0)),
                .uop_cache_hit(uop_hit[uoc_idx]),
                .uop_cache_ready(uop_ready[uoc_idx]),
                // Micro-op output (not routed individually - aggregated)
                .uop_micro_ops(),
                .uop_count(),
                .uop_valid(),
                // Decode interface
                .decode_request(uop_decode_req[uoc_idx]),
                .decode_complete(uop_decode_req[uoc_idx]),
                .decode_micro_ops(),
                .decode_uop_count(),
                // Performance counters
                .uop_hits(uop_hits[uoc_idx*32+:32]),
                .uop_misses(uop_misses[uoc_idx*32+:32]),
                .uop_evictions(uop_evictions[uoc_idx*32+:32]),
                .uop_hit_rate_percent(uop_hit_rates[uoc_idx])
            );
        end
    endgenerate

    // Aggregate stats (sum first 4 uop caches — representative sampling)
    assign uop_total_hits = uop_hits[31:0] + uop_hits[63:32] + uop_hits[95:64] + uop_hits[127:96];
    assign uop_total_misses = uop_misses[31:0] + uop_misses[63:32] + uop_misses[95:64] + uop_misses[127:96];
    assign uop_total_evictions = uop_evictions[31:0] + uop_evictions[63:32] + uop_evictions[95:64] + uop_evictions[127:96];
    assign uop_avg_hit_rate = uop_hit_rates[7:0];  // Use G-Core #0 as representative

    // ─────────────────────────────────────────────────────────────
    // 5. V-Cache (AMD 3D V-Cache) — MULTI-INSTANCE: 4 instances (per CCX cluster)
    // Setiap CCX (4 G-Cores) punya V-Cache sendiri, total 4×48MB = 192MB
    // ─────────────────────────────────────────────────────────────
    localparam NUM_VCACHE = 4;  // 4 CCX clusters

    wire [NUM_VCACHE-1:0]               vc_hit_int;
    wire [NUM_VCACHE-1:0]               vc_miss_int;
    wire [NUM_VCACHE*8-1:0]             vc_latency_int;
    wire [NUM_VCACHE*32-1:0]            vc_hits_int, vc_misses_int, vc_evictions_int, vc_promotions_int;
    wire [NUM_VCACHE*8-1:0]             vc_hit_rate_int;
    wire [NUM_VCACHE*32-1:0]            vc_cap_used_int;
    wire [NUM_VCACHE*DATA_WIDTH-1:0]    vcache_rd_data;
    wire [NUM_VCACHE-1:0]               vcache_rd_valid;
    wire [NUM_VCACHE-1:0]               vcache_rd_ready;
    wire [NUM_VCACHE-1:0]               vcache_wr_complete;
    wire                                vcache_rd_valid_agg;
    wire                                vcache_wr_complete_agg;
    wire [DATA_WIDTH-1:0]               vcache_rd_data_agg;

    // V-Cache address routing: each CCX handles 1/4 of address space
    // FIX: Also accept requests from memory fabric (not just L2 miss)
    // This allows V-Cache to function as L3 cache for all memory traffic
    wire [1:0] vc_ccx_select_l2 = l2_mem_addr[ADDR_WIDTH-1:ADDR_WIDTH-2];
    wire [1:0] vc_ccx_select_fab = mem_addr[ADDR_WIDTH-1:ADDR_WIDTH-2];
    
    // Combined request enable: L2 miss OR memory fabric access
    // FIX: Ensure V-Cache is always enabled for L2 traffic
    wire vc_req_from_l2 = l2_mem_rd_en || l2_mem_wr_en;  // Include writes too
    wire vc_req_from_fabric = mem_rd_en && !l2_mem_rd_en;  // Direct fabric access
    wire [1:0] vc_ccx_select = vc_req_from_fabric ? vc_ccx_select_fab : vc_ccx_select_l2;
    
    // CRITICAL FIX: Broadcast to ALL V-Cache instances instead of selective routing
    // This ensures V-Cache always gets traffic regardless of address mapping
    wire vc_enable_all = vc_req_from_l2 || vc_req_from_fabric;

    genvar vc_idx;
    generate
        for (vc_idx = 0; vc_idx < NUM_VCACHE; vc_idx = vc_idx + 1) begin : vcache_array
            // Each V-Cache covers 48MB of the 192MB total address range
            // Range: [vc_idx*48MB : (vc_idx+1)*48MB)
            // Address bits [27:26] select the CCX (48MB = 2^25 * 3, use top bits)
            wire vc_range_match = (vc_idx == (vc_req_from_fabric ? mem_addr[27:26] : l2_mem_addr[27:26]));
            vcache #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .VCACHE_CAPACITY_MB(48),  // 48MB per CCX (192MB total / 4)
                .VCACHE_LATENCY(7),
                .BASE_L3_LATENCY(4),
                .CACHE_LINE_SIZE(32),
                .ASSOCIATIVITY(16),
                .NUM_LINES(1536)  // 48MB / 32B = 1.5M, simplified for sim
            ) u_vcache (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Request interface — only enable the matching V-Cache instance
                .req_addr(vc_req_from_fabric ? mem_addr : l2_mem_addr),
                .req_wr_data(vc_req_from_fabric ? mem_wr_data : l2_mem_wr_data),
                .req_rd_en(vc_enable_all && vc_range_match),  // Only matching instance
                .req_wr_en(vc_enable_all && l2_mem_wr_en && vc_range_match),  // Only matching instance
                .gaming_workload(gaming_mode_active),
                .ai_workload(ai_mode_active),
                // Response interface
                .rd_data(vcache_rd_data[vc_idx*DATA_WIDTH+:DATA_WIDTH]),
                .rd_valid(vcache_rd_valid[vc_idx]),
                .rd_ready(vcache_rd_ready[vc_idx]),
                .wr_complete(vcache_wr_complete[vc_idx]),
                // Hit/miss status
                .vcache_hit(vc_hit_int[vc_idx]),
                .vcache_miss(vc_miss_int[vc_idx]),
                // Latency output
                .access_latency(vc_latency_int[vc_idx*8+:8]),
                // Working set promotion
                .promote_line(1'b0),
                .promote_addr({ADDR_WIDTH{1'b0}}),
                // Debug / performance counters
                .vcache_hits(vc_hits_int[vc_idx*32+:32]),
                .vcache_misses(vc_misses_int[vc_idx*32+:32]),
                .vcache_evictions(vc_evictions_int[vc_idx*32+:32]),
                .vcache_promotions(vc_promotions_int[vc_idx*32+:32]),
                .vcache_hit_rate_pct(vc_hit_rate_int[vc_idx*8+:8]),
                .vcache_capacity_used_mb(vc_cap_used_int[vc_idx*32+:32])
            );
        end
    endgenerate

    // Aggregate V-Cache signals (OR hits, sum counters)
    assign vc_hit           = |vc_hit_int;
    assign vc_miss          = |vc_miss_int;
    assign vc_latency       = vc_latency_int[7:0];  // CCX #0 latency as representative
    assign vc_hits          = vc_hits_int[31:0] + vc_hits_int[63:32] + vc_hits_int[95:64] + vc_hits_int[127:96];
    assign vc_misses        = vc_misses_int[31:0] + vc_misses_int[63:32] + vc_misses_int[95:64] + vc_misses_int[127:96];
    assign vc_evictions     = vc_evictions_int[31:0] + vc_evictions_int[63:32] + vc_evictions_int[95:64] + vc_evictions_int[127:96];
    assign vc_promotions    = vc_promotions_int[31:0] + vc_promotions_int[63:32] + vc_promotions_int[95:64] + vc_promotions_int[127:96];
    assign vc_hit_rate_pct  = vc_hit_rate_int[7:0];  // CCX #0 as representative
    assign vc_capacity_used_mb = vc_cap_used_int[31:0] + vc_cap_used_int[63:32] + vc_cap_used_int[95:64] + vc_cap_used_int[127:96];

    // Route V-Cache response data to cache hierarchy
    // Select from the matching V-Cache instance based on address
    wire [1:0] vc_resp_select = mem_addr[27:26];
    assign vcache_rd_valid_agg = vcache_rd_valid[vc_resp_select];
    assign vcache_wr_complete_agg = vcache_wr_complete[vc_resp_select];
    assign vcache_rd_data_agg = vcache_rd_data[vc_resp_select*DATA_WIDTH+:DATA_WIDTH];

    // =========================================================================
    // 6. Speed Shift / HWP (Intel) - Hardware P-State Control
    // =========================================================================
    wire [3:0]                  hwp_g_p_int, hwp_a_p_int, hwp_h_p_int, hwp_npu_p_int;
    wire [DATA_WIDTH-1:0]       hwp_g_f_int, hwp_a_f_int, hwp_h_f_int, hwp_npu_f_int;
    wire                        hwp_act_int, hwp_sw_ovr_int, hwp_chg_int;
    wire [3:0]                  hwp_last_domain_int;
    wire [31:0]                 hwp_trans_int, hwp_sw_cnt_int, hwp_thrm_cnt_int, hwp_resp_int;

    // Utilization estimation from core busy signals
    wire [7:0] g_util = (g0_busy) ? 8'd85 : 8'd15;
    wire [7:0] a_util = (a0_busy) ? 8'd90 : 8'd10;
    wire [7:0] h_util = (|h_core_busy) ? 8'd70 : 8'd20;
    wire [7:0] n_util = (|npu_busy) ? 8'd75 : 8'd25;

    // EPP values per workload type
    wire [7:0] epp_default = 8'h80;  // Balanced
    wire [7:0] epp_gaming  = 8'h40;  // Performance bias
    wire [7:0] epp_ai      = 8'h60;  // Perf-balance
    wire [7:0] epp_idle    = 8'hE0;  // Power savings

    // Dynamic EPP based on workload
    wire [7:0] epp_g_dyn = gaming_mode_active ? epp_gaming : (idle_workload_est ? epp_idle : epp_default);
    wire [7:0] epp_a_dyn = ai_mode_active ? epp_ai : (idle_workload_est ? epp_idle : epp_default);
    wire [7:0] epp_h_dyn = idle_workload_est ? epp_idle : epp_default;
    wire [7:0] epp_n_dyn = ai_mode_active ? epp_ai : (idle_workload_est ? epp_idle : epp_default);

    // CRITICAL FIX: Workload detection based on core activity, not just command dispatch
    // gaming_mode_active only high for 1 cycle during dispatch, but we need it high while core is busy
    wire hwp_gaming_workload = g0_busy || g1_busy || |g_core_busy_internal[NUM_G_CORES-1:1];
    wire hwp_ai_workload = a0_busy || |a_core_busy_internal;
    wire hwp_mixed_workload = hwp_gaming_workload && hwp_ai_workload;
    
    // Simple idle detection
    wire idle_workload_est = !hwp_gaming_workload && !hwp_ai_workload && !(|h_core_busy) && !(|npu_busy);

    speed_shift_hwp #(
        .DATA_WIDTH(DATA_WIDTH),
        .NUM_DOMAINS(4),
        .NUM_P_STATES(16),
        .RESPONSE_CYCLES(8),
        .G_MAX_FREQ_MHZ(6500),
        .A_MAX_FREQ_MHZ(4500),
        .H_MAX_FREQ_MHZ(3000),
        .N_MAX_FREQ_MHZ(1000)
    ) u_speed_shift_hwp (
        .clk(clk),
        .rst_n(rst_n_sync),

        // Hardware utilization inputs
        .g_utilization_pct(g_util),
        .a_utilization_pct(a_util),
        .h_utilization_pct(h_util),
        .npu_utilization_pct(n_util),

        .current_temp_c(current_temp_c),
        .current_power_mw(current_power_mw),

        // EPP inputs
        .epp_g_core(epp_g_dyn),
        .epp_a_core(epp_a_dyn),
        .epp_h_core(epp_h_dyn),
        .epp_npu(epp_n_dyn),

        // Workload type hints - FIX: Use core activity-based workload detection
        .gaming_workload(hwp_gaming_workload),
        .ai_workload(hwp_ai_workload),
        .mixed_workload(hwp_mixed_workload),
        .idle_workload(idle_workload_est),

        // HWP control
        .hwp_enable(1'b1),
        .hwp_override(1'b0),
        .sw_p_state_req(4'd0),
        .sw_p_state_valid(1'b0),

        // P-state outputs
        .g_p_state(hwp_g_p_int),
        .a_p_state(hwp_a_p_int),
        .h_p_state(hwp_h_p_int),
        .npu_p_state(hwp_npu_p_int),

        .g_freq_mhz(hwp_g_f_int),
        .a_freq_mhz(hwp_a_f_int),
        .h_freq_mhz(hwp_h_f_int),
        .npu_freq_mhz(hwp_npu_f_int),

        // Status signals
        .hwp_active(hwp_act_int),
        .sw_override_active(hwp_sw_ovr_int),
        .last_p_state_change_domain(hwp_last_domain_int),
        .p_state_changed(hwp_chg_int),

        // Debug counters
        .hwp_transition_count(hwp_trans_int),
        .sw_override_count(hwp_sw_cnt_int),
        .thermal_limited_count(hwp_thrm_cnt_int),
        .perf_limited_count(),
        .hwp_avg_p_state_g(),
        .hwp_avg_p_state_a(),
        .hwp_response_cycles(hwp_resp_int)
    );

    // Route Speed Shift signals to output ports
    assign hwp_g_p_state       = hwp_g_p_int;
    assign hwp_a_p_state       = hwp_a_p_int;
    assign hwp_h_p_state       = hwp_h_p_int;
    assign hwp_npu_p_state     = hwp_npu_p_int;
    assign hwp_g_freq_mhz      = hwp_g_f_int;
    assign hwp_a_freq_mhz      = hwp_a_f_int;
    assign hwp_h_freq_mhz      = hwp_h_f_int;
    assign hwp_npu_freq_mhz    = hwp_npu_f_int;
    assign hwp_active          = hwp_act_int;
    assign hwp_sw_override     = hwp_sw_ovr_int;
    assign hwp_transitions     = hwp_trans_int;
    assign hwp_sw_overrides    = hwp_sw_cnt_int;
    assign hwp_thermal_limits  = hwp_thrm_cnt_int;
    assign hwp_response_cycles = hwp_resp_int;

    // =========================================================================
    // 7. Power Management Integration
    // =========================================================================
    
    // Power management signals
    wire [10:0]                   g_core_voltage_mv, a_core_voltage_mv, h_core_voltage_mv, npu_voltage_mv;
    wire [NUM_G_CORES-1:0]        g_core_power_gate;
    wire [NUM_H_CORES-1:0]        h_core_power_gate;
    wire [NUM_A_CORES-1:0]        a_core_power_gate;
    wire [NUM_NPU_CLUSTERS-1:0]   npu_power_gate;
    wire [31:0]                   total_power_mw;
    wire                          thermal_throttle;
    
    power_management #(
        .NUM_G_CORES(NUM_G_CORES),
        .NUM_H_CORES(NUM_H_CORES),
        .NUM_A_CORES(NUM_A_CORES),
        .NUM_NPU_CLUSTERS(NUM_NPU_CLUSTERS)
    ) u_power_management (
        .clk(clk),
        .rst_n(rst_n_sync),
        
        // Core busy signals for power gating
        .g_core_busy(g_core_busy_internal),
        .h_core_busy(h_core_busy_internal),
        .a_core_busy(a_core_busy),
        .npu_busy(npu_busy_internal),
        
        // Power mode control
        .power_mode_sel(sys_power_mode[1:0]),
        
        // Voltage and frequency control
        .g_core_voltage_mv(g_core_voltage_mv),
        .a_core_voltage_mv(a_core_voltage_mv),
        .h_core_voltage_mv(h_core_voltage_mv),
        .npu_voltage_mv(npu_voltage_mv),
        
        // Power gating control
        .g_core_power_gate(g_core_power_gate),
        .h_core_power_gate(h_core_power_gate),
        .a_core_power_gate(a_core_power_gate),
        .npu_power_gate(npu_power_gate),
        
        // Power monitoring
        .total_power_mw(total_power_mw),
        .thermal_throttle(thermal_throttle)
    );

    // =========================================================================
    // 8. Hardware Prefetcher (Intel) - MULTI-INSTANCE: 4 instances (per core cluster)
    // Setiap cluster punya prefetcher sendiri untuk pattern detection yang lebih akurat
    // =========================================================================
    localparam NUM_PREFETCHERS = 4;

    wire [NUM_PREFETCHERS*4-1:0]    pf_stream_act;
    wire [NUM_PREFETCHERS*16-1:0]   pf_s0_stride, pf_s1_stride, pf_s2_stride, pf_s3_stride;
    wire [NUM_PREFETCHERS*32-1:0]   pf_req_cnt, pf_use_cnt, pf_unuse_cnt, pf_cov_cnt;
    wire [NUM_PREFETCHERS*32-1:0]   pf_alloc_cnt, pf_dealloc_cnt;
    wire [NUM_PREFETCHERS*8-1:0]    pf_util_pct;
    
    // FIX: Prefetcher output wires (connect to memory fabric for actual prefetching)
    wire [NUM_PREFETCHERS-1:0]      pf_valid_int;
    wire [NUM_PREFETCHERS*ADDR_WIDTH-1:0] pf_addr_int;

    genvar pf_idx;
    generate
        for (pf_idx = 0; pf_idx < NUM_PREFETCHERS; pf_idx = pf_idx + 1) begin : prefetcher_array
            // FIX: All prefetchers monitor L1 access patterns for stride detection
            // This ensures prefetcher sees all access patterns, not just misses
            wire pf_l1_miss_valid = mem_rd_en;  // Use direct memory access

            hw_prefetcher #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .NUM_STREAMS(4),
                .PREFETCH_DISTANCE(4),
                .MAX_STRIDE_BITS(16),
                .CONFIDENCE_MAX(8),
                .USELESS_THRESHOLD(4),
                .CACHE_LINE_BITS(6)
            ) u_hw_prefetcher (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Access monitor interface - watch all memory accesses
                .miss_addr(mem_addr),
                .miss_valid(pf_l1_miss_valid),
                .l1_access_addr(mem_addr),
                .l1_access_valid(mem_rd_en),
                // Workload hints
                .gaming_workload(gaming_mode_active),
                .ai_workload(ai_mode_active),
                .streaming_workload(1'b0),
                // Prefetcher control
                .prefetcher_enable(1'b1),
                .aggressive_mode(gaming_mode_active),
                // Prefetch request output — now connected!
                .pf_valid(pf_valid_int[pf_idx]),
                .pf_addr(pf_addr_int[pf_idx*ADDR_WIDTH+:ADDR_WIDTH]),
                .pf_stream_id(),
                .pf_ready(mem_ready),
                // Prefetch result tracking
                .pf_result_addr(l2_mem_addr),
                .pf_result_used(l2_mem_rd_en && l2_mem_ready),
                .pf_result_unused(pf_use_cnt[pf_idx*32+:32] > 0 && pf_unuse_cnt[pf_idx*32+:32] > pf_use_cnt[pf_idx*32+:32]),
                // Status outputs
                .stream_active(pf_stream_act[pf_idx*4+:4]),
                .stream0_stride(pf_s0_stride[pf_idx*16+:16]),
                .stream1_stride(pf_s1_stride[pf_idx*16+:16]),
                .stream2_stride(pf_s2_stride[pf_idx*16+:16]),
                .stream3_stride(pf_s3_stride[pf_idx*16+:16]),
                // Debug counters
                .pf_total_requests(pf_req_cnt[pf_idx*32+:32]),
                .pf_useful(pf_use_cnt[pf_idx*32+:32]),
                .pf_useless(pf_unuse_cnt[pf_idx*32+:32]),
                .pf_coverage(pf_cov_cnt[pf_idx*32+:32]),
                .pf_streams_allocated(pf_alloc_cnt[pf_idx*32+:32]),
                .pf_streams_deallocated(pf_dealloc_cnt[pf_idx*32+:32]),
                .pf_utilization_pct(pf_util_pct[pf_idx*8+:8])
            );
        end
    endgenerate

    // Aggregate prefetcher signals
    assign pf_stream_active       = pf_stream_act[3:0] | pf_stream_act[7:4] | pf_stream_act[11:8] | pf_stream_act[15:12];
    assign pf_stream0_stride      = pf_s0_stride[15:0];
    assign pf_stream1_stride      = pf_s1_stride[15:0];
    assign pf_stream2_stride      = pf_s2_stride[15:0];
    assign pf_stream3_stride      = pf_s3_stride[15:0];
    assign pf_total_requests      = pf_req_cnt[31:0] + pf_req_cnt[63:32] + pf_req_cnt[95:64] + pf_req_cnt[127:96];
    assign pf_useful_count        = pf_use_cnt[31:0] + pf_use_cnt[63:32] + pf_use_cnt[95:64] + pf_use_cnt[127:96];
    assign pf_useless_count       = pf_unuse_cnt[31:0] + pf_unuse_cnt[63:32] + pf_unuse_cnt[95:64] + pf_unuse_cnt[127:96];
    assign pf_coverage            = pf_cov_cnt[31:0] + pf_cov_cnt[63:32] + pf_cov_cnt[95:64] + pf_cov_cnt[127:96];
    assign pf_alloc_streams       = pf_alloc_cnt[31:0] + pf_alloc_cnt[63:32] + pf_alloc_cnt[95:64] + pf_alloc_cnt[127:96];
    assign pf_dealloc_streams     = pf_dealloc_cnt[31:0] + pf_dealloc_cnt[63:32] + pf_dealloc_cnt[95:64] + pf_dealloc_cnt[127:96];
    assign pf_utilization_pct     = pf_util_pct[7:0];  // PF #0 as representative

    // =========================================================================
    // 8. CET Anti-Cheat (Intel) — MULTI-INSTANCE: Per G-Core (16 instances)
    // Setiap G-Core punya CET engine sendiri untuk full coverage
    // =========================================================================
    wire [NUM_G_CORES-1:0]              cet_viol_int;
    wire [NUM_G_CORES*4-1:0]            cet_vtype_int;
    wire [NUM_G_CORES*ADDR_WIDTH-1:0]   cet_vpc_int;
    wire [NUM_G_CORES-1:0]              cet_shadow_act;
    wire [NUM_G_CORES*8-1:0]            cet_shadow_dep;
    wire [NUM_G_CORES-1:0]              cet_state_ok;
    wire [NUM_G_CORES*32-1:0]           cet_bchk_int, cet_rchk_int, cet_rop_int, cet_jop_int, cet_stviol_int;

    // Aggregated CET stats
    wire [31:0] cet_total_branch_checks, cet_total_return_checks;
    wire [31:0] cet_total_rop_violations, cet_total_jop_violations, cet_total_state_violations;

    // CET instruction monitoring per G-Core
    wire [NUM_G_CORES-1:0]  cet_is_branch;
    wire [NUM_G_CORES-1:0]  cet_is_call;
    wire [NUM_G_CORES-1:0]  cet_is_ret;
    wire [NUM_G_CORES-1:0]  cet_is_endbr;

    // Generate per-G-Core branch detection
    genvar cet_mon_idx;
    generate
        for (cet_mon_idx = 0; cet_mon_idx < NUM_G_CORES; cet_mon_idx = cet_mon_idx + 1) begin : cet_monitors
            // Each G-Core's opcode is tracked via command data bus
            // FIX: Use actual command opcode from sched_g_core_cmd_data[7:0]
            // Gaming opcodes: 0x01=DRAW, 0x02=TEXTURE, 0x03=PHYSICS, 0x04=COLLISION, 0x05=RAYTRACE, 0x06=FRAMEGEN, 0x07=SHADING
            wire [7:0] g_cmd_opcode = sched_g_core_cmd_data[7:0];
            assign cet_is_branch[cet_mon_idx] = (g_cmd_opcode == 8'h06);  // FRAMEGEN = branch-like
            assign cet_is_call[cet_mon_idx]   = (g_cmd_opcode == 8'h03);  // PHYSICS = call-like
            assign cet_is_ret[cet_mon_idx]    = (g_cmd_opcode == 8'h04);  // COLLISION = ret-like
            // cet_is_endbr: only for indirect branch opcodes (FRAMEGEN=0x06 with indirect flag)
            // Detect indirect branch: opcode 0x06 AND cmd_data[31] set (indirect flag)
            assign cet_is_endbr[cet_mon_idx]  = (g_cmd_opcode == 8'h06) && sched_g_core_cmd_data[31];
        end
    endgenerate

    genvar cet_idx;
    generate
        for (cet_idx = 0; cet_idx < NUM_G_CORES; cet_idx = cet_idx + 1) begin : cet_array
            cet_anti_cheat #(
                .DATA_WIDTH(DATA_WIDTH),
                .ADDR_WIDTH(ADDR_WIDTH),
                .SHADOW_STACK_DEPTH(256),
                .MAX_GAME_STATES(16)
            ) u_cet_anti_cheat (
                .clk(clk),
                .rst_n(rst_n_sync),
                // Instruction stream monitor — each CET monitors its own G-Core
                .instr_pc(sched_g_core_cmd_addr),
                .instr_opcode(sched_g_core_cmd_data),
                // FIX: Use g_dispatch_active for proper CET monitoring timing
                .instr_valid(sched_g_core_cmd_valid && (g_core_rr_index[3:0] == cet_idx[3:0]) && g_dispatch_active),
                .instr_is_branch(cet_is_branch[cet_idx]),
                .instr_is_call(cet_is_call[cet_idx]),
                .instr_is_ret(cet_is_ret[cet_idx]),
                .instr_is_endbranch(cet_is_endbr[cet_idx]),
                .instr_ret_addr(sched_g_core_cmd_addr),
                // Game state integrity
                .game_state_id(8'h00),
                .game_state_hash(sched_g_core_cmd_data[31:0]),
                .game_state_valid(sched_g_core_cmd_valid),
                .expected_state_hash(g_core_selected_data ^ {g_core_selected_addr[15:0], 16'hA5A5}),
                // CET control
                .cet_enable(1'b1),
                .cet_shadow_enable(1'b1),
                .cet_state_check(combined_g_complete),
                // Violation output
                .violation_detected(cet_viol_int[cet_idx]),
                .violation_type(cet_vtype_int[cet_idx*4+:4]),
                .violation_pc(cet_vpc_int[cet_idx*ADDR_WIDTH+:ADDR_WIDTH]),
                .violation_latched(),
                // Status
                .shadow_stack_active(cet_shadow_act[cet_idx]),
                .shadow_stack_depth_cnt(cet_shadow_dep[cet_idx*8+:8]),
                .game_state_integrity_ok(cet_state_ok[cet_idx]),
                // Debug counters
                .cet_branch_checks(cet_bchk_int[cet_idx*32+:32]),
                .cet_return_checks(cet_rchk_int[cet_idx*32+:32]),
                .cet_violations_rop(cet_rop_int[cet_idx*32+:32]),
                .cet_violations_jop(cet_jop_int[cet_idx*32+:32]),
                .cet_violations_state(cet_stviol_int[cet_idx*32+:32]),
                .cet_state_checks(),
                .cet_valid_transitions()
            );
        end
    endgenerate

    // Aggregate: OR all violations — any core violation = global violation
    assign cet_violation          = |cet_viol_int;
    assign cet_violation_type     = cet_vtype_int[3:0];  // First violator type
    assign cet_violation_pc       = cet_vpc_int[ADDR_WIDTH-1:0];  // First violator PC

    // Aggregate stats — sum all NUM_G_CORES (combinational for-loop to avoid UNOPTFLAT)
    reg [31:0] cet_bchk_total_reg;
    reg [31:0] cet_rchk_total_reg;
    reg [31:0] cet_rop_total_reg;
    reg [31:0] cet_jop_total_reg;
    reg [31:0] cet_stviol_total_reg;
    always @(*) begin
        cet_bchk_total_reg = 0;
        cet_rchk_total_reg = 0;
        cet_rop_total_reg = 0;
        cet_jop_total_reg = 0;
        cet_stviol_total_reg = 0;
        for (int ccs_i = 0; ccs_i < NUM_G_CORES; ccs_i++) begin
            cet_bchk_total_reg    = cet_bchk_total_reg    + cet_bchk_int[ccs_i*32+:32];
            cet_rchk_total_reg    = cet_rchk_total_reg    + cet_rchk_int[ccs_i*32+:32];
            cet_rop_total_reg     = cet_rop_total_reg     + cet_rop_int[ccs_i*32+:32];
            cet_jop_total_reg     = cet_jop_total_reg     + cet_jop_int[ccs_i*32+:32];
            cet_stviol_total_reg  = cet_stviol_total_reg  + cet_stviol_int[ccs_i*32+:32];
        end
    end
    assign cet_total_branch_checks    = cet_bchk_total_reg;
    assign cet_total_return_checks    = cet_rchk_total_reg;
    assign cet_total_rop_violations   = cet_rop_total_reg;
    assign cet_total_jop_violations   = cet_jop_total_reg;
    assign cet_total_state_violations = cet_stviol_total_reg;
    assign cet_shadow_active      = |cet_shadow_act;
    assign cet_shadow_depth       = cet_shadow_dep[7:0];  // CCX #0 depth
    assign cet_state_integrity_ok = &cet_state_ok;  // All cores must be OK
    assign cet_branch_checks      = cet_total_branch_checks;
    assign cet_return_checks      = cet_total_return_checks;
    assign cet_rop_violations     = cet_total_rop_violations;
    assign cet_jop_violations     = cet_total_jop_violations;
    assign cet_state_violations   = cet_total_state_violations;

    // Ring Bus + Chiplet Architecture (AMD) - Simplified
    // =========================================================================
    wire [31:0] ch_packets, cnpu_packets, chits;

    // FIX: Enable Ring Bus and connect to scheduler for load balancing
    // Node 0: Gaming Core 0
    wire [ADDR_WIDTH-1:0] rb_addr_0 = sched_g_core_cmd_addr;  // Connect to scheduler
    // CRITICAL FIX: Form proper packet for ring bus with direction field
    wire [DATA_WIDTH-1:0] rb_data_0;
    wire                  rb_valid_0 = sched_g_core_cmd_valid && !game_cmd_ready; // Use ring when direct not ready
    wire                  rb_ready_0;
    wire [DATA_WIDTH-1:0] rb_resp_0;
    
    // Packet formation for gaming traffic (Node 0 -> Node 2 for AI core)
    localparam G_PKT_SRC  = 8'd0;  // Gaming Core is node 0
    localparam G_PKT_DEST = 8'd2;  // Destination is AI core
    localparam G_PKT_DIR  = 2'b10; // CCW direction (0->2 is shorter CCW)
    localparam G_PKT_QOS  = 2'b11; // Highest priority for gaming
    
    assign rb_data_0 = {sched_g_core_cmd_addr, // 48 bits
                        G_PKT_SRC,            // 8 bits  
                        G_PKT_DEST,           // 8 bits
                        sched_g_core_cmd_data,// 128 bits
                        G_PKT_QOS,            // 2 bits
                        G_PKT_DIR,            // 2 bits
                        8'h00,                // 8 bits hops
                        32'h00000000};       // 32 bits timestamp
    wire                  rb_rvalid_0;

    // Node 1: Gaming Core 1 (backup)
    wire [ADDR_WIDTH-1:0] rb_addr_1 = game_cmd_addr;  // Direct from testbench
    // CRITICAL FIX: Form proper packet for ring bus with direction field
    wire [DATA_WIDTH-1:0] rb_data_1;
    wire                  rb_valid_1 = game_cmd_valid; // Always valid when game_cmd_valid
    wire                  rb_ready_1;
    wire [DATA_WIDTH-1:0] rb_resp_1;
    
    // Packet formation for backup gaming traffic (Node 1 -> Node 2 for AI core)
    localparam G1_PKT_SRC  = 8'd1;  // Gaming Core 1 is node 1
    localparam G1_PKT_DEST = 8'd2;  // Destination is AI core
    localparam G1_PKT_DIR  = 2'b01; // CW direction (1->2 is shorter CW)
    localparam G1_PKT_QOS  = 2'b10; // High priority
    
    assign rb_data_1 = {game_cmd_addr,       // 48 bits
                        G1_PKT_SRC,          // 8 bits  
                        G1_PKT_DEST,         // 8 bits
                        game_cmd_data,       // 128 bits
                        G1_PKT_QOS,          // 2 bits
                        G1_PKT_DIR,          // 2 bits
                        8'h00,               // 8 bits hops
                        32'h00000000};      // 32 bits timestamp
    wire                  rb_rvalid_1;

    // Node 2: AI Core
    wire [ADDR_WIDTH-1:0] rb_addr_2 = ai_cmd_addr;   // AI traffic
    // CRITICAL FIX: Form proper packet for ring bus with direction field
    wire [DATA_WIDTH-1:0] rb_data_2;
    wire                  rb_valid_2 = ai_cmd_valid && rb_ready_2; // Use ring when ready
    wire                  rb_ready_2;
    wire [DATA_WIDTH-1:0] rb_resp_2;
    
    // Packet formation for AI traffic (Node 2 -> Node 0 for gaming cores)
    localparam AI_PKT_SRC  = 8'd2;  // AI Core is node 2
    localparam AI_PKT_DEST = 8'd0;  // Destination is gaming core 0
    localparam AI_PKT_DIR  = 2'b01; // CW direction (2->0 is shorter CW)
    localparam AI_PKT_QOS  = 2'b10; // High priority for AI traffic
    
    assign rb_data_2 = {ai_cmd_addr,        // 48 bits
                        AI_PKT_SRC,         // 8 bits  
                        AI_PKT_DEST,        // 8 bits
                        ai_cmd_data,        // 64 bits
                        AI_PKT_QOS,         // 2 bits
                        AI_PKT_DIR,         // 2 bits
                        8'h00,             // 8 bits hops
                        32'h00000000,      // 32 bits timestamp
                        {(DATA_WIDTH > 172 ? DATA_WIDTH-172 : 0){1'b0}}};  // Zero-extend to DATA_WIDTH
                        // Total: 48+8+8+64+2+2+8+32 = 172 bits (fits in 512-bit bus)
    wire                  rb_rvalid_2;

    wire [ADDR_WIDTH-1:0] rb_addr_3 = {ADDR_WIDTH{1'b0}};
    wire [DATA_WIDTH-1:0] rb_data_3 = {DATA_WIDTH{1'b0}};
    wire                  rb_valid_3 = 1'b0;
    wire                  rb_ready_3;
    wire [DATA_WIDTH-1:0] rb_resp_3;
    wire                  rb_rvalid_3;

    // Verify ring bus packet width: addr + qos + dir + hops + timestamp + data + src + dest fits in packet_width
    // G ring uses packet_width=256; verify total packed width ≤ 256
    localparam RB_PKT_TOTAL = ADDR_WIDTH + 8 + 8 + DATA_WIDTH + 2 + 2 + 8 + 32;
    initial begin
        if (RB_PKT_TOTAL > 256)
            $fatal(1, "Ring bus packet width mismatch: total %0d > 256 (DATA_WIDTH=%0d)", RB_PKT_TOTAL, DATA_WIDTH);
    end

    // Use generate for ring bus arrays
    wire [ADDR_WIDTH-1:0] rb_addr_arr [0:3];
    wire [DATA_WIDTH-1:0] rb_data_arr [0:3];
    wire                  rb_valid_arr [0:3];
    wire                  rb_ready_arr [0:3];
    wire [DATA_WIDTH-1:0] rb_resp_arr [0:3];
    wire                  rb_rvalid_arr [0:3];

    assign rb_addr_arr[0] = rb_addr_0;
    assign rb_data_arr[0] = rb_data_0;
    assign rb_valid_arr[0] = rb_valid_0;
    assign rb_addr_arr[1] = rb_addr_1;
    assign rb_data_arr[1] = rb_data_1;
    assign rb_valid_arr[1] = rb_valid_1;
    assign rb_addr_arr[2] = rb_addr_2;
    assign rb_data_arr[2] = rb_data_2;
    assign rb_valid_arr[2] = rb_valid_2;
    assign rb_addr_arr[3] = rb_addr_3;
    assign rb_data_arr[3] = rb_data_3;
    assign rb_valid_arr[3] = rb_valid_3;

    assign rb_ready_0 = rb_ready_arr[0];
    assign rb_resp_0 = rb_resp_arr[0];
    assign rb_rvalid_0 = rb_rvalid_arr[0];
    assign rb_ready_1 = rb_ready_arr[1];
    assign rb_resp_1 = rb_resp_arr[1];
    assign rb_rvalid_1 = rb_rvalid_arr[1];
    assign rb_ready_2 = rb_ready_arr[2];
    assign rb_resp_2 = rb_resp_arr[2];
    assign rb_rvalid_2 = rb_rvalid_arr[2];
    assign rb_ready_3 = rb_ready_arr[3];
    assign rb_resp_3 = rb_resp_arr[3];
    assign rb_rvalid_3 = rb_rvalid_arr[3];

    wire [3:0] rb_resp_ready_arr;
    assign rb_resp_ready_arr = 4'b1111;

    // Ring bus response routing
    wire ring_bus_g_busy, ring_bus_a_busy;

    // Ring bus packet counters
    wire [31:0] cg_packets;
    wire [31:0] ca_packets;
    wire [31:0] ring_cw_pkt_cnt;
    wire [31:0] ring_ccw_pkt_cnt;
    
    assign ring_bus_g_busy = (cg_packets > 32'd50);  // Congestion threshold
    assign ring_bus_a_busy = (ca_packets > 32'd25);  // Lower threshold for A-Core

    ring_bus #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_NODES(4),
        .BUFFER_DEPTH(16)  // FIX: Increase from 4 to 16 to prevent backlog
    ) u_ring_bus_g (
        .clk(clk),
        .rst_n(rst_n_sync),

        .node_req_addr(rb_addr_arr),
        .node_req_data(rb_data_arr),
        .node_req_valid(rb_valid_arr),
        .node_req_ready(rb_ready_arr),
        .node_resp_data(rb_resp_arr),
        .node_resp_valid(rb_rvalid_arr),
        .node_resp_ready(rb_resp_ready_arr),

        .gaming_mode(gaming_mode_active),
        .node_priority(4'b1111),
        .node_congested({ring_bus_g_busy, ring_bus_g_busy, ring_bus_g_busy, 1'b0}),

        .ring_total_packets(cg_packets),
        .ring_avg_latency(),
        .ring_contention_count(ring_bus_contention),
        .ring_adaptive_routing_count(),
        .ring_cw_packets(ring_cw_pkt_cnt),
        .ring_ccw_packets(ring_ccw_pkt_cnt),
        .node_activity_mask()
    );
    
    // Ring bus packet counters menggunakan deklarasi yang sudah ada

    // A-Core ring bus (2 nodes)
    wire [ADDR_WIDTH-1:0] ra_addr_arr [0:2];
    wire [DATA_WIDTH-1:0] ra_data_arr [0:2];
    wire                  ra_valid_arr [0:2];
    wire                  ra_ready_arr [0:2];
    wire [DATA_WIDTH-1:0] ra_resp_arr [0:2];
    wire                  ra_rvalid_arr [0:2];

    assign ra_addr_arr[0] = sched_a_core_cmd_addr;
    assign ra_data_arr[0] = {{(DATA_WIDTH-64){1'b0}}, sched_a_core_cmd_data};
    assign ra_valid_arr[0] = sched_a_core_cmd_valid;
    assign ra_addr_arr[1] = {ADDR_WIDTH{1'b0}};
    assign ra_data_arr[1] = {DATA_WIDTH{1'b0}};
    assign ra_valid_arr[1] = 1'b0;
    // Node 2: A-Core direct path (backup/reroute)
    assign ra_addr_arr[2] = a_core_cmd_addr_mux;
    assign ra_data_arr[2] = {{(DATA_WIDTH-64){1'b0}}, a_core_cmd_data_mux};
    assign ra_valid_arr[2] = a_core_cmd_valid_mux && !a0_cmd_ready;  // Use ring when direct not ready

    // CRITICAL FIX: Connect A-Core result to ring bus response path
    wire [2:0] ra_resp_ready_arr;
    // Node 0: Scheduler response (always ready)
    // Node 1: A-Core result response (wait for scheduler consumption)
    // Node 2: A-Core command response (always ready)
    assign ra_resp_ready_arr[0] = 1'b1;  // Scheduler always ready
    assign ra_resp_ready_arr[1] = mq_a_core_result_ready;  // CRITICAL: Wait for scheduler!
    assign ra_resp_ready_arr[2] = 1'b1;  // Command response always ready
    
    // Connect A-Core result to ring bus response (credit return path)
    assign ra_resp_arr[0] = {DATA_WIDTH{1'b0}};  // Scheduler response (unused)
    assign ra_resp_arr[1] = {DATA_WIDTH{1'b0}};  // Unused node
    assign ra_resp_arr[2] = a0_result;           // A-Core result -> ring bus response
    assign ra_rvalid_arr[0] = 1'b0;              // Scheduler response (unused)
    assign ra_rvalid_arr[1] = 1'b0;              // Unused node
    assign ra_rvalid_arr[2] = a0_result_valid;    // A-Core result valid -> ring bus response valid

    ring_bus #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_NODES(3),  // CRITICAL FIX: Node 2 exists! Prevent out-of-bounds
        .BUFFER_DEPTH(16)  // FIX: Increase to 16 to match G-Core ring
    ) u_ring_bus_a (
        .clk(clk),
        .rst_n(rst_n_sync),

        .node_req_addr(ra_addr_arr),
        .node_req_data(ra_data_arr),
        .node_req_valid(ra_valid_arr),
        .node_req_ready(ra_ready_arr),
        .node_resp_data(ra_resp_arr),
        .node_resp_valid(ra_rvalid_arr),
        .node_resp_ready(ra_resp_ready_arr),

        .gaming_mode(1'b0),
        .node_priority(3'b111),
        .node_congested({ring_bus_a_busy, 1'b0, 1'b0}),

        .ring_total_packets(ca_packets),
        .ring_avg_latency(),
        .ring_contention_count(),
        .ring_adaptive_routing_count(),
        .ring_cw_packets(),
        .ring_ccw_packets(),
        .node_activity_mask()
    );

    // FIX #7: Ring bus & chiplet counters - no longer hardwired to 0
    // Count actual core activity for H-Core and NPU ring bus packets
    reg [31:0] ring_h_pkt_cnt;
    reg [31:0] ring_npu_pkt_cnt;
    // FIX: Chiplet local hit counter - count L1/L2 cache hits (not fabric accesses)
    // Local hit = when core accesses cache and gets response (not going to main memory)
    reg [31:0] chiplet_hit_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ring_h_pkt_cnt <= 32'd0;
            ring_npu_pkt_cnt <= 32'd0;
            chiplet_hit_cnt <= 32'd0;
        end else begin
            // Count H-Core command activity (FIX: count 1 per broadcast, not cores ready)
            if (h_core_broadcast_valid) begin
                ring_h_pkt_cnt <= ring_h_pkt_cnt + 1;  // FIX: +1 per broadcast event
            end
            // Count NPU command activity
            if (npu_broadcast_valid) begin
                ring_npu_pkt_cnt <= ring_npu_pkt_cnt + 1;  // FIX: +1 per broadcast event
            end
            // FIX: Count cache hits (L1/L2 responses, not main memory accesses)
            // L1/L2 hit = when core sends request and gets response from cache (not fabric)
            if (g_l1_l2_ready_any || a_l1_l2_ready) begin
                chiplet_hit_cnt <= chiplet_hit_cnt + 1;
            end
        end
    end

    assign ring_g_packets       = cg_packets;
    assign ring_a_packets       = ca_packets;
    assign ring_h_packets       = ring_h_pkt_cnt;
    assign ring_npu_packets     = ring_npu_pkt_cnt;
    assign chiplet_total_packets = cg_packets + ca_packets + ring_h_pkt_cnt + ring_npu_pkt_cnt;
    assign chiplet_local_hits   = chiplet_hit_cnt;
    
    // Ring bus congestion signals for scheduler
    assign ring_bus_congested   = ring_bus_g_busy || ring_bus_a_busy;

endmodule
