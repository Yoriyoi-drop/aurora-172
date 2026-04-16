`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team
//
// Create Date: 15 April 2026
// Design Name: AURORA-172 Exception Handler
// Module Name: exception_handler
//
// Description:
//   Centralized exception handler untuk AURORA-172 processor
//   - Menerima exception dari semua cores (G, A, H, NPU)
//   - Prioritizes exceptions based on severity
//   - Provides unified error reporting
//   - Supports exception recovery mechanisms
//
// Target: Robust exception handling for production system
//////////////////////////////////////////////////////////////////////////////////

module exception_handler #(
    parameter NUM_G_CORES       = 16,
    parameter NUM_A_CORES       = 64,
    parameter NUM_H_CORES       = 32,
    parameter NUM_NPU_CLUSTERS  = 8,
    parameter DATA_WIDTH        = 64,
    parameter ADDR_WIDTH        = 48
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

    // =========================================================================
    // Error code definitions
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
    
    // =========================================================================
    // Internal registers
    // =========================================================================
    reg [31:0]                       error_history [0:255];  // Circular buffer
    reg [7:0]                        error_history_head;
    reg [7:0]                        error_history_tail;
    
    reg [7:0]                        current_error_code;
    reg [15:0]                       current_error_source;
    reg                              current_error_valid;
    
    reg [3:0]                        error_priority [0:15];  // Priority levels
    
    // =========================================================================
    // Exception processing logic
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            system_error_flag <= 1'b0;
            system_error_code <= 8'h00;
            system_error_source <= 16'h0000;
            system_error_valid <= 1'b0;
            
            total_error_count <= 32'h00000000;
            g_core_error_count <= 32'h00000000;
            a_core_error_count <= 32'h00000000;
            h_core_error_count <= 32'h00000000;
            npu_error_count <= 32'h00000000;
            
            recovery_core_id <= 16'h0000;
            recovery_request <= 1'b0;
            recovery_action <= 8'h00;
            
            error_history_head <= 8'h00;
            error_history_tail <= 8'h00;
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
            
            // Process G-Core exceptions
            for (int g = 0; g < NUM_G_CORES; g = g + 1) begin
                if (g_core_error_valid[g]) begin
                    total_error_count <= total_error_count + 1;
                    g_core_error_count <= g_core_error_count + 1;
                    
                    // Log error
                    error_history[error_history_tail] <= {g_core_error_code[g], 8'h00, g[7:0]};
                    error_history_tail <= error_history_tail + 1;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(g_core_error_code[g]) > get_error_priority(current_error_code)) begin
                        current_error_code <= g_core_error_code[g];
                        current_error_source <= {8'h00, g[7:0]};  // G-Core type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] G-Core#%0d: Error 0x%02h", $time, g, g_core_error_code[g]);
                end
            end
            
            // Process A-Core exceptions
            for (int a = 0; a < NUM_A_CORES; a = a + 1) begin
                if (a_core_error_valid[a]) begin
                    total_error_count <= total_error_count + 1;
                    a_core_error_count <= a_core_error_count + 1;
                    
                    // Log error
                    error_history[error_history_tail] <= {a_core_error_code[a], 8'h01, a[7:0]};
                    error_history_tail <= error_history_tail + 1;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(a_core_error_code[a]) > get_error_priority(current_error_code)) begin
                        current_error_code <= a_core_error_code[a];
                        current_error_source <= {8'h01, a[7:0]};  // A-Core type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] A-Core#%0d: Error 0x%02h", $time, a, a_core_error_code[a]);
                end
            end
            
            // Process H-Core exceptions
            for (int h = 0; h < NUM_H_CORES; h = h + 1) begin
                if (h_core_error_valid[h]) begin
                    total_error_count <= total_error_count + 1;
                    h_core_error_count <= h_core_error_count + 1;
                    
                    // Log error
                    error_history[error_history_tail] <= {h_core_error_code[h], 8'h02, h[7:0]};
                    error_history_tail <= error_history_tail + 1;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(h_core_error_code[h]) > get_error_priority(current_error_code)) begin
                        current_error_code <= h_core_error_code[h];
                        current_error_source <= {8'h02, h[7:0]};  // H-Core type + ID
                        current_error_valid <= 1'b1;
                    end
                    
                    $display("[%0t] [EXCEPTION] H-Core#%0d: Error 0x%02h", $time, h, h_core_error_code[h]);
                end
            end
            
            // Process NPU exceptions
            for (int n = 0; n < NUM_NPU_CLUSTERS; n = n + 1) begin
                if (npu_error_valid[n]) begin
                    total_error_count <= total_error_count + 1;
                    npu_error_count <= npu_error_count + 1;
                    
                    // Log error
                    error_history[error_history_tail] <= {npu_error_code[n], 8'h03, n[7:0]};
                    error_history_tail <= error_history_tail + 1;
                    
                    // Determine if this is highest priority error
                    if (!current_error_valid || get_error_priority(npu_error_code[n]) > get_error_priority(current_error_code)) begin
                        current_error_code <= npu_error_code[n];
                        current_error_source <= {8'h03, n[7:0]};  // NPU type + ID
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
                    recovery_action <= get_recovery_action(current_error_code);
                end
            end
        end
    end
    
    // =========================================================================
    // Helper functions
    // =========================================================================
    
    // Get error priority (higher = more critical)
    function automatic [3:0] get_error_priority;
        input [7:0] error_code;
        begin
            case (error_code)
                ERR_HARDWARE_FAULT:    get_error_priority = 4'hF;  // Highest
                ERR_THERMAL_FAULT:     get_error_priority = 4'hE;
                ERR_POWER_FAULT:       get_error_priority = 4'hD;
                ERR_BUS_ERROR:         get_error_priority = 4'hC;
                ERR_MEMORY_FAULT:      get_error_priority = 4'hB;
                ERR_DIVIDE_BY_ZERO:    get_error_priority = 4'hA;
                ERR_PRIVILEGE_VIOLATION: get_error_priority = 4'h9;
                ERR_PAGE_FAULT:        get_error_priority = 4'h8;
                ERR_ALIGNMENT_FAULT:   get_error_priority = 4'h7;
                ERR_OVERFLOW:          get_error_priority = 4'h6;
                ERR_UNDERFLOW:         get_error_priority = 4'h5;
                ERR_TIMEOUT:           get_error_priority = 4'h4;
                ERR_ILLEGAL_OPCODE:    get_error_priority = 4'h3;
                ERR_DEBUG_TRAP:        get_error_priority = 4'h2;
                ERR_SYSTEM_CALL:       get_error_priority = 4'h1;
                default:                get_error_priority = 4'h0;
            endcase
        end
    endfunction
    
    // Get recovery action for error
    function automatic [7:0] get_recovery_action;
        input [7:0] error_code;
        begin
            case (error_code)
                ERR_HARDWARE_FAULT:    get_recovery_action = 8'h01;  // System reset
                ERR_THERMAL_FAULT:     get_recovery_action = 8'h02;  // Throttle
                ERR_POWER_FAULT:       get_recovery_action = 8'h03;  // Power down
                ERR_BUS_ERROR:         get_recovery_action = 8'h04;  // Retry
                ERR_MEMORY_FAULT:      get_recovery_action = 8'h05;  // Page fault handler
                ERR_DIVIDE_BY_ZERO:    get_recovery_action = 8'h06;  // Software trap
                ERR_PRIVILEGE_VIOLATION: get_recovery_action = 8'h07;  // Security handler
                ERR_PAGE_FAULT:        get_recovery_action = 8'h08;  // Page fault handler
                ERR_ALIGNMENT_FAULT:   get_recovery_action = 8'h09;  // Alignment fix
                ERR_OVERFLOW:          get_recovery_action = 8'h0A;  // Overflow handler
                ERR_UNDERFLOW:         get_recovery_action = 8'h0B;  // Underflow handler
                ERR_TIMEOUT:           get_recovery_action = 8'h0C;  // Timeout recovery
                ERR_ILLEGAL_OPCODE:    get_recovery_action = 8'h0D;  // Illegal opcode handler
                ERR_DEBUG_TRAP:        get_recovery_action = 8'h0E;  // Debug handler
                ERR_SYSTEM_CALL:       get_recovery_action = 8'h0F;  // System call handler
                default:                get_recovery_action = 8'h00;  // No action
            endcase
        end
    endfunction
    
    // =========================================================================
    // Debug and monitoring
    // =========================================================================
    
    // Error rate monitoring
    reg [31:0]                       error_rate_window;
    reg [31:0]                       error_rate_count;
    reg [31:0]                       error_rate_threshold = 32'd100;  // 100 errors per window
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            error_rate_window <= 32'h00000000;
            error_rate_count <= 32'h00000000;
        end else begin
            error_rate_window <= error_rate_window + 1;
            
            // Reset counter every 1000 cycles
            if (error_rate_window >= 32'd1000) begin
                error_rate_window <= 32'h00000000;
                error_rate_count <= 32'h00000000;
            end
            
            // Count errors in current window
            if (system_error_valid) begin
                error_rate_count <= error_rate_count + 1;
                
                // Trigger warning if error rate too high
                if (error_rate_count > error_rate_threshold) begin
                    $display("[%0t] [EXCEPTION] ** HIGH ERROR RATE: %0d errors in last 1000 cycles", 
                            $time, error_rate_count);
                end
            end
        end
    end
    
endmodule
