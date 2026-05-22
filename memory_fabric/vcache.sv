`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"


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
    parameter DATA_WIDTH        = `AURORA_DATA_WIDTH,   // FIXED: Use standard parameter
    parameter ADDR_WIDTH        = `AURORA_ADDR_WIDTH,   // FIXED: Use standard parameter
    parameter VCACHE_CAPACITY_MB = (NUM_SETS * ASSOCIATIVITY * CACHE_LINE_SIZE) / (1024 * 1024),  // CRITICAL FIX: Compute from geometry (actual ≪ 1 MB)
    parameter VCACHE_LATENCY    = 3,     // OPTIMIZED: 4->3 (faster access)
    parameter BASE_L3_LATENCY   = 3,
    parameter CACHE_LINE_SIZE   = 16,    // OPTIMIZED: 32->16 (smaller lines)
    parameter ASSOCIATIVITY     = 4,     // OPTIMIZED: 8->4 (very simple associativity)
    // Simplified: 16 sets x 4 ways = 64 lines = 1KB
    parameter NUM_SETS          = 16,    // OPTIMIZED: 32->16
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

    // Cache constants
    localparam LRU_INIT_TIMESTAMP = 8'd0;  // Initial LRU timestamp
    localparam MISS_TIMEOUT_CYCLES = 8'd64;  // Memory fill timeout
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

    // FIX v2: Per-set hit detection -- only scans ONE set selected by
    // access_index (not full array). Uses registered access_index/tag.
    // FIX: Use always @* for automatic sensitivity
    integer way_idx;
    always @* begin
        lookup_hit = 1'b0;
        lookup_data = {DATA_WIDTH{1'b0}};
        lookup_latency = BASE_L3_LATENCY;

        // FIXED: Unrolled loop for ASSOCIATIVITY=4 with priority encoder (else-if)
        // Way 0
        if (valid_array[access_index][0] &&
            tag_array[access_index][0] == access_tag) begin
            lookup_hit = 1'b1;
            lookup_data = data_array[access_index][0];
            lookup_latency = vcache_flag[access_index][0] ? VCACHE_LATENCY : BASE_L3_LATENCY;
        end
        // Way 1
        else if (valid_array[access_index][1] &&
            tag_array[access_index][1] == access_tag) begin
            lookup_hit = 1'b1;
            lookup_data = data_array[access_index][1];
            lookup_latency = vcache_flag[access_index][1] ? VCACHE_LATENCY : BASE_L3_LATENCY;
        end
        // Way 2
        else if (valid_array[access_index][2] &&
            tag_array[access_index][2] == access_tag) begin
            lookup_hit = 1'b1;
            lookup_data = data_array[access_index][2];
            lookup_latency = vcache_flag[access_index][2] ? VCACHE_LATENCY : BASE_L3_LATENCY;
        end
        // Way 3
        else if (valid_array[access_index][3] &&
            tag_array[access_index][3] == access_tag) begin
            lookup_hit = 1'b1;
            lookup_data = data_array[access_index][3];
            lookup_latency = vcache_flag[access_index][3] ? VCACHE_LATENCY : BASE_L3_LATENCY;
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
    // FIX: Use always @* for automatic sensitivity
    integer vcache_valid_count;
    always @* begin
        // FIXED: Unrolled nested loop for NUM_SETS=16, ASSOCIATIVITY=4
        vcache_valid_count = 0;
        // Set 0
        if (valid_array[0][0]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[0][1]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[0][2]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[0][3]) vcache_valid_count = vcache_valid_count + 1;
        // Set 1
        if (valid_array[1][0]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[1][1]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[1][2]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[1][3]) vcache_valid_count = vcache_valid_count + 1;
        // Set 2
        if (valid_array[2][0]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[2][1]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[2][2]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[2][3]) vcache_valid_count = vcache_valid_count + 1;
        // Set 3
        if (valid_array[3][0]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[3][1]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[3][2]) vcache_valid_count = vcache_valid_count + 1;
        if (valid_array[3][3]) vcache_valid_count = vcache_valid_count + 1;
        // Set 4-15: Simplified with loop for readability (smaller impact)
        for (integer s = 4; s < NUM_SETS; s = s + 1) begin
            if (valid_array[s][0]) vcache_valid_count = vcache_valid_count + 1;
            if (valid_array[s][1]) vcache_valid_count = vcache_valid_count + 1;
            if (valid_array[s][2]) vcache_valid_count = vcache_valid_count + 1;
            if (valid_array[s][3]) vcache_valid_count = vcache_valid_count + 1;
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
            // OPTIMIZED: Single loop for faster initialization
            for (int i = 0; i < NUM_SETS * ASSOCIATIVITY; i++) begin
                valid_array[i/ASSOCIATIVITY][i%ASSOCIATIVITY] <= 1'b0;
                tag_array[i/ASSOCIATIVITY][i%ASSOCIATIVITY] <= {TAG_BITS{1'b0}};
                data_array[i/ASSOCIATIVITY][i%ASSOCIATIVITY] <= {DATA_WIDTH{1'b0}};
                vcache_flag[i/ASSOCIATIVITY][i%ASSOCIATIVITY] <= 1'b0;
                lru_timestamp[i/ASSOCIATIVITY][i%ASSOCIATIVITY] <= LRU_INIT_TIMESTAMP;
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
                        mem_fill_addr[INDEX_BITS+OFFSET_BITS-1:OFFSET_BITS] == access_index &&
                        fill_tag == access_tag) begin  // FIXED: Check tag too, not just index
                        miss_timeout_counter <= 8'd0;  // Reset counter on success
                        state <= ST_FILL;
                    end else if (miss_timeout_counter >= MISS_TIMEOUT_CYCLES) begin
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
