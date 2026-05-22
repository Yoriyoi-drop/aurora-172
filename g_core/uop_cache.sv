`timescale 1ns / 1ps

// verilator lint_off DECLFILENAME
// verilator lint_off WIDTHEXPAND

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: Intel uop Cache)
//
// Create Date: 11 April 2026
// Design Name: Micro-Operation Cache
// Module Name: uop_cache
//
// Description:
//   Cache decoded micro-operations untuk menghindari decode berulang
//   Inspired by Intel uop Cache (1.5K entries di Golden Cove)
//   Adapted untuk AURORA G-Core (gaming instructions)
//
// Specification:
//   - 512 entries (1/3 Intel size)
//   - 8-way set associative
//   - LRU replacement
//   - Tag match: PC + instruction pattern
//
//////////////////////////////////////////////////////////////////////////////////

module uop_cache #(
    parameter DATA_WIDTH        = `AURORA_DATA_WIDTH,   // FIX: Use standard parameter
    parameter ADDR_WIDTH        = `AURORA_ADDR_WIDTH,   // FIX: Use standard parameter
    parameter INST_WIDTH        = `AURORA_INST_WIDTH,   // FIX: Use standard parameter
    parameter NUM_ENTRIES       = 512,
    parameter ASSOCIATIVITY     = 8,
    parameter NUM_SETS          = NUM_ENTRIES / ASSOCIATIVITY
)(
    input  wire                         clk,
    input  wire                         rst_n,

    input  wire [ADDR_WIDTH-1:0]        fetch_pc,
    input  wire [INST_WIDTH-1:0]        fetch_instruction,
    input  wire                         fetch_valid,
    output wire                         uop_cache_hit,
    output wire                         uop_cache_ready,

    output wire [63:0]                  uop_micro_ops,
    output wire [7:0]                   uop_count,
    output wire                         uop_valid,

    output wire                         decode_request,
    input  wire                         decode_complete,
    input  wire [63:0]                  decode_micro_ops,
    input  wire [7:0]                   decode_uop_count,

    output wire [31:0]                  uop_hits,
    output wire [31:0]                  uop_misses,
    output wire [31:0]                  uop_evictions,
    output wire [7:0]                   uop_hit_rate_percent
);

    localparam TAG_WIDTH        = ADDR_WIDTH - 10;
    localparam INDEX_WIDTH      = 6;
    localparam OFFSET_WIDTH     = 4;

    wire [INDEX_WIDTH-1:0]      fetch_index = fetch_pc[INDEX_WIDTH+OFFSET_WIDTH-1:OFFSET_WIDTH];
    wire [TAG_WIDTH-1:0]        fetch_tag   = fetch_pc[ADDR_WIDTH-1:OFFSET_WIDTH+INDEX_WIDTH];

    // FIX v2: PER-SET associative arrays (not flat 1D scan).
    // Arrays are indexed [set][way], matching true set-associative hardware.
    reg                         cache_valid   [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [TAG_WIDTH-1:0]         cache_tags    [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [63:0]                  cache_uops    [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [7:0]                   cache_uop_counts [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [7:0]                   cache_lru     [0:NUM_SETS-1][0:ASSOCIATIVITY-1];

    // Lookup result registers
    reg                         lookup_hit;
    reg [63:0]                  hit_uops;
    reg [7:0]                   hit_uop_count;

    // FIX v2: Per-set combinational lookup -- only scans ONE set (fetch_index),
    // not all 512 entries. This matches real set-associative cache hardware.
    integer way_idx;
    always @(*) begin
        lookup_hit = 1'b0;
        hit_uops = 64'h0;
        hit_uop_count = 8'd0;

        // FIX v2: Scan only the selected set (8 ways, not 512 entries)
        for (way_idx = 0; way_idx < ASSOCIATIVITY; way_idx = way_idx + 1) begin
            if (cache_valid[fetch_index][way_idx] &&
                cache_tags[fetch_index][way_idx] == fetch_tag) begin
                lookup_hit = 1'b1;
                hit_uops = cache_uops[fetch_index][way_idx];
                hit_uop_count = cache_uop_counts[fetch_index][way_idx];
            end
        end
    end

    // FIX Issue: Registered lookup outputs to prevent race with fill-to-same-index.
    // Pipeline stage aligns lookup result with the flip-flop-based cache array reads.
    reg                         lookup_hit_r;
    reg [63:0]                  hit_uops_r;
    reg [7:0]                   hit_uop_count_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            lookup_hit_r    <= 1'b0;
            hit_uops_r      <= '0;
            hit_uop_count_r <= '0;
        end else begin
            lookup_hit_r    <= lookup_hit;
            hit_uops_r      <= hit_uops;
            hit_uop_count_r <= hit_uop_count;
        end
    end

    assign uop_cache_hit    = lookup_hit_r && fetch_valid;
    assign uop_cache_ready  = 1'b1;
    assign uop_micro_ops    = hit_uops_r;
    assign uop_count        = hit_uop_count_r;
    assign uop_valid        = lookup_hit_r && fetch_valid;
    assign decode_request   = fetch_valid && !lookup_hit;  // Keep combinational to not miss decode trigger

    // FIXED: Register fetch_index at miss time so fill uses correct set
    reg [INDEX_WIDTH-1:0] fill_index_reg;
    reg [TAG_WIDTH-1:0] fill_tag_reg;
    reg                     fill_pending;
    reg [31:0]              dropped_miss_count;

    // Counters
    reg [31:0]              hit_counter;
    reg [31:0]              miss_counter;
    reg [31:0]              eviction_counter;

    assign uop_hits             = hit_counter;
    assign uop_misses           = miss_counter;
    assign uop_evictions        = eviction_counter;
    assign uop_hit_rate_percent = (hit_counter + miss_counter > 0) ?
                                  (hit_counter * 100 / (hit_counter + miss_counter)) : 8'd0;

    // FIX v2: Find LRU way within a specific set (highest LRU counter = oldest)
    function automatic integer find_lru_way;
        input [INDEX_WIDTH-1:0] set_idx;
        integer w;
        integer max_age;
        integer lru_way;
        begin
            max_age = 0;
            lru_way = 0;
            for (w = 0; w < ASSOCIATIVITY; w = w + 1) begin
                if (!cache_valid[set_idx][w]) begin
                    // Invalid entry = best candidate (no eviction needed)
                    find_lru_way = w;
                    return find_lru_way;  // FIXED: Early exit to avoid overwrite by valid entries
                end else if (cache_lru[set_idx][w] > max_age) begin
                    max_age = cache_lru[set_idx][w];
                    lru_way = w;
                end
            end
            find_lru_way = lru_way;
        end
    endfunction

    // Update logic
    always @(posedge clk) begin
        if (!rst_n) begin
            // Initialize arrays to zero
            for (int s = 0; s < NUM_SETS; s++) begin
                for (int w = 0; w < ASSOCIATIVITY; w++) begin
                    cache_valid[s][w] = 1'b0;
                    cache_tags[s][w] = {TAG_WIDTH{1'b0}};
                    cache_uops[s][w] = 64'h0;
                    cache_uop_counts[s][w] = 8'd0;
                    cache_lru[s][w] = 8'd0;
                end
            end
            hit_counter <= 32'd0;
            miss_counter <= 32'd0;
            eviction_counter <= 32'd0;
        end else begin
            // FIX v3: Only age LRU for the accessed set, not all 512 entries
            // This saves significant power vs aging every entry each cycle
            if (fetch_valid) begin
                for (int w = 0; w < ASSOCIATIVITY; w++) begin
                    if (cache_valid[fetch_index][w] && cache_lru[fetch_index][w] < 8'hFF) begin
                        cache_lru[fetch_index][w] <= cache_lru[fetch_index][w] + 8'd1;
                    end
                end
            end

            // Hit: update LRU timestamp (reset age = make young)
            if (fetch_valid && lookup_hit) begin
                hit_counter <= hit_counter + 32'd1;
                for (int w = 0; w < ASSOCIATIVITY; w++) begin
                    if (cache_valid[fetch_index][w] &&
                        cache_tags[fetch_index][w] == fetch_tag) begin
                        cache_lru[fetch_index][w] <= 8'd0;  // Reset = most recently used
                    end
                end
            end

            // Miss: save fetch_index/tag for later fill
            if (fetch_valid && !lookup_hit) begin
                miss_counter <= miss_counter + 32'd1;
                fill_index_reg <= fetch_index;  // FIXED: Latch index at miss time
                fill_tag_reg <= fetch_tag;      // FIXED: Latch tag at miss time
            end

            // Fill from decoder (use registered fetch_index, not live wire)
            if (decode_complete) begin
                integer lru_way;
                lru_way = find_lru_way(fill_index_reg);

                if (cache_valid[fill_index_reg][lru_way]) begin
                    eviction_counter <= eviction_counter + 32'd1;
                end

                cache_valid[fill_index_reg][lru_way] <= 1'b1;
                cache_tags[fill_index_reg][lru_way] <= fill_tag_reg;
                cache_uops[fill_index_reg][lru_way] <= decode_micro_ops;
                cache_uop_counts[fill_index_reg][lru_way] <= decode_uop_count;
                cache_lru[fill_index_reg][lru_way] <= 8'd0;  // Reset LRU age for new entry
            end
        end
    end

endmodule
