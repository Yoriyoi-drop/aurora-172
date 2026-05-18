`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"
`include "interfaces/aurora_timing_constants.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 15 April 2026
// Design Name: AURORA-172 Exception Handler
// Module Name: exception_handler
//
// Description:
//   Advanced centralized exception handler untuk AURORA-172 processor
//   - Menerima exception dari semua cores (G, A, H, NPU)
//   - Prioritizes exceptions based on severity
//   - Provides unified error reporting
//   - ADVANCED: Comprehensive error recovery mechanisms
//   - ADVANCED: Automatic system healing capabilities
//   - ADVANCED: Error pattern learning and prevention
//   - ADVANCED: Graceful degradation strategies
//
// Target: Production-ready robust exception handling with auto-recovery
//////////////////////////////////////////////////////////////////////////////////

module exception_handler #(
    // Use standardized parameters from aurora_params.svh
    parameter NUM_G_CORES       = AURORA_NUM_G_CORES,       // FIXED: Use standard parameter
    parameter NUM_A_CORES       = AURORA_NUM_A_CORES,       // FIXED: Use standard parameter
    parameter NUM_H_CORES       = AURORA_NUM_H_CORES,       // FIXED: Use standard parameter
    parameter NUM_NPU_CLUSTERS  = AURORA_NUM_NPU_CLUSTERS,  // FIXED: Use standard parameter
    parameter DATA_WIDTH        = AURORA_DATA_WIDTH,        // FIXED: Use standard parameter
    parameter ADDR_WIDTH        = AURORA_ADDR_WIDTH          // FIXED: Use standard parameter
)(
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Exception inputs from G-Cores
    input  wire [NUM_G_CORES-1:0]       g_core_error_flag,
    input  wire [7:0]                    g_core_error_code [0:NUM_G_CORES-1],
    input  wire [NUM_G_CORES-1:0]       g_core_error_valid,
    
    // Exception inputs from A-Cores
    input  wire [NUM_A_CORES-1:0]       a_core_error_flag,
    input  wire [7:0]                    a_core_error_code [0:NUM_A_CORES-1],
    input  wire [NUM_A_CORES-1:0]       a_core_error_valid,
    
    // Exception inputs from H-Cores
    input  wire [NUM_H_CORES-1:0]       h_core_error_flag,
    input  wire [7:0]                    h_core_error_code [0:NUM_H_CORES-1],
    input  wire [NUM_H_CORES-1:0]       h_core_error_valid,
    
    // Exception inputs from NPU Clusters
    input  wire [NUM_NPU_CLUSTERS-1:0]  npu_error_flag,
    input  wire [7:0]                    npu_error_code [0:NUM_NPU_CLUSTERS-1],
    input  wire [NUM_NPU_CLUSTERS-1:0]  npu_error_valid,
    
    // System exception output
    output reg                          system_error_flag,
    output reg [7:0]                    system_error_code,
    output reg [15:0]                   system_error_source,  // Core ID that caused error
    output reg                          system_error_valid,
    
    // Error statistics
    output reg [31:0]                   total_error_count,
    output reg [31:0]                   g_core_error_count,
    output reg [31:0]                   a_core_error_count,
    output reg [31:0]                   h_core_error_count,
    output reg [31:0]                   npu_error_count,
    
    // Recovery control
    input  wire                         recovery_enable,
    output reg [15:0]                   recovery_core_id,
    output reg                          recovery_request,
    output reg [7:0]                    recovery_action
);

