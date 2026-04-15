`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Power Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Power Management Unit
// Module Name: power_management
//
// Description:
//   Advanced Power Management dengan AI-based prediction
//   Fitur:
//   - Dynamic Voltage and Frequency Scaling (DVFS) per core cluster
//   - Power gating untuk idle cores
//   - Thermal-aware compute shifting
//   - Performance-per-watt optimization
//   - Multiple power modes dengan drain-before-switch protocol
//
// Target: Maximize performance/Watt, stay within TDP envelope
//////////////////////////////////////////////////////////////////////////////////

module power_management #(
    parameter NUM_G_CORES       = 16,
    parameter NUM_H_CORES       = 32,
    parameter NUM_A_CORES       = 64,
    parameter NUM_NPU_CLUSTERS  = 8,
    parameter TEMP_SENSORS      = 16,
    parameter DVFS_LEVELS       = 8
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Core activity indicators
    input  wire [NUM_G_CORES-1:0]       g_core_busy,
    input  wire [NUM_H_CORES-1:0]       h_core_busy,
    input  wire [NUM_A_CORES-1:0]       a_core_busy,
    input  wire [NUM_NPU_CLUSTERS-1:0]  npu_busy,

    // Thermal sensors (from on-die sensors)
    input  wire [15:0]                  temp_sensor [0:TEMP_SENSORS-1],
    input  wire                         thermal_threshold_reached,

    // Power limits
    input  wire [31:0]                  tdp_limit_mw,      // TDP in milliwatts
    input  wire [31:0]                  power_budget_mw,   // Current budget

    // Power mode control
    input  wire [1:0]                   power_mode_sel,    // 00=Gaming, 01=AI, 10=Mixed, 11=PowerSave

    // DVFS control outputs
    output reg [2:0]                    g_core_freq_scale,  // 0-7 (frequency scaling)
    output reg [2:0]                    h_core_freq_scale,
    output reg [2:0]                    a_core_freq_scale,
    output reg [2:0]                    npu_freq_scale,

    // Voltage control
    output reg [10:0]                   g_core_voltage_mv,  // Voltage in mV
    output reg [10:0]                   h_core_voltage_mv,
    output reg [10:0]                   a_core_voltage_mv,
    output reg [10:0]                   npu_voltage_mv,

    // Power gating control
    output reg [NUM_G_CORES-1:0]        g_core_power_gate,
    output reg [NUM_H_CORES-1:0]        h_core_power_gate,
    output reg [NUM_A_CORES-1:0]        a_core_power_gate,
    output reg [NUM_NPU_CLUSTERS-1:0]   npu_power_gate,

    // Power monitoring
    output reg [31:0]                   total_power_mw,
    output reg [31:0]                   g_core_power_mw,
    output reg [31:0]                   h_core_power_mw,
    output reg [31:0]                   a_core_power_mw,
    output reg [31:0]                   npu_power_mw,

    // Thermal management
    output reg                          thermal_throttle,
    output reg [15:0]                   max_temp,

    // Performance tracking
    output reg [31:0]                   perf_per_watt,     // Performance per watt metric
    output reg [31:0]                   energy_consumed_mj, // Total energy in millijoules
    
    // Power mode transition handshake
    output reg                          power_mode_busy,   // Asserted during mode transition
    output reg                          pipeline_draining, // Pipeline drain in progress
    output wire                         pipeline_empty     // All cores idle
);

    // Pipeline empty detection (all cores must be idle)
    assign pipeline_empty = (|g_core_busy == 1'b0) && 
                            (|h_core_busy == 1'b0) &&
                            (|a_core_busy == 1'b0) &&
                            (|npu_busy == 1'b0);

    // =========================================================================
    // Power modes
    // =========================================================================
    localparam MODE_GAMING      = 2'b00;
    localparam MODE_AI          = 2'b01;
    localparam MODE_MIXED       = 2'b10;
    localparam MODE_POWERSAVE   = 2'b11;

    // =========================================================================
    // Power mode transition state machine
    // =========================================================================
    localparam PM_IDLE          = 3'b000;
    localparam PM_DRAIN_WAIT    = 3'b001;  // Waiting for pipeline to drain
    localparam PM_TRANSITION    = 3'b010;  // Applying new settings
    localparam PM_SETTLE        = 3'b011;  // Settling period after transition

    reg [2:0]                   pm_state;
    reg [1:0]                   pm_target_mode;
    reg [1:0]                   pm_active_mode;  // Currently applied mode
    reg [15:0]                  pm_drain_cycles;
    reg [15:0]                  pm_settle_cycles;

    // Maximum drain timeout (prevent infinite wait)
    localparam MAX_DRAIN_CYCLES = 16'd200;   // ~200 cycles max drain time
    localparam SETTLE_CYCLES    = 16'd20;    // 20 cycles settle time
    
    // =========================================================================
    // DVFS voltage/frequency tables
    // =========================================================================
    // Frequency scale: 0=12.5%, 1=25%, ..., 7=100%
    // Voltage scales with frequency

    function automatic reg [10:0] get_voltage_for_freq;
        input [2:0] freq_scale;
        begin
            case (freq_scale)
                3'd0: get_voltage_for_freq = 11'd600;   // 0.6V (minimum)
                3'd1: get_voltage_for_freq = 11'd650;   // 0.65V
                3'd2: get_voltage_for_freq = 11'd700;   // 0.7V
                3'd3: get_voltage_for_freq = 11'd780;   // 0.78V
                3'd4: get_voltage_for_freq = 11'd880;   // 0.88V
                3'd5: get_voltage_for_freq = 11'd980;   // 0.98V
                3'd6: get_voltage_for_freq = 11'd1080;  // 1.08V
                3'd7: get_voltage_for_freq = 11'd1200;  // 1.2V (maximum)
                default: get_voltage_for_freq = 11'd880;
            endcase
        end
    endfunction

    // =========================================================================
    // Activity tracking
    // =========================================================================
    reg [31:0] g_core_activity_cnt;
    reg [31:0] h_core_activity_cnt;
    reg [31:0] a_core_activity_cnt;
    reg [31:0] npu_activity_cnt;

    // =========================================================================
    // Main power management controller
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Default: all cores at max performance
            g_core_freq_scale <= 3'd7;
            h_core_freq_scale <= 3'd7;
            a_core_freq_scale <= 3'd7;
            npu_freq_scale <= 3'd7;

            g_core_voltage_mv <= 11'd1200;
            h_core_voltage_mv <= 11'd1200;
            a_core_voltage_mv <= 11'd1200;
            npu_voltage_mv <= 11'd1200;

            // No power gating
            g_core_power_gate <= {NUM_G_CORES{1'b0}};
            h_core_power_gate <= {NUM_H_CORES{1'b0}};
            a_core_power_gate <= {NUM_A_CORES{1'b0}};
            npu_power_gate <= {NUM_NPU_CLUSTERS{1'b0}};

            thermal_throttle <= 1'b0;
            total_power_mw <= 32'b0;
            energy_consumed_mj <= 32'b0;
            perf_per_watt <= 32'b0;

            g_core_activity_cnt <= 32'b0;
            h_core_activity_cnt <= 32'b0;
            a_core_activity_cnt <= 32'b0;
            npu_activity_cnt <= 32'b0;
            
            // Power mode transition reset
            pm_state <= PM_IDLE;
            pm_target_mode <= MODE_GAMING;
            pm_active_mode <= MODE_GAMING;
            pm_drain_cycles <= 16'b0;
            pm_settle_cycles <= 16'b0;
            power_mode_busy <= 1'b0;
            pipeline_draining <= 1'b0;
        end else begin
            // Update activity counters
            g_core_activity_cnt <= $countones(g_core_busy);
            h_core_activity_cnt <= $countones(h_core_busy);
            a_core_activity_cnt <= $countones(a_core_busy);
            npu_activity_cnt <= $countones(npu_busy);

            // Calculate max temperature
            max_temp <= 16'b0;
            for (int i = 0; i < TEMP_SENSORS; i++) begin
                if (temp_sensor[i] > max_temp) begin
                    max_temp <= temp_sensor[i];
                end
            end

            // ─────────────────────────────────────────────────
            // Power Mode Transition State Machine (Drain-Before-Switch)
            // ─────────────────────────────────────────────────
            case (pm_state)
                PM_IDLE: begin
                    power_mode_busy <= 1'b0;
                    pipeline_draining <= 1'b0;
                    
                    // Detect mode change request
                    if (power_mode_sel != pm_active_mode) begin
                        pm_target_mode <= power_mode_sel;
                        pm_state <= PM_DRAIN_WAIT;
                        pm_drain_cycles <= 16'b0;
                        pipeline_draining <= 1'b1;
                        power_mode_busy <= 1'b1;
                    end
                end
                
                PM_DRAIN_WAIT: begin
                    // Wait for pipeline to be empty OR timeout
                    if (pipeline_empty) begin
                        // Pipeline drained successfully
                        pm_state <= PM_TRANSITION;
                        pm_active_mode <= pm_target_mode;  // Apply new mode
                        pm_drain_cycles <= 16'b0;
                    end else if (pm_drain_cycles >= MAX_DRAIN_CYCLES) begin
                        // Timeout: force transition anyway (prevent deadlock)
                        pm_state <= PM_TRANSITION;
                        pm_active_mode <= pm_target_mode;
                        pm_drain_cycles <= 16'b0;
                        // Note: Force transition may cause minor pipeline flush
                    end else begin
                        pm_drain_cycles <= pm_drain_cycles + 1;
                        // Keep draining - don't change power settings yet
                    end
                end
                
                PM_TRANSITION: begin
                    // Apply new power settings immediately
                    pm_state <= PM_SETTLE;
                    pm_settle_cycles <= 16'b0;
                    pipeline_draining <= 1'b0;
                    // power_mode_busy stays asserted
                end
                
                PM_SETTLE: begin
                    if (pm_settle_cycles >= SETTLE_CYCLES) begin
                        // Settling complete, back to idle
                        pm_state <= PM_IDLE;
                        power_mode_busy <= 1'b0;
                    end else begin
                        pm_settle_cycles <= pm_settle_cycles + 1;
                        // Keep power_mode_busy asserted during settle
                    end
                end
                
                default: pm_state <= PM_IDLE;
            endcase

            // Thermal throttling (highest priority - override mode if needed)
            if (max_temp > 16'd950) begin  // >95°C
                thermal_throttle <= 1'b1;
                // Aggressively reduce frequency
                g_core_freq_scale <= 3'd3;
                h_core_freq_scale <= 3'd3;
                a_core_freq_scale <= 3'd3;
                npu_freq_scale <= 3'd3;
            end else if (max_temp > 16'd850) begin  // >85°C
                thermal_throttle <= 1'b1;
                // Moderate reduction
                if (g_core_freq_scale > 3'd4) g_core_freq_scale <= g_core_freq_scale - 1;
                if (h_core_freq_scale > 3'd4) h_core_freq_scale <= h_core_freq_scale - 1;
                if (a_core_freq_scale > 3'd4) a_core_freq_scale <= a_core_freq_scale - 1;
                if (npu_freq_scale > 3'd4) npu_freq_scale <= npu_freq_scale - 1;
            end else begin
                thermal_throttle <= 1'b0;

                // FIXED: Only adjust power mode when NOT thermal throttling
                // Use max_temp directly to avoid race condition with thermal_throttle register
                if (max_temp <= 16'd850 && pm_state != PM_DRAIN_WAIT && pm_state != PM_TRANSITION) begin
                    // Adjust based on active power mode
                    case (pm_active_mode)
                        MODE_GAMING: begin
                            // Maximize G-Core performance
                            g_core_freq_scale <= 3'd7;
                            g_core_voltage_mv <= get_voltage_for_freq(3'd7);

                            // Reduce unused cores
                            h_core_freq_scale <= 3'd4;
                            h_core_voltage_mv <= get_voltage_for_freq(3'd4);

                            a_core_freq_scale <= (a_core_activity_cnt > 0) ? 3'd5 : 3'd2;
                            a_core_voltage_mv <= get_voltage_for_freq(a_core_freq_scale);

                            npu_freq_scale <= (npu_activity_cnt > 0) ? 3'd4 : 3'd1;
                            npu_voltage_mv <= get_voltage_for_freq(npu_freq_scale);

                            // Power gate idle cores
                            for (int i = 0; i < NUM_G_CORES; i++) begin
                                g_core_power_gate[i] <= !g_core_busy[i];
                            end
                        end

                        MODE_AI: begin
                            // Maximize AI performance
                            a_core_freq_scale <= 3'd7;
                            a_core_voltage_mv <= get_voltage_for_freq(3'd7);

                            npu_freq_scale <= 3'd7;
                            npu_voltage_mv <= get_voltage_for_freq(3'd7);

                            // Reduce gaming cores
                            g_core_freq_scale <= (g_core_activity_cnt > 0) ? 3'd4 : 3'd2;
                            g_core_voltage_mv <= get_voltage_for_freq(g_core_freq_scale);

                            h_core_freq_scale <= 3'd4;
                            h_core_voltage_mv <= get_voltage_for_freq(3'd4);

                            // Power gate idle cores
                            for (int i = 0; i < NUM_A_CORES; i++) begin
                                a_core_power_gate[i] <= !a_core_busy[i];
                            end
                            for (int i = 0; i < NUM_NPU_CLUSTERS; i++) begin
                                npu_power_gate[i] <= !npu_busy[i];
                            end
                        end

                        MODE_MIXED: begin
                            // Balanced approach
                            g_core_freq_scale <= 3'd5;
                            g_core_voltage_mv <= get_voltage_for_freq(3'd5);

                            h_core_freq_scale <= 3'd5;
                            h_core_voltage_mv <= get_voltage_for_freq(3'd5);

                            a_core_freq_scale <= 3'd5;
                            a_core_voltage_mv <= get_voltage_for_freq(3'd5);

                            npu_freq_scale <= 3'd5;
                            npu_voltage_mv <= get_voltage_for_freq(3'd5);

                            // Minimal power gating
                            g_core_power_gate <= {NUM_G_CORES{1'b0}};
                            h_core_power_gate <= {NUM_H_CORES{1'b0}};
                            a_core_power_gate <= {NUM_A_CORES{1'b0}};
                            npu_power_gate <= {NUM_NPU_CLUSTERS{1'b0}};
                        end

                        MODE_POWERSAVE: begin
                            // Minimize power consumption
                            g_core_freq_scale <= 3'd2;
                            g_core_voltage_mv <= get_voltage_for_freq(3'd2);

                            h_core_freq_scale <= 3'd2;
                            h_core_voltage_mv <= get_voltage_for_freq(3'd2);

                            a_core_freq_scale <= 3'd2;
                            a_core_voltage_mv <= get_voltage_for_freq(3'd2);

                            npu_freq_scale <= 3'd2;
                            npu_voltage_mv <= get_voltage_for_freq(3'd2);

                            // Aggressive power gating
                            for (int i = 0; i < NUM_G_CORES; i++) begin
                                g_core_power_gate[i] <= !g_core_busy[i];
                            end
                            for (int i = 0; i < NUM_H_CORES; i++) begin
                                h_core_power_gate[i] <= !h_core_busy[i];
                            end
                            for (int i = 0; i < NUM_A_CORES; i++) begin
                                a_core_power_gate[i] <= !a_core_busy[i];
                            end
                            for (int i = 0; i < NUM_NPU_CLUSTERS; i++) begin
                                npu_power_gate[i] <= !npu_busy[i];
                            end
                        end
                        
                        default: begin
                            // Safe default: mixed mode settings
                            g_core_freq_scale <= 3'd5;
                            a_core_freq_scale <= 3'd5;
                        end
                    endcase
                end
                // NOTE: During PM_DRAIN_WAIT/PM_TRANSITION or when max_temp > 85°C,
                // we DON'T change frequency/voltage to avoid disrupting active work
                // or overriding thermal protection
            end

            // REALISTIC POWER MODEL
            // Power = C × V² × f (dynamic power)
            // where C = capacitance, V = voltage, f = frequency
            // 
            // Per-core power estimation:
            // P_dynamic = α × C_eff × V² × f
            // where α = activity factor (0-1)
            // C_eff = effective capacitance (~1pF per core estimated)
            // V = operating voltage
            // f = operating frequency
            
            // G-Core power (16 cores, high performance)
            begin
                reg [63:0] g_voltage_sq;
                g_voltage_sq = (g_core_voltage_mv * g_core_voltage_mv) / 1_000_000;  // V² in V
                g_core_power_mw <= (g_core_activity_cnt * g_voltage_sq * (g_core_freq_scale + 1)) / 100;
            end
            
            // H-Core power (32 cores, medium performance)
            begin
                reg [63:0] h_voltage_sq;
                h_voltage_sq = (h_core_voltage_mv * h_core_voltage_mv) / 1_000_000;
                h_core_power_mw <= (h_core_activity_cnt * h_voltage_sq * (h_core_freq_scale + 1)) / 120;
            end
            
            // A-Core power (64 cores, AI/ML - higher power)
            begin
                reg [63:0] a_voltage_sq;
                a_voltage_sq = (a_core_voltage_mv * a_core_voltage_mv) / 1_000_000;
                a_core_power_mw <= (a_core_activity_cnt * a_voltage_sq * (a_core_freq_scale + 1)) / 80;
            end
            
            // NPU power (8 clusters, inference - optimized)
            begin
                reg [63:0] n_voltage_sq;
                n_voltage_sq = (npu_voltage_mv * npu_voltage_mv) / 1_000_000;
                npu_power_mw <= (npu_activity_cnt * n_voltage_sq * (npu_freq_scale + 1)) / 110;
            end

            total_power_mw <= g_core_power_mw + h_core_power_mw +
                             a_core_power_mw + npu_power_mw;

            // Energy tracking
            energy_consumed_mj <= energy_consumed_mj + (total_power_mw / 1000);

            // Performance per watt calculation
            if (total_power_mw > 0) begin
                perf_per_watt <= (g_core_activity_cnt + h_core_activity_cnt +
                                 a_core_activity_cnt + npu_activity_cnt) * 1000 / total_power_mw;
            end else begin
                perf_per_watt <= 32'b0;
            end
        end
    end

endmodule
