//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: Intel Speed Shift / HWP)
//
// Create Date: 12 April 2026
// Design Name: Hardware P-State Control (Speed Shift)
// Module Name: speed_shift_hwp
//
// Description:
//   Hardware-controlled performance state (P-state) selection
//   Inspired by Intel Speed Shift Technology (SST) / Hardware P-States (HWP)
//
//   Intel HWP Features:
//   - Hardware autonomous P-state control (no OS governor)
//   - Response time <1ms (sub-cycle in hardware)
//   - EPP (Energy Performance Preference): 0x00-0xFF
//     0x00 = Max Performance
//     0x80 = Balance Performance
//     0xFF = Max Power Savings
//   - Monitors: utilization, temperature, workload pattern
//   - Autonomous frequency adjustment without software intervention
//
//   AURORA Adaptation:
//   - Per-domain P-state control (G-Core, A-Core, H-Core, NPU)
//   - 16 P-state levels per domain (P0=max, P15=min)
//   - Hardware utilization monitor built-in
//   - EPP register configurable per workload type
//   - Response time: <10 cycles (vs OS governor 10-50ms)
//   - Scheduler-integrated for workload-aware selection
//
//   P-State Table (per domain):
//   P0:  Max frequency (turbo capable)
//   P1:  95% max
//   P2:  90% max
//   P3:  85% max
//   P4:  80% max
//   P5:  75% max
//   P6:  70% max
//   P7:  65% max
//   P8:  60% max
//   P9:  55% max
//   P10: 50% max
//   P11: 45% max
//   P12: 40% max
//   P13: 35% max
//   P14: 30% max
//   P15: Minimum frequency
//
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

