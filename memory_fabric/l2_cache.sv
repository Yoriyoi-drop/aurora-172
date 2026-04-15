`timescale 1ns / 1ps

// verilator lint_off CASEINCOMPLETE

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Memory Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 L2 Unified Cache
// Module Name: l2_cache
//
// Description:
//   L2 Cache - Shared unified cache with MESI coherence controller
//   - 8-way set associative (8MB total)
//   - MESI coherence protocol (Modified, Exclusive, Shared, Invalid)
//   - Write-back, write-allocate policy
//   - 64-byte cache lines
//   - Snoop-based coherence with L1 caches
//   - Victim cache for evicted lines
//
// Target: Shared coherence point for all L1 caches
//////////////////////////////////////////////////////////////////////////////////

module l2_cache #(
    parameter DATA_WIDTH    = 64,
    parameter ADDR_WIDTH    = 48,
    parameter CACHE_SIZE    = 8 * 1024 * 1024,  // 8MB L2
    parameter ASSOCIATIVITY = 8,                // 8-way set associative
    parameter LINE_SIZE     = 64,               // UPGRADED: 32→64 bytes (512-bit, match memory bus)
    parameter NUM_L1_PORTS  = 3                 // G-Core, A-Core, NPU ports
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // L1 port 0: G-Core interface
    input  wire [ADDR_WIDTH-1:0]        l1_0_addr,
    input  wire [LINE_SIZE-1:0]         l1_0_wr_data,
    input  wire                         l1_0_rd_en,
    input  wire                         l1_0_wr_en,
    output reg [LINE_SIZE-1:0]          l1_0_rd_data,
    output reg                          l1_0_ready,

    // L1 port 1: A-Core interface
    input  wire [ADDR_WIDTH-1:0]        l1_1_addr,
    input  wire [LINE_SIZE-1:0]         l1_1_wr_data,
    input  wire                         l1_1_rd_en,
    input  wire                         l1_1_wr_en,
    output reg [LINE_SIZE-1:0]          l1_1_rd_data,
    output reg                          l1_1_ready,

    // L1 port 2: NPU interface
    input  wire [ADDR_WIDTH-1:0]        l1_2_addr,
    input  wire [LINE_SIZE-1:0]         l1_2_wr_data,
    input  wire                         l1_2_rd_en,
    input  wire                         l1_2_wr_en,
    output reg [LINE_SIZE-1:0]          l1_2_rd_data,
    output reg                          l1_2_ready,

    // External memory interface (to memory fabric / DDR)
    output reg [ADDR_WIDTH-1:0]         mem_addr,
    output reg [LINE_SIZE-1:0]          mem_wr_data,
    output reg                          mem_rd_en,
    output reg                          mem_wr_en,
    input  wire [LINE_SIZE-1:0]         mem_rd_data,
    input  wire                         mem_ready,

    // Snoop broadcast to L1 caches
    output reg [ADDR_WIDTH-1:0]         snoop_addr,
    output reg                          snoop_invalidate,
    output reg                          snoop_update,

    // Performance counters
    output reg [31:0]                   l2_hits,
    output reg [31:0]                   l2_misses,
    output reg [31:0]                   l2_writebacks,
    output reg [31:0]                   l2_evictions,
    output reg [31:0]                   snoop_invalidations
);

    // =========================================================================
    // Cache organization
    // =========================================================================
    localparam NUM_SETS = CACHE_SIZE / (LINE_SIZE * ASSOCIATIVITY);
    localparam SET_IDX_WIDTH = $clog2(NUM_SETS);
    localparam TAG_WIDTH = ADDR_WIDTH - SET_IDX_WIDTH - $clog2(LINE_SIZE);

    // Cache arrays
    reg [LINE_SIZE-1:0]       cache_data [0:ASSOCIATIVITY-1][0:NUM_SETS-1];
    reg [TAG_WIDTH-1:0]       cache_tags [0:ASSOCIATIVITY-1][0:NUM_SETS-1];
    reg [1:0]                 cache_mesi [0:ASSOCIATIVITY-1][0:NUM_SETS-1];
    reg                       cache_valid [0:ASSOCIATIVITY-1][0:NUM_SETS-1];
    // FIX v2: Replace LRU bitmask with per-entry timestamp counter for true LRU
    reg [7:0]                 lru_timestamp [0:ASSOCIATIVITY-1][0:NUM_SETS-1];
    reg [7:0]                 lru_age_counter;

    // MESI state encoding
    localparam MESI_INVALID   = 2'b00;
    localparam MESI_MODIFIED  = 2'b01;
    localparam MESI_EXCLUSIVE = 2'b10;
    localparam MESI_SHARED    = 2'b11;

    // Victim cache (4 entries for evicted lines)
    reg [LINE_SIZE-1:0]       victim_data [0:3];
    reg [TAG_WIDTH-1:0]       victim_tags [0:3];
    reg                       victim_valid [0:3];
    // FIX v2: Replace bitmask LRU with per-entry timestamp counter for victim cache
    reg [7:0]                 victim_timestamp [0:3];

    // =========================================================================
    // Internal state machine
    // =========================================================================
    reg [3:0]                 state;
    localparam S_IDLE         = 4'b0000;
    localparam S_ARBITRATE    = 4'b0001;
    localparam S_HIT_CHECK    = 4'b0010;
    localparam S_SNOOP_CHECK  = 4'b0011;
    localparam S_MISS_FETCH   = 4'b0100;
    localparam S_WRITEBACK    = 4'b0101;
    localparam S_VICTIM_CHECK = 4'b0110;
    localparam S_COMPLETE_RD  = 4'b0111;
    localparam S_COMPLETE_WR  = 4'b1000;

    // Current request tracking
    reg [ADDR_WIDTH-1:0]      current_addr;
    reg [LINE_SIZE-1:0]       current_wr_data;
    reg                       current_is_write;
    reg [1:0]                 current_port;  // Which L1 port requested

    // MEDIUM FIX #4: Timeout counter for S_WRITEBACK state
    reg [7:0]                 writeback_timeout_counter;

    // Hit detection
    integer                   hit_way;
    reg                       is_hit;

    // Timeout victim way cache (declared at top level for synthesis)
    integer                   timeout_victim_way;

    // =========================================================================
    // Address decoding
    // =========================================================================
    wire [$clog2(LINE_SIZE)-1:0]  line_offset = current_addr[$clog2(LINE_SIZE)-1:0];
    wire [SET_IDX_WIDTH-1:0]      set_index   = current_addr[$clog2(LINE_SIZE) +: SET_IDX_WIDTH];
    wire [TAG_WIDTH-1:0]          tag           = current_addr[ADDR_WIDTH-1 -: TAG_WIDTH];

    // =========================================================================
    // Cache access functions
    // =========================================================================
    function automatic integer find_hit_way;
        input [SET_IDX_WIDTH-1:0] idx;
        input [TAG_WIDTH-1:0] t;
        integer w;
        begin
            find_hit_way = -1;
            for (w = 0; w < ASSOCIATIVITY; w = w + 1) begin
                if (cache_valid[w][idx] && cache_tags[w][idx] == t &&
                    cache_mesi[w][idx] != MESI_INVALID) begin
                    find_hit_way = w;
                end
            end
        end
    endfunction

    // FIX v2: True LRU victim selection using per-entry timestamp counters
    function automatic integer find_victim_way;
        input [SET_IDX_WIDTH-1:0] idx;
        integer w;
        integer oldest_way;
        integer oldest_ts;
        begin
            oldest_way = 0;
            oldest_ts = lru_timestamp[0][idx];
            for (w = 1; w < ASSOCIATIVITY; w = w + 1) begin
                if (lru_timestamp[w][idx] < oldest_ts) begin
                    oldest_ts = lru_timestamp[w][idx];
                    oldest_way = w;
                end
            end
            find_victim_way = oldest_way;
        end
    endfunction

    function automatic integer find_victim_cache;
        input [TAG_WIDTH-1:0] t;
        integer v;
        begin
            find_victim_cache = -1;
            for (v = 0; v < 4; v = v + 1) begin
                if (victim_valid[v] && victim_tags[v] == t) begin
                    find_victim_cache = v;
                end
            end
        end
    endfunction

    // FIX v2: Find LRU victim cache entry using per-entry timestamp
    function automatic integer find_victim_cache_lru;
        integer v;
        int oldest_v;
        int oldest_ts;
        begin
            oldest_v = 0;
            oldest_ts = victim_timestamp[0];
            for (v = 1; v < 4; v = v + 1) begin
                if (victim_timestamp[v] < oldest_ts) begin
                    oldest_ts = victim_timestamp[v];
                    oldest_v = v;
                end
            end
            find_victim_cache_lru = oldest_v;
        end
    endfunction

    // =========================================================================
    // FIX v2: Round-robin arbitration with last_granted register
    // Replaces fixed priority (G>A>NPU) with fair round-robin
    // =========================================================================
    reg [1:0]                 last_granted;
    reg [1:0]                 active_port;
    wire                      port_0_active = l1_0_rd_en || l1_0_wr_en;
    wire                      port_1_active = l1_1_rd_en || l1_1_wr_en;
    wire                      port_2_active = l1_2_rd_en || l1_2_wr_en;

    // FIX v2: Round-robin arbitration - next priority rotates based on last_granted
    function automatic logic [1:0] arbitrate;
        // Start searching from the port after last_granted
        case (last_granted)
            2'b00: begin
                // Last was G-Core, try A-Core > NPU > G-Core
                if (port_1_active)      arbitrate = 2'b01;
                else if (port_2_active) arbitrate = 2'b10;
                else if (port_0_active) arbitrate = 2'b00;
                else                    arbitrate = 2'b11;
            end
            2'b01: begin
                // Last was A-Core, try NPU > G-Core > A-Core
                if (port_2_active)      arbitrate = 2'b10;
                else if (port_0_active) arbitrate = 2'b00;
                else if (port_1_active) arbitrate = 2'b01;
                else                    arbitrate = 2'b11;
            end
            2'b10: begin
                // Last was NPU, try G-Core > A-Core > NPU
                if (port_0_active)      arbitrate = 2'b00;
                else if (port_1_active) arbitrate = 2'b01;
                else if (port_2_active) arbitrate = 2'b10;
                else                    arbitrate = 2'b11;
            end
            default: begin
                // No last grant, use default order: G > A > NPU
                if (port_0_active)      arbitrate = 2'b00;
                else if (port_1_active) arbitrate = 2'b01;
                else if (port_2_active) arbitrate = 2'b10;
                else                    arbitrate = 2'b11;
            end
        endcase
    endfunction

    // =========================================================================
    // Main L2 controller
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            l1_0_ready <= 1'b1;
            l1_1_ready <= 1'b1;
            l1_2_ready <= 1'b1;
            l1_0_rd_data <= {LINE_SIZE{1'b0}};
            l1_1_rd_data <= {LINE_SIZE{1'b0}};
            l1_2_rd_data <= {LINE_SIZE{1'b0}};
            mem_rd_en <= 1'b0;
            mem_wr_en <= 1'b0;
            snoop_invalidate <= 1'b0;
            snoop_update <= 1'b0;
            l2_hits <= 32'h0;
            l2_misses <= 32'h0;
            l2_writebacks <= 32'h0;
            l2_evictions <= 32'h0;
            snoop_invalidations <= 32'h0;
            victim_valid[0] <= 1'b0;
            victim_valid[1] <= 1'b0;
            victim_valid[2] <= 1'b0;
            victim_valid[3] <= 1'b0;
            // FIX v2: Initialize round-robin arbitration state
            last_granted <= 2'b11;
            lru_age_counter <= 8'b0;
            writeback_timeout_counter <= 8'b0;
        end else begin
            snoop_invalidate <= 1'b0;
            snoop_update <= 1'b0;
            // FIX v2: Increment LRU age counter for timestamp-based replacement
            lru_age_counter <= lru_age_counter + 1;

            case (state)
                S_IDLE: begin
                    l1_0_ready <= 1'b1;
                    l1_1_ready <= 1'b1;
                    l1_2_ready <= 1'b1;
                    mem_rd_en <= 1'b0;
                    mem_wr_en <= 1'b0;

                    active_port = arbitrate();

                    if (active_port != 2'b11) begin
                        // FIX v2: Update last_granted for round-robin rotation
                        last_granted <= active_port;

                        // Accept request
                        l1_0_ready <= (active_port == 2'b00) ? 1'b0 : 1'b1;
                        l1_1_ready <= (active_port == 2'b01) ? 1'b0 : 1'b1;
                        l1_2_ready <= (active_port == 2'b10) ? 1'b0 : 1'b1;

                        case (active_port)
                            2'b00: begin
                                current_addr <= l1_0_addr;
                                current_wr_data <= l1_0_wr_data;
                                current_is_write <= l1_0_wr_en;
                            end
                            2'b01: begin
                                current_addr <= l1_1_addr;
                                current_wr_data <= l1_1_wr_data;
                                current_is_write <= l1_1_wr_en;
                            end
                            2'b10: begin
                                current_addr <= l1_2_addr;
                                current_wr_data <= l1_2_wr_data;
                                current_is_write <= l1_2_wr_en;
                            end
                        endcase

                        current_port <= active_port;
                        state <= S_HIT_CHECK;
                    end
                end

                S_HIT_CHECK: begin
                    integer victim_hit;
                    hit_way = find_hit_way(set_index, tag);
                    is_hit = (hit_way >= 0);

                    if (is_hit) begin
                        l2_hits <= l2_hits + 1;

                        if (current_is_write) begin
                            // Write hit
                            if (cache_mesi[hit_way][set_index] == MESI_SHARED) begin
                                // Broadcast invalidate to other L1s
                                snoop_addr <= current_addr;
                                snoop_invalidate <= 1'b1;
                                snoop_invalidations <= snoop_invalidations + 1;
                            end

                            cache_mesi[hit_way][set_index] <= MESI_MODIFIED;

                            // Write full cache line
                            cache_data[hit_way][set_index] <= current_wr_data;

                            // FIX v2: Update LRU timestamp to current age (most recently used)
                            lru_timestamp[hit_way][set_index] <= lru_age_counter;
                            state <= S_COMPLETE_WR;
                        end else begin
                            // Read hit
                            case (current_port)
                                2'b00: l1_0_rd_data <= cache_data[hit_way][set_index];
                                2'b01: l1_1_rd_data <= cache_data[hit_way][set_index];
                                2'b10: l1_2_rd_data <= cache_data[hit_way][set_index];
                            endcase

                            // FIX v2: Update LRU timestamp to current age
                            lru_timestamp[hit_way][set_index] <= lru_age_counter;
                            state <= S_COMPLETE_RD;
                        end
                    end else begin
                        l2_misses <= l2_misses + 1;

                        // Check victim cache first
                        victim_hit = find_victim_cache(tag);
                        if (victim_hit >= 0) begin
                            // Victim cache hit
                            case (current_port)
                                2'b00: l1_0_rd_data <= victim_data[victim_hit];
                                2'b01: l1_1_rd_data <= victim_data[victim_hit];
                                2'b10: l1_2_rd_data <= victim_data[victim_hit];
                            endcase
                            // FIX v2: Update victim LRU timestamp
                            victim_timestamp[victim_hit] <= lru_age_counter;
                            state <= S_COMPLETE_RD;
                        end else begin
                            state <= S_MISS_FETCH;
                        end
                    end
                end

                S_MISS_FETCH: begin
                    // Find victim way for eviction
                    integer victim_way;
                    victim_way = find_victim_way(set_index);

                    // Check if victim is dirty
                    if (cache_valid[victim_way][set_index] &&
                        cache_mesi[victim_way][set_index] == MESI_MODIFIED) begin
                        // Writeback dirty line to memory
                        mem_addr <= {cache_tags[victim_way][set_index], set_index, {$clog2(LINE_SIZE){1'b0}}};
                        mem_wr_data <= cache_data[victim_way][set_index];
                        mem_wr_en <= 1'b1;
                        l2_writebacks <= l2_writebacks + 1;
                        state <= S_WRITEBACK;
                    end else begin
                        // Fetch from memory
                        mem_addr <= {tag, set_index, {$clog2(LINE_SIZE){1'b0}}};
                        mem_rd_en <= 1'b1;
                        state <= S_VICTIM_CHECK;
                    end
                end

                S_WRITEBACK: begin
                    mem_wr_en <= 1'b0;
                    // MEDIUM FIX #4: Add 128-cycle timeout to prevent permanent stall
                    // victim_way is the way we just wrote back from S_MISS_FETCH
                    if (mem_ready) begin
                        writeback_timeout_counter <= 8'h0;  // Reset counter
                        // Now fetch new line
                        mem_addr <= {tag, set_index, {$clog2(LINE_SIZE){1'b0}}};
                        mem_rd_en <= 1'b1;
                        state <= S_VICTIM_CHECK;
                    end else if (writeback_timeout_counter >= 8'd128) begin
                        // TIMEOUT: Memory not ready, abort writeback and force error recovery
                        $display("[%0t] [L2-CACHE] S_WRITEBACK TIMEOUT: mem_ready not asserted after 128 cycles", $time);
                        writeback_timeout_counter <= 8'h0;
                        // Invalidate the victim line to prevent corruption
                        // Note: victim_way was set in S_MISS_FETCH before transitioning here
                        timeout_victim_way = find_victim_way(set_index);
                        cache_valid[timeout_victim_way][set_index] <= 1'b0;
                        state <= S_IDLE;
                    end else begin
                        writeback_timeout_counter <= writeback_timeout_counter + 1;
                    end
                end

                S_VICTIM_CHECK: begin
                    integer victim_way;
                    integer v;
                    integer victim_cache_lru;
                    mem_rd_en <= 1'b0;
                    // CRITICAL FIX NEW-5: Add 128-cycle timeout (same as S_WRITEBACK)
                    if (mem_ready) begin
                        writeback_timeout_counter <= 8'h0;  // Reset counter
                        victim_way = find_victim_way(set_index);

                        // Move old victim to victim cache if valid
                        if (cache_valid[victim_way][set_index]) begin
                            // FIX v2: Use timestamp-based LRU to find oldest victim entry to replace
                            victim_cache_lru = find_victim_cache_lru();
                            victim_data[victim_cache_lru] = cache_data[victim_way][set_index];
                            victim_tags[victim_cache_lru] = cache_tags[victim_way][set_index];
                            victim_valid[victim_cache_lru] = 1'b1;
                            victim_timestamp[victim_cache_lru] = lru_age_counter;
                            l2_evictions <= l2_evictions + 1;
                        end

                        // Fill from memory
                        cache_data[victim_way][set_index] <= mem_rd_data;
                        cache_tags[victim_way][set_index] <= tag;
                        cache_valid[victim_way][set_index] <= 1'b1;

                        if (current_is_write) begin
                            cache_mesi[victim_way][set_index] <= MESI_MODIFIED;
                            cache_data[victim_way][set_index] <= current_wr_data;
                        end else begin
                            cache_mesi[victim_way][set_index] <= MESI_SHARED;
                            case (current_port)
                                2'b00: l1_0_rd_data <= mem_rd_data;
                                2'b01: l1_1_rd_data <= mem_rd_data;
                                2'b10: l1_2_rd_data <= mem_rd_data;
                            endcase
                        end

                        // FIX v2: Update LRU timestamp for newly filled way
                        lru_timestamp[victim_way][set_index] <= lru_age_counter;

                        if (current_is_write)
                            state <= S_COMPLETE_WR;
                        else
                            state <= S_COMPLETE_RD;
                    end else if (writeback_timeout_counter >= 8'd128) begin
                        // TIMEOUT: Memory not ready, abort and return to IDLE
                        $display("[%0t] [L2-CACHE] S_VICTIM_CHECK TIMEOUT: mem_ready not asserted after 128 cycles", $time);
                        writeback_timeout_counter <= 8'h0;
                        state <= S_IDLE;
                    end else begin
                        writeback_timeout_counter <= writeback_timeout_counter + 1;
                    end
                end

                S_COMPLETE_RD: begin
                    case (current_port)
                        2'b00: l1_0_ready <= 1'b1;
                        2'b01: l1_1_ready <= 1'b1;
                        2'b10: l1_2_ready <= 1'b1;
                    endcase
                    state <= S_IDLE;
                end

                S_COMPLETE_WR: begin
                    case (current_port)
                        2'b00: l1_0_ready <= 1'b1;
                        2'b01: l1_1_ready <= 1'b1;
                        2'b10: l1_2_ready <= 1'b1;
                    endcase
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule
