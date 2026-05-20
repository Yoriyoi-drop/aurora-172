//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: Intel Hardware Prefetcher)
//
// Create Date: 12 April 2026
// Design Name: Hardware Prefetcher (4-Stream Adaptive)
// Module Name: hw_prefetcher
//
// Description:
//   Hardware prefetcher dengan 4-stream adaptive dan stride detection
//   Inspired by Intel Hardware Prefetcher (Adaptive Prefetching)
//
//   Intel Prefetcher Features:
//   - 4 independent prefetch streams
//   - Automatic stride detection (forward & backward)
//   - Data streaming pattern recognition
//   - Adaptive: enables/disables streams based on utility
//   - L1 and L2 prefetch distance control
//
//   AURORA Adaptation:
//   - 4 prefetch streams with independent stride tracking
//   - Supports forward (+stride) and backward (-stride) prefetch
//   - Prefetch distance: 4 lines ahead (configurable)
//   - Stream allocation on first cache miss
//   - Stream deallocation after N useless prefetches
//   - Gaming-optimized: aggressive for linear access patterns
//   - AI-optimized: bulk sequential weight fetch
//
//   Stream Structure:
//     Each stream tracks:
//     - Base address (last accessed line)
//     - Stride (access distance)
//     - Confidence (how consistent the pattern is)
//     - Direction (forward/backward)
//     - Useless count (for deallocation)
//
//   Algorithm:
//     1. On L1 miss, check if address matches any stream
//     2. If match: confirm stride, increase confidence
//     3. If no match: allocate new stream (evict lowest confidence)
//     4. Prefetch N lines ahead from confirmed streams
//     5. Track prefetch utility → deallocate useless streams
//
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