module speed_shift_hwp #(
    parameter DATA_WIDTH            = `AURORA_DATA_WIDTH,   // FIXED: Use standard parameter
    parameter NUM_DOMAINS           = 3,    // OPTIMIZED: 4->3 (G, A, H only)
    parameter NUM_P_STATES          = 8,    // OPTIMIZED: 16->8 (P0-P7)
    parameter RESPONSE_CYCLES       = 4,    // OPTIMIZED: 8->4 (faster response)

    // Base frequencies per domain (MHz) - realistic
    parameter G_MAX_FREQ_MHZ        = 4000,  // OPTIMIZED: 6500->4000
    parameter A_MAX_FREQ_MHZ        = 3000,  // OPTIMIZED: 4500->3000
    parameter H_MAX_FREQ_MHZ        = 2000,  // OPTIMIZED: 3000->2000
    parameter N_MAX_FREQ_MHZ        = 2500   // NPU frequency
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Hardware utilization inputs (from core activity monitors)
    // ---
    input  wire [7:0]                   g_utilization_pct,    // 0-100%
    input  wire [7:0]                   a_utilization_pct,
    input  wire [7:0]                   h_utilization_pct,
    input  wire [7:0]                   npu_utilization_pct,

    input  wire [7:0]                   current_temp_c,       // Temperature sensor
    input  wire [DATA_WIDTH-1:0]        current_power_mw,     // Total power draw

    // --- EPP (Energy Performance Preference) - Software hint
    // 0x00 = Max Performance, 0xFF = Max Power Savings
    // ---
    input  wire [7:0]                   epp_g_core,           // G-Core EPP
    input  wire [7:0]                   epp_a_core,           // A-Core EPP
    input  wire [7:0]                   epp_h_core,           // H-Core EPP
    input  wire [7:0]                   epp_npu,              // NPU EPP

    // --- Workload type hints (from scheduler)
    // ---
    input  wire                         gaming_workload,
    input  wire                         ai_workload,
    input  wire                         mixed_workload,
    input  wire                         idle_workload,

    // --- HWP control
    // ---
    input  wire                         hwp_enable,           // Enable HWP
    input  wire                         hwp_override,         // Force software override
    input  wire [3:0]                   sw_p_state_req,       // Software P-state request
    input  wire                         sw_p_state_valid,     // Software request valid

    // --- P-state outputs (per domain)
    // ---
    output reg  [3:0]                   g_p_state,            // Current P-state (0-15)
    output reg  [3:0]                   a_p_state,
    output reg  [3:0]                   h_p_state,
    output reg  [3:0]                   npu_p_state,

    // Frequency output (MHz) - derived from P-state
    output reg  [DATA_WIDTH-1:0]        g_freq_mhz,
    output reg  [DATA_WIDTH-1:0]        a_freq_mhz,
    output reg  [DATA_WIDTH-1:0]        h_freq_mhz,
    output reg  [DATA_WIDTH-1:0]        npu_freq_mhz,

    // --- Status signals
    // ---
    output reg                          hwp_active,           // HWP is controlling
    output reg                          sw_override_active,   // Software override active
    output reg [3:0]                    last_p_state_change_domain,  // Which domain changed
    output reg                          p_state_changed,      // Pulse on P-state change

    // --- Debug / performance counters
    // ---
    output reg [31:0]                   hwp_transition_count,  // Total P-state transitions
    output reg [31:0]                   sw_override_count,     // Software override events
    output reg [31:0]                   thermal_limited_count, // Thermal-limited transitions
    output reg [31:0]                   perf_limited_count,    // Performance-limited transitions
    output reg [7:0]                    hwp_avg_p_state_g,     // Average P-state (G)
    output reg [7:0]                    hwp_avg_p_state_a,     // Average P-state (A)
    output reg [31:0]                   hwp_response_cycles    // Actual response time tracking
);

    // --- P-State Frequency Table
    // Maps P-state (0-15) to frequency percentage of max
    // ---
    function [7:0] p_state_to_pct;
        input [3:0] p_state;
        begin
            case (p_state)
                4'd0:  p_state_to_pct = 8'd100;   // P0: 100%
                4'd1:  p_state_to_pct = 8'd95;    // P1: 95%
                4'd2:  p_state_to_pct = 8'd90;    // P2: 90%
                4'd3:  p_state_to_pct = 8'd85;    // P3: 85%
                4'd4:  p_state_to_pct = 8'd80;    // P4: 80%
                4'd5:  p_state_to_pct = 8'd75;    // P5: 75%
                4'd6:  p_state_to_pct = 8'd70;    // P6: 70%
                4'd7:  p_state_to_pct = 8'd65;    // P7: 65%
                4'd8:  p_state_to_pct = 8'd60;    // P8: 60%
                4'd9:  p_state_to_pct = 8'd55;    // P9: 55%
                4'd10: p_state_to_pct = 8'd50;    // P10: 50%
                4'd11: p_state_to_pct = 8'd45;    // P11: 45%
                4'd12: p_state_to_pct = 8'd40;    // P12: 40%
                4'd13: p_state_to_pct = 8'd35;    // P13: 35%
                4'd14: p_state_to_pct = 8'd30;    // P14: 30%
                4'd15: p_state_to_pct = 8'd25;    // P15: 25%
                default: p_state_to_pct = 8'd100;
            endcase
        end
    endfunction

    // --- EPP to P-state bias conversion
    // Low EPP (performance) -> bias toward P0
    // High EPP (efficiency) -> bias toward P15
    // ---
    function [3:0] epp_to_bias;
        input [7:0] epp;
        begin
            // Map 0-255 to 0-15
            epp_to_bias = epp[7:4];  // Top 4 bits = bias
        end
    endfunction

    // --- Utilization to target P-state calculation
    // High utilization -> low P-state (high frequency)
    // Low utilization -> high P-state (low frequency)
    // ---
    function [3:0] util_to_p_state;
        input [7:0] util_pct;
        input [3:0] epp_bias;
        begin
            // Base P-state from utilization
            if (util_pct >= 80) begin
                util_to_p_state = 4'd0;       // 80-100% -> P0-P1
            end else if (util_pct >= 70) begin
                util_to_p_state = 4'd2;       // 70-79% -> P2-P3
            end else if (util_pct >= 60) begin
                util_to_p_state = 4'd4;       // 60-69% -> P4-P5
            end else if (util_pct >= 50) begin
                util_to_p_state = 4'd6;       // 50-59% -> P6-P7
            end else if (util_pct >= 40) begin
                util_to_p_state = 4'd8;       // 40-49% -> P8-P9
            end else if (util_pct >= 30) begin
                util_to_p_state = 4'd10;      // 30-39% -> P10-P11
            end else if (util_pct >= 20) begin
                util_to_p_state = 4'd12;      // 20-29% -> P12-P13
            end else begin
                util_to_p_state = 4'd14;      // 0-19% -> P14-P15
            end

            // Apply EPP bias
            // Performance bias (low EPP): reduce P-state number (higher freq)
            // Efficiency bias (high EPP): increase P-state number (lower freq)
            if (epp_bias < 4'd4) begin
                // Performance bias: up to 2 steps toward P0
                if (util_to_p_state > 2) begin
                    util_to_p_state = util_to_p_state - 2;
                end else begin
                    util_to_p_state = 4'd0;
                end
            end else if (epp_bias > 4'd11) begin
                // Efficiency bias: up to 2 steps toward P15
                if (util_to_p_state < 13) begin
                    util_to_p_state = util_to_p_state + 2;
                end else begin
                    util_to_p_state = 4'd15;
                end
            end
        end
    endfunction

    // --- Thermal limit P-state calculation
    // If temperature is high, force higher P-state (lower freq)
    // ---
    function [3:0] thermal_limit_p_state;
        input [7:0] temp_c;
        begin
            if (temp_c >= 95) begin
                thermal_limit_p_state = 4'd12;  // Force P12 (40%) at 95C
            end else if (temp_c >= 90) begin
                thermal_limit_p_state = 4'd10;  // Force P10 (50%) at 90C
            end else if (temp_c >= 85) begin
                thermal_limit_p_state = 4'd8;   // Force P8 (60%) at 85C
            end else if (temp_c >= 80) begin
                thermal_limit_p_state = 4'd4;   // Force P4 (80%) at 80C
            end else begin
                thermal_limit_p_state = 4'd0;   // No thermal limit
            end
        end
    endfunction

    // --- Frequency calculation from P-state
    // ---
    // FIX v2: Use $unsigned for intermediate calculation to prevent truncation issues
    function [DATA_WIDTH-1:0] calc_freq;
        input [DATA_WIDTH-1:0] max_freq;
        input [3:0] p_state;
        reg [7:0] pct;
        begin
            pct = p_state_to_pct(p_state);
            calc_freq = (max_freq * $unsigned(pct)) / 100;
        end
    endfunction

    // --- State machine
    // ---
    typedef enum logic [1:0] {
        HWP_IDLE,
        HWP_MEASURE,
        HWP_CALCULATE,
        HWP_APPLY
    } hwp_state_t;

    hwp_state_t     hwp_state;
    reg [3:0]       hwp_counter;

    // Response time tracking
    reg [7:0]       response_timer;

    // FIX v2: Transition event tracking (module-level declarations)
    reg             sw_any_domain_changed;
    reg             hw_any_domain_changed;

    // FIX BUG-4: Module-level declarations for P-state calculation intermediates
    // (previously illegally declared inside the always block)
    reg [3:0] g_target_p, a_target_p, h_target_p, n_target_p;
    reg [3:0] g_thermal, a_thermal, h_thermal, n_thermal;
    reg [3:0] g_bias, a_bias, h_bias, n_bias;

    // --- Main State Machine
    // ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hwp_state <= HWP_IDLE;
            hwp_counter <= 4'd0;
            response_timer <= 8'd0;
        end else begin
            case (hwp_state)
                HWP_IDLE: begin
                    hwp_counter <= 4'd0;
                    // FIX v2: Reset response_timer to 0 when re-entering HWP_IDLE
                    response_timer <= 8'd0;
                    if (hwp_enable) begin
                        hwp_state <= HWP_MEASURE;
                    end
                end

                HWP_MEASURE: begin
                    // Sample utilization (1 cycle)
                    hwp_counter <= hwp_counter + 4'd1;
                    response_timer <= response_timer + 8'd1;
                    hwp_state <= HWP_CALCULATE;
                end

                HWP_CALCULATE: begin
                    // Calculate new P-states (1 cycle)
                    hwp_counter <= hwp_counter + 4'd1;
                    response_timer <= response_timer + 8'd1;
                    hwp_state <= HWP_APPLY;
                end

                HWP_APPLY: begin
                    // Apply P-states (1 cycle)
                    hwp_counter <= hwp_counter + 4'd1;
                    response_timer <= response_timer + 8'd1;
                    hwp_state <= HWP_IDLE;
                end

                default: hwp_state <= HWP_IDLE;
            endcase
        end
    end

    // --- P-State Selection & Application
    // ---
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset to default P-states
            g_p_state <= 4'd0;
            a_p_state <= 4'd0;
            h_p_state <= 4'd0;
            npu_p_state <= 4'd0;

            g_freq_mhz   <= G_MAX_FREQ_MHZ;
            a_freq_mhz   <= A_MAX_FREQ_MHZ;
            h_freq_mhz   <= H_MAX_FREQ_MHZ;
            npu_freq_mhz <= N_MAX_FREQ_MHZ;

            hwp_active <= 1'b0;
            sw_override_active <= 1'b0;
            // FIX v2: Default p_state_changed to 0 at start of always block (1-cycle pulse)
            p_state_changed <= 1'b0;
            last_p_state_change_domain <= 4'd0;

            hwp_transition_count <= 32'd0;
            sw_override_count <= 32'd0;
            thermal_limited_count <= 32'd0;
            perf_limited_count <= 32'd0;
            hwp_avg_p_state_g <= 8'd0;
            hwp_avg_p_state_a <= 8'd0;
            hwp_response_cycles <= 32'd0;
        end else begin
            // FIX v2: Default p_state_changed to 0 at start of always block (1-cycle pulse only)
            p_state_changed <= 1'b0;

            // --- Software Override (highest priority)
            // ---
            if (hwp_override && sw_p_state_valid) begin
                sw_override_active <= 1'b1;
                hwp_active <= 1'b0;
                sw_override_count <= sw_override_count + 32'd1;

                // Apply software request to all domains
                // FIX v2: Count transition EVENTS, not per-domain changes
                // One SW request = 1 event, even if multiple domains change
                sw_any_domain_changed = 1'b0;

                if (g_p_state != sw_p_state_req) begin
                    g_p_state <= sw_p_state_req;
                    g_freq_mhz <= calc_freq(G_MAX_FREQ_MHZ, sw_p_state_req);
                    p_state_changed <= 1'b1;
                    last_p_state_change_domain <= 4'd0;
                    sw_any_domain_changed = 1'b1;
                end
                if (a_p_state != sw_p_state_req) begin
                    a_p_state <= sw_p_state_req;
                    a_freq_mhz <= calc_freq(A_MAX_FREQ_MHZ, sw_p_state_req);
                    p_state_changed <= 1'b1;
                    last_p_state_change_domain <= 4'd1;
                    sw_any_domain_changed = 1'b1;
                end
                if (h_p_state != sw_p_state_req) begin
                    h_p_state <= sw_p_state_req;
                    h_freq_mhz <= calc_freq(H_MAX_FREQ_MHZ, sw_p_state_req);
                    p_state_changed <= 1'b1;
                    last_p_state_change_domain <= 4'd2;
                    sw_any_domain_changed = 1'b1;
                end
                if (npu_p_state != sw_p_state_req) begin
                    npu_p_state <= sw_p_state_req;
                    npu_freq_mhz <= calc_freq(N_MAX_FREQ_MHZ, sw_p_state_req);
                    p_state_changed <= 1'b1;
                    last_p_state_change_domain <= 4'd3;
                    sw_any_domain_changed = 1'b1;
                end

                // FIX v2: Count 1 per transition event, not per domain
                if (sw_any_domain_changed) begin
                    hwp_transition_count <= hwp_transition_count + 32'd1;
                end
            end else if (hwp_enable) begin
                // --- Hardware Autonomous P-State Control
                // ---
                sw_override_active <= 1'b0;
                hwp_active <= 1'b1;

                if (hwp_state == HWP_APPLY) begin
                    // EPP biases
                    g_bias = epp_to_bias(epp_g_core);
                    a_bias = epp_to_bias(epp_a_core);
                    h_bias = epp_to_bias(epp_h_core);
                    n_bias = epp_to_bias(epp_npu);

                    // Target P-states from utilization
                    g_target_p = util_to_p_state(g_utilization_pct, g_bias);
                    a_target_p = util_to_p_state(a_utilization_pct, a_bias);
                    h_target_p = util_to_p_state(h_utilization_pct, h_bias);
                    n_target_p = util_to_p_state(npu_utilization_pct, n_bias);

                    // Thermal limits
                    g_thermal = thermal_limit_p_state(current_temp_c);
                    a_thermal = thermal_limit_p_state(current_temp_c);
                    h_thermal = thermal_limit_p_state(current_temp_c);
                    n_thermal = thermal_limit_p_state(current_temp_c);

                    // Apply thermal limit (use higher P-state = lower freq if thermal limited)
                    if (g_target_p < g_thermal) begin
                        g_target_p = g_thermal;
                        thermal_limited_count <= thermal_limited_count + 32'd1;
                    end
                    if (a_target_p < a_thermal) begin
                        a_target_p = a_thermal;
                        thermal_limited_count <= thermal_limited_count + 32'd1;
                    end
                    if (h_target_p < h_thermal) begin
                        h_target_p = h_thermal;
                        thermal_limited_count <= thermal_limited_count + 32'd1;
                    end
                    if (n_target_p < n_thermal) begin
                        n_target_p = n_thermal;
                        thermal_limited_count <= thermal_limited_count + 32'd1;
                    end

                    // Workload-aware adjustments
                    if (gaming_workload) begin
                        // Gaming: boost G-Core, reduce others
                        if (g_target_p > 0) g_target_p = g_target_p - 1;
                        if (a_target_p < 14) a_target_p = a_target_p + 2;
                    end else if (ai_workload) begin
                        // AI: boost A-Core, reduce G-Core
                        if (a_target_p > 0) a_target_p = a_target_p - 1;
                        if (g_target_p < 14) g_target_p = g_target_p + 2;
                    end else if (idle_workload) begin
                        // Idle: all to max P-state (min freq)
                        g_target_p = 4'd15;
                        a_target_p = 4'd15;
                        h_target_p = 4'd15;
                        n_target_p = 4'd15;
                    end

                    // Apply G-Core P-state
                    // FIX v2: Count transition EVENTS, not per-domain changes
                    hw_any_domain_changed = 1'b0;

                    if (g_p_state != g_target_p) begin
                        g_p_state <= g_target_p;
                        g_freq_mhz <= calc_freq(G_MAX_FREQ_MHZ, g_target_p);
                        p_state_changed <= 1'b1;
                        last_p_state_change_domain <= 4'd0;
                        hw_any_domain_changed = 1'b1;
                    end

                    // Apply A-Core P-state
                    if (a_p_state != a_target_p) begin
                        a_p_state <= a_target_p;
                        a_freq_mhz <= calc_freq(A_MAX_FREQ_MHZ, a_target_p);
                        p_state_changed <= 1'b1;
                        last_p_state_change_domain <= 4'd1;
                        hw_any_domain_changed = 1'b1;
                    end

                    // Apply H-Core P-state
                    if (h_p_state != h_target_p) begin
                        h_p_state <= h_target_p;
                        h_freq_mhz <= calc_freq(H_MAX_FREQ_MHZ, h_target_p);
                        p_state_changed <= 1'b1;
                        last_p_state_change_domain <= 4'd2;
                        hw_any_domain_changed = 1'b1;
                    end

                    // Apply NPU P-state
                    if (npu_p_state != n_target_p) begin
                        npu_p_state <= n_target_p;
                        npu_freq_mhz <= calc_freq(N_MAX_FREQ_MHZ, n_target_p);
                        p_state_changed <= 1'b1;
                        last_p_state_change_domain <= 4'd3;
                        hw_any_domain_changed = 1'b1;
                    end

                    // FIX v2: Count 1 per transition event, not per domain
                    if (hw_any_domain_changed) begin
                        hwp_transition_count <= hwp_transition_count + 32'd1;
                    end

                    // Track response time
                    if (response_timer > 0) begin
                        hwp_response_cycles <= 32'(response_timer);
                    end
                end
            end else begin
                // HWP disabled - hold current state
                hwp_active <= 1'b0;
            end
        end
    end

endmodule
