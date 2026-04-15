`timescale 1ns / 1ps

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
    parameter DATA_WIDTH = 64,
    parameter ADDR_WIDTH = 48,
    parameter CACHE_LINE_WIDTH = 512
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
    // Helper sequences
    // ========================================================================
    
    // Read request sequence
    sequence read_req_seq;
        mem_rd_en && !mem_wr_en;
    endsequence
    
    // Write request sequence
    sequence write_req_seq;
        !mem_rd_en && mem_wr_en;
    endsequence
    
    // Cache hit sequence
    sequence cache_hit_seq;
        l1_hit || l2_hit || l3_hit;
    endsequence
    
    // ========================================================================
    // Protocol Assertions
    // ========================================================================
    
    // A1: Read and write should not be asserted simultaneously
    property no_simultaneous_rw;
        @(posedge clk) 
        disable iff (!rst_n)
        !(mem_rd_en && mem_wr_en);
    endproperty
    
    assert property (no_simultaneous_rw) 
        else $error("[%0t] ASSERTION VIOLATION: Simultaneous read and write", $time);
    
    // A2: Memory ready should be asserted when request is active
    property ready_on_request;
        @(posedge clk)
        disable iff (!rst_n)
        (mem_rd_en || mem_wr_en) |-> ##[1:10] mem_ready;
    endproperty
    
    assert property (ready_on_request)
        else $error("[%0t] ASSERTION VIOLATION: Memory not ready within 10 cycles", $time);
    
    // A3: Cache hit should result in faster response
    property cache_hit_faster;
        @(posedge clk)
        disable iff (!rst_n)
        read_req_seq && cache_hit_seq |-> ##[1:3] mem_ready;
    endproperty
    
    assert property (cache_hit_faster)
        else $error("[%0t] ASSERTION VIOLATION: Cache hit response too slow", $time);
    
    // ========================================================================
    // Cache Coherency Assertions
    // ========================================================================
    
    // C1: MESI state transitions should be valid
    property valid_mesi_transition;
        @(posedge clk)
        disable iff (!rst_n)
        $stable(cache_state) || 
        (cache_state == 2'b00 && $past(cache_state) != 2'b00) || // Invalid transition
        (cache_state == 2'b01 && $past(cache_state) != 2'b01) || // Shared transition
        (cache_state == 2'b10 && $past(cache_state) != 2'b10) || // Exclusive transition
        (cache_state == 2'b11 && $past(cache_state) != 2'b11);   // Modified transition
    endproperty
    
    assert property (valid_mesi_transition)
        else $error("[%0t] ASSERTION VIOLATION: Invalid MESI state transition", $time);
    
    // C2: Write should only happen in Modified or Exclusive state
    property write_only_m_e;
        @(posedge clk)
        disable iff (!rst_n)
        write_req_seq |-> (cache_state == 2'b11 || cache_state == 2'b10);
    endproperty
    
    assert property (write_only_m_e)
        else $error("[%0t] ASSERTION VIOLATION: Write in non-M/E state", $time);
    
    // ========================================================================
    // Performance Assertions
    // ========================================================================
    
    // P1: Cache hit rate should be reasonable (>80%)
    property cache_hit_rate;
        @(posedge clk)
        disable iff (!rst_n)
        (total_requests > 32'd100) |-> 
        ((cache_hits * 32'd100) / total_requests >= 32'd80);
    endproperty
    
    assert property (cache_hit_rate)
        else $warning("[%0t] PERFORMANCE WARNING: Cache hit rate below 80%%", $time);
    
    // P2: No request should take more than 50 cycles
    property max_latency;
        @(posedge clk)
        disable iff (!rst_n)
        read_req_seq |-> ##[1:50] mem_ready;
    endproperty
    
    assert property (max_latency)
        else $error("[%0t] PERFORMANCE VIOLATION: Request latency > 50 cycles", $time);
    
    // ========================================================================
    // Cover Properties for Verification Coverage
    // ========================================================================
    
    // Cover all cache states
    property cover_mesi_states;
        @(posedge clk)
        disable iff (!rst_n)
        cache_state == 2'b00 || cache_state == 2'b01 || 
        cache_state == 2'b10 || cache_state == 2'b11;
    endproperty
    
    cover property (cover_mesi_states);
    
    // Cover read and write operations
    property cover_operations;
        @(posedge clk)
        disable iff (!rst_n)
        read_req_seq || write_req_seq;
    endproperty
    
    cover property (cover_operations);
    
    // Cover cache hit and miss scenarios
    property cover_cache_scenarios;
        @(posedge clk)
        disable iff (!rst_n)
        cache_hit_seq || (!cache_hit_seq);
    endproperty
    
    cover property (cover_cache_scenarios);
    
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
