//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: Intel Turbo Boost + AMD Precision Boost)
//
// Create Date: 11 April 2026
// Design Name: Hybrid Turbo Boost
// Module Name: turbo_boost
//
// Description:
//   Hybrid turbo boost combining Intel + AMD approaches:
//   - Intel style: Time-limited turbo (tau = 28 seconds)
//   - AMD style: Thermal-based sustained boost (unlimited)
//
//   AURORA adaptation:
//   - Gaming: Intel time-limited (burst turbo)
//   - AI: AMD thermal-based (sustained, unlimited)
//   - Mixed: Adaptive per workload
//
// Specification:
//   Base Clock: 6.0 GHz (G-Core), 4.0 GHz (A-Core)
//   Turbo Max: 6.5 GHz (+8% G-Core), 4.5 GHz (+12% A-Core)
//   Tau (Gaming): 28000 cycles (28ms)
//   Tau (AI): Unlimited (thermal limited only)
//   TDP Headroom: +20% PL2 for gaming, +15% for AI
//
// State Machine:
//   IDLE → CHECK → GAMING_TURBO / AI_TURBO / COOLDOWN
//
//////////////////////////////////////////////////////////////////////////////////

`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

module turbo_boost #(
    parameter DATA_WIDTH            = `AURORA_DATA_WIDTH,   // Standard data width
    parameter CLK_FREQ_MHZ          = 4000,  // 4GHz base clock frequency

    // G-Core turbo parameters
    parameter G_BASE_CLOCK_MHZ      = 4000,
    parameter G_TURBO_CLOCK_MHZ     = 4400,  // +10% boost over base
    parameter G_TAU_CYCLES          = 14000, // Fast response time

    // A-Core turbo parameters
    parameter A_BASE_CLOCK_MHZ      = 3000,
    parameter A_TURBO_CLOCK_MHZ     = 3300,  // +10% boost over base
    parameter A_TAU_UNLIMITED       = 1'b0,  // Limited turbo for thermal safety

    // H-Core turbo parameters
    parameter H_BASE_CLOCK_MHZ      = 2000,
    parameter H_TURBO_CLOCK_MHZ     = 2400,  // +20% boost for H-Core (gaming workloads)
    parameter H_TAU_CYCLES          = 14000,

    // NPU turbo parameters
    parameter N_BASE_CLOCK_MHZ      = 2500,
    parameter N_TURBO_CLOCK_MHZ     = 3000,  // +20% boost for NPU (AI workloads)
    parameter N_TAU_CYCLES          = 14000,

    // Thermal parameters
    parameter TEMP_MAX_C            = 80,    // Maximum safe operating temperature
    parameter TEMP_THROTTLE_C       = 90,    // Thermal throttling threshold
    parameter TEMP_COOLDOWN_C       = 70,    // Cooldown temperature threshold

    // TDP parameters
    parameter TDP_BASE_MW           = 250000, // 250W
    parameter TDP_TURBO_MW          = 300000  // 300W (+20%)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Workload indicators
    input  wire                         gaming_mode,
    input  wire                         ai_mode,
    input  wire                         mixed_mode,
    input  wire                         gpu_bound,            // Gaming is GPU-bound

    // Thermal monitoring
    input  wire [7:0]                   current_temp_c,       // Current temperature
    input  wire [DATA_WIDTH-1:0]        current_power_mw,     // Current power draw

    // TDP limit
    input  wire [DATA_WIDTH-1:0]        tdp_limit_mw,

    // Turbo control
    input  wire                         turbo_enable,         // External turbo enable
    input  wire                         turbo_override,       // Force turbo on/off

    // Frequency output (MHz)
    output reg  [DATA_WIDTH-1:0]        g_core_freq_mhz,
    output reg  [DATA_WIDTH-1:0]        a_core_freq_mhz,
    output reg  [DATA_WIDTH-1:0]        h_core_freq_mhz,
    output reg  [DATA_WIDTH-1:0]        npu_freq_mhz,

    // Status signals
    output reg                          turbo_active,
    output reg                          turbo_gaming,
    output reg                          turbo_ai,
    output reg                          thermal_throttle,
    output reg                          tdp_limited,

    // Debug counters
    output reg [31:0]                   turbo_entry_count,
    output reg [31:0]                   turbo_timeout_count,
    output reg [31:0]                   thermal_throttle_count,
    output reg [31:0]                   cooldown_count
);

    // State machine
    typedef enum logic [2:0] {
        TB_IDLE,
        TB_CHECK_CONDITIONS,
        TB_GAMING_TURBO,
        TB_AI_TURBO,
        TB_MIXED_TURBO,
        TB_COOLDOWN,
        TB_THROTTLE
    } turbo_state_t;

    turbo_state_t       tb_state;
    // FIX v2: Removed separate tb_next_state to merge combinational + sequential
    // into a single sequential always block, preventing race conditions

    // Turbo timer (Intel-style time limit)
    reg [DATA_WIDTH-1:0]    turbo_timer;
    reg [DATA_WIDTH-1:0]    turbo_time_remaining;

    // Cooldown counter
    reg [31:0]              cooldown_counter;

    // ─────────────────────────────────────────────────────────────
    // FIX v2: MERGED always block - combines next-state logic and
    // state actions into ONE sequential always block to prevent
    // race conditions between combinational and sequential logic.
    // ─────────────────────────────────────────────────────────────
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tb_state <= TB_IDLE;

            // Reset to base frequencies
            g_core_freq_mhz <= G_BASE_CLOCK_MHZ;
            a_core_freq_mhz <= A_BASE_CLOCK_MHZ;
            h_core_freq_mhz <= G_BASE_CLOCK_MHZ / 2;  // 3 GHz
            npu_freq_mhz    <= A_BASE_CLOCK_MHZ / 4;  // 1 GHz

            turbo_active <= 1'b0;
            turbo_gaming <= 1'b0;
            turbo_ai <= 1'b0;
            thermal_throttle <= 1'b0;
            tdp_limited <= 1'b0;

            turbo_timer <= G_TAU_CYCLES;
            turbo_time_remaining <= G_TAU_CYCLES;
            cooldown_counter <= 32'd0;

            turbo_entry_count <= 32'd0;
            turbo_timeout_count <= 32'd0;
            thermal_throttle_count <= 32'd0;
            cooldown_count <= 32'd0;
        end else begin
            // Default: update thermal throttle based on current temp
            thermal_throttle <= (current_temp_c >= TEMP_THROTTLE_C);

            // ─────────────────────────────────────────────────
            // Next-state logic (was combinational, now sequential)
            // ─────────────────────────────────────────────────
            case (tb_state)
                TB_IDLE: begin
                    if (turbo_enable) begin
                        tb_state <= TB_CHECK_CONDITIONS;
                    end
                end

                TB_CHECK_CONDITIONS: begin
                    if (thermal_throttle) begin
                        tb_state <= TB_THROTTLE;
                    end else if (gaming_mode && gpu_bound) begin
                        tb_state <= TB_GAMING_TURBO;
                    end else if (ai_mode) begin
                        tb_state <= TB_AI_TURBO;
                    end else if (mixed_mode) begin
                        tb_state <= TB_MIXED_TURBO;
                    end else begin
                        tb_state <= TB_IDLE;
                    end
                end

                TB_GAMING_TURBO: begin
                    // FIX v2: Check == 1 (not == 0) before transitioning to COOLDOWN.
                    // At == 0 the timer has already expired; we must transition
                    // one cycle earlier so the state change and timer decrement
                    // happen in the same cycle correctly.
                    if (thermal_throttle) begin
                        tb_state <= TB_THROTTLE;
                    end else if (turbo_time_remaining == 1) begin
                        tb_state <= TB_COOLDOWN;
                    end else if (!gaming_mode) begin
                        tb_state <= TB_IDLE;
                    end
                end

                TB_AI_TURBO: begin
                    if (thermal_throttle) begin
                        tb_state <= TB_THROTTLE;
                    end else if (!ai_mode) begin
                        tb_state <= TB_IDLE;
                    end
                    // No timeout - sustained boost!
                end

                TB_MIXED_TURBO: begin
                    // FIX v2: Same fix - check == 1 (not == 0) for COOLDOWN transition
                    if (thermal_throttle) begin
                        tb_state <= TB_THROTTLE;
                    end else if (turbo_time_remaining == 1) begin
                        tb_state <= TB_COOLDOWN;
                    end else if (!mixed_mode) begin
                        tb_state <= TB_IDLE;
                    end
                end

                TB_COOLDOWN: begin
                    if (current_temp_c <= TEMP_COOLDOWN_C) begin
                        tb_state <= TB_IDLE;
                    end
                end

                TB_THROTTLE: begin
                    if (current_temp_c <= (TEMP_THROTTLE_C - 5)) begin
                        tb_state <= TB_CHECK_CONDITIONS;
                    end
                end

                default: tb_state <= TB_IDLE;
            endcase

            // ─────────────────────────────────────────────────
            // State actions (merged into same always block)
            // ─────────────────────────────────────────────────
            case (tb_state)
                TB_IDLE: begin
                    // Base frequencies
                    g_core_freq_mhz <= G_BASE_CLOCK_MHZ;
                    a_core_freq_mhz <= A_BASE_CLOCK_MHZ;
                    h_core_freq_mhz <= H_BASE_CLOCK_MHZ;
                    npu_freq_mhz    <= N_BASE_CLOCK_MHZ;

                    turbo_active <= 1'b0;
                    turbo_gaming <= 1'b0;
                    turbo_ai <= 1'b0;
                    tdp_limited <= 1'b0;

                    // Reset timer
                    turbo_time_remaining <= G_TAU_CYCLES;
                    cooldown_counter <= 32'd0;
                end

                TB_CHECK_CONDITIONS: begin
                    // Prepare for turbo
                    if (turbo_override) begin
                        // Override checks
                    end

                    // Check TDP headroom
                    if (current_power_mw >= TDP_TURBO_MW) begin
                        tdp_limited <= 1'b1;
                    end else begin
                        tdp_limited <= 1'b0;
                        turbo_entry_count <= turbo_entry_count + 32'd1;
                    end
                end

                TB_GAMING_TURBO: begin
                    // Intel-style time-limited turbo
                    turbo_active <= 1'b1;
                    turbo_gaming <= 1'b1;
                    turbo_ai <= 1'b0;

                    // Boost G-Core and H-Core frequency for gaming workloads
                    g_core_freq_mhz <= G_TURBO_CLOCK_MHZ;
                    a_core_freq_mhz <= A_BASE_CLOCK_MHZ;  // A-Core stays at base
                    h_core_freq_mhz <= H_TURBO_CLOCK_MHZ; // Boost H-Core for gaming
                    npu_freq_mhz    <= N_BASE_CLOCK_MHZ;

                    // Countdown timer
                    if (turbo_time_remaining > 0) begin
                        turbo_time_remaining <= turbo_time_remaining - 1;
                    end

                    // FIX v2: Timeout count incremented when timer reaches 1
                    // (the same cycle we transition to COOLDOWN)
                    if (turbo_time_remaining == 1) begin
                        turbo_timeout_count <= turbo_timeout_count + 32'd1;
                    end
                end

                TB_AI_TURBO: begin
                    // AMD-style unlimited turbo
                    turbo_active <= 1'b1;
                    turbo_gaming <= 1'b0;
                    turbo_ai <= 1'b1;

                    // Boost A-Core and NPU frequency (sustained AI workloads)
                    g_core_freq_mhz <= G_BASE_CLOCK_MHZ;
                    a_core_freq_mhz <= A_TURBO_CLOCK_MHZ;
                    h_core_freq_mhz <= H_BASE_CLOCK_MHZ;
                    npu_freq_mhz    <= N_TURBO_CLOCK_MHZ;  // Boost NPU for AI

                    // No timer countdown!
                    turbo_time_remaining <= G_TAU_CYCLES;  // Keep reset
                end

                TB_MIXED_TURBO: begin
                    // Moderate boost untuk semua
                    turbo_active <= 1'b1;
                    turbo_gaming <= 1'b0;
                    turbo_ai <= 1'b0;

                    // Moderate boost (halfway)
                    g_core_freq_mhz <= (G_BASE_CLOCK_MHZ + G_TURBO_CLOCK_MHZ) >> 1;
                    a_core_freq_mhz <= (A_BASE_CLOCK_MHZ + A_TURBO_CLOCK_MHZ) >> 1;
                    h_core_freq_mhz <= (H_BASE_CLOCK_MHZ + H_TURBO_CLOCK_MHZ) >> 1;
                    npu_freq_mhz    <= (N_BASE_CLOCK_MHZ + N_TURBO_CLOCK_MHZ) >> 1;

                    // Countdown timer
                    if (turbo_time_remaining > 0) begin
                        turbo_time_remaining <= turbo_time_remaining - 1;
                    end
                end

                TB_COOLDOWN: begin
                    // MEDIUM FIX NEW-3: Add safety timeout (10000 cycles) for sensor fault
                    // Reduce frequency to cool down
                    turbo_active <= 1'b0;
                    cooldown_count <= cooldown_count + 32'd1;

                    // Prevent unsigned underflow
                    g_core_freq_mhz <= (G_BASE_CLOCK_MHZ > 500) ? (G_BASE_CLOCK_MHZ - 500) : 100;
                    a_core_freq_mhz <= (A_BASE_CLOCK_MHZ > 500) ? (A_BASE_CLOCK_MHZ - 500) : 100;
                    h_core_freq_mhz <= (H_BASE_CLOCK_MHZ > 500) ? (H_BASE_CLOCK_MHZ - 500) : 100;
                    npu_freq_mhz    <= (N_BASE_CLOCK_MHZ > 500) ? (N_BASE_CLOCK_MHZ - 500) : 100;

                    cooldown_counter <= cooldown_counter + 32'd1;

                    // Normal exit: temperature dropped below threshold
                    if (current_temp_c <= TEMP_COOLDOWN_C) begin
                        cooldown_counter <= 32'd0;
                        tb_state <= TB_IDLE;
                    end else if (cooldown_counter >= 32'd10000) begin
                        // SAFETY TIMEOUT: Temperature sensor可能 fault, force exit
                        $display("[%0t] [TURBO-BOOST] TB_COOLDOWN TIMEOUT: temp still high after 10000 cycles, forcing exit", $time);
                        cooldown_counter <= 32'd0;
                        tb_state <= TB_IDLE;
                    end
                end

                TB_THROTTLE: begin
                    // Emergency thermal throttle
                    thermal_throttle <= 1'b1;
                    thermal_throttle_count <= thermal_throttle_count + 32'd1;

                    // Minimal frequencies
                    g_core_freq_mhz <= G_BASE_CLOCK_MHZ >> 1;
                    a_core_freq_mhz <= A_BASE_CLOCK_MHZ >> 1;
                    h_core_freq_mhz <= H_BASE_CLOCK_MHZ >> 1;
                    npu_freq_mhz    <= N_BASE_CLOCK_MHZ >> 1;
                end

                default: begin
                    g_core_freq_mhz <= G_BASE_CLOCK_MHZ;
                    a_core_freq_mhz <= A_BASE_CLOCK_MHZ;
                end
            endcase
        end
    end

endmodule
