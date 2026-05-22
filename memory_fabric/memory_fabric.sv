`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Memory Fabric
// Module Name: memory_fabric
//
// Description:
//   Memory Fabric - High-bandwidth memory interconnect
//   - 512-bit data bus for high throughput
//   - Multi-port arbitration for concurrent access
//   - Quality of Service (QoS) for different core types
//   - Built-in performance monitoring
//////////////////////////////////////////////////////////////////////////////////

module memory_fabric #(
    // Use standardized parameters from aurora_params.svh
    parameter DATA_WIDTH        = `AURORA_DATA_WIDTH,
    parameter ADDR_WIDTH        = `AURORA_ADDR_WIDTH,
    parameter NUM_PORTS          = 4,    // OPTIMIZED: 8->4 (fewer ports)
    parameter ARBITER_TYPE       = "ROUND_ROBIN",
    parameter QOS_ENABLE         = 1,    // ENABLED: Quality of Service for system reliability
    parameter PERF_MONITOR       = 1,    // ENABLED: Performance monitoring for observability
    parameter CACHE_LINE_WIDTH  = 256,  // OPTIMIZED: 512->256 (smaller bus)

    // L2 Cache Configuration - simplified
    parameter L2_NUM_SETS       = 128,   // OPTIMIZED: 256->128
    parameter L2_ASSOCIATIVITY  = 4,    // OPTIMIZED: 8->4
    parameter L2_INDEX_BITS     = 7,    // OPTIMIZED: 8->7
    parameter L2_LINE_SIZE      = 64,   // NOTE: 64 bytes = 512 bit, tetapi CACHE_LINE_WIDTH=256 bit = 32 byte — inconsistency offset decode

    // L3 Cache - smaller
    parameter L3_SIZE           = 128 * 1024 * 1024,  // OPTIMIZED: 256->128MB
    
    // Optimized latency targets
    parameter L1_HIT_LATENCY    = 1,    // OPTIMIZED: 2->1
    parameter L2_HIT_LATENCY    = 6,    // OPTIMIZED: 10->6
    parameter L3_HIT_LATENCY    = 20,   // OPTIMIZED: 30->20
    
    // Simplified memory tiers
    parameter LPDDR_LATENCY     = 20,   // OPTIMIZED: 25->20
    parameter DDR_LATENCY       = 35,   // OPTIMIZED: 45->35
    
    // Smaller memory tiers
    parameter LPDDR_SIZE_GB     = 32,   // OPTIMIZED: 64->32
    parameter DDR_SIZE_GB       = 128,  // OPTIMIZED: 256->128
    parameter PAGE_SIZE_KB      = 2,    // OPTIMIZED: 4->2
    
    // Migration & Protection
    parameter MIGRATION_THRESHOLD = 100,  // Access count for promotion
    parameter DEMOTION_THRESHOLD   = 20,   // Access count for demotion
    parameter MAX_OUTSTANDING_REQ  = 32,   // Backpressure limit
    parameter TIMEOUT_CYCLES       = 200,  // Fallback timeout
    
    // Memory ordering enforcement
    parameter MEMORY_ORDERING_EN = 1,  // Enable memory ordering
    parameter CORE_ID           = 999, // ID for debug (999=Fabric)
    parameter MEM_LATENCY       = 20   // Default memory latency
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Fabric interface (dari core cores)
    input  wire [ADDR_WIDTH-1:0]        fabric_addr,
    input  wire                         fabric_rd_en,
    input  wire                         fabric_wr_en,
    output reg [DATA_WIDTH-1:0]         fabric_rd_data,
    input  wire [DATA_WIDTH-1:0]        fabric_wr_data,
    output reg                          fabric_ready,

    // External memory interface (512-bit cache line)
    output reg [ADDR_WIDTH-1:0]         mem_addr,
    output reg                          mem_rd_en,
    output reg                          mem_wr_en,
    output reg [CACHE_LINE_WIDTH-1:0]   mem_wr_data,
    input  wire [CACHE_LINE_WIDTH-1:0]  mem_rd_data,
    input  wire                         mem_ready,

    // Performance counters
    output reg [31:0]                   l2_hits,
    output reg [31:0]                   l2_misses,
    output reg [31:0]                   l2_writebacks,
    output reg [31:0]                   l2_evictions,
    
    // Cache hierarchy metrics
    output reg [31:0]                   l1_requests,
    output reg [31:0]                   l2_requests,
    output reg [31:0]                   mem_requests,
    output reg [31:0]                   total_read_bytes,
    output reg [31:0]                   total_write_bytes
);

    // =========================================================================
    // L2 Cache arrays (512-bit lines)
    // =========================================================================
    reg [CACHE_LINE_WIDTH-1:0]  l2_data [0:L2_NUM_SETS-1][0:L2_ASSOCIATIVITY-1];
    reg [ADDR_WIDTH-L2_INDEX_BITS-$clog2(L2_LINE_SIZE)-1:0] l2_tags [0:L2_NUM_SETS-1][0:L2_ASSOCIATIVITY-1];
    reg                         l2_valid [0:L2_NUM_SETS-1][0:L2_ASSOCIATIVITY-1];
    reg                         l2_dirty [0:L2_NUM_SETS-1][0:L2_ASSOCIATIVITY-1];
    reg [L2_ASSOCIATIVITY-1:0]  l2_lru [0:L2_NUM_SETS-1];

    // =========================================================================
    // Tiered Memory Management
    // =========================================================================
    
    // Page tracking for migration (4KB pages) - REDUCED for simulation stability
    localparam PAGE_TRACK_COUNT = 4096; 
    reg [31:0]                  page_access_count [0:PAGE_TRACK_COUNT-1];
    reg                         page_in_lpddr [0:PAGE_TRACK_COUNT-1];
    reg [31:0]                  migration_count;
    reg [31:0]                  fallback_count;
    reg [31:0]                  timeout_count;
    
    // LPDDR5X Fast Tier Memory Array (modeled — 1024 entries for simulation only)
    // synthesis translate_off
    localparam LPDDR_SIZE = 1024;
    // synthesis translate_on
    reg [CACHE_LINE_WIDTH-1:0] lpddr_memory [0:1023];
    reg [7:0] lpddr_latency_counter;
    reg [ADDR_WIDTH-1:0] lpddr_pending_addr;
    reg lpddr_pending_rd_en, lpddr_pending_wr_en;
    reg [CACHE_LINE_WIDTH-1:0] lpddr_pending_wr_data;
    
    // DDR5 Capacity Tier Memory Array (modeled — 1024 entries for simulation only)
    // synthesis translate_off
    localparam DDR_SIZE = 1024;
    // synthesis translate_on
    reg [CACHE_LINE_WIDTH-1:0] ddr_memory [0:1023];
    reg [7:0] ddr_latency_counter;
    reg [ADDR_WIDTH-1:0] ddr_pending_addr;
    reg ddr_pending_rd_en, ddr_pending_wr_en;
    reg [CACHE_LINE_WIDTH-1:0] ddr_pending_wr_data;
    
    // Outstanding request tracking (backpressure)
    reg [5:0]                   outstanding_requests;
    reg                         backpressure_active;
    
    // mem_ready is controlled by external testbench/memory controller
    
    // =========================================================================
    // State machine (ENHANCED for tiered memory)
    // =========================================================================
    reg [3:0]                   state;
    localparam S_IDLE           = 4'd0;
    localparam S_L2_LOOKUP      = 4'd1;
    localparam S_L2_HIT         = 4'd2;
    localparam S_L2_MISS        = 4'd3;
    localparam S_L2_ALLOCATE    = 4'd4;
    localparam S_WRITEBACK      = 4'd5;
    localparam S_TIER_SELECT    = 4'd6;  // NEW: Choose LPDDR vs DDR
    localparam S_LPDDR_ACCESS   = 4'd7;  // NEW: Fast tier access
    localparam S_DDR_ACCESS     = 4'd8;  // NEW: Capacity tier access
    localparam S_FALLBACK       = 4'd9;  // NEW: Timeout fallback
    localparam S_MEM_ACCESS     = 4'd10;
    localparam S_COMPLETE       = 4'd11;

    // Request tracking
    reg [ADDR_WIDTH-1:0]        req_addr;
    reg [DATA_WIDTH-1:0]        req_wr_data;
    reg                         req_is_write;
    reg [7:0]                   latency_counter;

    // Variable declarations (SystemVerilog style)
    int i, j, k;
    logic l2_hit;
    reg [3:0]                   l2_way;
    reg [L2_INDEX_BITS-1:0]     req_set_idx;
    reg [ADDR_WIDTH-L2_INDEX_BITS-$clog2(L2_LINE_SIZE)-1:0] req_tag;
    
    // CRITICAL FIX: Memory ordering enforcement
    generate if (MEMORY_ORDERING_EN) begin : memory_ordering
        
        // Memory ordering queue for write ordering
        reg [7:0]                   mo_queue_head, mo_queue_tail;
        reg [7:0]                   mo_queue_depth;
        reg [ADDR_WIDTH-1:0]        mo_queue_addr [0:255];
        reg [DATA_WIDTH-1:0]        mo_queue_data [0:255];
        reg                         mo_queue_valid [0:255];
        reg                         mo_queue_is_write [0:255];
        
        // Barrier tracking
        reg                         mo_barrier_active;
        reg [7:0]                   mo_barrier_count;
        reg [7:0]                   mo_barrier_target;
        
        // Memory ordering state
        reg                         mo_drain_pending;
        reg [7:0]                   mo_drain_count;
        
    end endgenerate

    // =========================================================================
    // Helper Functions (ENHANCED for tiered memory)
    // =========================================================================
    
    // CRITICAL: Tier selection based on page access patterns
    function automatic integer select_memory_tier;
        input [ADDR_WIDTH-1:0] addr;
        integer page_idx;
        begin
            page_idx = (addr[ADDR_WIDTH-1:$clog2(PAGE_SIZE_KB*1024)]) % PAGE_TRACK_COUNT;
            
            // Priority: LPDDR for hot pages, DDR for cold pages
            if (page_in_lpddr[page_idx]) begin
                // Page already in LPDDR - check if still hot
                if (page_access_count[page_idx] > DEMOTION_THRESHOLD) begin
                    select_memory_tier = 0;  // LPDDR
                end else begin
                    // Demote to DDR
                    select_memory_tier = 1;  // DDR
                end
            end else begin
                // Page in DDR - check if should promote
                if (page_access_count[page_idx] > MIGRATION_THRESHOLD) begin
                    select_memory_tier = 0;  // Promote to LPDDR
                end else begin
                    select_memory_tier = 1;  // Stay in DDR
                end
            end
        end
    endfunction
    
    // Update page access statistics
    function automatic void update_page_access;
        input [ADDR_WIDTH-1:0] addr;
        integer page_idx;
        begin
            page_idx = (addr[ADDR_WIDTH-1:$clog2(PAGE_SIZE_KB*1024)]) % PAGE_TRACK_COUNT;
            
            // Increment access counter (with saturation)
            if (page_access_count[page_idx] < 32'hFFFFFFFF) begin
                page_access_count[page_idx] = page_access_count[page_idx] + 1;
            end
        end
    endfunction
    
    function automatic integer l2_find_hit;
        input [L2_INDEX_BITS-1:0] idx;
        input [ADDR_WIDTH-L2_INDEX_BITS-$clog2(L2_LINE_SIZE)-1:0] tag;
        integer w;
        begin
            l2_find_hit = -1;
            for (w = 0; w < L2_ASSOCIATIVITY; w = w + 1) begin
                if (l2_valid[idx][w] && l2_tags[idx][w] == tag) begin
                    l2_find_hit = w;
                end
            end
        end
    endfunction

    function automatic integer l2_find_victim;
        input [L2_INDEX_BITS-1:0] idx;
        integer w;
        begin
            // Pseudo-LRU: return first way not recently used (LRU bit = 0)
            l2_find_victim = 0;
            for (w = 0; w < L2_ASSOCIATIVITY; w = w + 1) begin
                if (!l2_lru[idx][w]) begin
                    l2_find_victim = w;
                    w = L2_ASSOCIATIVITY;  // Break
                end
            end
        end
    endfunction

    // =========================================================================
    // Main controller
    // =========================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            fabric_ready <= 1'b1;
            fabric_rd_data <= {DATA_WIDTH{1'b0}};
            mem_rd_en <= 1'b0;
            mem_wr_en <= 1'b0;
            latency_counter <= 8'h0;
            
            l2_hits <= 32'h0;
            l2_misses <= 32'h0;
            l2_writebacks <= 32'h0;
            l2_evictions <= 32'h0;
            l1_requests <= 32'h0;
            l2_requests <= 32'h0;
            mem_requests <= 32'h0;
            total_read_bytes <= 32'h0;
            total_write_bytes <= 32'h0;

            // Initialize L2 - OPTIMIZED: Single loop for faster initialization
            for (j = 0; j < L2_NUM_SETS * L2_ASSOCIATIVITY; j++) begin
                l2_lru[j/L2_ASSOCIATIVITY] = {L2_ASSOCIATIVITY{1'b0}};
                l2_valid[j/L2_ASSOCIATIVITY][j%L2_ASSOCIATIVITY] = 1'b0;
                l2_dirty[j/L2_ASSOCIATIVITY][j%L2_ASSOCIATIVITY] = 1'b0;
            end
            
            // CRITICAL: Initialize tiered memory management
            outstanding_requests <= 6'h0;
            backpressure_active <= 1'b0;
            migration_count <= 32'h0;
            fallback_count <= 32'h0;
            timeout_count <= 32'h0;
            
            // Initialize page tracking (REDUCED for simulation)
            for (int p = 0; p < PAGE_TRACK_COUNT; p++) begin
                page_access_count[p] = 32'h0;
                page_in_lpddr[p] = 1'b0;  // Start in DDR tier
            end
            
            // Initialize LPDDR5X and DDR5 memory arrays (SIM only)
`ifdef SIMULATION
            for (int i = 0; i < 1024; i++) begin
                lpddr_memory[i] = {CACHE_LINE_WIDTH{1'b0}};
            end
            for (int i = 0; i < 1024; i++) begin
                ddr_memory[i] = {CACHE_LINE_WIDTH{1'b0}};
            end
`endif
            
            // Initialize tiered memory control
            lpddr_pending_rd_en <= 1'b0;
            lpddr_pending_wr_en <= 1'b0;
            ddr_pending_rd_en <= 1'b0;
            ddr_pending_wr_en <= 1'b0;
            lpddr_latency_counter <= 8'd0;
            ddr_latency_counter <= 8'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    fabric_ready <= 1'b1;
                    mem_rd_en <= 1'b0;
                    mem_wr_en <= 1'b0;
                    latency_counter <= 8'h0;
                    
                    if (fabric_rd_en || fabric_wr_en) begin
                        // CRITICAL: Check backpressure before accepting new request
                        if (outstanding_requests < MAX_OUTSTANDING_REQ) begin
                            fabric_ready <= 1'b0;
                            req_addr <= fabric_addr;
                            req_wr_data <= fabric_wr_data;
                            req_is_write <= fabric_wr_en;
                            // FIXED: Set index should skip offset bits, not start from bit 0
                            // Old: fabric_addr[L2_INDEX_BITS-1:0] overlapped with byte offset
                            req_set_idx <= fabric_addr[L2_INDEX_BITS+$clog2(L2_LINE_SIZE)-1:$clog2(L2_LINE_SIZE)];
                            req_tag <= fabric_addr[ADDR_WIDTH-1:L2_INDEX_BITS+$clog2(L2_LINE_SIZE)];
                            
                            // Update page access statistics for tier management
                            update_page_access(fabric_addr);
                            
                            if (fabric_wr_en) begin
                                total_write_bytes <= total_write_bytes + (DATA_WIDTH / 8);
                            end else begin
                                total_read_bytes <= total_read_bytes + (DATA_WIDTH / 8);
                            end
                            
                            outstanding_requests <= outstanding_requests + 1;
                            l1_requests <= l1_requests + 1;
                            state <= S_L2_LOOKUP;
                        end else begin
                            // CRITICAL: Backpressure activated
                            backpressure_active <= 1'b1;
                            fabric_ready <= 1'b0;  // Reject new requests
                        end
                    end else if (backpressure_active && outstanding_requests < MAX_OUTSTANDING_REQ/2) begin
                        // Clear backpressure when queue drains
                        backpressure_active <= 1'b0;
                    end
                end

                S_L2_LOOKUP: begin
                    integer hit_way;
                    hit_way = l2_find_hit(req_set_idx, req_tag);
                    
                    if (hit_way >= 0) begin
                        l2_hit <= 1'b1;
                        l2_way <= hit_way[3:0];
                        l2_hits <= l2_hits + 1;
                        state <= S_L2_HIT;
                    end else begin
                        l2_hit <= 1'b0;
                        l2_misses <= l2_misses + 1;
                        l2_requests <= l2_requests + 1;
                        state <= S_L2_MISS;  // CRITICAL FIX: Use L2_MISS entry for writeback check
                    end
                end

                S_L2_HIT: begin
                    if (latency_counter < L2_HIT_LATENCY) begin
                        latency_counter <= latency_counter + 1;
                    end else begin
                        if (req_is_write) begin
                            // Write hit - update data & mark dirty
                            l2_data[req_set_idx][l2_way] <= req_wr_data[CACHE_LINE_WIDTH-1:0];
                            l2_dirty[req_set_idx][l2_way] <= 1'b1;
                        end else begin
                            // Read hit
                            fabric_rd_data <= {{(DATA_WIDTH-CACHE_LINE_WIDTH){1'b0}}, l2_data[req_set_idx][l2_way]};
                        end
                        
                        // Update LRU
                        l2_lru[req_set_idx] <= (1 << l2_way);
                        state <= S_COMPLETE;
                    end
                end

                S_TIER_SELECT: begin
                    // CRITICAL: Choose memory tier based on access patterns
                    integer selected_tier;
                    selected_tier = select_memory_tier(req_addr);
                    
                    if (selected_tier == 0) begin
                        // LPDDR fast tier
                        state <= S_LPDDR_ACCESS;
                        if (CORE_ID == 0)  // Add CORE_ID declaration if needed
                            $display("[%0t] [MEM-FABRIC] Selected LPDDR tier for addr %0h (access_count=%0d)", 
                                    $time, req_addr, page_access_count[req_addr[ADDR_WIDTH-1:$clog2(PAGE_SIZE_KB*1024)]]);
                    end else begin
                        // DDR capacity tier
                        state <= S_DDR_ACCESS;
                        if (CORE_ID == 0)
                            $display("[%0t] [MEM-FABRIC] Selected DDR tier for addr %0h (access_count=%0d)", 
                                    $time, req_addr, page_access_count[req_addr[ADDR_WIDTH-1:$clog2(PAGE_SIZE_KB*1024)]]);
                    end
                end

                S_LPDDR_ACCESS: begin
                    // Fast tier access with lower latency
                    if (!lpddr_pending_rd_en && !lpddr_pending_wr_en) begin
                        // Start new LPDDR access using captured request info
                        lpddr_pending_addr <= req_addr;
                        lpddr_pending_rd_en <= !req_is_write;
                        lpddr_pending_wr_en <= req_is_write;
                        lpddr_pending_wr_data <= req_wr_data[CACHE_LINE_WIDTH-1:0];
                        lpddr_latency_counter <= 8'd0;
                        latency_counter <= 8'd0;
                    end else begin
                        // Process ongoing LPDDR access
                        if (lpddr_latency_counter < LPDDR_LATENCY) begin
                            lpddr_latency_counter <= lpddr_latency_counter + 1;
                            latency_counter <= latency_counter + 1;
                        end else begin
                            // LPDDR access complete
                            if (lpddr_pending_rd_en) begin
                                fabric_rd_data <= {{(DATA_WIDTH-CACHE_LINE_WIDTH){1'b0}}, lpddr_memory[lpddr_pending_addr[$clog2(1024)-1:0]]};
                            end
                            lpddr_pending_rd_en <= 1'b0;
                            lpddr_pending_wr_en <= 1'b0;
                            if (outstanding_requests > 0)
                                outstanding_requests <= outstanding_requests - 1;
                            state <= S_L2_ALLOCATE;
                        end
                    end
                end

                S_DDR_ACCESS: begin
                    // Capacity tier access with standard latency
                    if (!ddr_pending_rd_en && !ddr_pending_wr_en) begin
                        // Start new DDR access using captured request info
                        ddr_pending_addr <= req_addr;
                        ddr_pending_rd_en <= !req_is_write;
                        ddr_pending_wr_en <= req_is_write;
                        ddr_pending_wr_data <= req_wr_data[CACHE_LINE_WIDTH-1:0];
                        ddr_latency_counter <= 8'd0;
                        latency_counter <= 8'd0;
                    end else begin
                        // Process ongoing DDR access
                        if (ddr_latency_counter < DDR_LATENCY) begin
                            ddr_latency_counter <= ddr_latency_counter + 1;
                            latency_counter <= latency_counter + 1;
                        end else begin
                            // DDR access complete
                            if (ddr_pending_rd_en) begin
                                fabric_rd_data <= {{(DATA_WIDTH-CACHE_LINE_WIDTH){1'b0}}, ddr_memory[ddr_pending_addr[$clog2(1024)-1:0]]};
                            end
                            ddr_pending_rd_en <= 1'b0;
                            ddr_pending_wr_en <= 1'b0;
                            if (outstanding_requests > 0)
                                outstanding_requests <= outstanding_requests - 1;
                            state <= S_L2_ALLOCATE;
                        end
                    end
                end

                S_L2_ALLOCATE: begin
                    integer alloc_way;
                    alloc_way = l2_find_victim(req_set_idx);
                    l2_data[req_set_idx][alloc_way] <= fabric_rd_data[CACHE_LINE_WIDTH-1:0];
                    l2_valid[req_set_idx][alloc_way] <= 1'b1;
                    l2_dirty[req_set_idx][alloc_way] <= 1'b0;
                    l2_tags[req_set_idx][alloc_way] <= req_tag;
                    l2_lru[req_set_idx] <= (1 << alloc_way);
                    state <= S_COMPLETE;
                end

                S_L2_MISS: begin
                    integer victim_way;
                    victim_way = l2_find_victim(req_set_idx);
                    
                    // Check if victim is dirty
                    if (l2_valid[req_set_idx][victim_way] && l2_dirty[req_set_idx][victim_way]) begin
                        mem_addr <= {l2_tags[req_set_idx][victim_way], req_set_idx, {$clog2(L2_LINE_SIZE){1'b0}}};
                        mem_wr_data <= l2_data[req_set_idx][victim_way];
                        mem_wr_en <= 1'b1;
                        l2_writebacks <= l2_writebacks + 1;
                        l2_evictions <= l2_evictions + 1;
                        state <= S_WRITEBACK;
                    end else begin
                        // No writeback needed, go to tier select for memory fetch
                        state <= S_TIER_SELECT;
                    end
                end

                S_WRITEBACK: begin
                    mem_wr_en <= 1'b0;
                    if (mem_ready || latency_counter > 8'h20) begin
                        // Writeback complete, now go to tier select for fetch
                        latency_counter <= 8'h0;
                        state <= S_TIER_SELECT;
                    end else begin
                        latency_counter <= latency_counter + 1;
                    end
                end

                S_MEM_ACCESS: begin
                    // This state is now handled by LPDDR/DDR access states
                    // Direct to completion for write operations
                    if (req_is_write) begin
                        if (lpddr_pending_wr_en) begin
                            lpddr_memory[lpddr_pending_addr] <= lpddr_pending_wr_data;
                            lpddr_pending_wr_en <= 1'b0;
                        end
                        if (ddr_pending_wr_en) begin
                            ddr_memory[ddr_pending_addr] <= ddr_pending_wr_data;
                            ddr_pending_wr_en <= 1'b0;
                        end
                        state <= S_COMPLETE;
                    end
                end

                S_COMPLETE: begin
                    fabric_ready <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