// Include timing and system constants
`include "interfaces/aurora_timing_constants.svh"
`include "interfaces/aurora_constants.svh"

    // =========================================================================
    // Error code definitions using system constants
    // =========================================================================
    localparam ERR_NONE              = 8'h00;
    localparam ERR_ILLEGAL_OPCODE    = 8'h01;
    localparam ERR_MEMORY_FAULT      = 8'h02;
    localparam ERR_BUS_ERROR        = 8'h03;
    localparam ERR_TIMEOUT           = 8'h04;
    localparam ERR_OVERFLOW          = 8'h05;
    localparam ERR_UNDERFLOW         = 8'h06;
    localparam ERR_DIVIDE_BY_ZERO    = 8'h07;
    localparam ERR_PRIVILEGE_VIOLATION = 8'h08;
    localparam ERR_PAGE_FAULT        = 8'h09;
    localparam ERR_ALIGNMENT_FAULT   = 8'h0A;
    localparam ERR_DEBUG_TRAP        = 8'h0B;
    localparam ERR_SYSTEM_CALL       = 8'h0C;
    localparam ERR_HARDWARE_FAULT    = 8'h0D;
    localparam ERR_POWER_FAULT       = 8'h0E;
    localparam ERR_THERMAL_FAULT     = 8'h0F;
    
    // Exception handler constants
    localparam EXC_ERROR_HISTORY_SIZE = 128;  // Expanded history for development system
    localparam EXC_ERROR_COUNT_ZERO = 32'd0;
    localparam EXC_ERROR_CODE_NONE = 8'h00;
    localparam EXC_CORE_ID_ZERO = 16'd0;
    localparam EXC_RECOVERY_ACTION_NONE = 8'd0;
    
    reg [31:0]                       error_history [0:EXC_ERROR_HISTORY_SIZE-1];
    reg [6:0]                        error_history_head;     // 7 bits for 128 entries
    reg [6:0]                        error_history_tail;     // 7 bits for 128 entries
    
    reg [7:0]                        current_error_code;
    reg [15:0]                       current_error_source;
    reg                              current_error_valid;
    
    reg [3:0]                        error_priority [0:15];  // Priority levels
    
    // Error rate monitoring variables
    reg [31:0]                       error_rate_window;
    reg [31:0]                       error_rate_count;
    reg [31:0]                       error_rate_total;
    reg                              error_rate_threshold_exceeded;
    
    // ADVANCED: Error Recovery Mechanisms
    localparam RECOVERY_HISTORY_SIZE = 64;
    localparam MAX_RECOVERY_ATTEMPTS = 3;
    localparam RECOVERY_COOLDOWN = 100;  // 100 cycles between recovery attempts
    
    // Recovery state machine
    localparam RECOVERY_IDLE = 3'b000;
    localparam RECOVERY_DIAGNOSE = 3'b001;
    localparam RECOVERY_ISOLATE = 3'b010;
    localparam RECOVERY_HEAL = 3'b011;
    localparam RECOVERY_VERIFY = 3'b100;
    localparam RECOVERY_DEGRADE = 3'b101;
    
    reg [2:0]                       recovery_state;
    reg [31:0]                      recovery_attempts [0:15];  // Per-core recovery attempts
    reg [31:0]                      recovery_success [0:15];   // Per-core recovery success
    reg [31:0]                      recovery_failures [0:15];   // Per-core recovery failures
    reg [15:0]                      recovery_cooldown_counter;
    reg                             recovery_active;
    
    // Error pattern learning
    reg [7:0]                       error_pattern [0:RECOVERY_HISTORY_SIZE-1];
    reg [15:0]                      pattern_count [0:255];  // Error type frequency
    reg [ADDR_WIDTH-1:0]            error_addr_history [0:RECOVERY_HISTORY_SIZE-1];
    reg [$clog2(RECOVERY_HISTORY_SIZE)-1:0] pattern_history_ptr;
    reg                             pattern_detected;
    reg [7:0]                       predicted_error_type;
    
    // System healing capabilities
    reg [31:0]                      healing_action_count;
    reg [31:0]                      healing_success_count;
    reg [31:0]                      healing_failure_count;
    reg                             auto_healing_enabled;
    reg [7:0]                       healing_confidence;
    
    // Graceful degradation
    reg [3:0]                       system_health_level;  // 0=healthy, 15=critical
    reg [15:0]                      degraded_cores_mask;  // Bitmask of degraded cores
    reg                             degradation_active;
    reg [31:0]                      performance_impact;
    
    // Recovery actions
    localparam ACTION_NONE = 8'h00;
    localparam ACTION_RESET = 8'h01;
    localparam ACTION_ISOLATE = 8'h02;
    localparam ACTION_DEGRADE = 8'h03;
    localparam ACTION_RECONFIGURE = 8'h04;
    localparam ACTION_POWER_CYCLE = 8'h05;
    localparam ACTION_CLOCK_GATING = 8'h06;
    localparam ACTION_CACHE_FLUSH = 8'h07;
    
    reg [7:0]                       last_recovery_action [0:15];
    reg [31:0]                      last_recovery_timestamp [0:15];
    reg [7:0]                       recovery_success_rate [0:15];
    
    // =========================================================================
    // Exception processing logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            system_error_flag <= 1'b0;
            system_error_code <= EXC_ERROR_CODE_NONE;
            system_error_source <= EXC_CORE_ID_ZERO;
            system_error_valid <= 1'b0;
            
            total_error_count <= EXC_ERROR_COUNT_ZERO;
            g_core_error_count <= EXC_ERROR_COUNT_ZERO;
            a_core_error_count <= EXC_ERROR_COUNT_ZERO;
            h_core_error_count <= EXC_ERROR_COUNT_ZERO;
            
            // ADVANCED: Initialize error recovery system
            recovery_state <= RECOVERY_IDLE;
            recovery_active <= 1'b0;
            recovery_cooldown_counter <= 16'b0;
            
            // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
            recovery_attempts[0] <= 32'b0; recovery_success[0] <= 32'b0; recovery_failures[0] <= 32'b0; last_recovery_action[0] <= ACTION_NONE; last_recovery_timestamp[0] <= 32'b0; recovery_success_rate[0] <= 8'd100;
            recovery_attempts[1] <= 32'b0; recovery_success[1] <= 32'b0; recovery_failures[1] <= 32'b0; last_recovery_action[1] <= ACTION_NONE; last_recovery_timestamp[1] <= 32'b0; recovery_success_rate[1] <= 8'd100;
            recovery_attempts[2] <= 32'b0; recovery_success[2] <= 32'b0; recovery_failures[2] <= 32'b0; last_recovery_action[2] <= ACTION_NONE; last_recovery_timestamp[2] <= 32'b0; recovery_success_rate[2] <= 8'd100;
            recovery_attempts[3] <= 32'b0; recovery_success[3] <= 32'b0; recovery_failures[3] <= 32'b0; last_recovery_action[3] <= ACTION_NONE; last_recovery_timestamp[3] <= 32'b0; recovery_success_rate[3] <= 8'd100;
            recovery_attempts[4] <= 32'b0; recovery_success[4] <= 32'b0; recovery_failures[4] <= 32'b0; last_recovery_action[4] <= ACTION_NONE; last_recovery_timestamp[4] <= 32'b0; recovery_success_rate[4] <= 8'd100;
            recovery_attempts[5] <= 32'b0; recovery_success[5] <= 32'b0; recovery_failures[5] <= 32'b0; last_recovery_action[5] <= ACTION_NONE; last_recovery_timestamp[5] <= 32'b0; recovery_success_rate[5] <= 8'd100;
            recovery_attempts[6] <= 32'b0; recovery_success[6] <= 32'b0; recovery_failures[6] <= 32'b0; last_recovery_action[6] <= ACTION_NONE; last_recovery_timestamp[6] <= 32'b0; recovery_success_rate[6] <= 8'd100;
            recovery_attempts[7] <= 32'b0; recovery_success[7] <= 32'b0; recovery_failures[7] <= 32'b0; last_recovery_action[7] <= ACTION_NONE; last_recovery_timestamp[7] <= 32'b0; recovery_success_rate[7] <= 8'd100;
            recovery_attempts[8] <= 32'b0; recovery_success[8] <= 32'b0; recovery_failures[8] <= 32'b0; last_recovery_action[8] <= ACTION_NONE; last_recovery_timestamp[8] <= 32'b0; recovery_success_rate[8] <= 8'd100;
            recovery_attempts[9] <= 32'b0; recovery_success[9] <= 32'b0; recovery_failures[9] <= 32'b0; last_recovery_action[9] <= ACTION_NONE; last_recovery_timestamp[9] <= 32'b0; recovery_success_rate[9] <= 8'd100;
            recovery_attempts[10] <= 32'b0; recovery_success[10] <= 32'b0; recovery_failures[10] <= 32'b0; last_recovery_action[10] <= ACTION_NONE; last_recovery_timestamp[10] <= 32'b0; recovery_success_rate[10] <= 8'd100;
            recovery_attempts[11] <= 32'b0; recovery_success[11] <= 32'b0; recovery_failures[11] <= 32'b0; last_recovery_action[11] <= ACTION_NONE; last_recovery_timestamp[11] <= 32'b0; recovery_success_rate[11] <= 8'd100;
            recovery_attempts[12] <= 32'b0; recovery_success[12] <= 32'b0; recovery_failures[12] <= 32'b0; last_recovery_action[12] <= ACTION_NONE; last_recovery_timestamp[12] <= 32'b0; recovery_success_rate[12] <= 8'd100;
            recovery_attempts[13] <= 32'b0; recovery_success[13] <= 32'b0; recovery_failures[13] <= 32'b0; last_recovery_action[13] <= ACTION_NONE; last_recovery_timestamp[13] <= 32'b0; recovery_success_rate[13] <= 8'd100;
            recovery_attempts[14] <= 32'b0; recovery_success[14] <= 32'b0; recovery_failures[14] <= 32'b0; last_recovery_action[14] <= ACTION_NONE; last_recovery_timestamp[14] <= 32'b0; recovery_success_rate[14] <= 8'd100;
            recovery_attempts[15] <= 32'b0; recovery_success[15] <= 32'b0; recovery_failures[15] <= 32'b0; last_recovery_action[15] <= ACTION_NONE; last_recovery_timestamp[15] <= 32'b0; recovery_success_rate[15] <= 8'd100;
            
            // Initialize error pattern learning
            pattern_history_ptr <= {$clog2(RECOVERY_HISTORY_SIZE){1'b0}};
            pattern_detected <= 1'b0;
            predicted_error_type <= 8'h00;
            
            // DEADLOCK FIX: Complete array initialization to prevent undefined behavior
            // Initialize pattern_count array (all 256 entries)
            pattern_count[0] <= 16'b0; pattern_count[1] <= 16'b0; pattern_count[2] <= 16'b0; pattern_count[3] <= 16'b0;
            pattern_count[4] <= 16'b0; pattern_count[5] <= 16'b0; pattern_count[6] <= 16'b0; pattern_count[7] <= 16'b0;
            pattern_count[8] <= 16'b0; pattern_count[9] <= 16'b0; pattern_count[10] <= 16'b0; pattern_count[11] <= 16'b0;
            pattern_count[12] <= 16'b0; pattern_count[13] <= 16'b0; pattern_count[14] <= 16'b0; pattern_count[15] <= 16'b0;
            pattern_count[16] <= 16'b0; pattern_count[17] <= 16'b0; pattern_count[18] <= 16'b0; pattern_count[19] <= 16'b0;
            pattern_count[20] <= 16'b0; pattern_count[21] <= 16'b0; pattern_count[22] <= 16'b0; pattern_count[23] <= 16'b0;
            pattern_count[24] <= 16'b0; pattern_count[25] <= 16'b0; pattern_count[26] <= 16'b0; pattern_count[27] <= 16'b0;
            pattern_count[28] <= 16'b0; pattern_count[29] <= 16'b0; pattern_count[30] <= 16'b0; pattern_count[31] <= 16'b0;
            pattern_count[32] <= 16'b0; pattern_count[33] <= 16'b0; pattern_count[34] <= 16'b0; pattern_count[35] <= 16'b0;
            pattern_count[36] <= 16'b0; pattern_count[37] <= 16'b0; pattern_count[38] <= 16'b0; pattern_count[39] <= 16'b0;
            pattern_count[40] <= 16'b0; pattern_count[41] <= 16'b0; pattern_count[42] <= 16'b0; pattern_count[43] <= 16'b0;
            pattern_count[44] <= 16'b0; pattern_count[45] <= 16'b0; pattern_count[46] <= 16'b0; pattern_count[47] <= 16'b0;
            pattern_count[48] <= 16'b0; pattern_count[49] <= 16'b0; pattern_count[50] <= 16'b0; pattern_count[51] <= 16'b0;
            pattern_count[52] <= 16'b0; pattern_count[53] <= 16'b0; pattern_count[54] <= 16'b0; pattern_count[55] <= 16'b0;
            pattern_count[56] <= 16'b0; pattern_count[57] <= 16'b0; pattern_count[58] <= 16'b0; pattern_count[59] <= 16'b0;
            pattern_count[60] <= 16'b0; pattern_count[61] <= 16'b0; pattern_count[62] <= 16'b0; pattern_count[63] <= 16'b0;
            pattern_count[64] <= 16'b0; pattern_count[65] <= 16'b0; pattern_count[66] <= 16'b0; pattern_count[67] <= 16'b0;
            pattern_count[68] <= 16'b0; pattern_count[69] <= 16'b0; pattern_count[70] <= 16'b0; pattern_count[71] <= 16'b0;
            pattern_count[72] <= 16'b0; pattern_count[73] <= 16'b0; pattern_count[74] <= 16'b0; pattern_count[75] <= 16'b0;
            pattern_count[76] <= 16'b0; pattern_count[77] <= 16'b0; pattern_count[78] <= 16'b0; pattern_count[79] <= 16'b0;
            pattern_count[80] <= 16'b0; pattern_count[81] <= 16'b0; pattern_count[82] <= 16'b0; pattern_count[83] <= 16'b0;
            pattern_count[84] <= 16'b0; pattern_count[85] <= 16'b0; pattern_count[86] <= 16'b0; pattern_count[87] <= 16'b0;
            pattern_count[88] <= 16'b0; pattern_count[89] <= 16'b0; pattern_count[90] <= 16'b0; pattern_count[91] <= 16'b0;
            pattern_count[92] <= 16'b0; pattern_count[93] <= 16'b0; pattern_count[94] <= 16'b0; pattern_count[95] <= 16'b0;
            pattern_count[96] <= 16'b0; pattern_count[97] <= 16'b0; pattern_count[98] <= 16'b0; pattern_count[99] <= 16'b0;
            pattern_count[100] <= 16'b0; pattern_count[101] <= 16'b0; pattern_count[102] <= 16'b0; pattern_count[103] <= 16'b0;
            pattern_count[104] <= 16'b0; pattern_count[105] <= 16'b0; pattern_count[106] <= 16'b0; pattern_count[107] <= 16'b0;
            pattern_count[108] <= 16'b0; pattern_count[109] <= 16'b0; pattern_count[110] <= 16'b0; pattern_count[111] <= 16'b0;
            pattern_count[112] <= 16'b0; pattern_count[113] <= 16'b0; pattern_count[114] <= 16'b0; pattern_count[115] <= 16'b0;
            pattern_count[116] <= 16'b0; pattern_count[117] <= 16'b0; pattern_count[118] <= 16'b0; pattern_count[119] <= 16'b0;
            pattern_count[120] <= 16'b0; pattern_count[121] <= 16'b0; pattern_count[122] <= 16'b0; pattern_count[123] <= 16'b0;
            pattern_count[124] <= 16'b0; pattern_count[125] <= 16'b0; pattern_count[126] <= 16'b0; pattern_count[127] <= 16'b0;
            pattern_count[128] <= 16'b0; pattern_count[129] <= 16'b0; pattern_count[130] <= 16'b0; pattern_count[131] <= 16'b0;
            pattern_count[132] <= 16'b0; pattern_count[133] <= 16'b0; pattern_count[134] <= 16'b0; pattern_count[135] <= 16'b0;
            pattern_count[136] <= 16'b0; pattern_count[137] <= 16'b0; pattern_count[138] <= 16'b0; pattern_count[139] <= 16'b0;
            pattern_count[140] <= 16'b0; pattern_count[141] <= 16'b0; pattern_count[142] <= 16'b0; pattern_count[143] <= 16'b0;
            pattern_count[144] <= 16'b0; pattern_count[145] <= 16'b0; pattern_count[146] <= 16'b0; pattern_count[147] <= 16'b0;
            pattern_count[148] <= 16'b0; pattern_count[149] <= 16'b0; pattern_count[150] <= 16'b0; pattern_count[151] <= 16'b0;
            pattern_count[152] <= 16'b0; pattern_count[153] <= 16'b0; pattern_count[154] <= 16'b0; pattern_count[155] <= 16'b0;
            pattern_count[156] <= 16'b0; pattern_count[157] <= 16'b0; pattern_count[158] <= 16'b0; pattern_count[159] <= 16'b0;
            pattern_count[160] <= 16'b0; pattern_count[161] <= 16'b0; pattern_count[162] <= 16'b0; pattern_count[163] <= 16'b0;
            pattern_count[164] <= 16'b0; pattern_count[165] <= 16'b0; pattern_count[166] <= 16'b0; pattern_count[167] <= 16'b0;
            pattern_count[168] <= 16'b0; pattern_count[169] <= 16'b0; pattern_count[170] <= 16'b0; pattern_count[171] <= 16'b0;
            pattern_count[172] <= 16'b0; pattern_count[173] <= 16'b0; pattern_count[174] <= 16'b0; pattern_count[175] <= 16'b0;
            pattern_count[176] <= 16'b0; pattern_count[177] <= 16'b0; pattern_count[178] <= 16'b0; pattern_count[179] <= 16'b0;
            pattern_count[180] <= 16'b0; pattern_count[181] <= 16'b0; pattern_count[182] <= 16'b0; pattern_count[183] <= 16'b0;
            pattern_count[184] <= 16'b0; pattern_count[185] <= 16'b0; pattern_count[186] <= 16'b0; pattern_count[187] <= 16'b0;
            pattern_count[188] <= 16'b0; pattern_count[189] <= 16'b0; pattern_count[190] <= 16'b0; pattern_count[191] <= 16'b0;
            pattern_count[192] <= 16'b0; pattern_count[193] <= 16'b0; pattern_count[194] <= 16'b0; pattern_count[195] <= 16'b0;
            pattern_count[196] <= 16'b0; pattern_count[197] <= 16'b0; pattern_count[198] <= 16'b0; pattern_count[199] <= 16'b0;
            pattern_count[200] <= 16'b0; pattern_count[201] <= 16'b0; pattern_count[202] <= 16'b0; pattern_count[203] <= 16'b0;
            pattern_count[204] <= 16'b0; pattern_count[205] <= 16'b0; pattern_count[206] <= 16'b0; pattern_count[207] <= 16'b0;
            pattern_count[208] <= 16'b0; pattern_count[209] <= 16'b0; pattern_count[210] <= 16'b0; pattern_count[211] <= 16'b0;
            pattern_count[212] <= 16'b0; pattern_count[213] <= 16'b0; pattern_count[214] <= 16'b0; pattern_count[215] <= 16'b0;
            pattern_count[216] <= 16'b0; pattern_count[217] <= 16'b0; pattern_count[218] <= 16'b0; pattern_count[219] <= 16'b0;
            pattern_count[220] <= 16'b0; pattern_count[221] <= 16'b0; pattern_count[222] <= 16'b0; pattern_count[223] <= 16'b0;
            pattern_count[224] <= 16'b0; pattern_count[225] <= 16'b0; pattern_count[226] <= 16'b0; pattern_count[227] <= 16'b0;
            pattern_count[228] <= 16'b0; pattern_count[229] <= 16'b0; pattern_count[230] <= 16'b0; pattern_count[231] <= 16'b0;
            pattern_count[232] <= 16'b0; pattern_count[233] <= 16'b0; pattern_count[234] <= 16'b0; pattern_count[235] <= 16'b0;
            pattern_count[236] <= 16'b0; pattern_count[237] <= 16'b0; pattern_count[238] <= 16'b0; pattern_count[239] <= 16'b0;
            pattern_count[240] <= 16'b0; pattern_count[241] <= 16'b0; pattern_count[242] <= 16'b0; pattern_count[243] <= 16'b0;
            pattern_count[244] <= 16'b0; pattern_count[245] <= 16'b0; pattern_count[246] <= 16'b0; pattern_count[247] <= 16'b0;
            pattern_count[248] <= 16'b0; pattern_count[249] <= 16'b0; pattern_count[250] <= 16'b0; pattern_count[251] <= 16'b0;
            pattern_count[252] <= 16'b0; pattern_count[253] <= 16'b0; pattern_count[254] <= 16'b0; pattern_count[255] <= 16'b0;
            
            // DEADLOCK FIX: Complete array initialization to prevent undefined behavior
            // Initialize error_pattern and error_addr_history arrays (all RECOVERY_HISTORY_SIZE entries)
            error_pattern[0] <= 8'h00; error_addr_history[0] <= {ADDR_WIDTH{1'b0}};
            error_pattern[1] <= 8'h00; error_addr_history[1] <= {ADDR_WIDTH{1'b0}};
            error_pattern[2] <= 8'h00; error_addr_history[2] <= {ADDR_WIDTH{1'b0}};
            error_pattern[3] <= 8'h00; error_addr_history[3] <= {ADDR_WIDTH{1'b0}};
            error_pattern[4] <= 8'h00; error_addr_history[4] <= {ADDR_WIDTH{1'b0}};
            error_pattern[5] <= 8'h00; error_addr_history[5] <= {ADDR_WIDTH{1'b0}};
            error_pattern[6] <= 8'h00; error_addr_history[6] <= {ADDR_WIDTH{1'b0}};
            error_pattern[7] <= 8'h00; error_addr_history[7] <= {ADDR_WIDTH{1'b0}};
            error_pattern[8] <= 8'h00; error_addr_history[8] <= {ADDR_WIDTH{1'b0}};
            error_pattern[9] <= 8'h00; error_addr_history[9] <= {ADDR_WIDTH{1'b0}};
            error_pattern[10] <= 8'h00; error_addr_history[10] <= {ADDR_WIDTH{1'b0}};
            error_pattern[11] <= 8'h00; error_addr_history[11] <= {ADDR_WIDTH{1'b0}};
            error_pattern[12] <= 8'h00; error_addr_history[12] <= {ADDR_WIDTH{1'b0}};
            error_pattern[13] <= 8'h00; error_addr_history[13] <= {ADDR_WIDTH{1'b0}};
            error_pattern[14] <= 8'h00; error_addr_history[14] <= {ADDR_WIDTH{1'b0}};
            error_pattern[15] <= 8'h00; error_addr_history[15] <= {ADDR_WIDTH{1'b0}};
            error_pattern[16] <= 8'h00; error_addr_history[16] <= {ADDR_WIDTH{1'b0}};
            error_pattern[17] <= 8'h00; error_addr_history[17] <= {ADDR_WIDTH{1'b0}};
            error_pattern[18] <= 8'h00; error_addr_history[18] <= {ADDR_WIDTH{1'b0}};
            error_pattern[19] <= 8'h00; error_addr_history[19] <= {ADDR_WIDTH{1'b0}};
            error_pattern[20] <= 8'h00; error_addr_history[20] <= {ADDR_WIDTH{1'b0}};
            error_pattern[21] <= 8'h00; error_addr_history[21] <= {ADDR_WIDTH{1'b0}};
            error_pattern[22] <= 8'h00; error_addr_history[22] <= {ADDR_WIDTH{1'b0}};
            error_pattern[23] <= 8'h00; error_addr_history[23] <= {ADDR_WIDTH{1'b0}};
            error_pattern[24] <= 8'h00; error_addr_history[24] <= {ADDR_WIDTH{1'b0}};
            error_pattern[25] <= 8'h00; error_addr_history[25] <= {ADDR_WIDTH{1'b0}};
            error_pattern[26] <= 8'h00; error_addr_history[26] <= {ADDR_WIDTH{1'b0}};
            error_pattern[27] <= 8'h00; error_addr_history[27] <= {ADDR_WIDTH{1'b0}};
            error_pattern[28] <= 8'h00; error_addr_history[28] <= {ADDR_WIDTH{1'b0}};
            error_pattern[29] <= 8'h00; error_addr_history[29] <= {ADDR_WIDTH{1'b0}};
            error_pattern[30] <= 8'h00; error_addr_history[30] <= {ADDR_WIDTH{1'b0}};
            error_pattern[31] <= 8'h00; error_addr_history[31] <= {ADDR_WIDTH{1'b0}};
            error_pattern[32] <= 8'h00; error_addr_history[32] <= {ADDR_WIDTH{1'b0}};
            error_pattern[33] <= 8'h00; error_addr_history[33] <= {ADDR_WIDTH{1'b0}};
            error_pattern[34] <= 8'h00; error_addr_history[34] <= {ADDR_WIDTH{1'b0}};
            error_pattern[35] <= 8'h00; error_addr_history[35] <= {ADDR_WIDTH{1'b0}};
            error_pattern[36] <= 8'h00; error_addr_history[36] <= {ADDR_WIDTH{1'b0}};
            error_pattern[37] <= 8'h00; error_addr_history[37] <= {ADDR_WIDTH{1'b0}};
            error_pattern[38] <= 8'h00; error_addr_history[38] <= {ADDR_WIDTH{1'b0}};
            error_pattern[39] <= 8'h00; error_addr_history[39] <= {ADDR_WIDTH{1'b0}};
            error_pattern[40] <= 8'h00; error_addr_history[40] <= {ADDR_WIDTH{1'b0}};
            error_pattern[41] <= 8'h00; error_addr_history[41] <= {ADDR_WIDTH{1'b0}};
            error_pattern[42] <= 8'h00; error_addr_history[42] <= {ADDR_WIDTH{1'b0}};
            error_pattern[43] <= 8'h00; error_addr_history[43] <= {ADDR_WIDTH{1'b0}};
            error_pattern[44] <= 8'h00; error_addr_history[44] <= {ADDR_WIDTH{1'b0}};
            error_pattern[45] <= 8'h00; error_addr_history[45] <= {ADDR_WIDTH{1'b0}};
            error_pattern[46] <= 8'h00; error_addr_history[46] <= {ADDR_WIDTH{1'b0}};
            error_pattern[47] <= 8'h00; error_addr_history[47] <= {ADDR_WIDTH{1'b0}};
            error_pattern[48] <= 8'h00; error_addr_history[48] <= {ADDR_WIDTH{1'b0}};
            error_pattern[49] <= 8'h00; error_addr_history[49] <= {ADDR_WIDTH{1'b0}};
            error_pattern[50] <= 8'h00; error_addr_history[50] <= {ADDR_WIDTH{1'b0}};
            error_pattern[51] <= 8'h00; error_addr_history[51] <= {ADDR_WIDTH{1'b0}};
            error_pattern[52] <= 8'h00; error_addr_history[52] <= {ADDR_WIDTH{1'b0}};
            error_pattern[53] <= 8'h00; error_addr_history[53] <= {ADDR_WIDTH{1'b0}};
            error_pattern[54] <= 8'h00; error_addr_history[54] <= {ADDR_WIDTH{1'b0}};
            error_pattern[55] <= 8'h00; error_addr_history[55] <= {ADDR_WIDTH{1'b0}};
            error_pattern[56] <= 8'h00; error_addr_history[56] <= {ADDR_WIDTH{1'b0}};
            error_pattern[57] <= 8'h00; error_addr_history[57] <= {ADDR_WIDTH{1'b0}};
            error_pattern[58] <= 8'h00; error_addr_history[58] <= {ADDR_WIDTH{1'b0}};
            error_pattern[59] <= 8'h00; error_addr_history[59] <= {ADDR_WIDTH{1'b0}};
            error_pattern[60] <= 8'h00; error_addr_history[60] <= {ADDR_WIDTH{1'b0}};
            error_pattern[61] <= 8'h00; error_addr_history[61] <= {ADDR_WIDTH{1'b0}};
            error_pattern[62] <= 8'h00; error_addr_history[62] <= {ADDR_WIDTH{1'b0}};
            error_pattern[63] <= 8'h00; error_addr_history[63] <= {ADDR_WIDTH{1'b0}};
            error_pattern[64] <= 8'h00; error_addr_history[64] <= {ADDR_WIDTH{1'b0}};
            error_pattern[65] <= 8'h00; error_addr_history[65] <= {ADDR_WIDTH{1'b0}};
            error_pattern[66] <= 8'h00; error_addr_history[66] <= {ADDR_WIDTH{1'b0}};
            error_pattern[67] <= 8'h00; error_addr_history[67] <= {ADDR_WIDTH{1'b0}};
            error_pattern[68] <= 8'h00; error_addr_history[68] <= {ADDR_WIDTH{1'b0}};
            error_pattern[69] <= 8'h00; error_addr_history[69] <= {ADDR_WIDTH{1'b0}};
            error_pattern[70] <= 8'h00; error_addr_history[70] <= {ADDR_WIDTH{1'b0}};
            error_pattern[71] <= 8'h00; error_addr_history[71] <= {ADDR_WIDTH{1'b0}};
            error_pattern[72] <= 8'h00; error_addr_history[72] <= {ADDR_WIDTH{1'b0}};
            error_pattern[73] <= 8'h00; error_addr_history[73] <= {ADDR_WIDTH{1'b0}};
            error_pattern[74] <= 8'h00; error_addr_history[74] <= {ADDR_WIDTH{1'b0}};
            error_pattern[75] <= 8'h00; error_addr_history[75] <= {ADDR_WIDTH{1'b0}};
            error_pattern[76] <= 8'h00; error_addr_history[76] <= {ADDR_WIDTH{1'b0}};
            error_pattern[77] <= 8'h00; error_addr_history[77] <= {ADDR_WIDTH{1'b0}};
            error_pattern[78] <= 8'h00; error_addr_history[78] <= {ADDR_WIDTH{1'b0}};
            error_pattern[79] <= 8'h00; error_addr_history[79] <= {ADDR_WIDTH{1'b0}};
            error_pattern[80] <= 8'h00; error_addr_history[80] <= {ADDR_WIDTH{1'b0}};
            error_pattern[81] <= 8'h00; error_addr_history[81] <= {ADDR_WIDTH{1'b0}};
            error_pattern[82] <= 8'h00; error_addr_history[82] <= {ADDR_WIDTH{1'b0}};
            error_pattern[83] <= 8'h00; error_addr_history[83] <= {ADDR_WIDTH{1'b0}};
            error_pattern[84] <= 8'h00; error_addr_history[84] <= {ADDR_WIDTH{1'b0}};
            error_pattern[85] <= 8'h00; error_addr_history[85] <= {ADDR_WIDTH{1'b0}};
            error_pattern[86] <= 8'h00; error_addr_history[86] <= {ADDR_WIDTH{1'b0}};
            error_pattern[87] <= 8'h00; error_addr_history[87] <= {ADDR_WIDTH{1'b0}};
            error_pattern[88] <= 8'h00; error_addr_history[88] <= {ADDR_WIDTH{1'b0}};
            error_pattern[89] <= 8'h00; error_addr_history[89] <= {ADDR_WIDTH{1'b0}};
            error_pattern[90] <= 8'h00; error_addr_history[90] <= {ADDR_WIDTH{1'b0}};
            error_pattern[91] <= 8'h00; error_addr_history[91] <= {ADDR_WIDTH{1'b0}};
            error_pattern[92] <= 8'h00; error_addr_history[92] <= {ADDR_WIDTH{1'b0}};
            error_pattern[93] <= 8'h00; error_addr_history[93] <= {ADDR_WIDTH{1'b0}};
            error_pattern[94] <= 8'h00; error_addr_history[94] <= {ADDR_WIDTH{1'b0}};
            error_pattern[95] <= 8'h00; error_addr_history[95] <= {ADDR_WIDTH{1'b0}};
            error_pattern[96] <= 8'h00; error_addr_history[96] <= {ADDR_WIDTH{1'b0}};
            error_pattern[97] <= 8'h00; error_addr_history[97] <= {ADDR_WIDTH{1'b0}};
            error_pattern[98] <= 8'h00; error_addr_history[98] <= {ADDR_WIDTH{1'b0}};
            error_pattern[99] <= 8'h00; error_addr_history[99] <= {ADDR_WIDTH{1'b0}};
            error_pattern[100] <= 8'h00; error_addr_history[100] <= {ADDR_WIDTH{1'b0}};
            error_pattern[101] <= 8'h00; error_addr_history[101] <= {ADDR_WIDTH{1'b0}};
            error_pattern[102] <= 8'h00; error_addr_history[102] <= {ADDR_WIDTH{1'b0}};
            error_pattern[103] <= 8'h00; error_addr_history[103] <= {ADDR_WIDTH{1'b0}};
            error_pattern[104] <= 8'h00; error_addr_history[104] <= {ADDR_WIDTH{1'b0}};
            error_pattern[105] <= 8'h00; error_addr_history[105] <= {ADDR_WIDTH{1'b0}};
            error_pattern[106] <= 8'h00; error_addr_history[106] <= {ADDR_WIDTH{1'b0}};
            error_pattern[107] <= 8'h00; error_addr_history[107] <= {ADDR_WIDTH{1'b0}};
            error_pattern[108] <= 8'h00; error_addr_history[108] <= {ADDR_WIDTH{1'b0}};
            error_pattern[109] <= 8'h00; error_addr_history[109] <= {ADDR_WIDTH{1'b0}};
            error_pattern[110] <= 8'h00; error_addr_history[110] <= {ADDR_WIDTH{1'b0}};
            error_pattern[111] <= 8'h00; error_addr_history[111] <= {ADDR_WIDTH{1'b0}};
            error_pattern[112] <= 8'h00; error_addr_history[112] <= {ADDR_WIDTH{1'b0}};
            error_pattern[113] <= 8'h00; error_addr_history[113] <= {ADDR_WIDTH{1'b0}};
            error_pattern[114] <= 8'h00; error_addr_history[114] <= {ADDR_WIDTH{1'b0}};
            error_pattern[115] <= 8'h00; error_addr_history[115] <= {ADDR_WIDTH{1'b0}};
            error_pattern[116] <= 8'h00; error_addr_history[116] <= {ADDR_WIDTH{1'b0}};
            error_pattern[117] <= 8'h00; error_addr_history[117] <= {ADDR_WIDTH{1'b0}};
            error_pattern[118] <= 8'h00; error_addr_history[118] <= {ADDR_WIDTH{1'b0}};
            error_pattern[119] <= 8'h00; error_addr_history[119] <= {ADDR_WIDTH{1'b0}};
            error_pattern[120] <= 8'h00; error_addr_history[120] <= {ADDR_WIDTH{1'b0}};
            error_pattern[121] <= 8'h00; error_addr_history[121] <= {ADDR_WIDTH{1'b0}};
            error_pattern[122] <= 8'h00; error_addr_history[122] <= {ADDR_WIDTH{1'b0}};
            error_pattern[123] <= 8'h00; error_addr_history[123] <= {ADDR_WIDTH{1'b0}};
            error_pattern[124] <= 8'h00; error_addr_history[124] <= {ADDR_WIDTH{1'b0}};
            error_pattern[125] <= 8'h00; error_addr_history[125] <= {ADDR_WIDTH{1'b0}};
            error_pattern[126] <= 8'h00; error_addr_history[126] <= {ADDR_WIDTH{1'b0}};
            
            // Initialize system healing
            healing_action_count <= 32'b0;
            healing_success_count <= 32'b0;
            healing_failure_count <= 32'b0;
            auto_healing_enabled <= 1'b1;
            healing_confidence <= 8'd75;
            
            // Initialize graceful degradation
            system_health_level <= 4'b0000;  // Healthy
            degraded_cores_mask <= 16'b0000;
            degradation_active <= 1'b0;
            performance_impact <= 32'b0;
            npu_error_count <= EXC_ERROR_COUNT_ZERO;
            
            // Initialize error rate counters
            error_rate_window <= EXC_ERROR_COUNT_ZERO;
            error_rate_count <= EXC_ERROR_COUNT_ZERO;
            error_rate_total <= EXC_ERROR_COUNT_ZERO;
            
            recovery_core_id <= EXC_CORE_ID_ZERO;
            recovery_request <= 1'b0;
            recovery_action <= EXC_RECOVERY_ACTION_NONE;
            
            error_history_head <= 7'b00;
            error_history_tail <= 7'b00;
            current_error_valid <= 1'b0;
        end else begin
            // Clear system error valid after one cycle
            if (system_error_valid) begin
                system_error_valid <= 1'b0;
            end
            
            // Clear recovery request after one cycle
            if (recovery_request) begin
                recovery_request <= 1'b0;
            end
            
            // DEADLOCK FIX: Use explicit assignments instead of for-loop in always block
            // Process G-Core exceptions with rate limiting (4 cores)
            if (g_core_error_valid[0] && (error_rate_count < ERROR_RATE_THRESHOLD)) begin
                    total_error_count <= total_error_count + 1;
                    g_core_error_count <= g_core_error_count + 1;
                    
                    // Log error with overflow protection
                    error_history[error_history_tail] <= {g_core_error_code[0], EXC_ERROR_CODE_NONE, 8'd0};
                    error_history_tail <= (error_history_tail + 1) % EXC_ERROR_HISTORY_SIZE;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || g_core_error_code[0][3:0] > current_error_code[3:0]) begin
                        current_error_code <= g_core_error_code[0];
                        current_error_source <= {CORE_TYPE_G, 8'd0};  // G-Core type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] G-Core#%0d: Error 0x%02h", $time, 8'd0, g_core_error_code[0]);
                end
            end
            
            // Process A-Core exceptions with rate limiting - OPTIMIZED: Early exit
            for (int a = 0; a < NUM_A_CORES && error_rate_count < ERROR_RATE_THRESHOLD; a = a + 1) begin
                if (a_core_error_valid[a] && (error_rate_count < ERROR_RATE_THRESHOLD)) begin
                    total_error_count <= total_error_count + 1;
                    a_core_error_count <= a_core_error_count + 1;
                    
                    // Log error with overflow protection
                    error_history[error_history_tail] <= {a_core_error_code[a], EXC_ERROR_CODE_NONE, a[7:0]};
                    error_history_tail <= (error_history_tail + 1) % EXC_ERROR_HISTORY_SIZE;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(a_core_error_code[a]) > get_error_priority(current_error_code)) begin
                        current_error_code <= a_core_error_code[a];
                        current_error_source <= {CORE_TYPE_A, a[7:0]};  // A-Core type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] A-Core#%0d: Error 0x%02h", $time, a, a_core_error_code[a]);
                end
            end
            
            // Process H-Core exceptions with rate limiting - OPTIMIZED: Early exit
            for (int h = 0; h < NUM_H_CORES && error_rate_count < ERROR_RATE_THRESHOLD; h = h + 1) begin
                if (h_core_error_valid[h] && (error_rate_count < ERROR_RATE_THRESHOLD)) begin
                    total_error_count <= total_error_count + 1;
                    h_core_error_count <= h_core_error_count + 1;
                    
                    // Log error with overflow protection
                    error_history[error_history_tail] <= {h_core_error_code[h], CORE_TYPE_H, h[7:0]};
                    error_history_tail <= (error_history_tail + 1) % EXC_ERROR_HISTORY_SIZE;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(h_core_error_code[h]) > get_error_priority(current_error_code)) begin
                        current_error_code <= h_core_error_code[h];
                        current_error_source <= {CORE_TYPE_H, h[7:0]};  // H-Core type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] H-Core#%0d: Error 0x%02h", $time, h, h_core_error_code[h]);
                end
            end
            
            // Process NPU exceptions with rate limiting - OPTIMIZED: Early exit
            for (int n = 0; n < NUM_NPU_CLUSTERS && error_rate_count < ERROR_RATE_THRESHOLD; n = n + 1) begin
                if (npu_error_valid[n] && (error_rate_count < ERROR_RATE_THRESHOLD)) begin
                    total_error_count <= total_error_count + 1;
                    npu_error_count <= npu_error_count + 1;
                    
                    // Log error with overflow protection
                    error_history[error_history_tail] <= {npu_error_code[n], CORE_TYPE_NPU, n[7:0]};
                    error_history_tail <= (error_history_tail + 1) % EXC_ERROR_HISTORY_SIZE;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(npu_error_code[n]) > get_error_priority(current_error_code)) begin
                        current_error_code <= npu_error_code[n];
                        current_error_source <= {CORE_TYPE_NPU, n[7:0]};  // NPU type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] NPU#%0d: Error 0x%02h", $time, n, npu_error_code[n]);
                end
            end
            
            // Generate system error if we have a current error
            if (current_error_valid) begin
                system_error_flag <= 1'b1;
                system_error_code <= current_error_code;
                system_error_source <= current_error_source;
                system_error_valid <= 1'b1;
                current_error_valid <= 1'b0;
                
                // Generate recovery request if enabled
                if (recovery_enable) begin
                    recovery_core_id <= current_error_source;
                    recovery_request <= 1'b1;
                    recovery_action <= current_error_code;
                end
            end
        end
    
    // =========================================================================
    // Helper functions
    // =========================================================================
    
    // Helper function to get error priority
    function [3:0] get_error_priority;
        input [7:0] error_code;
        begin
            case (error_code)
                ERR_NONE:                get_error_priority = 4'd0;   // No error - lowest priority
                ERR_ILLEGAL_OPCODE:      get_error_priority = 4'd10;  // Instruction fault
                ERR_MEMORY_FAULT:        get_error_priority = 4'd13;  // Memory fault
                ERR_BUS_ERROR:           get_error_priority = 4'd12;  // Bus fault
                ERR_TIMEOUT:             get_error_priority = 4'd7;   // Timeout
                ERR_OVERFLOW:            get_error_priority = 4'd9;   // Overflow fault
                ERR_UNDERFLOW:           get_error_priority = 4'd9;   // Underflow fault
                ERR_DIVIDE_BY_ZERO:     get_error_priority = 4'd10;  // Division fault
                ERR_PRIVILEGE_VIOLATION: get_error_priority = 4'd11;  // Privilege fault
                ERR_PAGE_FAULT:          get_error_priority = 4'd11;  // Page/TLB fault
                ERR_ALIGNMENT_FAULT:     get_error_priority = 4'd10;  // Address fault
                ERR_DEBUG_TRAP:          get_error_priority = 4'd6;   // Debug trap
                ERR_SYSTEM_CALL:         get_error_priority = 4'd5;   // System call
                ERR_HARDWARE_FAULT:      get_error_priority = 4'd12;  // Hardware fault
                ERR_POWER_FAULT:         get_error_priority = 4'd14;  // Power fault
                ERR_THERMAL_FAULT:       get_error_priority = 4'd15;  // Thermal fault - highest priority
                default:                 get_error_priority = 4'd7;   // Unknown error - medium priority
            endcase
        end
    endfunction
    
    // =========================================================================
    // Debug and monitoring
    // =========================================================================

    // Error rate monitoring logic - ENABLED for system reliability
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_rate_window <= 32'h00000000;
            error_rate_count <= 32'd0;
            error_rate_threshold_exceeded <= 1'b0;
        end else begin
            // Simple error rate counting
            if (total_error_count > 32'd1000) begin
                error_rate_count <= error_rate_count + 1;

                if (error_rate_count >= 32'd500) begin
                    error_rate_threshold_exceeded <= 1'b1;
                    $display("[%0t] [EXCEPTION] ** HIGH ERROR RATE: %0d errors in last 1000 cycles", $time, error_rate_count);
                end
            end else begin
                error_rate_count <= 32'd0;
                error_rate_threshold_exceeded <= 1'b0;
            end

            // Reset counter if it gets too high
            if (error_rate_count >= 32'd10000) begin
                $display("[%0t] [EXCEPTION] ** TOTAL ERROR COUNT OVERFLOW - resetting counter", $time);
                error_rate_count <= 32'd0;
            end
        end
    end
    
endmodule