module hw_prefetcher #(
    parameter DATA_WIDTH            = AURORA_DATA_WIDTH,   // FIXED: Use standard parameter
    parameter PREFETCH_DISTANCE     = 2,    // OPTIMIZED: 4->2 (less aggressive)
    parameter CACHE_LINE_BITS       = 5,    // 32-byte lines
    parameter ADDR_WIDTH            = AURORA_ADDR_WIDTH,   // FIXED: Use standard parameter
    parameter NUM_STREAMS           = 4,    // OPTIMIZED: 8->4 (simpler tracking)
    parameter MAX_STRIDE_BITS       = 12,   // OPTIMIZED: 16->12 (smaller stride)
    parameter CONFIDENCE_MAX        = 8,    // Max confidence level
    parameter USELESS_THRESHOLD     = 4     // Deallocation threshold
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // ─────────────────────────────────────────────────────────────
    // Access monitor interface (from L1/L2 miss tracking)
    // ─────────────────────────────────────────────────────────────
    input  wire [ADDR_WIDTH-1:0]        miss_addr,           // Cache miss address
    input  wire                         miss_valid,          // Miss observed

    input  wire [ADDR_WIDTH-1:0]        l1_access_addr,      // L1 access for stride tracking
    input  wire                         l1_access_valid,     // L1 access observed

    // ─────────────────────────────────────────────────────────────
    // Workload hints (adjust prefetch aggression)
    // ─────────────────────────────────────────────────────────────
    /* verilator lint_off UNUSED */
    input  wire                         gaming_workload,
    input  wire                         ai_workload,
    input  wire                         streaming_workload,    // Known sequential access
    input  wire                         aggressive_mode,     // Override for aggressive prefetch
    input  wire                         prefetcher_enable,
    /* verilator lint_on UNUSED */

    // ─────────────────────────────────────────────────────────────
    // Prefetch request output (to memory fabric)
    // ─────────────────────────────────────────────────────────────
    output reg                          pf_valid,            // Prefetch request valid
    output reg  [ADDR_WIDTH-1:0]        pf_addr,             // Prefetch address
    output reg  [1:0]                   pf_stream_id,        // Which stream requested
    input  wire                         pf_ready,            // Fabric ready to accept

    // ─────────────────────────────────────────────────────────────
    // Prefetch result tracking (from cache)
    // ─────────────────────────────────────────────────────────────
    input  wire [ADDR_WIDTH-1:0]        pf_result_addr,      // Prefetched line address
    input  wire                         pf_result_used,      // Line was actually used
    input  wire                         pf_result_unused,    // Line was evicted unused

    // ─────────────────────────────────────────────────────────────
    // Status outputs
    // ─────────────────────────────────────────────────────────────
    output wire [NUM_STREAMS-1:0]       stream_active,       // Active stream mask
    output wire [MAX_STRIDE_BITS-1:0]   stream0_stride,
    output wire [MAX_STRIDE_BITS-1:0]   stream1_stride,
    output wire [MAX_STRIDE_BITS-1:0]   stream2_stride,
    output wire [MAX_STRIDE_BITS-1:0]   stream3_stride,

    // ─────────────────────────────────────────────────────────────
    // Debug / performance counters
    // ─────────────────────────────────────────────────────────────
    output wire [31:0]                  pf_total_requests,
    output wire [31:0]                  pf_useful,
    output wire [31:0]                  pf_useless,
    output wire [31:0]                  pf_coverage,         // Misses covered by prefetch
    output wire [31:0]                  pf_streams_allocated,
    output wire [31:0]                  pf_streams_deallocated,
    output wire [7:0]                   pf_utilization_pct   // Useful / total * 100
);

    // ─────────────────────────────────────────────────────────────
    // Stream entry structure (packed for Verilator compatibility)
    // ─────────────────────────────────────────────────────────────
    // Per-stream registers
    reg [ADDR_WIDTH-1:0]        stream_base   [0:NUM_STREAMS-1];
    reg [MAX_STRIDE_BITS-1:0]   stream_stride [0:NUM_STREAMS-1];
    reg [3:0]                   stream_confidence [0:NUM_STREAMS-1];  // 0-8
    reg                         stream_dir    [0:NUM_STREAMS-1];      // 0=forward, 1=backward
    reg                         stream_valid  [0:NUM_STREAMS-1];      // Stream active
    reg [7:0]                   stream_useless [0:NUM_STREAMS-1];     // Useless counter
    reg [3:0]                   stream_pf_dist [0:NUM_STREAMS-1];     // Current prefetch distance

    assign stream_active[0] = stream_valid[0];
    assign stream_active[1] = stream_valid[1];
    assign stream_active[2] = stream_valid[2];
    assign stream_active[3] = stream_valid[3];

    assign stream0_stride = stream_stride[0];
    assign stream1_stride = stream_stride[1];
    assign stream2_stride = stream_stride[2];
    assign stream3_stride = stream_stride[3];

    // ─────────────────────────────────────────────────────────────
    // Stride calculation
    // ─────────────────────────────────────────────────────────────
    /* verilator lint_off UNUSED */
    reg [MAX_STRIDE_BITS-1:0]   calc_stride;
    reg                         calc_dir;  // 0=forward, 1=backward
    wire [MAX_STRIDE_BITS-1:0] calc_stride_unused = calc_stride;
    wire calc_dir_unused = calc_dir;
    /* verilator lint_on UNUSED */

    function [MAX_STRIDE_BITS-1:0] abs_diff;
        input [ADDR_WIDTH-1:0] a;
        input [ADDR_WIDTH-1:0] b;
        begin
            if (a >= b)
                abs_diff = 16'(a - b);
            else
                abs_diff = 16'(b - a);
        end
    endfunction

    // ─────────────────────────────────────────────────────────────
    // Stream matching logic
    // ─────────────────────────────────────────────────────────────
    reg [1:0]                   match_stream_idx;
    reg                         match_found;

    integer match_i;
    always @(*) begin
        match_found = 1'b0;
        match_stream_idx = 2'b00;

        for (match_i = 0; match_i < NUM_STREAMS; match_i = match_i + 1) begin
            if (stream_valid[match_i]) begin
                // Check if address matches expected next line in stream
                if (stream_dir[match_i] == 0) begin
                    // Forward: addr = base + stride * distance
                    if (miss_addr == (stream_base[match_i] + (stream_stride[match_i] * stream_pf_dist[match_i]))) begin
                        match_found = 1'b1;
                        match_stream_idx = 2'(match_i);
                    end
                end else begin
                    // Backward: addr = base - stride * distance
                    if (miss_addr == (stream_base[match_i] - (stream_stride[match_i] * stream_pf_dist[match_i]))) begin
                        match_found = 1'b1;
                        match_stream_idx = 2'(match_i);
                    end
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────────
    // Stream allocation: find lowest confidence stream to evict
    // ─────────────────────────────────────────────────────────────
    reg [1:0]                   evict_stream_idx;
    reg                         find_evict_valid;

    integer evict_i;
    always @(*) begin
        evict_stream_idx = 2'b00;
        find_evict_valid = 1'b0;

        // First try to find an invalid (empty) slot
        for (evict_i = 0; evict_i < NUM_STREAMS; evict_i = evict_i + 1) begin
            if (!stream_valid[evict_i]) begin
                evict_stream_idx = 2'(evict_i);
                find_evict_valid = 1'b1;
                evict_i = NUM_STREAMS;
            end
        end

        // If all valid, find lowest confidence
        if (!find_evict_valid) begin
            for (evict_i = 0; evict_i < NUM_STREAMS; evict_i = evict_i + 1) begin
                if (stream_confidence[evict_i] < stream_confidence[evict_stream_idx]) begin
                    evict_stream_idx = 2'(evict_i);
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────────
    // Prefetch request generation
    // ─────────────────────────────────────────────────────────────
    reg [NUM_STREAMS-1:0]       pf_pending_mask;  // Which streams have pending pf
    reg [31:0]                  total_pf_req;
    reg [31:0]                  total_pf_useful;
    reg [31:0]                  total_pf_useless;
    reg [31:0]                  total_pf_coverage;
    reg [31:0]                  total_alloc;
    reg [31:0]                  total_dealloc;

    assign pf_total_requests    = total_pf_req;
    assign pf_useful            = total_pf_useful;
    assign pf_useless           = total_pf_useless;
    assign pf_coverage          = total_pf_coverage;
    assign pf_streams_allocated  = total_alloc;
    assign pf_streams_deallocated = total_dealloc;
    assign pf_utilization_pct   = (total_pf_req > 0) ?
                                  8'((total_pf_useful * 100) / total_pf_req) : 8'd0;

    // ─────────────────────────────────────────────────────────────
    // Prefetch state machine
    // ─────────────────────────────────────────────────────────────
    typedef enum logic [1:0] {
        PF_IDLE,
        PF_CHECK_STREAMS,
        PF_GENERATE,
        PF_WAIT
    } pf_state_t;

    pf_state_t  pf_state;
    reg [1:0]   pf_stream_select;   // Round-robin stream selector

    // ─────────────────────────────────────────────────────────────
    // Main Prefetcher Logic
    // ─────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset streams
            pf_state <= PF_IDLE;
            pf_valid <= 1'b0;
            pf_addr <= {ADDR_WIDTH{1'b0}};
            pf_stream_id <= 2'b00;
            pf_stream_select <= 2'b00;
            pf_pending_mask <= {NUM_STREAMS{1'b0}};

            total_pf_req <= 32'd0;
            total_pf_useful <= 32'd0;
            total_pf_useless <= 32'd0;
            total_pf_coverage <= 32'd0;
            total_alloc <= 32'd0;
            total_dealloc <= 32'd0;
        end else if (!prefetcher_enable) begin
            pf_state <= PF_IDLE;
            pf_valid <= 1'b0;
        end else begin
            // Default
            pf_valid <= 1'b0;

            case (pf_state)
                PF_IDLE: begin
                    if (l1_access_valid || miss_valid) begin
                        pf_state <= PF_CHECK_STREAMS;
                    end
                end

                PF_CHECK_STREAMS: begin
                    // Update stream tracking based on access
                    if (l1_access_valid) begin
                        update_streams(l1_access_addr);
                    end

                    if (miss_valid) begin
                        update_streams(miss_addr);
                    end

                    pf_state <= PF_GENERATE;
                end

                PF_GENERATE: begin
                    // Select next stream (round-robin among active)
                    reg found_active;
                    reg [1:0] sel;
                    integer try_i;

                    found_active = 1'b0;
                    sel = pf_stream_select;

                    // Find next active stream
                    for (try_i = 0; try_i < NUM_STREAMS; try_i = try_i + 1) begin
                        if (stream_valid[sel] && !pf_pending_mask[sel] &&
                            stream_confidence[sel] >= 4'd2) begin
                            found_active = 1'b1;
                            pf_stream_select <= sel + 2'd1;
                            try_i = NUM_STREAMS;
                        end else begin
                            sel = sel + 2'd1;
                        end
                    end

                    if (found_active) begin
                        // Generate prefetch for selected stream
                        pf_valid <= 1'b1;

                        if (stream_dir[sel] == 0) begin
                            // Forward prefetch
                            pf_addr <= stream_base[sel] + (stream_stride[sel] * stream_pf_dist[sel]);
                        end else begin
                            // Backward prefetch
                            pf_addr <= stream_base[sel] - (stream_stride[sel] * stream_pf_dist[sel]);
                        end

                        pf_stream_id <= sel;
                        pf_pending_mask[sel] <= 1'b1;

                        total_pf_req <= total_pf_req + 32'd1;

                        if (pf_ready) begin
                            // Advance prefetch distance
                            stream_pf_dist[sel] <= stream_pf_dist[sel] + 4'd1;
                            pf_pending_mask[sel] <= 1'b0;
                        end
                    end

                    pf_state <= PF_IDLE;
                end

                default: pf_state <= PF_IDLE;
            endcase

            // ─────────────────────────────────────────────────
            // Track prefetch results
            // ─────────────────────────────────────────────────
            if (pf_result_used) begin
                integer i;
                reg [ADDR_WIDTH-1:0] prefetch_addr;
                total_pf_useful <= total_pf_useful + 32'd1;
                // Clear pending for the stream that used this
                for (i = 0; i < NUM_STREAMS; i = i + 1) begin
                    prefetch_addr = stream_base[i] + stream_stride[i] * stream_pf_dist[i];
                    if (pf_result_addr == prefetch_addr) begin
                        pf_pending_mask[i] <= 1'b0;
                        stream_useless[i] <= 8'd0;  // Reset useless
                    end
                end
            end

            if (pf_result_unused) begin
                integer i;
                reg [ADDR_WIDTH-1:0] prefetch_addr;
                total_pf_useless <= total_pf_useless + 32'd1;
                // Increment useless counter
                for (i = 0; i < NUM_STREAMS; i = i + 1) begin
                    prefetch_addr = stream_base[i] + stream_stride[i] * stream_pf_dist[i];
                    if (pf_result_addr == prefetch_addr) begin
                        if (stream_useless[i] < USELESS_THRESHOLD) begin
                            stream_useless[i] <= stream_useless[i] + 8'd1;
                        end

                        // Deallocation if too many useless
                        if (stream_useless[i] >= USELESS_THRESHOLD) begin
                            stream_valid[i] <= 1'b0;
                            stream_confidence[i] <= 4'd0;
                            stream_pf_dist[i] <= 4'd1;
                            pf_pending_mask[i] <= 1'b0;
                            total_dealloc <= total_dealloc + 32'd1;
                        end
                    end
                end
            end
        end
    end

    // ─────────────────────────────────────────────────────────────
    // Update stream tracking task
    // ─────────────────────────────────────────────────────────────
    task update_streams;
        input [ADDR_WIDTH-1:0] access_addr;
        integer i;
        integer j;
        reg [1:0] alloc_idx;
        reg [MAX_STRIDE_BITS-1:0] new_stride;

        begin
            // Check if access matches any existing stream
            if (match_found) begin
                i = 32'(match_stream_idx);

                // Confirm stride pattern
                stream_confidence[i] <= stream_confidence[i] + 4'd1;
                if (stream_confidence[i] >= CONFIDENCE_MAX) begin
                    stream_confidence[i] <= CONFIDENCE_MAX;
                end

                // Update base to latest access
                stream_base[i] <= access_addr;

                // Advance distance
                stream_pf_dist[i] <= stream_pf_dist[i] + 4'd1;

                // Track coverage
                if (miss_valid) begin
                    total_pf_coverage <= total_pf_coverage + 32'd1;
                end
            end else if (miss_valid) begin
                // New miss that doesn't match any stream → try to allocate
                // Find two consecutive misses to establish stride
                // Simplified: use access history

                // Find stream to allocate (empty slot or evict lowest confidence)
                alloc_idx = 2'(evict_stream_idx);

                // If evicting a valid stream, track deallocation
                if (stream_valid[alloc_idx]) begin
                    total_dealloc <= total_dealloc + 32'd1;
                end

                // Simple stride estimation from previous access
                // In real HW, this would use a small address history buffer
                if (access_addr > stream_base[alloc_idx]) begin
                    new_stride = 16'(access_addr - stream_base[alloc_idx]);
                    stream_dir[alloc_idx] <= 1'b0;  // Forward
                end else begin
                    new_stride = 16'(stream_base[alloc_idx] - access_addr);
                    stream_dir[alloc_idx] <= 1'b1;  // Backward
                end

                // Only allocate if stride is reasonable (not too large/small)
                if (new_stride > 0 && new_stride < (1 << 14)) begin
                    stream_valid[alloc_idx] <= 1'b1;
                    stream_stride[alloc_idx] <= new_stride;
                    stream_base[alloc_idx] <= access_addr;
                    stream_confidence[alloc_idx] <= 4'd1;  // Start low
                    stream_useless[alloc_idx] <= 8'd0;
                    stream_pf_dist[alloc_idx] <= 4'd1;
                    total_alloc <= total_alloc + 32'd1;
                end
            end
        end
    endtask

endmodule
