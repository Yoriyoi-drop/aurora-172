`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Verification Team
//
// Create Date: 14 April 2026
// Design Name: AURORA-172 Memory Assertions
// Module Name: memory_assertions
//
// Description:
//   SystemVerilog Assertions untuk memory fabric AURORA-172
//   Meliputi cache coherency, protocol checking, dan performance properties
//////////////////////////////////////////////////////////////////////////////////

module memory_assertions #(
    // Use standardized parameters from aurora_params.svh
    parameter DATA_WIDTH = AURORA_DATA_WIDTH,      // FIXED: Use standard parameter
    parameter ADDR_WIDTH = AURORA_ADDR_WIDTH,       // FIXED: Use standard parameter
    parameter CACHE_LINE_WIDTH = AURORA_CACHE_LINE_WIDTH // FIXED: Use standard parameter
)(
    input  wire                         clk,
    input  wire                         rst_n,
    
    // Memory interface signals
    input  wire [ADDR_WIDTH-1:0]        mem_addr,
    input  wire                         mem_rd_en,
    input  wire                         mem_wr_en,
    input  wire [CACHE_LINE_WIDTH-1:0]  mem_wr_data,
    input  wire                         mem_ready,
    
    // Cache signals
    input  wire                         l1_hit,
    input  wire                         l2_hit,
    input  wire                         l3_hit,
    input  wire [1:0]                   cache_state,  // MESI states
    
    // Performance signals
    input  wire [31:0]                  total_requests,
    input  wire [31:0]                  cache_hits,
    input  wire [31:0]                  cache_misses
);

    // ========================================================================
    // Helper functions (Icarus Verilog Compatible)
    // ========================================================================
    
    // Read request detection
    function read_req_seq;
        input mem_rd_en, mem_wr_en;
        begin
            read_req_seq = mem_rd_en && !mem_wr_en;
        end
    endfunction
    
    // Write request detection
    function write_req_seq;
        input mem_rd_en, mem_wr_en;
        begin
            write_req_seq = !mem_rd_en && mem_wr_en;
        end
    endfunction
    
    // Cache hit detection
    function cache_hit_seq;
        input l1_hit, l2_hit, l3_hit;
        begin
            cache_hit_seq = l1_hit || l2_hit || l3_hit;
        end
    endfunction
    
    // ========================================================================
    // Protocol Assertions (Icarus Verilog Compatible)
    // ========================================================================
    
    // A1: Read and write should not be asserted simultaneously
    always @(posedge clk) begin
        if (rst_n && (mem_rd_en && mem_wr_en)) begin
            $error("[%0t] ASSERTION VIOLATION: Simultaneous read and write", $time);
        end
    end
    
    // A2: Memory ready timeout detection
    integer ready_timeout_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ready_timeout_counter <= 0;
        end else begin
            if (mem_rd_en || mem_wr_en) begin
                if (ready_timeout_counter < 10) begin
                    ready_timeout_counter <= ready_timeout_counter + 1;
                end else if (!mem_ready) begin
                    $error("[%0t] ASSERTION VIOLATION: Memory not ready within 10 cycles", $time);
                end
            end else begin
                ready_timeout_counter <= 0;
            end
        end
    end
    
    // DEADLOCK FIX: Enhanced ready/valid protocol validation
    integer valid_stuck_counter;
    integer ready_stuck_counter;
    reg [1:0] handshake_state;
    localparam HS_IDLE = 2'b00;
    localparam HS_VALID_ASSERTED = 2'b01;
    localparam HS_READY_ASSERTED = 2'b10;
    localparam HS_COMPLETE = 2'b11;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_stuck_counter <= 0;
            ready_stuck_counter <= 0;
            handshake_state <= HS_IDLE;
        end else begin
            case (handshake_state)
                HS_IDLE: begin
                    if (mem_rd_en || mem_wr_en) begin
                        handshake_state <= HS_VALID_ASSERTED;
                        valid_stuck_counter <= 0;
                        ready_stuck_counter <= 0;
                    end
                end
                
                HS_VALID_ASSERTED: begin
                    if (mem_ready) begin
                        handshake_state <= HS_COMPLETE;
                    end else begin
                        valid_stuck_counter <= valid_stuck_counter + 1;
                        if (valid_stuck_counter >= 20) begin
                            $error("[%0t] ASSERTION VIOLATION: Ready signal stuck low for 20+ cycles", $time);
                            // Force recovery
                            handshake_state <= HS_IDLE;
                        end
                    end
                end
                
                HS_COMPLETE: begin
                    handshake_state <= HS_IDLE;
                end
                
                default: handshake_state <= HS_IDLE;
            endcase
        end
    end
    
    // A3: Cache hit response time monitoring
    integer cache_hit_timeout_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache_hit_timeout_counter <= 0;
        end else begin
            if (read_req_seq(mem_rd_en, mem_wr_en) && cache_hit_seq(l1_hit, l2_hit, l3_hit)) begin
                if (cache_hit_timeout_counter < 3) begin
                    cache_hit_timeout_counter <= cache_hit_timeout_counter + 1;
                end else if (!mem_ready) begin
                    $error("[%0t] ASSERTION VIOLATION: Cache hit response too slow", $time);
                end
            end else begin
                cache_hit_timeout_counter <= 0;
            end
        end
    end
    
    // ========================================================================
    // Cache Coherency Assertions (Icarus Verilog Compatible)
    // ========================================================================
    
    // C1: MESI state transition validation
    reg [1:0] cache_state_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cache_state_prev <= 2'b00;
        end else begin
            // Check for invalid transitions
            if (cache_state != cache_state_prev) begin
                case (cache_state)
                    2'b00: begin
                        case (cache_state_prev)
                            2'b01: $display("[%0t] [ASSERTION] MESI: Shared -> Invalid", $time);
                            2'b10: $display("[%0t] [ASSERTION] MESI: Exclusive -> Invalid", $time);
                            2'b11: $display("[%0t] [ASSERTION] MESI: Modified -> Invalid", $time);
                            default: $display("[%0t] [ASSERTION] MESI: Invalid -> Invalid", $time);
                        endcase
                    end
                    2'b01: if (cache_state_prev != 2'b01) $display("[%0t] [ASSERTION] MESI: Transition to Shared", $time);
                    2'b10: if (cache_state_prev != 2'b10) $display("[%0t] [ASSERTION] MESI: Transition to Exclusive", $time);
                    2'b11: if (cache_state_prev != 2'b11) $display("[%0t] [ASSERTION] MESI: Transition to Modified", $time);
                endcase
            end
            cache_state_prev <= cache_state;
        end
    end
    
    // C2: Write state validation
    always @(posedge clk) begin
        if (rst_n && write_req_seq(mem_rd_en, mem_wr_en)) begin
            if (!(cache_state == 2'b11 || cache_state == 2'b10)) begin
                $error("[%0t] ASSERTION VIOLATION: Write in non-M/E state", $time);
            end
        end
    end
    
    // ========================================================================
    // Performance Assertions (Icarus Verilog Compatible)
    // ========================================================================
    
    // P1: Cache hit rate monitoring
    always @(posedge clk) begin
        if (rst_n && total_requests > 32'd100) begin
            if (((cache_hits * 32'd100) / total_requests) < 32'd80) begin
                $warning("[%0t] PERFORMANCE WARNING: Cache hit rate below 80%%", $time);
            end
        end
    end
    
    // P2: Maximum latency monitoring
    integer max_latency_counter;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            max_latency_counter <= 0;
        end else begin
            if (read_req_seq(mem_rd_en, mem_wr_en)) begin
                if (max_latency_counter < 50) begin
                    max_latency_counter <= max_latency_counter + 1;
                end else if (!mem_ready) begin
                    $error("[%0t] PERFORMANCE VIOLATION: Request latency > 50 cycles", $time);
                end
            end else begin
                max_latency_counter <= 0;
            end
        end
    end
    
    // ========================================================================
    // Coverage Monitoring (Icarus Verilog Compatible)
    // ========================================================================
    
    // Coverage counters
    reg [31:0] cover_mesi_states_count[0:3];
    reg [31:0] cover_read_ops, cover_write_ops;
    reg [31:0] cover_hit_ops, cover_miss_ops;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cover_mesi_states_count[0] <= 0;
            cover_mesi_states_count[1] <= 0;
            cover_mesi_states_count[2] <= 0;
            cover_mesi_states_count[3] <= 0;
            cover_read_ops <= 0;
            cover_write_ops <= 0;
            cover_hit_ops <= 0;
            cover_miss_ops <= 0;
        end else begin
            // Cover MESI states
            if (cache_state == 2'b00) cover_mesi_states_count[0] <= cover_mesi_states_count[0] + 1;
            if (cache_state == 2'b01) cover_mesi_states_count[1] <= cover_mesi_states_count[1] + 1;
            if (cache_state == 2'b10) cover_mesi_states_count[2] <= cover_mesi_states_count[2] + 1;
            if (cache_state == 2'b11) cover_mesi_states_count[3] <= cover_mesi_states_count[3] + 1;
            
            // Cover operations
            if (read_req_seq(mem_rd_en, mem_wr_en)) cover_read_ops <= cover_read_ops + 1;
            if (write_req_seq(mem_rd_en, mem_wr_en)) cover_write_ops <= cover_write_ops + 1;
            
            // Cover cache scenarios
            if (cache_hit_seq(l1_hit, l2_hit, l3_hit)) cover_hit_ops <= cover_hit_ops + 1;
            if (!cache_hit_seq(l1_hit, l2_hit, l3_hit) && (mem_rd_en || mem_wr_en)) cover_miss_ops <= cover_miss_ops + 1;
        end
    end
    
    // ========================================================================
    // Assertion Statistics
    // ========================================================================
    
    initial begin
        $display("[%0t] [ASSERTIONS] Memory assertions initialized", $time);
    end
    
    final begin
        $display("[%0t] [ASSERTIONS] Memory assertions completed", $time);
        $display("  Total requests: %0d", total_requests);
        $display("  Cache hits: %0d", cache_hits);
        $display("  Cache misses: %0d", cache_misses);
        if (total_requests > 0) begin
            $display("  Hit rate: %0.2f%%", (cache_hits * 100.0) / total_requests);
        end
    end

endmodule
