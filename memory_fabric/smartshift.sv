`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: AMD SmartShift)
// Module Name: smartshift
// FIX v2: Complete rewrite - no automatic vars, no complex ternary
//////////////////////////////////////////////////////////////////////////////////

module smartshift #(
    parameter DATA_WIDTH    = `AURORA_DATA_WIDTH,   // FIXED: Use standard parameter
    parameter POWER_UNIT    = 1000,
    parameter MAX_TDP_WATTS = 250,
    parameter G_CORE_BASE_W = 100,   // OPTIMIZED: 150->100 (lower base)
    parameter A_CORE_BASE_W = 80,    // OPTIMIZED: 100->80 (lower base)
    parameter H_CORE_BASE_W = 40,    // OPTIMIZED: 50->40 (lower base)
    parameter NPU_BASE_W    = 10     // OPTIMIZED: 20->10 (minimal NPU)
)(
    input  wire                         clk,
    input  wire                         rst_n,
    input  wire [DATA_WIDTH-1:0]        g_core_demand_mw,
    input  wire [DATA_WIDTH-1:0]        a_core_demand_mw,
    input  wire [DATA_WIDTH-1:0]        h_core_demand_mw,
    input  wire [DATA_WIDTH-1:0]        npu_demand_mw,
    input  wire                         gaming_mode,
    input  wire                         ai_mode,
    input  wire                         mixed_mode,
    input  wire                         gpu_bound,
    input  wire [DATA_WIDTH-1:0]        tdp_limit_mw,
    output reg  [DATA_WIDTH-1:0]        g_core_budget_mw,
    output reg  [DATA_WIDTH-1:0]        a_core_budget_mw,
    output reg  [DATA_WIDTH-1:0]        h_core_budget_mw,
    output reg  [DATA_WIDTH-1:0]        npu_budget_mw,
    output reg                          redistribution_active,
    output wire [DATA_WIDTH-1:0]        total_allocated_mw,
    output wire [DATA_WIDTH-1:0]        power_surplus_mw,
    output wire [DATA_WIDTH-1:0]        power_deficit_mw,
    output reg  [31:0]                  redistribution_count,
    output reg  [31:0]                  g_core_boost_count,
    output reg  [31:0]                  a_core_boost_count,
    output reg  [31:0]                  tdp_limit_hit_count,

    // Throttle control outputs (Bug 2: budget enforcement)
    // Asserted when actual_power exceeds the computed budget
    input  wire [DATA_WIDTH-1:0]        g_core_actual_mw,
    input  wire [DATA_WIDTH-1:0]        a_core_actual_mw,
    input  wire [DATA_WIDTH-1:0]        h_core_actual_mw,
    input  wire [DATA_WIDTH-1:0]        npu_actual_mw,
    output reg                          throttle_g_core,
    output reg                          throttle_a_core,
    output reg                          throttle_h_core,
    output reg                          throttle_npu,
    output reg                          throttle_any,
    output reg [DATA_WIDTH-1:0]         throttle_excess_mw
);

    // Internal signals
    wire [DATA_WIDTH-1:0] ss_tdp_hits;

    localparam G_CORE_BASE_MW = G_CORE_BASE_W * POWER_UNIT;
    localparam A_CORE_BASE_MW = A_CORE_BASE_W * POWER_UNIT;
    localparam H_CORE_BASE_MW = H_CORE_BASE_W * POWER_UNIT;
    localparam NPU_BASE_MW    = NPU_BASE_W * POWER_UNIT;
    // FIX v2: Floor = half of base
    localparam G_FLOOR = G_CORE_BASE_MW >> 1;
    localparam A_FLOOR = A_CORE_BASE_MW >> 1;
    localparam H_FLOOR = H_CORE_BASE_MW >> 1;
    localparam N_FLOOR = NPU_BASE_MW >> 1;

    localparam GAMING_G_W = 8'd60;
    localparam AI_A_W     = 8'd70;
    localparam MIXED_G_W  = 8'd35;
    localparam MIXED_A_W  = 8'd40;
    localparam MIXED_H_W  = 8'd25;
    localparam MAX_SCALE  = 12'd1500;

    // Internal state machine
    typedef enum logic [2:0] { SS_IDLE, SS_MEASURE, SS_CALC, SS_APPLY, SS_SETTLE } ss_state_t;
    ss_state_t      ss_state;
    reg [7:0]       ss_cnt;

    // FIX v2: Intermediate budget registers (computed in CALC, applied in APPLY)
    reg [DATA_WIDTH-1:0] g_budget_next, a_budget_next, h_budget_next, n_budget_next;

    wire [DATA_WIDTH-1:0] total_demand = g_core_demand_mw + a_core_demand_mw + h_core_demand_mw + npu_demand_mw;
    assign power_surplus_mw = (tdp_limit_mw > total_allocated_mw) ? (tdp_limit_mw - total_allocated_mw) : {DATA_WIDTH{1'b0}};
    assign power_deficit_mw = (total_demand > tdp_limit_mw) ? (total_demand - tdp_limit_mw) : {DATA_WIDTH{1'b0}};
    assign total_allocated_mw = g_core_budget_mw + a_core_budget_mw + h_core_budget_mw + npu_budget_mw;

    // FSM
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ss_state <= SS_IDLE; ss_cnt <= 8'd0;
            redistribution_active <= 1'b0; redistribution_count <= 32'd0;
        end else begin
            case (ss_state)
                SS_IDLE: begin
                    redistribution_active <= 1'b0; ss_cnt <= 8'd0;
                    if (total_demand != total_allocated_mw) ss_state <= SS_MEASURE;
                end
                SS_MEASURE: begin ss_cnt <= ss_cnt + 1; ss_state <= SS_CALC; end
                SS_CALC: begin
                    redistribution_active <= 1'b1;
                    redistribution_count <= redistribution_count + 32'd1;
                    ss_state <= SS_APPLY;
                end
                SS_APPLY: begin
                    // FIX v2: Apply computed budgets
                    g_core_budget_mw <= g_budget_next;
                    a_core_budget_mw <= a_budget_next;
                    h_core_budget_mw <= h_budget_next;
                    npu_budget_mw    <= n_budget_next;
                    ss_state <= SS_SETTLE;
                end
                SS_SETTLE: begin
                    if (ss_cnt >= 8'd5) begin ss_state <= SS_IDLE; redistribution_active <= 1'b0; end
                    else ss_cnt <= ss_cnt + 1;
                end
                default: ss_state <= SS_IDLE;
            endcase
        end
    end

    // FIX v2: Budget computation using if/else (no automatic, no complex ternary)
    // FIX: Remove circular dependency by computing tdp_hits separately
    reg [31:0] tdp_hits_reg;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tdp_hits_reg <= 32'b0;
        end else begin
            tdp_hits_reg <= (total_demand >= tdp_limit_mw) ? (tdp_hits_reg + 1) : tdp_hits_reg;
        end
    end
    
    always @(*) begin
        // Defaults = base
        g_budget_next = G_CORE_BASE_MW;
        a_budget_next = A_CORE_BASE_MW;
        h_budget_next = H_CORE_BASE_MW;
        n_budget_next = NPU_BASE_MW;

        if (total_demand >= tdp_limit_mw) begin
            // Use registered counter instead of combinational increment
            if (gaming_mode && gpu_bound) begin
                // Gaming: boost G from A+H surplus
                g_budget_next = G_CORE_BASE_MW + ((((a_core_demand_mw > A_CORE_BASE_MW) ? 0 : A_CORE_BASE_MW - a_core_demand_mw) + ((h_core_demand_mw > H_CORE_BASE_MW) ? 0 : H_CORE_BASE_MW - h_core_demand_mw) + power_surplus_mw) * GAMING_G_W >> 8);
                a_budget_next = A_CORE_BASE_MW - ((a_core_demand_mw > A_CORE_BASE_MW) ? 0 : A_CORE_BASE_MW - a_core_demand_mw);
                h_budget_next = H_CORE_BASE_MW - ((h_core_demand_mw > H_CORE_BASE_MW) ? 0 : H_CORE_BASE_MW - h_core_demand_mw);
                n_budget_next = NPU_BASE_MW;
                // Floor clamp
                if (g_budget_next < G_FLOOR) g_budget_next = G_FLOOR;
                if (a_budget_next < A_FLOOR) a_budget_next = A_FLOOR;
                if (h_budget_next < H_FLOOR) h_budget_next = H_FLOOR;
                if (n_budget_next < N_FLOOR) n_budget_next = N_FLOOR;
            end else if (ai_mode) begin
                // AI: boost A from G surplus + NPU boost
                a_budget_next = A_CORE_BASE_MW + ((((g_core_demand_mw > G_CORE_BASE_MW) ? 0 : G_CORE_BASE_MW - g_core_demand_mw) + power_surplus_mw) * AI_A_W >> 8);
                g_budget_next = G_CORE_BASE_MW - ((g_core_demand_mw > G_CORE_BASE_MW) ? 0 : G_CORE_BASE_MW - g_core_demand_mw);
                h_budget_next = H_CORE_BASE_MW;
                // FIX v2: NPU boost
                if (npu_demand_mw > NPU_BASE_MW)
                    n_budget_next = NPU_BASE_MW + (power_surplus_mw >> 4);
                else
                    n_budget_next = NPU_BASE_MW;
                if (g_budget_next < G_FLOOR) g_budget_next = G_FLOOR;
                if (a_budget_next < A_FLOOR) a_budget_next = A_FLOOR;
                if (h_budget_next < H_FLOOR) h_budget_next = H_FLOOR;
                if (n_budget_next < N_FLOOR) n_budget_next = N_FLOOR;
            end else if (mixed_mode) begin
                g_budget_next = G_CORE_BASE_MW + (power_surplus_mw * MIXED_G_W >> 8);
                a_budget_next = A_CORE_BASE_MW + (power_surplus_mw * MIXED_A_W >> 8);
                h_budget_next = H_CORE_BASE_MW + (power_surplus_mw * MIXED_H_W >> 8);
                n_budget_next = NPU_BASE_MW;
                if (g_budget_next < G_FLOOR) g_budget_next = G_FLOOR;
                if (a_budget_next < A_FLOOR) a_budget_next = A_FLOOR;
                if (h_budget_next < H_FLOOR) h_budget_next = H_FLOOR;
            end
            // Else: stay at base (floors already satisfied)
        end else begin
            // TDP headroom - give demand (capped at 1.5x base)
            if (g_core_demand_mw > (G_CORE_BASE_MW * MAX_SCALE >> 12))
                g_budget_next = G_CORE_BASE_MW * MAX_SCALE >> 12;
            else g_budget_next = g_core_demand_mw;

            if (a_core_demand_mw > (A_CORE_BASE_MW * MAX_SCALE >> 12))
                a_budget_next = A_CORE_BASE_MW * MAX_SCALE >> 12;
            else a_budget_next = a_core_demand_mw;

            if (h_core_demand_mw > (H_CORE_BASE_MW * MAX_SCALE >> 12))
                h_budget_next = H_CORE_BASE_MW * MAX_SCALE >> 12;
            else h_budget_next = h_core_demand_mw;

            n_budget_next = NPU_BASE_MW;
        end
    end

    // Boost counters (combinational tracking)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g_core_boost_count <= 32'd0;
            a_core_boost_count <= 32'd0;
        end else if (ss_state == SS_CALC) begin
            if (gaming_mode && gpu_bound && g_budget_next > G_CORE_BASE_MW)
                g_core_boost_count <= g_core_boost_count + 1;
            if (ai_mode && a_budget_next > A_CORE_BASE_MW)
                a_core_boost_count <= a_core_boost_count + 1;
        end
    end

    // ─────────────────────────────────────────────────────────────
    // Bug 2: Power budget enforcement with hysteresis
    // Compare actual power consumption against allocated budget
    // and assert throttle signals when exceeded.
    // ─────────────────────────────────────────────────────────────
    reg [DATA_WIDTH-1:0] throttle_excess;
    reg [3:0] throttle_hyst_cnt;

    localparam THROTTLE_HYSTERESIS = 4'd3;  // cycles before throttle activates

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            throttle_g_core <= 1'b0;
            throttle_a_core <= 1'b0;
            throttle_h_core <= 1'b0;
            throttle_npu    <= 1'b0;
            throttle_any    <= 1'b0;
            throttle_excess_mw <= {DATA_WIDTH{1'b0}};
            throttle_excess <= {DATA_WIDTH{1'b0}};
            throttle_hyst_cnt <= 4'd0;
        end else begin
            // Compute excess per domain
            throttle_excess <= 32'd0;

            // G-Core throttle
            if (g_core_actual_mw > g_core_budget_mw) begin
                throttle_excess <= g_core_actual_mw - g_core_budget_mw;
                if (throttle_hyst_cnt >= THROTTLE_HYSTERESIS) begin
                    throttle_g_core <= 1'b1;
                end else begin
                    throttle_hyst_cnt <= throttle_hyst_cnt + 4'd1;
                end
            end else begin
                throttle_g_core <= 1'b0;
            end

            // A-Core throttle
            if (a_core_actual_mw > a_core_budget_mw) begin
                throttle_excess <= a_core_actual_mw - a_core_budget_mw;
                if (throttle_hyst_cnt >= THROTTLE_HYSTERESIS) begin
                    throttle_a_core <= 1'b1;
                end else begin
                    throttle_hyst_cnt <= throttle_hyst_cnt + 4'd1;
                end
            end else begin
                throttle_a_core <= 1'b0;
            end

            // H-Core throttle
            if (h_core_actual_mw > h_core_budget_mw) begin
                throttle_excess <= h_core_actual_mw - h_core_budget_mw;
                if (throttle_hyst_cnt >= THROTTLE_HYSTERESIS) begin
                    throttle_h_core <= 1'b1;
                end else begin
                    throttle_hyst_cnt <= throttle_hyst_cnt + 4'd1;
                end
            end else begin
                throttle_h_core <= 1'b0;
            end

            // NPU throttle
            if (npu_actual_mw > npu_budget_mw) begin
                throttle_excess <= npu_actual_mw - npu_budget_mw;
                if (throttle_hyst_cnt >= THROTTLE_HYSTERESIS) begin
                    throttle_npu <= 1'b1;
                end else begin
                    throttle_hyst_cnt <= throttle_hyst_cnt + 4'd1;
                end
            end else begin
                throttle_npu <= 1'b0;
            end

            // Combined throttle flag
            throttle_any <= throttle_g_core || throttle_a_core ||
                            throttle_h_core || throttle_npu;
            throttle_excess_mw <= throttle_excess;

            // Clear hysteresis when all domains are within budget
            if (!(g_core_actual_mw > g_core_budget_mw) &&
                !(a_core_actual_mw > a_core_budget_mw) &&
                !(h_core_actual_mw > h_core_budget_mw) &&
                !(npu_actual_mw > npu_budget_mw)) begin
                throttle_hyst_cnt <= 4'd0;
            end
        end
    end

// FIX: Assign tdp_hits from registered value to break circular dependency
    assign ss_tdp_hits = tdp_hits_reg;

endmodule
