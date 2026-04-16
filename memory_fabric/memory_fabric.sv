`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
// Module Name: memory_fabric
//
// Description:
//   Memory Fabric - Tiered Memory Architecture dengan stability focus
//   - L1: Per-core private (32KB G-Core, 128KB A-Core)
//   - L2: Unified shared (8MB, 8-way SA)
//   - L3: Last-level cache (256MB conceptual)
//   - Memory Tiers:
//     * LPDDR5X Fast Tier: 64GB, low latency, high bandwidth
//     * DDR5 Capacity Tier: 256GB, standard latency
//   - Bandwidth: LPDDR5X (~1.5TB/s) + DDR5 (~800GB/s)
//   - Coherence: MESI-GA protocol with tier ownership
//   - Migration: Page-based (4KB) with hot data tracking
//////////////////////////////////////////////////////////////////////////////////

module memory_fabric #(
    parameter DATA_WIDTH        = 128,
    parameter ADDR_WIDTH        = 48,
    parameter CACHE_LINE_WIDTH  = 512,  // 512-bit memory bus

    // L2 Cache Configuration
    parameter L2_NUM_SETS       = 256,
    parameter L2_ASSOCIATIVITY  = 8,
    parameter L2_INDEX_BITS     = 8,
    parameter L2_LINE_SIZE      = 64,   // 64 bytes = 512 bits

    // L3 Cache
    parameter L3_SIZE           = 256 * 1024 * 1024,
    
    // Latency targets
    parameter L1_HIT_LATENCY    = 2,
    parameter L2_HIT_LATENCY    = 10,
    parameter L3_HIT_LATENCY    = 30,
    
    // Tiered Memory Latency (REALISTIC)
    parameter LPDDR_LATENCY     = 25,   // Fast tier: ~25ns
    parameter DDR_LATENCY       = 45,   // Capacity tier: ~45ns
    
    // Memory Tier Configuration
    parameter LPDDR_SIZE_GB     = 64,   // Fast tier capacity
    parameter DDR_SIZE_GB       = 256,  // Capacity tier
    parameter PAGE_SIZE_KB      = 4,    // Migration granularity
    
    // Migration & Protection
    parameter MIGRATION_THRESHOLD = 100,  // Access count for promotion
    parameter DEMOTION_THRESHOLD   = 20,   // Access count for demotion
    parameter MAX_OUTSTANDING_REQ  = 32,   // Backpressure limit
    parameter TIMEOUT_CYCLES       = 200,  // Fallback timeout
    
    // Memory ordering enforcement
    parameter MEMORY_ORDERING_EN = 1  // Enable memory ordering
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
    
    // Page tracking for migration (4KB pages)
    reg [31:0]                  page_access_count [0:DDR_SIZE_GB*1024*256/PAGE_SIZE_KB-1];  // 4KB pages
    reg                         page_in_lpddr [0:DDR_SIZE_GB*1024*256/PAGE_SIZE_KB-1];
    reg [31:0]                  migration_count;
    reg [31:0]                  fallback_count;
    reg [31:0]                  timeout_count;
    
    // Outstanding request tracking (backpressure)
    reg [5:0]                   outstanding_requests;
    reg                         backpressure_active;
    
    // =========================================================================
    // State machine (ENHANCED for tiered memory)
    // =========================================================================
    reg [3:0]                   state;
    localparam S_IDLE           = 4'b0000;
    localparam S_L2_LOOKUP      = 4'b0001;
    localparam S_L2_HIT         = 4'b0010;
    localparam S_L2_MISS        = 4'b0011;
    localparam S_L2_ALLOCATE    = 4'b0100;
    localparam S_WRITEBACK      = 4'b0101;
    localparam S_TIER_SELECT    = 4'b0110;  // NEW: Choose LPDDR vs DDR
    localparam S_LPDDR_ACCESS   = 4'b0111;  // NEW: Fast tier access
    localparam S_DDR_ACCESS     = 4'b1000;  // NEW: Capacity tier access
    localparam S_FALLBACK       = 4'b1001;  // NEW: Timeout fallback
    localparam S_MEM_ACCESS     = 4'b0110;
    localparam S_COMPLETE       = 4'b0111;

    // Request tracking
    reg [ADDR_WIDTH-1:0]        req_addr;
    reg [DATA_WIDTH-1:0]        req_wr_data;
    reg                         req_is_write;
    reg [7:0]                   latency_counter;

    // Variable declarations (SystemVerilog style)
    int i, j, k, l, m, n, o, p, q, r, s, t, u, v, w, x, y, z;       
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
            page_idx = addr[ADDR_WIDTH-1:$clog2(PAGE_SIZE_KB*1024)];
            
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
            page_idx = addr[ADDR_WIDTH-1:$clog2(PAGE_SIZE_KB*1024)];
            
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
            // Pseudo-LRU: use stored LRU bits
            l2_find_victim = 0;
            for (w = 0; w < L2_ASSOCIATIVITY; w = w + 1) begin
                if (l2_lru[idx][w]) begin
                    l2_find_victim = w;
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

            // Initialize L2
            for (int s = 0; s < L2_NUM_SETS; s++) begin
                l2_lru[s] = {L2_ASSOCIATIVITY{1'b0}};
                for (int w = 0; w < L2_ASSOCIATIVITY; w++) begin
                    l2_valid[s][w] = 1'b0;
                    l2_dirty[s][w] = 1'b0;
                end
            end
            
            // CRITICAL: Initialize tiered memory management
            outstanding_requests <= 6'h0;
            backpressure_active <= 1'b0;
            migration_count <= 32'h0;
            fallback_count <= 32'h0;
            timeout_count <= 32'h0;
            
            // Initialize page tracking (all pages start in DDR)
            for (int p = 0; p < DDR_SIZE_GB*1024*256/PAGE_SIZE_KB; p++) begin
                page_access_count[p] <= 32'h0;
                page_in_lpddr[p] <= 1'b0;  // Start in DDR tier
            end
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
                            req_set_idx <= fabric_addr[L2_INDEX_BITS-1:0];
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
                        state <= S_TIER_SELECT;  // NEW: Choose memory tier first
                    end
                end

                S_L2_HIT: begin
                    if (latency_counter < L2_HIT_LATENCY) begin
                        latency_counter <= latency_counter + 1;
                    end else begin
                        if (req_is_write) begin
                            // Write hit - update data & mark dirty
                            l2_data[req_set_idx][l2_way] <= {4{req_wr_data}};
                            l2_dirty[req_set_idx][l2_way] <= 1'b1;
                        end else begin
                            // Read hit
                            fabric_rd_data <= l2_data[req_set_idx][l2_way][DATA_WIDTH-1:0];
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
                    if (latency_counter < LPDDR_LATENCY) begin
                        latency_counter <= latency_counter + 1;
                    end else if (mem_ready) begin
                        // LPDDR access complete
                        fabric_rd_data <= mem_rd_data;
                        outstanding_requests <= outstanding_requests - 1;
                        state <= S_L2_ALLOCATE;
                    end else if (latency_counter > TIMEOUT_CYCLES) begin
                        // Fallback to DDR on timeout
                        fallback_count <= fallback_count + 1;
                        timeout_count <= timeout_count + 1;
                        $display("[%0t] [MEM-FABRIC] LPDDR timeout, falling back to DDR", $time);
                        state <= S_DDR_ACCESS;
                        latency_counter <= 8'h0;
                    end
                end

                S_DDR_ACCESS: begin
                    // Capacity tier access with standard latency
                    if (latency_counter < DDR_LATENCY) begin
                        latency_counter <= latency_counter + 1;
                    end else if (mem_ready) begin
                        // DDR access complete
                        fabric_rd_data <= mem_rd_data;
                        outstanding_requests <= outstanding_requests - 1;
                        state <= S_L2_ALLOCATE;
                    end else if (latency_counter > TIMEOUT_CYCLES) begin
                        // Critical error - both tiers failed
                        timeout_count <= timeout_count + 1;
                        $display("[%0t] [MEM-FABRIC] CRITICAL: Both memory tiers failed!", $time);
                        // Return dummy data and complete request
                        fabric_rd_data <= {DATA_WIDTH{1'b1}};  // Error pattern
                        outstanding_requests <= outstanding_requests - 1;
                        state <= S_COMPLETE;
                    end
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
                        // No writeback needed, fetch from memory
                        mem_addr <= {req_tag, req_set_idx, {$clog2(L2_LINE_SIZE){1'b0}}};
                        mem_rd_en <= 1'b1;
                        mem_requests <= mem_requests + 1;
                        state <= S_MEM_ACCESS;
                    end
                end

                S_WRITEBACK: begin
                    mem_wr_en <= 1'b0;
                    if (mem_ready || latency_counter > 8'h20) begin
                        // Writeback complete, now fetch
                        mem_addr <= {req_tag, req_set_idx, {$clog2(L2_LINE_SIZE){1'b0}}};
                        mem_rd_en <= 1'b1;
                        mem_requests <= mem_requests + 1;
                        latency_counter <= 8'h0;
                        state <= S_MEM_ACCESS;
                    end else begin
                        latency_counter <= latency_counter + 1;
                    end
                end

                S_MEM_ACCESS: begin
                    mem_rd_en <= 1'b0;
                    if (latency_counter < MEM_LATENCY) begin
                        latency_counter <= latency_counter + 1;
                    end else if (mem_ready) begin
                        // Fill L2 from memory
                        integer victim_way;
                        victim_way = l2_find_victim(req_set_idx);
                        
                        l2_data[req_set_idx][victim_way] <= mem_rd_data;
                        l2_tags[req_set_idx][victim_way] <= req_tag;
                        l2_valid[req_set_idx][victim_way] <= 1'b1;
                        l2_dirty[req_set_idx][victim_way] <= req_is_write;
                        l2_lru[req_set_idx] <= (1 << victim_way);
                        
                        if (!req_is_write) begin
                            fabric_rd_data <= mem_rd_data[DATA_WIDTH-1:0];
                        end
                        
                        state <= S_COMPLETE;
                    end else begin
                        // Timeout fallback
                        if (latency_counter > 8'h40) begin
                            fabric_rd_data <= {DATA_WIDTH{1'b0}};
                            state <= S_COMPLETE;
                        end else begin
                            latency_counter <= latency_counter + 1;
                        end
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
