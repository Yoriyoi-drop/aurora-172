`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Cache Profiler
// Module Name: cache_profiler
//
// Description:
//   Cache Performance Profiler - Real-time cache performance monitoring
//   - Per-core L1 hit/miss rates
//   - L2 aggregate hit/miss rates
//   - MESI state distribution
//   - Writeback frequency
//   - Cache utilization percentages
//
// Target: Provide visibility into cache hierarchy performance
//////////////////////////////////////////////////////////////////////////////////

module cache_profiler #(
    parameter ADDR_WIDTH    = `AURORA_ADDR_WIDTH,   // FIXED: Use standard parameter
    parameter NUM_CORES     = 16,        // OPTIMIZED: 32->16 (smaller profiler)
    parameter HISTOGRAM_BINS = 8         // OPTIMIZED: 16->8 (simpler histogram)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // L1 cache metrics (per core)
    input  wire [31:0]                  l1_hits [0:NUM_CORES-1],
    input  wire [31:0]                  l1_misses [0:NUM_CORES-1],
    input  wire [31:0]                  l1_writebacks [0:NUM_CORES-1],
    input  wire [31:0]                  l1_invalidations [0:NUM_CORES-1],

    // L2 cache metrics
    input  wire [31:0]                  l2_hits,
    input  wire [31:0]                  l2_misses,
    input  wire [31:0]                  l2_writebacks,
    input  wire [31:0]                  l2_evictions,
    input  wire [31:0]                  snoop_invalidations,

    // MESI controller metrics
    input  wire [31:0]                   mesi_invalidations,
    input  wire [31:0]                  mesi_upgrades,
    input  wire [31:0]                  mesi_writebacks,
    input  wire [31:0]                  mesi_shared_grants,

    // Access latency tracking
    input  wire                         access_start,
    input  wire                         access_complete,
    input  wire [7:0]                   access_latency,    // Cycles for this access

    // Output: Aggregated metrics (readable by testbench)
    output reg [31:0]                   total_accesses,
    output reg [31:0]                   total_l1_hits,
    output reg [31:0]                   total_l1_misses,
    output reg [31:0]                   total_l2_hits,
    output reg [31:0]                   total_l2_misses,
    output reg [31:0]                   total_writebacks,
    output reg [31:0]                   total_invalidations,
    
    // Calculated rates
    output reg [7:0]                    l1_hit_rate_pct,      // L1 hit rate percentage
    output reg [7:0]                    l2_hit_rate_pct,      // L2 hit rate percentage (of L1 misses)
    output reg [7:0]                    overall_hit_rate_pct, // Overall hit rate (L1+L2)
    output reg [7:0]                    avg_access_latency,   // Average access latency in cycles

    // Latency histogram
    output reg [31:0]                   latency_histogram [0:HISTOGRAM_BINS-1],

    // MESI state distribution
    output reg [31:0]                   mesi_modified_count,
    output reg [31:0]                   mesi_exclusive_count,
    output reg [31:0]                   mesi_shared_count,
    output reg [31:0]                   mesi_invalid_count,

    // Print trigger
    input  wire                         trigger_print,
    output reg                          print_done
);

    // =========================================================================
    // Metrics aggregation
    // =========================================================================
    integer i;
    
    // FIX: Move all variable declarations to module level (not inside always block)
    reg [31:0] prev_l1_hits_sum;
    reg [31:0] prev_l1_misses_sum;
    reg [31:0] prev_l1_writebacks_sum;
    reg [31:0] prev_l1_invalidations_sum;
    
    reg [31:0] cycle_l1_hits;
    reg [31:0] cycle_l1_misses;
    reg [31:0] cycle_writebacks;
    reg [31:0] cycle_invalidations;
    
    reg signed [31:0] delta_l1_hits;
    reg signed [31:0] delta_l1_misses;
    reg signed [31:0] delta_l1_writebacks;
    reg signed [31:0] delta_l1_invalidations;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            total_accesses <= 32'h0;
            total_l1_hits <= 32'h0;
            total_l1_misses <= 32'h0;
            total_l2_hits <= 32'h0;
            total_l2_misses <= 32'h0;
            total_writebacks <= 32'h0;
            total_invalidations <= 32'h0;
            l1_hit_rate_pct <= 8'd0;
            l2_hit_rate_pct <= 8'd0;
            overall_hit_rate_pct <= 8'd0;
            avg_access_latency <= 8'd0;

            // FIXED: Reset delta tracking registers
            prev_l1_hits_sum <= 32'h0;
            prev_l1_misses_sum <= 32'h0;
            prev_l1_writebacks_sum <= 32'h0;
            prev_l1_invalidations_sum <= 32'h0;
            mesi_modified_count <= 32'h0;
            mesi_exclusive_count <= 32'h0;
            mesi_shared_count <= 32'h0;
            mesi_invalid_count <= 32'h0;
            print_done <= 1'b0;

            for (i = 0; i < HISTOGRAM_BINS; i = i + 1) begin
                latency_histogram[i] <= 32'h0;
            end
        end else begin
            // FIX: Compute deltas from cumulative counters to prevent double counting
            // Sum current per-core L1 counters
            cycle_l1_hits = 0;
            cycle_l1_misses = 0;
            cycle_writebacks = 0;
            cycle_invalidations = 0;

            for (i = 0; i < NUM_CORES; i = i + 1) begin
                cycle_l1_hits = cycle_l1_hits + l1_hits[i];
                cycle_l1_misses = cycle_l1_misses + l1_misses[i];
                cycle_writebacks = cycle_writebacks + l1_writebacks[i];
                cycle_invalidations = cycle_invalidations + l1_invalidations[i];
            end

            // Compute deltas (current - previous) to get per-cycle changes
            // FIX: Use unsigned subtraction to prevent underflow - deltas should never be negative
            delta_l1_hits = (cycle_l1_hits >= prev_l1_hits_sum) ? (cycle_l1_hits - prev_l1_hits_sum) : 32'd0;
            delta_l1_misses = (cycle_l1_misses >= prev_l1_misses_sum) ? (cycle_l1_misses - prev_l1_misses_sum) : 32'd0;
            delta_l1_writebacks = (cycle_writebacks >= prev_l1_writebacks_sum) ? (cycle_writebacks - prev_l1_writebacks_sum) : 32'd0;
            delta_l1_invalidations = (cycle_invalidations >= prev_l1_invalidations_sum) ? (cycle_invalidations - prev_l1_invalidations_sum) : 32'd0;

            // Update previous values for next cycle
            prev_l1_hits_sum <= cycle_l1_hits;
            prev_l1_misses_sum <= cycle_l1_misses;
            prev_l1_writebacks_sum <= cycle_writebacks;
            prev_l1_invalidations_sum <= cycle_invalidations;

            // Accumulate totals using deltas (FIXED v2: no double counting)
            // FIX v2: Removed extra "+ snoop_invalidations + mesi_invalidations" from
            // delta_invalidations — deltas already include these via per-core counters.
            // Also removed extra "+ l2_writebacks" from delta_writebacks.
            if (delta_l1_hits > 0) total_l1_hits <= total_l1_hits + delta_l1_hits;
            if (delta_l1_misses > 0) total_l1_misses <= total_l1_misses + delta_l1_misses;
            if (delta_l1_writebacks > 0) total_writebacks <= total_writebacks + delta_l1_writebacks;
            if (delta_l1_invalidations > 0) total_invalidations <= total_invalidations + delta_l1_invalidations;

            // L2 metrics (snapshot, not accumulated)
            total_l2_hits <= l2_hits;
            total_l2_misses <= l2_misses;

            // Total accesses
            total_accesses <= total_l1_hits + total_l1_misses;

            // Calculate hit rates
            if (total_accesses > 0) begin
                l1_hit_rate_pct <= (total_l1_hits * 100) / total_accesses;
            end else begin
                l1_hit_rate_pct <= 8'd0;
            end

            if (total_l1_misses > 0) begin
                l2_hit_rate_pct <= (total_l2_hits * 100) / total_l1_misses;
            end else begin
                l2_hit_rate_pct <= 8'd0;
            end

            // Overall hit rate (L1 hits + L2 hits) / total
            if (total_accesses > 0) begin
                overall_hit_rate_pct <= ((total_l1_hits + total_l2_hits) * 100) / total_accesses;
            end else begin
                overall_hit_rate_pct <= 8'd0;
            end

            // Average latency (exponential moving average)
            if (access_complete) begin
                avg_access_latency <= ((avg_access_latency * 7) + access_latency) / 8;
            end

            // Latency histogram
            if (access_complete && access_latency < HISTOGRAM_BINS) begin
                latency_histogram[access_latency] <= latency_histogram[access_latency] + 1;
            end

            // MESI state distribution (sampled from L2 cache state)
            // (Simplified: track via snoop responses)
            if (mesi_shared_grants > 0) begin
                mesi_shared_count <= mesi_shared_count + mesi_shared_grants;
            end
            if (mesi_writebacks > 0) begin
                mesi_modified_count <= mesi_modified_count + mesi_writebacks;
            end
            // Track exclusive lines: inferred as read misses that get exclusive state
            // (approximated as L1 misses - L1 writebacks - shared grants)
            if (total_l1_misses >= total_writebacks + mesi_shared_count) begin
                mesi_exclusive_count <= total_l1_misses - total_writebacks - mesi_shared_count;
            end

            // Print trigger
            if (trigger_print) begin
                print_cache_report();
                print_done <= 1'b1;
            end else begin
                print_done <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Print cache performance report
    // =========================================================================
    task automatic print_cache_report;
        integer bin;
        begin
            $display("\n========================================");
            $display("  AURORA-172 Cache Performance Report");
            $display("========================================");
            $display("");
            $display("L1 Cache Metrics:");
            $display("  Total Accesses:      %0d", total_accesses);
            $display("  L1 Hits:             %0d", total_l1_hits);
            $display("  L1 Misses:           %0d", total_l1_misses);
            $display("  L1 Hit Rate:         %0d%%", l1_hit_rate_pct);
            $display("  L1 Writebacks:       %0d", total_writebacks);
            $display("  L1 Invalidations:    %0d", total_invalidations);
            $display("");
            $display("L2 Cache Metrics:");
            $display("  L2 Hits:             %0d", total_l2_hits);
            $display("  L2 Misses:           %0d", total_l2_misses);
            $display("  L2 Hit Rate (of L1 miss): %0d%%", l2_hit_rate_pct);
            $display("  L2 Writebacks:       %0d", l2_writebacks);
            $display("  L2 Evictions:        %0d", l2_evictions);
            $display("  Snoop Invalidations: %0d", snoop_invalidations);
            $display("");
            $display("Overall:");
            $display("  Overall Hit Rate:    %0d%%", overall_hit_rate_pct);
            $display("  Avg Access Latency:  %0d cycles", avg_access_latency);
            $display("");
            $display("MESI Coherence:");
            $display("  Modified Lines:      %0d", mesi_modified_count);
            $display("  Exclusive Lines:     %0d", mesi_exclusive_count);
            $display("  Shared Lines:        %0d", mesi_shared_count);
            $display("  Invalid Lines:       %0d", mesi_invalid_count);
            $display("  Total Invalidations: %0d", mesi_invalidations);
            $display("  Upgrades Sent:       %0d", mesi_upgrades);
            $display("  Shared Grants:       %0d", mesi_shared_grants);
            $display("");

            // Latency distribution
            $display("Latency Distribution:");
            for (bin = 0; bin < HISTOGRAM_BINS; bin = bin + 1) begin
                if (latency_histogram[bin] > 0) begin
                    $display("  %2d cycles: %0d accesses", bin, latency_histogram[bin]);
                end
            end

            $display("========================================\n");
        end
    endtask

endmodule
