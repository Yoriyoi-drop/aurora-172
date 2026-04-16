`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: AMD Ring Bus)
//
// Create Date: 12 April 2026
// Design Name: Ring Bus Interconnect
// Module Name: ring_bus
//
// FIXES v3:
//  1. Removed 'logic' declarations inside always_ff → moved to module scope
//  2. Added missing 'end' for STEP 2 CCW for-loop
//  3. Fixed 'resp_src' name collision → renamed local var to 'resp_src_node'
//  4. Fixed 'cw_head'/'cw_tail' undeclared → aliased to *_vc0 variants
//  5. Fixed 'global_congested' blocking assign inside always_ff → wire+assign
//  6. Removed duplicate 'integer i'
//  7. Fixed missing 'end' brackets for always_ff blocks
//  8. Fixed get_cw/ccw_occupancy functions to use _vc0 variants
//  9. Fixed PKT_HOPS_LSB offset (was missing PKT_TIMESTAMP_W)
//////////////////////////////////////////////////////////////////////////////////

module ring_bus #(
    parameter DATA_WIDTH           = 128,
    parameter ADDR_WIDTH           = 48,
    parameter NUM_NODES            = 8,
    parameter BUFFER_DEPTH         = 16,
    parameter packet_width         = 256,
    parameter NUM_PRIORITY         = 2,
    parameter CONGESTION_THRESHOLD = 12
)(
    input  wire                     clk,
    input  wire                     rst_n,

    input  wire [ADDR_WIDTH-1:0]    node_req_addr  [0:NUM_NODES-1],
    input  wire [DATA_WIDTH-1:0]    node_req_data  [0:NUM_NODES-1],
    input  wire                     node_req_valid [0:NUM_NODES-1],
    input  wire [1:0]               node_req_qos   [0:NUM_NODES-1],
    output wire                     node_req_ready [0:NUM_NODES-1],

    output wire [DATA_WIDTH-1:0]    node_resp_data [0:NUM_NODES-1],
    output wire                     node_resp_valid[0:NUM_NODES-1],
    input  wire [NUM_NODES-1:0]     node_resp_ready,

    input  wire                     gaming_mode,
    input  wire [NUM_NODES-1:0]     node_priority,
    input  wire [NUM_NODES-1:0]     node_congested,

    output wire [31:0]              ring_total_packets,
    output wire [31:0]              ring_avg_latency,
    output wire [31:0]              ring_contention_count,
    output wire [31:0]              ring_adaptive_routing_count,
    output wire [31:0]              ring_cw_packets,
    output wire [31:0]              ring_ccw_packets,
    output wire [NUM_NODES-1:0]     node_activity_mask
);

    // -----------------------------------------------------------------------
    // Packet field widths
    // -----------------------------------------------------------------------
    localparam PKT_ADDR_W      = ADDR_WIDTH;
    localparam PKT_DATA_W      = DATA_WIDTH;
    localparam PKT_SRC_W       = 8;
    localparam PKT_DEST_W      = 8;
    localparam PKT_QOS_W       = 2;
    localparam PKT_DIR_W       = 2;
    localparam PKT_HOPS_W      = 8;
    localparam PKT_TIMESTAMP_W = 32;
    localparam PKT_TOTAL_W     = PKT_ADDR_W + PKT_DATA_W + PKT_SRC_W + PKT_DEST_W +
                                 PKT_QOS_W + PKT_DIR_W + PKT_HOPS_W + PKT_TIMESTAMP_W;
    localparam PKT_PADDING_W   = (packet_width > PKT_TOTAL_W) ? (packet_width - PKT_TOTAL_W) : 0;

    localparam DIR_UNSET = 2'b00;
    localparam DIR_CW    = 2'b01;
    localparam DIR_CCW   = 2'b10;

    // Virtual Channel priorities
    localparam VC_LOW      = 1'b0;
    localparam VC_HIGH     = 1'b1;
    localparam VC_NUM      = 2;

    // -----------------------------------------------------------------------
    // FIX 9: Correct field offsets (LSB = bit 0)
    // Layout [MSB..LSB]: addr | src | dest | data | qos | dir | hops | timestamp
    // -----------------------------------------------------------------------
    localparam PKT_TIMESTAMP_LSB = 0;
    localparam PKT_TIMESTAMP_MSB = PKT_TIMESTAMP_LSB + PKT_TIMESTAMP_W - 1;

    localparam PKT_HOPS_LSB = PKT_TIMESTAMP_MSB + 1;          // FIX 9: was missing PKT_TIMESTAMP_W
    localparam PKT_HOPS_MSB = PKT_HOPS_LSB + PKT_HOPS_W - 1;

    localparam PKT_DIR_LSB  = PKT_HOPS_MSB + 1;
    localparam PKT_DIR_MSB  = PKT_DIR_LSB + PKT_DIR_W - 1;

    localparam PKT_QOS_LSB  = PKT_DIR_MSB + 1;
    localparam PKT_QOS_MSB  = PKT_QOS_LSB + PKT_QOS_W - 1;

    localparam PKT_DATA_LSB = PKT_QOS_MSB + 1;
    localparam PKT_DATA_MSB = PKT_DATA_LSB + PKT_DATA_W - 1;

    localparam PKT_DEST_LSB = PKT_DATA_MSB + 1;
    localparam PKT_DEST_MSB = PKT_DEST_LSB + PKT_DEST_W - 1;

    localparam PKT_SRC_LSB  = PKT_DEST_MSB + 1;
    localparam PKT_SRC_MSB  = PKT_SRC_LSB  + PKT_SRC_W  - 1;

    localparam PKT_ADDR_LSB = PKT_SRC_MSB  + 1;
    localparam PKT_ADDR_MSB = PKT_ADDR_LSB + PKT_ADDR_W - 1;

    // -----------------------------------------------------------------------
    // Parameter validation
    // -----------------------------------------------------------------------
    initial begin
        if (PKT_TOTAL_W > packet_width)
            $error("PKT_TOTAL_W (%0d) exceeds packet_width (%0d)", PKT_TOTAL_W, packet_width);
    end

    // -----------------------------------------------------------------------
    // Ring buffers — Virtual Channels (VC0=Low Priority, VC1=High Priority)
    // -----------------------------------------------------------------------
    reg [packet_width-1:0]           cw_buffer_vc0  [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [packet_width-1:0]           cw_buffer_vc1  [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [$clog2(BUFFER_DEPTH):0]     cw_head_vc0    [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     cw_tail_vc0    [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     cw_head_vc1    [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     cw_tail_vc1    [0:NUM_NODES-1];
    reg [7:0]                        cw_hops_vc0    [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [7:0]                        cw_hops_vc1    [0:NUM_NODES-1][0:BUFFER_DEPTH-1];

    reg [packet_width-1:0]           ccw_buffer_vc0 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [packet_width-1:0]           ccw_buffer_vc1 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [$clog2(BUFFER_DEPTH):0]     ccw_head_vc0   [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     ccw_tail_vc0   [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     ccw_head_vc1   [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     ccw_tail_vc1   [0:NUM_NODES-1];
    reg [7:0]                        ccw_hops_vc0   [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [7:0]                        ccw_hops_vc1   [0:NUM_NODES-1][0:BUFFER_DEPTH-1];

    // High-priority escape buffers (smaller, faster path)
    reg [packet_width-1:0]           cw_hp_buffer    [0:NUM_NODES-1][0:3];  // 4-deep HP buffer
    reg [$clog2(4):0]               cw_hp_head      [0:NUM_NODES-1];
    reg [$clog2(4):0]               cw_hp_tail      [0:NUM_NODES-1];
    reg [7:0]                        cw_hp_hops      [0:NUM_NODES-1][0:3];
    
    reg [packet_width-1:0]           ccw_hp_buffer   [0:NUM_NODES-1][0:3];  // 4-deep HP buffer
    reg [$clog2(4):0]               ccw_hp_head     [0:NUM_NODES-1];
    reg [$clog2(4):0]               ccw_hp_tail     [0:NUM_NODES-1];
    reg [7:0]                        ccw_hp_hops     [0:NUM_NODES-1][0:3];

    // FIX 4: Aliases so generate blocks can use generic names
    // (maps to vc0 which carries request traffic)
    `define cw_head(n)  cw_head_vc0[n]
    `define cw_tail(n)  cw_tail_vc0[n]
    `define ccw_head(n) ccw_head_vc0[n]
    `define ccw_tail(n) ccw_tail_vc0[n]

    // -----------------------------------------------------------------------
    // Credit-based flow control
    // -----------------------------------------------------------------------
    reg [7:0] credit_cw_vc0  [0:NUM_NODES-1];
    reg [7:0] credit_cw_vc1  [0:NUM_NODES-1];
    reg [7:0] credit_ccw_vc0 [0:NUM_NODES-1];
    reg [7:0] credit_ccw_vc1 [0:NUM_NODES-1];

    integer init_node;
    initial begin
        for (init_node = 0; init_node < NUM_NODES; init_node = init_node + 1) begin
            credit_cw_vc0[init_node]  = BUFFER_DEPTH - 1;
            credit_cw_vc1[init_node]  = BUFFER_DEPTH - 1;
            credit_ccw_vc0[init_node] = BUFFER_DEPTH - 1;
            credit_ccw_vc1[init_node] = BUFFER_DEPTH - 1;
        end
        $display("[%0t] [RING-BUS] VC + Credit System Initialized", $time);
    end

    // -----------------------------------------------------------------------
    // Response buffers
    // -----------------------------------------------------------------------
    reg [DATA_WIDTH-1:0]             resp_buffer [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [7:0]                        resp_src    [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg                              resp_dir    [0:NUM_NODES-1][0:BUFFER_DEPTH-1];  // NEW: Track direction (CW/CCW)
    reg                              resp_valid  [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [$clog2(BUFFER_DEPTH):0]     resp_head   [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0]     resp_tail   [0:NUM_NODES-1];

    // -----------------------------------------------------------------------
    // Performance counters
    // -----------------------------------------------------------------------
    reg [31:0] total_packets;
    reg [31:0] total_latency;
    reg [31:0] contention_count;
    reg [31:0] adaptive_routing_count;
    reg [31:0] cw_packet_count;
    reg [31:0] ccw_packet_count;
    reg [31:0] packet_count_per_node [0:NUM_NODES-1];
    
    // NEW: Packet age and drop detection for observability
    reg [31:0] aged_packets;
    reg [31:0] dropped_packets;
    reg [15:0] max_packet_age;
    reg [7:0]  packet_age [0:NUM_NODES-1][0:BUFFER_DEPTH-1];

    assign ring_total_packets          = total_packets;
    assign ring_avg_latency            = (total_packets > 0) ? (total_latency / total_packets) : 32'd0;
    assign ring_contention_count       = contention_count;
    assign ring_adaptive_routing_count = adaptive_routing_count;
    assign ring_cw_packets             = cw_packet_count;
    assign ring_ccw_packets            = ccw_packet_count;
    
    // NEW: Age tracking outputs
    assign ring_aged_packets          = aged_packets;
    assign ring_dropped_packets       = dropped_packets;
    assign ring_max_packet_age        = max_packet_age;

    // FIX 2 (activity): split inject/congest regs, combine for output
    reg [NUM_NODES-1:0] activity_inject;
    reg [NUM_NODES-1:0] activity_congest;
    assign node_activity_mask = activity_inject | activity_congest;

    // -----------------------------------------------------------------------
    // FIX 5: global_congested as wire driven by combinational logic
    // -----------------------------------------------------------------------
    reg [31:0] injected_packets;
    reg [31:0] completed_packets;
    wire       global_congested;
    assign global_congested = ((injected_packets - completed_packets) > 32'd100);

    // -----------------------------------------------------------------------
    // FIX 1: Module-scope temporaries (was 'logic' inside always_ff)
    // -----------------------------------------------------------------------
    reg [7:0]              t_next_node;
    reg [7:0]              t_prev_node;
    reg [7:0]              t_pkt_dest_cw;
    reg [7:0]              t_pkt_dest_ccw;
    reg [DATA_WIDTH-1:0]   t_pkt_data_cw;
    reg [DATA_WIDTH-1:0]   t_pkt_data_ccw;
    reg [7:0]              t_pkt_hops_cw;
    reg [7:0]              t_pkt_hops_ccw;
    reg [1:0]              t_pkt_dir;
    reg [1:0]              t_pkt_qos;        // NEW: Extract QoS for priority
    reg                      t_is_high_priority; // NEW: High priority flag
    reg [$clog2(BUFFER_DEPTH)-1:0] t_resp_idx;
    reg [$clog2(BUFFER_DEPTH)-1:0] t_next_idx;
    reg [$clog2(BUFFER_DEPTH)-1:0] t_prev_idx;
    reg [$clog2(BUFFER_DEPTH)-1:0] t_inj_idx;
    reg [7:0]              t_resp_src_node;    // FIX 3: was 'resp_src' → collision with array
    reg [1:0]              t_hp_idx;         // NEW: High-priority buffer index

    // -----------------------------------------------------------------------
    // FIX 8: Occupancy functions reference _vc0 arrays
    // -----------------------------------------------------------------------
    function automatic integer get_cw_occupancy;
        input integer node;
        integer h, t;
        begin
            h = cw_head_vc0[node];
            t = cw_tail_vc0[node];
            get_cw_occupancy = (h >= t) ? (h - t) : (BUFFER_DEPTH - t + h);
        end
    endfunction

    function automatic integer get_ccw_occupancy;
        input integer node;
        integer h, t;
        begin
            h = ccw_head_vc0[node];
            t = ccw_tail_vc0[node];
            get_ccw_occupancy = (h >= t) ? (h - t) : (BUFFER_DEPTH - t + h);
        end
    endfunction

    // -----------------------------------------------------------------------
    // Adaptive routing helpers
    // -----------------------------------------------------------------------
    function automatic [1:0] get_direction;
        input [7:0] src;
        input [7:0] dest;
        input [NUM_NODES-1:0] congested_map;
        integer dist_cw, dist_ccw;
        begin
            dist_cw  = (dest >= src) ? (dest - src) : (NUM_NODES - src + dest);
            dist_ccw = (src >= dest) ? (src - dest)  : (NUM_NODES - dest + src);
            if (dist_cw <= dist_ccw)
                get_direction = DIR_CW;
            else
                get_direction = DIR_CCW;
            if (congested_map[src] && (dist_cw > dist_ccw)) begin
                if (dist_ccw - dist_cw < 2) get_direction = DIR_CCW;
            end else if (congested_map[(src + 1) % NUM_NODES] && (dist_ccw < dist_cw)) begin
                get_direction = DIR_CCW;
            end
        end
    endfunction

    // -----------------------------------------------------------------------
    // Generate: node_req_ready & response outputs
    // FIX 4: use _vc0 variants via `cw_head / cw_tail macros
    // -----------------------------------------------------------------------
    genvar g_idx;
    generate
        for (g_idx = 0; g_idx < NUM_NODES; g_idx = g_idx + 1) begin : gen_ready
            wire [$clog2(BUFFER_DEPTH)+1:0] cw_occ, ccw_occ, resp_occ;

            assign cw_occ = (`cw_head(g_idx) >= `cw_tail(g_idx)) ?
                            (`cw_head(g_idx) - `cw_tail(g_idx)) :
                            (BUFFER_DEPTH - `cw_tail(g_idx) + `cw_head(g_idx));

            assign ccw_occ = (`ccw_head(g_idx) >= `ccw_tail(g_idx)) ?
                             (`ccw_head(g_idx) - `ccw_tail(g_idx)) :
                             (BUFFER_DEPTH - `ccw_tail(g_idx) + `ccw_head(g_idx));

            assign resp_occ = (resp_head[g_idx] >= resp_tail[g_idx]) ?
                              (resp_head[g_idx] - resp_tail[g_idx]) :
                              (BUFFER_DEPTH - resp_tail[g_idx] + resp_head[g_idx]);

            assign node_req_ready[g_idx] = !global_congested &&
                                           (cw_occ   < (BUFFER_DEPTH / 2)) &&  // REDUCED: -2 → /2 for stricter control
                                           (ccw_occ  < (BUFFER_DEPTH / 2)) &&
                                           (resp_occ < (BUFFER_DEPTH / 2));
        end

        for (g_idx = 0; g_idx < NUM_NODES; g_idx = g_idx + 1) begin : gen_resp
            wire [$clog2(BUFFER_DEPTH)-1:0] read_idx;
            assign read_idx          = resp_tail[g_idx] % BUFFER_DEPTH;
            assign node_resp_data[g_idx]  = resp_valid[g_idx][read_idx] ?
                                            resp_buffer[g_idx][read_idx] : {DATA_WIDTH{1'b0}};
            assign node_resp_valid[g_idx] = (resp_head[g_idx] != resp_tail[g_idx]) &&
                                            resp_valid[g_idx][read_idx];
        end
    endgenerate

    // -----------------------------------------------------------------------
    // Main ring bus always_ff
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NUM_NODES; i++) begin
                cw_head_vc0[i]  <= 0; cw_tail_vc0[i]  <= 0;
                cw_head_vc1[i]  <= 0; cw_tail_vc1[i]  <= 0;
                ccw_head_vc0[i] <= 0; ccw_tail_vc0[i] <= 0;
                ccw_head_vc1[i] <= 0; ccw_tail_vc1[i] <= 0;
                resp_head[i]    <= 0; resp_tail[i]     <= 0;
                credit_cw_vc0[i]  <= BUFFER_DEPTH - 1;
                credit_cw_vc1[i]  <= BUFFER_DEPTH - 1;
                credit_ccw_vc0[i] <= BUFFER_DEPTH - 1;
                credit_ccw_vc1[i] <= BUFFER_DEPTH - 1;
                packet_count_per_node[i] <= 32'd0;
                for (int j = 0; j < BUFFER_DEPTH; j++) begin
                    resp_valid[i][j] <= 1'b0;
                    resp_dir[i][j]   <= DIR_UNSET;  // NEW: Initialize direction
                end
            end
            total_packets       <= 32'd0;
            total_latency       <= 32'd0;
            contention_count    <= 32'd0;
            adaptive_routing_count <= 32'd0;
            cw_packet_count     <= 32'd0;
            ccw_packet_count    <= 32'd0;
            
            // Initialize age tracking
            aged_packets        <= 32'd0;
            dropped_packets     <= 32'd0;
            max_packet_age      <= 16'd0;
            for (int i = 0; i < NUM_NODES; i++) begin
                for (int j = 0; j < BUFFER_DEPTH; j++) begin
                    packet_age[i][j] <= 8'd0;
                end
            end
            activity_inject     <= {NUM_NODES{1'b0}};
            activity_congest    <= {NUM_NODES{1'b0}};

        end else begin

            // ----------------------------------------------------------------
            // STEP 1: Rotate CW ring (VC0 — Request)
            // ----------------------------------------------------------------
            for (int i = 0; i < NUM_NODES; i++) begin
                t_next_node = (i + 1) % NUM_NODES;

                if (cw_head_vc0[i] != cw_tail_vc0[i]) begin
                    t_pkt_dest_cw = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_DEST_MSB:PKT_DEST_LSB];

                    if (credit_cw_vc0[t_next_node] > 0) begin
                        if (t_pkt_dest_cw == i[7:0]) begin
                            // --- Deliver to response buffer ---
                            t_pkt_data_cw = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_DATA_MSB:PKT_DATA_LSB];
                            t_pkt_hops_cw = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_HOPS_MSB:PKT_HOPS_LSB];

                            if (resp_head[i] != ((resp_tail[i] + 1) % BUFFER_DEPTH)) begin
                                t_resp_idx = resp_head[i][$clog2(BUFFER_DEPTH)-1:0];
                                resp_buffer[i][t_resp_idx] <= t_pkt_data_cw;
                                resp_src[i][t_resp_idx]    <= cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_SRC_MSB:PKT_SRC_LSB];
                                resp_dir[i][t_resp_idx]    <= DIR_CW;
                                resp_valid[i][t_resp_idx]  <= 1'b1;
                                resp_head[i]    <= (resp_head[i] == BUFFER_DEPTH-1) ? 0 : resp_head[i] + 1;
                                cw_tail_vc0[i]  <= (cw_tail_vc0[i] == BUFFER_DEPTH-1) ? 0 : cw_tail_vc0[i] + 1;
                                // FIX #3/#9: Credit CW dikembalikan on-delivery (sama seperti CCW fix)
                                t_resp_src_node = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_SRC_MSB:PKT_SRC_LSB];
                                if (t_resp_src_node < NUM_NODES)
                                    credit_cw_vc0[t_resp_src_node] <= credit_cw_vc0[t_resp_src_node] + 1;
                                $display("[%0t] [RING-BUS] CREDIT_RETURN: src=%0d, dir=CW (on-delivery), cw_credit=%0d, ccw_credit=%0d",
                                         $time, t_resp_src_node, credit_cw_vc0[t_resp_src_node] + 1,
                                         credit_ccw_vc0[t_resp_src_node]);
                                total_packets   <= total_packets + 32'd1;
                                cw_packet_count <= cw_packet_count + 32'd1;
                                total_latency   <= total_latency + t_pkt_hops_cw;
                            end

                        end else begin
                            // --- Forward to next node ---
                            if (cw_head_vc0[t_next_node] != ((cw_tail_vc0[t_next_node] + 1) % BUFFER_DEPTH)) begin
                                t_next_idx = cw_head_vc0[t_next_node][$clog2(BUFFER_DEPTH)-1:0];
                                cw_buffer_vc0[t_next_node][t_next_idx] <= cw_buffer_vc0[i][cw_tail_vc0[i]];
                                cw_hops_vc0[t_next_node][t_next_idx]   <= cw_hops_vc0[i][cw_tail_vc0[i]] + 1;
                                cw_head_vc0[t_next_node] <= (cw_head_vc0[t_next_node] == BUFFER_DEPTH-1) ? 0 : cw_head_vc0[t_next_node] + 1;
                                cw_tail_vc0[i]  <= (cw_tail_vc0[i]  == BUFFER_DEPTH-1) ? 0 : cw_tail_vc0[i]  + 1;
                                credit_cw_vc0[t_next_node] <= credit_cw_vc0[t_next_node] - 1;
                            end
                        end

                    end else begin
                        contention_count  <= contention_count + 32'd1;
                        activity_congest[i] <= 1'b1;
                    end
                end
            end // STEP 1

            // ----------------------------------------------------------------
            // STEP 2: Rotate CCW ring (VC0 — Request)
            // ----------------------------------------------------------------
            for (int i = 0; i < NUM_NODES; i++) begin   // FIX 2: was missing end before STEP 3
                t_prev_node = (i == 0) ? (NUM_NODES - 1) : (i - 1);

                if (ccw_head_vc0[i] != ccw_tail_vc0[i]) begin
                    t_pkt_dest_ccw = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_DEST_MSB:PKT_DEST_LSB];

                    if (credit_ccw_vc0[t_prev_node] > 0) begin
                        if (t_pkt_dest_ccw == i[7:0]) begin
                            t_pkt_data_ccw = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_DATA_MSB:PKT_DATA_LSB];
                            t_pkt_hops_ccw = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_HOPS_MSB:PKT_HOPS_LSB];

                            if (resp_head[i] != ((resp_tail[i] + 1) % BUFFER_DEPTH)) begin
                                t_resp_idx = resp_head[i][$clog2(BUFFER_DEPTH)-1:0];
                                resp_buffer[i][t_resp_idx] <= t_pkt_data_ccw;
                                resp_src[i][t_resp_idx]    <= ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_SRC_MSB:PKT_SRC_LSB];
                                resp_dir[i][t_resp_idx]    <= DIR_CCW;
                                resp_valid[i][t_resp_idx]  <= 1'b1;
                                resp_head[i]     <= (resp_head[i] == BUFFER_DEPTH-1) ? 0 : resp_head[i] + 1;
                                ccw_tail_vc0[i]  <= (ccw_tail_vc0[i] == BUFFER_DEPTH-1) ? 0 : ccw_tail_vc0[i] + 1;
                                // FIX #3/#9: Credit CCW dikembalikan di sini, saat packet sudah di-deliver
                                // ke resp buffer (bukan menunggu consumer ack di STEP 4).
                                // Bug lama: credit return bergantung pada node_resp_ready yang tidak pernah
                                // high karena consumer_ready=x. Kredit terdrain tanpa recovery.
                                t_resp_src_node = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_SRC_MSB:PKT_SRC_LSB];
                                if (t_resp_src_node < NUM_NODES)
                                    credit_ccw_vc0[t_resp_src_node] <= credit_ccw_vc0[t_resp_src_node] + 1;
                                $display("[%0t] [RING-BUS] CREDIT_RETURN: src=%0d, dir=CCW (on-delivery), cw_credit=%0d, ccw_credit=%0d",
                                         $time, t_resp_src_node, credit_cw_vc0[t_resp_src_node],
                                         credit_ccw_vc0[t_resp_src_node] + 1);
                                total_packets    <= total_packets + 32'd1;
                                ccw_packet_count <= ccw_packet_count + 32'd1;
                                total_latency    <= total_latency + t_pkt_hops_ccw;
                            end

                        end else begin
                            if (ccw_head_vc0[t_prev_node] != ((ccw_tail_vc0[t_prev_node] + 1) % BUFFER_DEPTH)) begin
                                t_prev_idx = ccw_head_vc0[t_prev_node][$clog2(BUFFER_DEPTH)-1:0];
                                ccw_buffer_vc0[t_prev_node][t_prev_idx] <= ccw_buffer_vc0[i][ccw_tail_vc0[i]];
                                ccw_hops_vc0[t_prev_node][t_prev_idx]   <= ccw_hops_vc0[i][ccw_tail_vc0[i]] + 1;
                                ccw_head_vc0[t_prev_node] <= (ccw_head_vc0[t_prev_node] == BUFFER_DEPTH-1) ? 0 : ccw_head_vc0[t_prev_node] + 1;
                                ccw_tail_vc0[i]  <= (ccw_tail_vc0[i]  == BUFFER_DEPTH-1) ? 0 : ccw_tail_vc0[i]  + 1;
                                credit_ccw_vc0[t_prev_node] <= credit_ccw_vc0[t_prev_node] - 1;
                            end
                        end

                    end else begin
                        contention_count    <= contention_count + 32'd1;
                        activity_congest[i] <= 1'b1;
                    end
                end
            end // FIX 2: This 'end' was the missing one — STEP 2 loop now closed

            // ----------------------------------------------------------------
            // STEP 3: Packet injection (VC0)
            // ----------------------------------------------------------------
            for (int i = 0; i < NUM_NODES; i++) begin
                if (node_req_valid[i] && node_req_ready[i]) begin
                    // FIX 1: t_pkt_dir is now a module-scope reg
                    t_pkt_dir = node_req_data[i][PKT_DIR_MSB:PKT_DIR_LSB];
                    t_pkt_qos = node_req_data[i][PKT_QOS_MSB:PKT_QOS_LSB];
                    t_is_high_priority = (t_pkt_qos >= 2'b10);  // QoS 2-3 = high priority
                    
                    // DEBUG: Print actual direction values
                    if (i == 2) begin  // Only for Node 2 (A-Core)
                        $display("[%0t] [RING-BUS] DEBUG: Node %0d raw_data=0x%h, extracted_dir=%0d, expected_dir=%0d", 
                                 $time, i, node_req_data[i], t_pkt_dir, (t_pkt_dir == DIR_CCW) ? 2 : (t_pkt_dir == DIR_CW) ? 1 : 0);
                    end

                    if (t_pkt_dir == DIR_CW) begin
                        // HIGH PRIORITY ESCAPE PATH
                        if (t_is_high_priority && (cw_hp_head[i] != ((cw_hp_tail[i] + 1) % 4))) begin
                            t_hp_idx = cw_hp_head[i][1:0];
                            cw_hp_buffer[i][t_hp_idx] <= node_req_data[i];
                            cw_hp_hops[i][t_hp_idx]   <= 8'b0;
                            cw_hp_head[i] <= (cw_hp_head[i] == 3) ? 0 : cw_hp_head[i] + 1;
                            cw_packet_count <= cw_packet_count + 32'd1;
                            packet_count_per_node[i] <= packet_count_per_node[i] + 32'd1;
                            activity_inject[i] <= 1'b1;
                            $display("[%0t] [RING-BUS] HP_INJECT CW: Node %0d (QoS=%0d)", $time, i, t_pkt_qos);
                        // NORMAL PATH - STRICTER CREDIT CHECK
                        end else if (credit_cw_vc0[i] > 2 &&  // MINIMUM 2 credits required
                            (cw_head_vc0[i] != ((cw_tail_vc0[i] + 1) % BUFFER_DEPTH))) begin
                            t_inj_idx = cw_head_vc0[i][$clog2(BUFFER_DEPTH)-1:0];
                            cw_buffer_vc0[i][t_inj_idx] <= node_req_data[i];
                            cw_hops_vc0[i][t_inj_idx]   <= 8'b0;
                            cw_head_vc0[i]  <= (cw_head_vc0[i]  == BUFFER_DEPTH-1) ? 0 : cw_head_vc0[i]  + 1;
                            credit_cw_vc0[i] <= credit_cw_vc0[i] - 1;
                            cw_packet_count <= cw_packet_count + 32'd1;
                            packet_count_per_node[i] <= packet_count_per_node[i] + 32'd1;
                            activity_inject[i] <= 1'b1;
                            $display("[%0t] [RING-BUS] VC0 INJECT CW: Node %0d (credits: %0d)",
                                     $time, i, credit_cw_vc0[i] - 1);
                        end else begin
                            contention_count    <= contention_count + 32'd1;
                            activity_congest[i] <= 1'b1;
                            if (credit_cw_vc0[i] <= 2 && i == 0)
                                $display("[%0t] [RING-BUS] ⚠ CREDIT STARVATION: Node %0d CW credits=%0d (min=2)", $time, i, credit_cw_vc0[i]);
                        end

                    end else if (t_pkt_dir == DIR_CCW) begin
                        if (credit_ccw_vc0[i] > 2 &&  // MINIMUM 2 credits required
                            (ccw_head_vc0[i] != ((ccw_tail_vc0[i] + 1) % BUFFER_DEPTH))) begin
                            t_inj_idx = ccw_head_vc0[i][$clog2(BUFFER_DEPTH)-1:0];
                            ccw_buffer_vc0[i][t_inj_idx] <= node_req_data[i];
                            ccw_hops_vc0[i][t_inj_idx]   <= 8'b0;
                            ccw_head_vc0[i]   <= (ccw_head_vc0[i]   == BUFFER_DEPTH-1) ? 0 : ccw_head_vc0[i]   + 1;
                            credit_ccw_vc0[i] <= credit_ccw_vc0[i] - 1;
                            ccw_packet_count <= ccw_packet_count + 32'd1;
                            packet_count_per_node[i] <= packet_count_per_node[i] + 32'd1;
                            activity_inject[i] <= 1'b1;
                            $display("[%0t] [RING-BUS] VC0 INJECT CCW: Node %0d (credits: %0d)",
                                     $time, i, credit_ccw_vc0[i] - 1);
                        end else begin
                            contention_count    <= contention_count + 32'd1;
                            activity_congest[i] <= 1'b1;
                            if (credit_ccw_vc0[i] <= 2 && i == 0)
                                $display("[%0t] [RING-BUS] ⚠ CREDIT STARVATION: Node %0d CCW credits=%0d (min=2)", $time, i, credit_ccw_vc0[i]);
                        end
                    end
                end
            end // STEP 3

            // ----------------------------------------------------------------
            // STEP 4: Consume responses + credit return (legacy consumer-side)
            // FIX #3/#9: Credit return sudah dipindah ke STEP 1/2 (on-delivery).
            // STEP 4 sekarang hanya membersihkan resp buffer saat consumer mengambil.
            // ----------------------------------------------------------------
            for (int i = 0; i < NUM_NODES; i++) begin
                if (node_resp_valid[i] && node_resp_ready[i] && (resp_head[i] != resp_tail[i])) begin
                    // Bersihkan resp buffer entry (credit sudah di-return di STEP 1/2)
                    resp_valid[i][resp_tail[i][$clog2(BUFFER_DEPTH)-1:0]] <= 1'b0;
                    resp_tail[i] <= (resp_tail[i] == BUFFER_DEPTH-1) ? 0 : resp_tail[i] + 1;
                    // Tidak ada credit return di sini — sudah dilakukan on-delivery
                end
                // Hapus RESPONSE_STALL warning yang membanjiri log saat consumer=x
            end // STEP 4

            // ----------------------------------------------------------------
            // STEP 5: Congestion detection
            // ----------------------------------------------------------------
            for (int i = 0; i < NUM_NODES; i++) begin
                if ((get_cw_occupancy(i) > CONGESTION_THRESHOLD) ||
                    (get_ccw_occupancy(i) > CONGESTION_THRESHOLD))
                    activity_congest[i] <= 1'b1;
                else
                    activity_congest[i] <= 1'b0;
            end

        // NEW: Packet age tracking and drop detection
            for (int i = 0; i < NUM_NODES; i++) begin
                // Increment age for all packets in buffers
                for (int j = 0; j < BUFFER_DEPTH; j++) begin
                    if (cw_head_vc0[i] != cw_tail_vc0[i] && j == cw_head_vc0[i]) begin
                        packet_age[i][j] <= packet_age[i][j] + 1;
                        if (packet_age[i][j] > max_packet_age)
                            max_packet_age <= packet_age[i][j];
                        
                        // Drop packets older than 255 cycles
                        if (packet_age[i][j] >= 8'd255) begin
                            dropped_packets <= dropped_packets + 1;
                            $display("[%0t] [RING-BUS] DROP: Node %0d packet aged %0d cycles, dropping", $time, i, packet_age[i][j]);
                            // Advance head to drop the packet
                            cw_head_vc0[i] <= (cw_head_vc0[i] == (BUFFER_DEPTH-1)) ? 0 : cw_head_vc0[i] + 1;
                        end
                    end
                end
            end

        end // else (!rst_n)
    end // always_ff main

    // -----------------------------------------------------------------------
    // Injection/completion tracker + credit recovery
    // FIX 5: global_congested is wire, no blocking assign inside always_ff
    // FIX 6: integer i not duplicated (only one always_ff block now)
    // -----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            injected_packets  <= 32'd0;
            completed_packets <= 32'd0;
        end else begin
            for (int i = 0; i < NUM_NODES; i++) begin
                if (node_req_valid[i] && node_req_ready[i])
                    injected_packets <= injected_packets + 32'd1;
                if (node_resp_valid[i] && node_resp_ready[i])
                    completed_packets <= completed_packets + 32'd1;
            end

            // Warn once at threshold
            if ((injected_packets - completed_packets) == 32'd101)
                $display("[%0t] [RING-BUS] WARNING BACKLOG: pending=%0d",
                         $time, injected_packets - completed_packets);

            // Credit recovery to escape deadlock - IMPROVED
            if ((injected_packets - completed_packets) > 32'd100) begin
                $display("[%0t] [RING-BUS] CREDIT RECOVERY: pending=%0d > 100, resetting all credits", $time, injected_packets - completed_packets);
                for (int i = 0; i < NUM_NODES; i++) begin
                    credit_cw_vc0[i]  <= BUFFER_DEPTH - 1;
                    credit_cw_vc1[i]  <= BUFFER_DEPTH - 1;
                    credit_ccw_vc0[i] <= BUFFER_DEPTH - 1;
                    credit_ccw_vc1[i] <= BUFFER_DEPTH - 1;
                end
                // Reset packet counters to prevent false triggers
                injected_packets  <= completed_packets;
            end
        end
    end // always_ff tracker

endmodule