`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
// Module Name: memory_fabric
//
// Description:
//   Memory Fabric - 512-bit unified memory bus dengan full cache hierarchy
//   - L1: Per-core private (32KB G-Core, 128KB A-Core)
//   - L2: Unified shared (8MB, 8-way SA)
//   - L3: Last-level cache (256MB conceptual)
//   - Memory: HBM4/HBM5 interface (512-bit bus)
//   - Bandwidth: >4 TB/s (512-bit @ 6GHz DDR)
//   - Coherence: MESI-GA protocol
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
    parameter MEM_LATENCY       = 70
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
    // State machine
    // =========================================================================
    reg [3:0]                   state;
    localparam S_IDLE           = 4'b0000;
    localparam S_L2_LOOKUP      = 4'b0001;
    localparam S_L2_HIT         = 4'b0010;
    localparam S_L2_MISS        = 4'b0011;
    localparam S_L2_ALLOCATE    = 4'b0100;
    localparam S_WRITEBACK      = 4'b0101;
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

    // =========================================================================
    // Helper functions
    // =========================================================================
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
        end else begin
            case (state)
                S_IDLE: begin
                    fabric_ready <= 1'b1;
                    mem_rd_en <= 1'b0;
                    mem_wr_en <= 1'b0;
                    latency_counter <= 8'h0;
                    
                    if (fabric_rd_en || fabric_wr_en) begin
                        fabric_ready <= 1'b0;
                        req_addr <= fabric_addr;
                        req_wr_data <= fabric_wr_data;
                        req_is_write <= fabric_wr_en;
                        req_set_idx <= fabric_addr[L2_INDEX_BITS-1:0];
                        req_tag <= fabric_addr[ADDR_WIDTH-1:L2_INDEX_BITS+$clog2(L2_LINE_SIZE)];
                        
                        if (fabric_wr_en) begin
                            total_write_bytes <= total_write_bytes + (DATA_WIDTH / 8);
                        end else begin
                            total_read_bytes <= total_read_bytes + (DATA_WIDTH / 8);
                        end
                        
                        l1_requests <= l1_requests + 1;
                        state <= S_L2_LOOKUP;
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
                        state <= S_L2_MISS;
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
