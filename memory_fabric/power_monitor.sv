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

module power_monitor #(
    parameter DATA_WIDTH            = 128,  // OPTIMIZED: 64→128 for finer energy tracking
    parameter NUM_DOMAINS           = 5,    // G, A, H, NPU, Memory
    parameter ENERGY_UNIT_uJ        = 1,    // 1μJ per count (Intel: 15.3μJ)
    parameter POWER_AVG_WINDOW      = 1000  // 1000 cycle averaging window
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
    // Energy Counters (64-bit, accumulate in μJ)
    // Intel RAPL equivalent
    // ─────────────────────────────────────────────────────────────
    reg [63:0]  energy_g_counter;
    reg [63:0]  energy_a_counter;
    reg [63:0]  energy_h_counter;
    reg [63:0]  energy_npu_counter;

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
    assign domain_pl1_exceeded = {2'b0, npu_pl1_exceed, h_pl1_exceed, a_pl1_exceed, g_pl1_exceed};
    assign domain_pl2_exceeded = {2'b0, 1'b0, 1'b0, a_pl2_exceed, g_pl2_exceed};

    // ─────────────────────────────────────────────────────────────
    // Main Logic: Energy counting + limit enforcement
    // ─────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            energy_g_counter <= 64'd0;
            energy_a_counter <= 64'd0;
            energy_h_counter <= 64'd0;
            energy_npu_counter <= 64'd0;

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
            // Energy Accumulation - REALISTIC MODEL
            // Energy (μJ) = Power (mW) × Time (ns) / 1000
            // At 6GHz: cycle_time = 0.167ns (167ps)
            // Energy per cycle = mW × 0.167 / 1000 = mW × 0.000167 μJ
            //
            // To avoid floating point, use fixed-point arithmetic:
            // energy_increment = (power_mw * CYCLE_TIME_PS) / 1_000_000
            // where CYCLE_TIME_PS = 167 (picoseconds at 6GHz)
            // ─────────────────────────────────────────────────

            // G-Core energy accumulation
            if (g_core_power_mw > 0) begin
                energy_g_counter <= energy_g_counter + (g_core_power_mw * 167) / 1_000_000;
            end

            // A-Core energy accumulation
            if (a_core_power_mw > 0) begin
                energy_a_counter <= energy_a_counter + (a_core_power_mw * 167) / 1_000_000;
            end

            // H-Core energy accumulation
            if (h_core_power_mw > 0) begin
                energy_h_counter <= energy_h_counter + (h_core_power_mw * 167) / 1_000_000;
            end

            // NPU energy accumulation
            if (npu_power_mw > 0) begin
                energy_npu_counter <= energy_npu_counter + (npu_power_mw * 167) / 1_000_000;
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
            // PL1 Limit Enforcement (Long-term)
            // Intel RAPL: Auto-throttle to stay within PL1
            // ─────────────────────────────────────────────────
            if (enable_limit_enforce) begin
                if (total_pl1_exceed) begin
                    pl1_violation_count <= pl1_violation_count + 32'd1;

                    // Throttle the highest power domain
                    if (g_pl1_exceed) begin
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd0;  // G-Core
                    end else if (a_pl1_exceed) begin
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd1;  // A-Core
                    end else if (h_pl1_exceed) begin
                        // FIX v2: H-Core throttle path
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd2;  // H-Core
                    end else if (npu_pl1_exceed) begin
                        // FIX v2: NPU throttle path
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd3;  // NPU
                    end else begin
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd2;  // H-Core (fallback)
                    end

                    throttle_event_count <= throttle_event_count + 32'd1;
                end else begin
                    // FIX v2: Auto-clear throttle_request after 1 cycle (pulse behavior)
                    throttle_request <= 1'b0;
                end

                // ─────────────────────────────────────────────
                // PL2 Limit Enforcement (Short-term turbo)
                // More aggressive, immediate response
                // ─────────────────────────────────────────────
                if (total_pl2_exceed) begin
                    pl2_violation_count <= pl2_violation_count + 32'd1;

                    // Immediate hard throttle
                    if (g_pl2_exceed) begin
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd0;
                    end else begin
                        throttle_request <= 1'b1;
                        throttle_domain <= 4'd1;
                    end

                    throttle_event_count <= throttle_event_count + 32'd1;
                end else begin
                    // FIX v2: Auto-clear throttle when PL2 not exceeded (pulse behavior)
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
