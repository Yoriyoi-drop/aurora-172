`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Cache Hierarchy Integration
// Module Name: cache_hierarchy
//
// Description:
//   Cache Hierarchy Integration - Connects L1 caches (G-Core, A-Core) to L2
//   - Manages L1 <-> L2 <-> Memory Fabric connectivity
//   - MESI coherence controller integration
//   - Cache performance profiling
//   - 172-bit memory bus interface
//
//   FIX v2:
//   - L2 mem_wr_data: proper zero-extend fabric_wr_data to 512-bit
//   - Profiler: remove double-counting in delta accumulation
//   - L2 fairness: alternate G/A priority with l2_priority_toggle
//
// Target: Top-level cache hierarchy integration for AURORA-172
//////////////////////////////////////////////////////////////////////////////////

module cache_hierarchy #(
    parameter DATA_WIDTH        = 128,  // OPTIMIZED: 64→128 for wider data path
    parameter ADDR_WIDTH        = 48,
    parameter CACHE_LINE_WIDTH  = 256,  // OPTIMIZED: 172→256 (power of 2)
    parameter NUM_G_CORES       = 1,
    parameter NUM_A_CORES       = 1
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // G-Core L1 interfaces (multiple G-cores)
    // G-Core 0
    input  wire [ADDR_WIDTH-1:0]        g_l1_addr,
    input  wire [DATA_WIDTH-1:0]        g_l1_wr_data,
    input  wire                         g_l1_rd_en,
    input  wire                         g_l1_wr_en,
    output wire [DATA_WIDTH-1:0]        g_l1_rd_data,
    output wire                         g_l1_ready,
    output wire [ADDR_WIDTH-1:0]        g_l2_addr,
    output wire [511:0]                 g_l2_wr_data,
    output wire                         g_l2_rd_en,
    output wire                         g_l2_wr_en,
    input  wire [511:0]                 g_l2_rd_data,
    input  wire                         g_l2_ready,
    output wire [ADDR_WIDTH-1:0]        g_snoop_addr,
    output wire                         g_snoop_invalidate,
    output wire                         g_snoop_update,
    output wire [31:0]                  g_l1_hits,
    output wire [31:0]                  g_l1_misses,
    output wire [31:0]                  g_l1_writebacks,
    output wire [31:0]                  g_l1_invalidations,

    // A-Core L1 interfaces
    input  wire [ADDR_WIDTH-1:0]        a_l1_addr,
    input  wire [DATA_WIDTH-1:0]        a_l1_wr_data,
    input  wire                         a_l1_rd_en,
    input  wire                         a_l1_wr_en,
    output wire [DATA_WIDTH-1:0]        a_l1_rd_data,
    output wire                         a_l1_ready,
    output wire [ADDR_WIDTH-1:0]        a_l2_addr,
    output wire [511:0]                 a_l2_wr_data,
    output wire                         a_l2_rd_en,
    output wire                         a_l2_wr_en,
    input  wire [511:0]                 a_l2_rd_data,
    input  wire                         a_l2_ready,
    output wire [ADDR_WIDTH-1:0]        a_snoop_addr,
    output wire                         a_snoop_invalidate,
    output wire                         a_snoop_update,
    output wire [31:0]                  a_l1_hits,
    output wire [31:0]                  a_l1_misses,
    output wire [31:0]                  a_l1_writebacks,
    output wire [31:0]                  a_l1_invalidations,

    // Memory fabric interface (to external memory)
    output reg [ADDR_WIDTH-1:0]         fabric_addr,
    output reg                          fabric_rd_en,
    output reg                          fabric_wr_en,
    input  wire [DATA_WIDTH-1:0]        fabric_rd_data,
    output reg [DATA_WIDTH-1:0]         fabric_wr_data,
    input  wire                         fabric_ready,

    // Cache profiler outputs
    output wire [31:0]                  profiler_total_accesses,
    output wire [31:0]                  profiler_l1_hits,
    output wire [31:0]                  profiler_l1_misses,
    output wire [31:0]                  profiler_l2_hits,
    output wire [31:0]                  profiler_l2_misses,
    output wire [7:0]                   profiler_l1_hit_rate,
    output wire [7:0]                   profiler_l2_hit_rate,
    output wire [7:0]                   profiler_overall_hit_rate,
    output wire [7:0]                   profiler_avg_latency,

    // Print trigger
    input  wire                         trigger_print,
    output wire                         print_done,

    // ─────────────────────────────────────────────────────────────
    // MOESIX-GA Coherency debug outputs
    // ─────────────────────────────────────────────────────────────
    output wire [31:0]                  mesi_forwards_served,
    output wire [31:0]                  mesi_gaming_hits,
    output wire [31:0]                  mesi_ai_prefetches,
    output wire [31:0]                  mesi_owned_trans
);

    // =========================================================================
    // Internal signals
    // =========================================================================

    // L2 cache interface
    wire [ADDR_WIDTH-1:0]         l2_addr;
    wire [511:0]                  l2_wr_data;
    wire                          l2_rd_en;
    wire                          l2_wr_en;
    wire [511:0]                  l2_rd_data;
    wire                          l2_ready;

    // MESI controller interface
    wire [ADDR_WIDTH-1:0]         mesi_req_addr;
    wire                          mesi_req_write;
    wire                          mesi_req_read;
    wire                          mesi_req_valid;
    wire                          mesi_req_ready;
    wire                          mesi_resp_shared;
    wire                          mesi_resp_exclusive;
    wire                          mesi_resp_need_writeback;
    wire [DATA_WIDTH-1:0]         mesi_resp_data_cache;  // FIXED: Declare missing signal
    wire                          mesi_resp_ready;

    // Snoop signals from MESI to L1 caches
    wire [ADDR_WIDTH-1:0]         mesi_snoop_0_addr;
    wire                          mesi_snoop_0_invalidate;
    wire                          mesi_snoop_0_update;
    wire [ADDR_WIDTH-1:0]         mesi_snoop_1_addr;
    wire                          mesi_snoop_1_invalidate;
    wire                          mesi_snoop_1_update;

    // MESI performance counters
    wire [31:0]                   mesi_invalidations;
    wire [31:0]                   mesi_upgrades;
    wire [31:0]                   mesi_writebacks;
    wire [31:0]                   mesi_shared_grants;
    wire [31:0]                   mesi_forwards_served_int;
    wire [31:0]                   mesi_gaming_hits_int;
    wire [31:0]                   mesi_ai_prefetches_int;
    wire [31:0]                   mesi_owned_trans_int;

    // Snoop forward signals
    wire                          g_snoop_forward;
    wire                          a_snoop_forward;
    wire                          snoop_2_forward_npu;

    // L2 performance counters
    wire [31:0]                   l2_writebacks_int;
    wire [31:0]                   l2_evictions_int;
    wire [511:0]                  l2_rd_data_npu;
    wire                          l2_ready_npu;

    // NPU snoop signals (unused, tied to dummy values for MESI instantiation)
    wire [ADDR_WIDTH-1:0]         snoop_2_addr_npu;
    wire                          snoop_2_invalidate_npu;
    wire                          snoop_2_update_npu;
    wire [1:0]                    snoop_2_state_npu = 2'b00;
    wire                          snoop_2_valid_npu = 1'b0;

    // Cache profiler internal signals (not exposed at module level)
    wire [31:0]                   profiler_total_l2_hits;
    wire [31:0]                   profiler_total_l2_misses;
    wire [31:0]                   profiler_total_writebacks;
    wire [31:0]                   profiler_total_invalidations;
    wire [31:0]                   latency_histogram_int [0:15];
    wire [31:0]                   mesi_modified_count_int;
    wire [31:0]                   mesi_exclusive_count_int;
    wire [31:0]                   mesi_shared_count_int;
    wire [31:0]                   mesi_invalid_count_int;

    // Cache profiler access latency tracking
    reg [7:0]                     access_latency_counter;
    reg                           access_active;
    wire [7:0]                    current_latency;

    // =========================================================================
    // L1 to L2 multiplexing
    // =========================================================================

    // G-Core L2 signals
    wire [ADDR_WIDTH-1:0]         g_l2_addr_int;
    wire [511:0]                  g_l2_wr_data_int;
    wire                          g_l2_rd_en_int;
    wire                          g_l2_wr_en_int;

    // A-Core L2 signals
    wire [ADDR_WIDTH-1:0]         a_l2_addr_int;
    wire [511:0]                  a_l2_wr_data_int;
    wire                          a_l2_rd_en_int;
    wire                          a_l2_wr_en_int;

    // FIX v2: Fairness — alternate G-Core/A-Core L2 priority using toggle
    reg                           l2_priority_toggle;

    // FIX v2: Arbitration alternates priority based on l2_priority_toggle
    reg                           g_wins_arb;
    always @(*) begin
        if (g_l2_rd_en_int || g_l2_wr_en_int) begin
            if (a_l2_rd_en_int || a_l2_wr_en_int) begin
                // Both active: use toggle to decide
                g_wins_arb = ~l2_priority_toggle;  // 0 => G wins, 1 => A wins
            end else begin
                g_wins_arb = 1'b1;
            end
        end else begin
            g_wins_arb = 1'b0;
        end
    end

    assign l2_addr = g_wins_arb ? g_l2_addr_int : a_l2_addr_int;
    assign l2_wr_data = g_wins_arb ? g_l2_wr_data_int : a_l2_wr_data_int;
    assign l2_rd_en = g_l2_rd_en_int | a_l2_rd_en_int;
    assign l2_wr_en = g_l2_wr_en_int | a_l2_wr_en_int;

    // FIX v2: L2 ready to cores based on fair arbitration
    assign g_l2_ready = l2_ready && g_wins_arb;
    assign a_l2_ready = l2_ready && !g_wins_arb;

    // FIX v2: Toggle priority on each completed L2 access
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            l2_priority_toggle <= 1'b0;
        end else if (l2_ready && (l2_rd_en || l2_wr_en)) begin
            l2_priority_toggle <= ~l2_priority_toggle;
        end
    end

    // =========================================================================
    // L2 Cache instance (8-way, 8MB, MESI)
    // =========================================================================
    l2_cache #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH),
        .CACHE_SIZE(8 * 1024 * 1024),
        .ASSOCIATIVITY(8),
        .LINE_SIZE(64),
        .NUM_L1_PORTS(2)
    ) u_l2_cache (
        .clk(clk),
        .rst_n(rst_n),

        // L1 port 0: G-Core
        .l1_0_addr(g_l2_addr_int),
        .l1_0_wr_data(g_l2_wr_data_int),
        .l1_0_rd_en(g_l2_rd_en_int),
        .l1_0_wr_en(g_l2_wr_en_int),
        .l1_0_rd_data(g_l2_rd_data),
        .l1_0_ready(g_l2_ready),

        // L1 port 1: A-Core
        .l1_1_addr(a_l2_addr_int),
        .l1_1_wr_data(a_l2_wr_data_int),
        .l1_1_rd_en(a_l2_rd_en_int),
        .l1_1_wr_en(a_l2_wr_en_int),
        .l1_1_rd_data(a_l2_rd_data),
        .l1_1_ready(a_l2_ready),

        // L1 port 2: NPU (unused for now)
        .l1_2_addr({ADDR_WIDTH{1'b0}}),
        .l1_2_wr_data({512{1'b0}}),
        .l1_2_rd_en(1'b0),
        .l1_2_wr_en(1'b0),
        .l1_2_rd_data(l2_rd_data_npu),
        .l1_2_ready(l2_ready_npu),

        // External memory interface
        .mem_addr(fabric_addr),
        // FIX v2: Properly zero-extend fabric_wr_data (128-bit) to 512-bit
        .mem_wr_data({(512 - DATA_WIDTH){1'b0}} | fabric_wr_data),
        .mem_rd_en(fabric_rd_en),
        .mem_wr_en(fabric_wr_en),
        // FIX v2: Properly zero-extend fabric_rd_data (128-bit) to 512-bit
        .mem_rd_data({(512 - DATA_WIDTH){1'b0}} | fabric_rd_data),
        .mem_ready(fabric_ready),

        // Snoop broadcast
        .snoop_addr(mesi_req_addr),
        .snoop_invalidate(mesi_snoop_0_invalidate),
        .snoop_update(mesi_snoop_0_update),

        // Performance counters
        .l2_hits(profiler_l2_hits),
        .l2_misses(profiler_l2_misses),
        .l2_writebacks(l2_writebacks_int),
        .l2_evictions(l2_evictions_int),
        .snoop_invalidations(mesi_invalidations)
    );

    // =========================================================================
    // MESI Coherence Controller (MOESIX-GA)
    // =========================================================================
    wire [2:0]  g_l1_state_out, a_l1_state_out, npu_l1_state_out;
    wire        g_l1_valid_out, a_l1_valid_out, npu_l1_valid_out;

    mesi_controller #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_CACHES(2),
        .LINE_SIZE(64)
    ) u_mesi_controller (
        .clk(clk),
        .rst_n(rst_n),

        // Request from L2
        .req_addr(mesi_req_addr),
        .req_is_write(l2_wr_en),
        .req_is_read(l2_rd_en),
        .req_is_gaming(1'b0),
        .req_is_ai(1'b0),
        .req_valid(l2_rd_en || l2_wr_en),
        .req_ready(mesi_req_ready),

        // L1 0: G-Core snoop
        .snoop_0_addr(mesi_snoop_0_addr),
        .snoop_0_invalidate(g_snoop_invalidate),
        .snoop_0_update(g_snoop_update),
        .snoop_0_forward(g_snoop_forward),
        .snoop_0_state(g_l1_state_out),
        .snoop_0_valid(g_l1_valid_out),

        // L1 1: A-Core snoop
        .snoop_1_addr(mesi_snoop_1_addr),
        .snoop_1_invalidate(a_snoop_invalidate),
        .snoop_1_update(a_snoop_update),
        .snoop_1_forward(a_snoop_forward),
        .snoop_1_state(a_l1_state_out),
        .snoop_1_valid(a_l1_valid_out),

        // L1 2: NPU snoop (unused in current config)
        .snoop_2_addr(snoop_2_addr_npu),
        .snoop_2_invalidate(snoop_2_invalidate_npu),
        .snoop_2_update(snoop_2_update_npu),
        .snoop_2_forward(snoop_2_forward_npu),
        .snoop_2_state(npu_l1_state_out),
        .snoop_2_valid(npu_l1_valid_out),

        // Response
        .resp_is_shared(mesi_resp_shared),
        .resp_is_exclusive(mesi_resp_exclusive),
        .resp_need_writeback(mesi_resp_need_writeback),
        .resp_data_from_cache(mesi_resp_data_cache),
        .resp_ready(mesi_resp_ready),

        // Performance counters
        .invalidations_sent(mesi_invalidations),
        .upgrades_sent(mesi_upgrades),
        .writebacks_forced(mesi_writebacks),
        .shared_grants(mesi_shared_grants),
        .forwards_served(mesi_forwards_served),
        .gaming_priority_hits(mesi_gaming_hits),
        .ai_bulk_prefetches(mesi_ai_prefetches),
        .owned_transitions(mesi_owned_trans)
    );

    // =========================================================================
    // Cache Performance Profiler
    // =========================================================================
    cache_profiler #(
        .ADDR_WIDTH(ADDR_WIDTH),
        .NUM_CORES(2),
        .HISTOGRAM_BINS(16)
    ) u_cache_profiler (
        .clk(clk),
        .rst_n(rst_n),

        // L1 metrics
        .l1_hits('{g_l1_hits, a_l1_hits}),
        .l1_misses('{g_l1_misses, a_l1_misses}),
        .l1_writebacks('{g_l1_writebacks, a_l1_writebacks}),
        .l1_invalidations('{g_l1_invalidations, a_l1_invalidations}),

        // L2 metrics
        .l2_hits(profiler_l2_hits),
        .l2_misses(profiler_l2_misses),
        .l2_writebacks(l2_writebacks_int),
        .l2_evictions(l2_evictions_int),
        .snoop_invalidations(mesi_invalidations),

        // MESI metrics
        .mesi_invalidations(mesi_invalidations),
        .mesi_upgrades(mesi_upgrades),
        .mesi_writebacks(mesi_writebacks),
        .mesi_shared_grants(mesi_shared_grants),

        // Access latency
        .access_start(g_l1_rd_en || a_l1_rd_en),
        .access_complete(g_l1_ready || a_l1_ready),
        .access_latency(access_latency_counter),

        // Outputs
        .total_accesses(profiler_total_accesses),
        .total_l1_hits(profiler_l1_hits),
        .total_l1_misses(profiler_l1_misses),
        .total_l2_hits(profiler_total_l2_hits),
        .total_l2_misses(profiler_total_l2_misses),
        .total_writebacks(profiler_total_writebacks),
        .total_invalidations(profiler_total_invalidations),
        .l1_hit_rate_pct(profiler_l1_hit_rate),
        .l2_hit_rate_pct(profiler_l2_hit_rate),
        .overall_hit_rate_pct(profiler_overall_hit_rate),
        .avg_access_latency(profiler_avg_latency),
        .latency_histogram(latency_histogram_int),

        .mesi_modified_count(mesi_modified_count_int),
        .mesi_exclusive_count(mesi_exclusive_count_int),
        .mesi_shared_count(mesi_shared_count_int),
        .mesi_invalid_count(mesi_invalid_count_int),

        .trigger_print(trigger_print),
        .print_done(print_done)
    );

    // =========================================================================
    // Access latency counter
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            access_latency_counter <= 8'h0;
            access_active <= 1'b0;
        end else begin
            if (g_l1_rd_en || a_l1_rd_en || g_l1_wr_en || a_l1_wr_en) begin
                access_active <= 1'b1;
                access_latency_counter <= 8'h1;
            end else if (access_active) begin
                if (g_l1_ready || a_l1_ready) begin
                    access_active <= 1'b0;
                end else begin
                    access_latency_counter <= access_latency_counter + 1;
                end
            end
        end
    end

    // =========================================================================
    // MOESIX-GA output assignments
    // =========================================================================
    assign mesi_forwards_served  = mesi_forwards_served_int;
    assign mesi_gaming_hits      = mesi_gaming_hits_int;
    assign mesi_ai_prefetches    = mesi_ai_prefetches_int;
    assign mesi_owned_trans      = mesi_owned_trans_int;

endmodule
