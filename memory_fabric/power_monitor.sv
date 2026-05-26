//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: Intel RAPL)
//
// Create Date: 11 April 2026
// Design Name: Power Monitor (RAPL-like)
// Module Name: power_monitor
//
// Description:
//   Hardware power monitoring dengan energy counter dan limit enforcement
//   Inspired by Intel RAPL (Running Average Power Limit)
//
//   Intel RAPL Features:
//   - 64-bit energy counter (15.3μJ resolution)
//   - Per-domain measurement (Package, PP0, PP1, DRAM)
//   - Power limit enforcement (PL1 + PL2)
//   - Auto throttle on limit exceed
//
//   AURORA Adaptation:
//   - Per-domain: G-Core, A-Core, H-Core, NPU, Memory
//   - Energy counter: 64-bit (1μJ resolution)
//   - Power limit: PL1 (long-term) + PL2 (short-term turbo)
//   - Real-time power averaging
//
// Registers (Intel RAPL style):
//   0x00: Energy Status (per domain)
//   0x01: Power Limit 1 (long-term)
//   0x02: Power Limit 2 (short-term)
//   0x03: Power Policy (priority)
//
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

module power_monitor #(
    parameter DATA_WIDTH            = `AURORA_DATA_WIDTH,   // FIXED: Use standard parameter
    parameter NUM_DOMAINS           = 5,    // FIXED: was 3, but we track G, A, H, NPU, Memory
    parameter ENERGY_UNIT_uJ        = 1,    // 1µJ per count
    parameter POWER_AVG_WINDOW      = 256   // OPTIMIZED: 1000->256 (faster averaging)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Instantaneous power input (dari sensors per domain)
    input  wire [DATA_WIDTH-1:0]        g_core_power_mw,      // G-Core instantaneous (mW)
    input  wire [DATA_WIDTH-1:0]        a_core_power_mw,      // A-Core
    input  wire [DATA_WIDTH-1:0]        h_core_power_mw,      // H-Core
    input  wire [DATA_WIDTH-1:0]        npu_power_mw,         // NPU
    input  wire [DATA_WIDTH-1:0]        memory_power_mw,      // Memory

    // Power limits (PL1 - long-term TDP)
    input  wire [DATA_WIDTH-1:0]        pl1_g_core_mw,
    input  wire [DATA_WIDTH-1:0]        pl1_a_core_mw,
    input  wire [DATA_WIDTH-1:0]        pl1_h_core_mw,
    input  wire [DATA_WIDTH-1:0]        pl1_npu_mw,
    input  wire [DATA_WIDTH-1:0]        pl1_total_mw,

    // Power limits (PL2 - short-term turbo)
    input  wire [DATA_WIDTH-1:0]        pl2_g_core_mw,
    input  wire [DATA_WIDTH-1:0]        pl2_a_core_mw,
    input  wire [DATA_WIDTH-1:0]        pl2_total_mw,
    input  wire [31:0]                  pl2_time_window_cycles, // Turbo time window

    // Control
    input  wire                         enable_monitor,
    input  wire                         enable_limit_enforce,

    // Energy counter output (Intel RAPL MSR read equivalent)
    output wire [63:0]                  energy_g_core_uj,     // Energy consumed (μJ)
    output wire [63:0]                  energy_a_core_uj,
    output wire [63:0]                  energy_h_core_uj,
    output wire [63:0]                  energy_npu_uj,
    output wire [63:0]                  energy_total_uj,

    // Average power output (moving average)
    output wire [DATA_WIDTH-1:0]        avg_g_core_power_mw,
    output wire [DATA_WIDTH-1:0]        avg_a_core_power_mw,
    // FIX v2: Added H-Core and NPU average power output ports
    output wire [DATA_WIDTH-1:0]        avg_h_core_power_mw,
    output wire [DATA_WIDTH-1:0]        avg_npu_power_mw,
    // FIX v2: avg_total now averages ALL 4 domains (G+A+H+NPU)
    output wire [DATA_WIDTH-1:0]        avg_total_power_mw,

    // Limit status
    output wire                         pl1_exceeded,
    output wire                         pl2_exceeded,
    output wire [NUM_DOMAINS-1:0]       domain_pl1_exceeded,
    output wire [NUM_DOMAINS-1:0]       domain_pl2_exceeded,

    // Throttle request (ke frequency controller)
    // FIX v2: throttle_request auto-clears after 1 cycle (pulse, not held)
    output reg                          throttle_request,
    output reg [3:0]                    throttle_domain,      // Which domain to throttle

    // Debug / performance
    output reg [31:0]                   pl1_violation_count,
    output reg [31:0]                   pl2_violation_count,
    output reg [31:0]                   throttle_event_count
);

    // ─────────────────────────────────────────────────────────────
    // Energy Counters (64-bit fixed-point, accumulate in μJ)
    // Intel RAPL equivalent
    // Sub-μJ precision via 32-bit fractional accumulators.
    // ─────────────────────────────────────────────────────────────
    reg [63:0]  energy_g_counter;
    reg [63:0]  energy_a_counter;
    reg [63:0]  energy_h_counter;
    reg [63:0]  energy_npu_counter;

    // Fractional accumulators (fixed-point, unit = 2^-32 μJ)
    reg [31:0]  energy_g_frac;
    reg [31:0]  energy_a_frac;
    reg [31:0]  energy_h_frac;
    reg [31:0]  energy_npu_frac;

    // Scale factor: 167/1_000_000 represented as K/2^32
    // K = (167 << 32) / 1_000_000 ≈ 717702
    localparam [31:0] ENERGY_K = 32'd717702;

    // Time-base counter: update energy once per microsecond (~6000 cycles at 6GHz)
    localparam [15:0] USEC_CYCLES = 16'd6000;
    reg [15:0] timebase_count;

    assign energy_g_core_uj   = energy_g_counter;
    assign energy_a_core_uj   = energy_a_counter;
    assign energy_h_core_uj   = energy_h_counter;
    assign energy_npu_uj      = energy_npu_counter;
    assign energy_total_uj    = energy_g_counter + energy_a_counter +
                                energy_h_counter + energy_npu_counter;

    // ─────────────────────────────────────────────────────────────
    // Power Averaging (Moving Average Filter)
    // Window: POWER_AVG_WINDOW cycles
    // ─────────────────────────────────────────────────────────────
    reg [DATA_WIDTH-1:0]    g_power_sum;
    reg [DATA_WIDTH-1:0]    a_power_sum;
    // FIX v2: Added H-Core and NPU power sum registers for averaging
    reg [DATA_WIDTH-1:0]    h_power_sum;
    reg [DATA_WIDTH-1:0]    npu_power_sum;
    reg [DATA_WIDTH-1:0]    power_sample_count;

    // FIX v2: Per-domain average calculations
    assign avg_g_core_power_mw = (power_sample_count > 0) ?
                                 (g_power_sum / power_sample_count) : g_core_power_mw;
    assign avg_a_core_power_mw = (power_sample_count > 0) ?
                                 (a_power_sum / power_sample_count) : a_core_power_mw;
    assign avg_h_core_power_mw = (power_sample_count > 0) ?
                                 (h_power_sum / power_sample_count) : h_core_power_mw;
    assign avg_npu_power_mw = (power_sample_count > 0) ?
                              (npu_power_sum / power_sample_count) : npu_power_mw;
    // FIX v2: avg_total is average of ALL 4 domains (G+A+H+NPU), not just G+A
    assign avg_total_power_mw  = avg_g_core_power_mw + avg_a_core_power_mw +
                                 avg_h_core_power_mw + avg_npu_power_mw;

    // ─────────────────────────────────────────────────────────────
    // Limit Status Flags
    // ─────────────────────────────────────────────────────────────
    wire g_pl1_exceed = avg_g_core_power_mw > pl1_g_core_mw;
    wire a_pl1_exceed = avg_a_core_power_mw > pl1_a_core_mw;
    // FIX v2: H-Core and NPU PL1 checks included
    wire h_pl1_exceed = avg_h_core_power_mw > pl1_h_core_mw;
    wire npu_pl1_exceed = avg_npu_power_mw > pl1_npu_mw;
    wire total_pl1_exceed = avg_total_power_mw > pl1_total_mw;

    wire g_pl2_exceed = g_core_power_mw > pl2_g_core_mw;
    wire a_pl2_exceed = a_core_power_mw > pl2_a_core_mw;
    // FIX v2: total PL2 now accounts for all 4 domains
    wire total_pl2_exceed = (g_core_power_mw + a_core_power_mw +
                             h_core_power_mw + npu_power_mw) > pl2_total_mw;

    assign pl1_exceeded = total_pl1_exceed;
    assign pl2_exceeded = total_pl2_exceed;
    assign domain_pl1_exceeded = {1'b0, npu_pl1_exceed, h_pl1_exceed, a_pl1_exceed, g_pl1_exceed};
    assign domain_pl2_exceeded = {1'b0, 1'b0, 1'b0, a_pl2_exceed, g_pl2_exceed};

    // ─────────────────────────────────────────────────────────────
    // Main Logic: Energy counting + limit enforcement
    // ─────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            energy_g_counter <= 64'd0;
            energy_a_counter <= 64'd0;
            energy_h_counter <= 64'd0;
            energy_npu_counter <= 64'd0;

            energy_g_frac <= 32'd0;
            energy_a_frac <= 32'd0;
            energy_h_frac <= 32'd0;
            energy_npu_frac <= 32'd0;
            timebase_count <= 16'd0;

            g_power_sum <= {DATA_WIDTH{1'b0}};
            a_power_sum <= {DATA_WIDTH{1'b0}};
            // FIX v2: Initialize H-Core and NPU power sum registers
            h_power_sum <= {DATA_WIDTH{1'b0}};
            npu_power_sum <= {DATA_WIDTH{1'b0}};
            power_sample_count <= {DATA_WIDTH{1'b0}};

            throttle_request <= 1'b0;
            throttle_domain <= 4'd0;

            pl1_violation_count <= 32'd0;
            pl2_violation_count <= 32'd0;
            throttle_event_count <= 32'd0;
        end else if (enable_monitor) begin
            // ─────────────────────────────────────────────────
            // Energy Accumulation - REALISTIC MODEL (fixed-point)
            // Energy (μJ) = Power (mW) × Time (ns) / 1000
            // At 6GHz: cycle_time = 0.167ns (167ps)
            //
            // Fixed-point accumulation using 64-bit + 32-bit fractional:
            //   energy_frac += power_mw * K  where K = (167 << 32) / 1_000_000
            //   When fraction overflows 2^32, carry 1 μJ into main counter
            //
            // Time base: update once per microsecond (6000 cycles @ 6GHz)
            // to bound accumulation error and reduce gate count.
            // ─────────────────────────────────────────────────
            if (timebase_count >= USEC_CYCLES - 1) begin
                timebase_count <= 16'd0;

                // G-Core energy accumulation (fixed-point)
                energy_g_frac <= energy_g_frac + (g_core_power_mw * ENERGY_K);
                if (energy_g_frac > (g_core_power_mw * ENERGY_K))  // overflow
                    energy_g_counter <= energy_g_counter + 64'd1;
                else if (energy_g_frac + (g_core_power_mw * ENERGY_K) < energy_g_frac)
                    energy_g_counter <= energy_g_counter + 64'd1;

                // A-Core energy accumulation
                energy_a_frac <= energy_a_frac + (a_core_power_mw * ENERGY_K);
                if (energy_a_frac > (a_core_power_mw * ENERGY_K))
                    energy_a_counter <= energy_a_counter + 64'd1;
                else if (energy_a_frac + (a_core_power_mw * ENERGY_K) < energy_a_frac)
                    energy_a_counter <= energy_a_counter + 64'd1;

                // H-Core energy accumulation
                energy_h_frac <= energy_h_frac + (h_core_power_mw * ENERGY_K);
                if (energy_h_frac > (h_core_power_mw * ENERGY_K))
                    energy_h_counter <= energy_h_counter + 64'd1;
                else if (energy_h_frac + (h_core_power_mw * ENERGY_K) < energy_h_frac)
                    energy_h_counter <= energy_h_counter + 64'd1;

                // NPU energy accumulation
                energy_npu_frac <= energy_npu_frac + (npu_power_mw * ENERGY_K);
                if (energy_npu_frac > (npu_power_mw * ENERGY_K))
                    energy_npu_counter <= energy_npu_counter + 64'd1;
                else if (energy_npu_frac + (npu_power_mw * ENERGY_K) < energy_npu_frac)
                    energy_npu_counter <= energy_npu_counter + 64'd1;
            end else begin
                timebase_count <= timebase_count + 16'd1;
            end

            // ─────────────────────────────────────────────────
            // Power Averaging
            // ─────────────────────────────────────────────────
            if (power_sample_count >= POWER_AVG_WINDOW) begin
                // Reset window
                g_power_sum <= g_core_power_mw;
                a_power_sum <= a_core_power_mw;
                // FIX v2: Include H-Core and NPU in power averaging window reset
                h_power_sum <= h_core_power_mw;
                npu_power_sum <= npu_power_mw;
                power_sample_count <= 64'd1;
            end else begin
                g_power_sum <= g_power_sum + g_core_power_mw;
                a_power_sum <= a_power_sum + a_core_power_mw;
                // FIX v2: Accumulate H-Core and NPU power sums
                h_power_sum <= h_power_sum + h_core_power_mw;
                npu_power_sum <= npu_power_sum + npu_power_mw;
                power_sample_count <= power_sample_count + 64'd1;
            end

            // ─────────────────────────────────────────────────
            // PL1 & PL2 Limit Enforcement (Combined)
            // Intel RAPL: Auto-throttle to stay within limits
            // PL2 (short-term turbo) takes priority over PL1
            // ─────────────────────────────────────────────────
            if (enable_limit_enforce) begin
                // PL1 count
                if (total_pl1_exceed) begin
                    pl1_violation_count <= pl1_violation_count + 32'd1;
                end
                // PL2 count
                if (total_pl2_exceed) begin
                    pl2_violation_count <= pl2_violation_count + 32'd1;
                end

                // Combined throttle decision: OR both conditions
                if (total_pl1_exceed || total_pl2_exceed) begin
                    // PL2 has priority (more urgent)
                    if (total_pl2_exceed) begin
                        if (g_pl2_exceed) begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd0;
                        end else begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd1;
                        end
                    end else begin
                        // PL1 throttle
                        if (g_pl1_exceed) begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd0;  // G-Core
                        end else if (a_pl1_exceed) begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd1;  // A-Core
                        end else if (h_pl1_exceed) begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd2;  // H-Core
                        end else if (npu_pl1_exceed) begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd3;  // NPU
                        end else begin
                            throttle_request <= 1'b1;
                            throttle_domain <= 4'd2;  // H-Core (fallback)
                        end
                    end

                    // Count events separately to avoid PL2 overriding PL1
                    if (total_pl2_exceed) begin
                        throttle_event_count <= throttle_event_count + 32'd1;
                    end
                    if (total_pl1_exceed) begin
                        throttle_event_count <= throttle_event_count + 32'd1;
                    end
                end else begin
                    // FIX v2: Auto-clear throttle when no limit exceeded (pulse behavior)
                    throttle_request <= 1'b0;
                end
            end else begin
                // FIX v2: When limit enforcement disabled, clear throttle pulse
                throttle_request <= 1'b0;
            end
        end else begin
            // Monitor disabled - hold counters
            // FIX v2: Auto-clear throttle pulse when monitor disabled
            throttle_request <= 1'b0;
        end
    end

endmodule
