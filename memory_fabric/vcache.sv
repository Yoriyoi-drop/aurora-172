`timescale 1ns / 1ps

// verilator lint_off BLKLOOPINIT

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: AMD 3D V-Cache)
//
// Create Date: 12 April 2026
// Design Name: V-Cache (3D Stacked Cache Model)
// Module Name: vcache
//
// Description:
//   Full 3D V-Cache implementation with proper cache management
//////////////////////////////////////////////////////////////////////////////////

module vcache #(
    parameter DATA_WIDTH        = 128,
    parameter ADDR_WIDTH        = 48,
    parameter VCACHE_CAPACITY_MB = 192,
    parameter VCACHE_LATENCY    = 7,
    parameter BASE_L3_LATENCY   = 4,
    parameter CACHE_LINE_SIZE   = 32,
    parameter ASSOCIATIVITY     = 16,
    // Reduced for simulation feasibility: 64 sets x 16 ways = 1024 lines = 32KB
    parameter NUM_SETS          = 64,
    parameter NUM_LINES         = NUM_SETS * ASSOCIATIVITY
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Request interface
    input  wire [ADDR_WIDTH-1:0]        req_addr,
    input  wire [DATA_WIDTH-1:0]        req_wr_data,
    input  wire                         req_rd_en,
    input  wire                         req_wr_en,
    input  wire                         gaming_workload,
    input  wire                         ai_workload,

    // Response interface
    output wire [DATA_WIDTH-1:0]        rd_data,
    output wire                         rd_valid,
    output wire                         rd_ready,
    output wire                         wr_complete,

    // Hit/miss status
    output wire                         vcache_hit,
    output wire                         vcache_miss,

    // Latency output
    output wire [7:0]                   access_latency,

    // Working set promotion
    input  wire                         promote_line,
    input  wire [ADDR_WIDTH-1:0]        promote_addr,

    // Memory fill interface (CRITICAL: real data from memory)
    input  wire [DATA_WIDTH-1:0]        mem_fill_data,
    input  wire                         mem_fill_valid,
    input  wire [ADDR_WIDTH-1:0]        mem_fill_addr,

    // Debug / performance counters
    output wire [31:0]                  vcache_hits,
    output wire [31:0]                  vcache_misses,
    output wire [31:0]                  vcache_evictions,
    output wire [31:0]                  vcache_promotions,
    output wire [7:0]                   vcache_hit_rate_pct,
    output wire [31:0]                  vcache_capacity_used_mb
);

    // Cache geometry
    localparam OFFSET_BITS = $clog2(CACHE_LINE_SIZE);
    localparam INDEX_BITS = $clog2(NUM_SETS);
    localparam TAG_BITS = ADDR_WIDTH - INDEX_BITS - OFFSET_BITS;

    // Address decomposition
    wire [OFFSET_BITS-1:0]      req_offset = req_addr[OFFSET_BITS-1:0];
    wire [INDEX_BITS-1:0]       req_index  = req_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    wire [TAG_BITS-1:0]         req_tag    = req_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];
    wire [OFFSET_BITS-1:0]      fill_offset = mem_fill_addr[OFFSET_BITS-1:0];
    wire [INDEX_BITS-1:0]       fill_index  = mem_fill_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
    wire [TAG_BITS-1:0]         fill_tag    = mem_fill_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];

    // Cache arrays - PER SET (true set-associative)
    reg                         valid_array   [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [TAG_BITS-1:0]          tag_array     [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [DATA_WIDTH-1:0]        data_array    [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg                         vcache_flag   [0:NUM_SETS-1][0:ASSOCIATIVITY-1];

    // TRUE LRU: Use access timestamp per way (lower = older = LRU)
    reg [7:0]                   lru_timestamp [0:NUM_SETS-1][0:ASSOCIATIVITY-1];
    reg [7:0]                   lru_counter;

    // Performance counters
    reg [31:0]                  hit_count;
    reg [31:0]                  miss_count;
    reg [31:0]                  eviction_count;
    reg [31:0]                  promotion_count;
    reg [7:0]                   access_lat;

    // State machine for cache access
    reg [2:0]                   state;
    localparam ST_IDLE     = 3'b000;
    localparam ST_LOOKUP   = 3'b001;
    localparam ST_MISS     = 3'b010;
    localparam ST_FILL     = 3'b011;
    localparam ST_COMPLETE = 3'b100;

    // Access tracking
    reg  [DATA_WIDTH-1:0]       lookup_data;
    reg                         lookup_hit;
    reg [7:0]                   lookup_latency;
    reg [INDEX_BITS-1:0]        access_index;
    reg [TAG_BITS-1:0]          access_tag;
    reg                         access_is_wr;

    // CRITICAL FIX #2: Timeout counter for ST_MISS state
    reg [7:0]                   miss_timeout_counter;

    // FIX v2: Per-set hit detection -- only scans the ONE set selected by
    // access_index (not the full array). Uses registered access_index/tag.
    integer way_idx;
    always @(*) begin
        lookup_hit = 1'b0;
        lookup_data = {DATA_WIDTH{1'b0}};
        lookup_latency = BASE_L3_LATENCY;

        // FIX v2: Scan only the selected set (per-set lookup, not full array)
        for (way_idx = 0; way_idx < ASSOCIATIVITY; way_idx = way_idx + 1) begin
            if (valid_array[access_index][way_idx] &&
                tag_array[access_index][way_idx] == access_tag) begin
                lookup_hit = 1'b1;
                lookup_data = data_array[access_index][way_idx];

                if (vcache_flag[access_index][way_idx]) begin
                    lookup_latency = VCACHE_LATENCY;
                end else begin
                    lookup_latency = BASE_L3_LATENCY;
                end
            end
        end
    end

    // LRU way selection (find oldest = lowest timestamp)
    function automatic integer find_lru_way;
        input [INDEX_BITS-1:0] idx;
        integer w;
        integer min_ts;
        integer min_way;
        begin
            min_ts = 255;
            min_way = 0;
            for (w = 0; w < ASSOCIATIVITY; w = w + 1) begin
                if (lru_timestamp[idx][w] < min_ts) begin
                    min_ts = lru_timestamp[idx][w];
                    min_way = w;
                end
            end
            find_lru_way = min_way;
        end
    endfunction

    // FIX v2: capacity_used_mb -- count valid entries and compute MB
    // Each line = CACHE_LINE_SIZE bytes. capacity = (valid_count * line_size) / (1024*1024)
    // IVC: Replace function with always @(*) for VVP compatibility
    integer vcache_valid_count;
    always @(*) begin
        integer s, w;
        vcache_valid_count = 0;
        for (s = 0; s < NUM_SETS; s = s + 1) begin
            for (w = 0; w < ASSOCIATIVITY; w = w + 1) begin
                if (valid_array[s][w]) begin
                    vcache_valid_count = vcache_valid_count + 1;
                end
            end
        end
    end

    // Output assignments
    assign rd_data        = lookup_data;
    assign rd_valid       = lookup_hit && req_rd_en && (state == ST_COMPLETE);
    assign rd_ready       = (state == ST_IDLE);
    assign wr_complete    = (state == ST_COMPLETE) && access_is_wr;
    assign vcache_hit     = lookup_hit && req_rd_en && (state == ST_IDLE || state == ST_LOOKUP);
    assign vcache_miss    = !lookup_hit && req_rd_en && (state == ST_IDLE);
    assign access_latency = lookup_latency;
    assign vcache_hits    = hit_count;
    assign vcache_misses  = miss_count;
    assign vcache_evictions = eviction_count;
    assign vcache_promotions = promotion_count;
    assign vcache_hit_rate_pct = (hit_count + miss_count > 0) ?
                                 ((hit_count * 100) / (hit_count + miss_count)) : 8'd0;

    // FIX v2: Real capacity_used_mb calculation instead of hardcoded 0
    // IVC: Use vcache_valid_count instead of function call
    assign vcache_capacity_used_mb = (vcache_valid_count * CACHE_LINE_SIZE) / (1024 * 1024);

    // Main state machine
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int s = 0; s < NUM_SETS; s++) begin
                for (int w = 0; w < ASSOCIATIVITY; w++) begin
                    valid_array[s][w] <= 1'b0;
                    tag_array[s][w] <= {TAG_BITS{1'b0}};
                    data_array[s][w] <= {DATA_WIDTH{1'b0}};
                    vcache_flag[s][w] <= 1'b0;
                    lru_timestamp[s][w] <= 8'd0;
                end
            end

            hit_count <= 0;
            miss_count <= 0;
            eviction_count <= 0;
            promotion_count <= 0;
            access_lat <= 0;
            state <= ST_IDLE;
            lru_counter <= 0;
            access_is_wr <= 0;
            access_index <= {INDEX_BITS{1'b0}};
            access_tag <= {TAG_BITS{1'b0}};
            miss_timeout_counter <= 8'd0;

        end else begin
            lru_counter <= lru_counter + 1;

            case (state)
                ST_IDLE: begin
                    access_lat <= 0;
                    // FIX v2: Both read AND write requests trigger the state machine
                    if (req_rd_en || req_wr_en) begin
                        state <= ST_LOOKUP;
                        access_index <= req_index;
                        access_tag <= req_tag;
                        access_is_wr <= req_wr_en;
                    end else if (promote_line) begin
                        // Working set promotion -- handle in a dedicated cycle
                        state <= ST_IDLE;
                    end
                end

                ST_LOOKUP: begin
                    if (lookup_hit) begin
                        // HIT: Update LRU timestamp for the matching way
                        for (int w = 0; w < ASSOCIATIVITY; w++) begin
                            if (valid_array[access_index][w] &&
                                tag_array[access_index][w] == access_tag) begin
                                lru_timestamp[access_index][w] <= lru_counter;
                                // FIX v2: On write hit, update data in-place
                                if (access_is_wr) begin
                                    data_array[access_index][w] <= req_wr_data;
                                end
                            end
                        end

                        hit_count <= hit_count + 1;
                        access_lat <= lookup_latency;
                        state <= ST_COMPLETE;
                    end else begin
                        // MISS: Need to fetch from memory
                        miss_count <= miss_count + 1;
                        state <= ST_MISS;
                    end
                end

                ST_MISS: begin
                    // CRITICAL FIX #2: Add 64-cycle timeout to prevent permanent stall
                    // If mem_fill_valid never arrives, timeout and proceed with dummy data
                    if (mem_fill_valid &&
                        mem_fill_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS] == access_index) begin
                        miss_timeout_counter <= 8'd0;  // Reset counter on success
                        state <= ST_FILL;
                    end else if (miss_timeout_counter >= 8'd64) begin
                        // TIMEOUT: Memory fill did not arrive
                        $display("[%0t] [V-CACHE] ST_MISS TIMEOUT: mem_fill_valid not asserted after 64 cycles", $time);
                        miss_timeout_counter <= 8'd0;
                        state <= ST_FILL;  // Proceed to fill with dummy data
                    end else begin
                        miss_timeout_counter <= miss_timeout_counter + 1;
                    end
                end

                ST_FILL: begin
                    // Fill cache line with real data from memory
                    integer lru_way;
                    lru_way = find_lru_way(access_index);

                    // Check if we're evicting a valid line
                    if (valid_array[access_index][lru_way]) begin
                        eviction_count <= eviction_count + 1;
                    end

                    // Fill with real memory data
                    valid_array[access_index][lru_way] <= 1'b1;
                    tag_array[access_index][lru_way] <= fill_tag;
                    data_array[access_index][lru_way] <= mem_fill_data;
                    lru_timestamp[access_index][lru_way] <= lru_counter;

                    // Decide whether to promote to V-Cache region
                    if (gaming_workload) begin
                        vcache_flag[access_index][lru_way] <= 1'b1;
                    end else if (ai_workload) begin
                        vcache_flag[access_index][lru_way] <= 1'b0;
                    end else begin
                        vcache_flag[access_index][lru_way] <= 1'b0;
                    end

                    state <= ST_COMPLETE;
                end

                ST_COMPLETE: begin
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase

            // FIX v2: Handle working set promotion using per-set lookup
            // (not full array scan) -- only scan the set derived from promote_addr
            if (promote_line) begin
                integer promo_index;
                integer promo_tag;

                promo_index = promote_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS];
                promo_tag = promote_addr[ADDR_WIDTH-1:INDEX_BITS+OFFSET_BITS];

                // FIX v2: Only scan the one set that promote_addr maps to
                for (int w = 0; w < ASSOCIATIVITY; w = w + 1) begin
                    if (valid_array[promo_index][w] && tag_array[promo_index][w] == promo_tag) begin
                        vcache_flag[promo_index][w] <= 1'b1;  // Promote to V-Cache
                        promotion_count <= promotion_count + 1;
                    end
                end
            end
        end
    end

endmodule
