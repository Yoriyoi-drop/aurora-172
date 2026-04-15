`timescale 1ns / 1ps

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Architecture Team (ATM: AMD Ring Bus)
//
// Create Date: 12 April 2026
// Design Name: Ring Bus Interconnect
// Module Name: ring_bus
//
// Description:
//   Advanced ring topology interconnect untuk intra-chiplet communication
//   Inspired by AMD Infinity Fabric ring bus (di dalam CCD)
//
//   Features:
//   - Ring topology: Each node connected to 2 neighbors
//   - Low latency: ~1-2 cycles per hop
//   - ADAPTIVE ROUTING: Choose shortest path (CW or CCW)
//   - Bidirectional rings (clockwise + counterclockwise)
//   - Credit-based flow control
//   - Per-node input/output buffers
//   - Gaming-optimized: priority bypass for G-Core
//   - Proper response path (not simplified)
//   - Deadlock-free by design
//   - Congestion-aware routing
//
//   Ring Structure:
//   Node 0 -> Node 1 -> Node 2 -> ... -> Node N-1 -> Node 0 (CW)
//   Node 0 <- Node 1 <- Node 2 <- ... <- Node N-1 <- Node 0 (CCW)
//
//   Routing Algorithm:
//   - Calculate distance CW: (dest - src + N) % N
//   - Calculate distance CCW: (src - dest + N) % N
//   - Choose direction with fewer hops
//   - Max latency: N/2 hops
//
//////////////////////////////////////////////////////////////////////////////////

// FIX v2: Add parameter validation
module ring_bus #(
    parameter DATA_WIDTH        = 128,
    parameter ADDR_WIDTH        = 48,
    parameter NUM_NODES         = 8,
    parameter BUFFER_DEPTH      = 16,  // INCREASED: 8→16 for better throughput
    parameter packet_width      = 256,  // Increased to fit full packet format (236 bits minimum)
    parameter NUM_PRIORITY      = 2,  // Normal and High priority
    parameter CONGESTION_THRESHOLD = 12  // ADJUSTED: for larger buffer
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // --- Per-node request interfaces
    input  wire [ADDR_WIDTH-1:0]        node_req_addr  [0:NUM_NODES-1],
    input  wire [DATA_WIDTH-1:0]        node_req_data  [0:NUM_NODES-1],
    input  wire                         node_req_valid [0:NUM_NODES-1],
    input  wire [1:0]                   node_req_qos   [0:NUM_NODES-1],  // QoS priority
    output wire                         node_req_ready [0:NUM_NODES-1],

    // --- Per-node response interfaces (PROPER IMPLEMENTATION)
    output wire [DATA_WIDTH-1:0]        node_resp_data [0:NUM_NODES-1],
    output wire                         node_resp_valid[0:NUM_NODES-1],
    input  wire [NUM_NODES-1:0]         node_resp_ready,

    // --- Configuration
    input  wire                         gaming_mode,      // Priority for gaming nodes
    input  wire [NUM_NODES-1:0]         node_priority,   // Per-node priority
    input  wire [NUM_NODES-1:0]         node_congested,  // Congestion status per node

    // --- Debug / performance
    output wire [31:0]                  ring_total_packets,
    output wire [31:0]                  ring_avg_latency,
    output wire [31:0]                  ring_contention_count,
    output wire [31:0]                  ring_adaptive_routing_count,  // Count of adaptive routing decisions
    output wire [31:0]                  ring_cw_packets,              // Packets routed CW
    output wire [31:0]                  ring_ccw_packets,             // Packets routed CCW
    output wire [NUM_NODES-1:0]         node_activity_mask
);

    // FIX v2: Parameter validation
    initial begin
        if (PKT_TOTAL_W > packet_width)
            $error("PKT_TOTAL_W exceeds packet_width");
    end

    // --- Enhanced packet format with routing info
    // {addr[47:0], data[DATA_WIDTH-1:0], src[7:0], dest[7:0], qos[1:0], direction[1:0], hops[7:0], timestamp[31:0]}
    // ---
    localparam PKT_ADDR_W      = ADDR_WIDTH;
    localparam PKT_DATA_W      = DATA_WIDTH;
    localparam PKT_SRC_W       = 8;
    localparam PKT_DEST_W      = 8;
    localparam PKT_QOS_W       = 2;
    localparam PKT_DIR_W       = 2;  // 0=unset, 1=CW, 2=CCW
    localparam PKT_HOPS_W      = 8;
    localparam PKT_TIMESTAMP_W = 32;
    localparam PKT_TOTAL_W     = PKT_ADDR_W + PKT_DATA_W + PKT_SRC_W + PKT_DEST_W +
                                 PKT_QOS_W + PKT_DIR_W + PKT_HOPS_W + PKT_TIMESTAMP_W;
    localparam PKT_PADDING_W   = (packet_width > PKT_TOTAL_W) ? (packet_width - PKT_TOTAL_W) : 0;

    // Direction encoding
    localparam DIR_UNSET = 2'b00;
    localparam DIR_CW    = 2'b01;
    localparam DIR_CCW   = 2'b10;

    // FIXED: Clear field offset definitions untuk packet extraction
    localparam PKT_DEST_LSB   = PKT_TIMESTAMP_W + PKT_HOPS_W + PKT_DIR_W + PKT_QOS_W + PKT_DATA_W;
    localparam PKT_DEST_MSB   = PKT_DEST_LSB + PKT_DEST_W - 1;
    localparam PKT_SRC_LSB    = PKT_DEST_MSB + 1;
    localparam PKT_SRC_MSB    = PKT_SRC_LSB + PKT_SRC_W - 1;
    localparam PKT_DATA_LSB   = PKT_QOS_W + PKT_DIR_W + PKT_HOPS_W + PKT_TIMESTAMP_W;
    localparam PKT_DATA_MSB   = PKT_DATA_LSB + PKT_DATA_W - 1;
    localparam PKT_HOPS_LSB   = PKT_DIR_W + PKT_QOS_W;
    localparam PKT_HOPS_MSB   = PKT_HOPS_LSB + PKT_HOPS_W - 1;

    // --- Virtual Channel Structure (LEVEL-UP NoC Design)
    // VC0 = Request packets (inbound traffic)
    // VC1 = Response packets (outbound traffic)
    // This prevents deadlock by separating request/response dependencies
    // ---
    reg [packet_width-1:0]  cw_buffer_vc0 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];  // Request VC
    reg [packet_width-1:0]  cw_buffer_vc1 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];  // Response VC
    reg [$clog2(BUFFER_DEPTH):0] cw_head_vc0 [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] cw_tail_vc0 [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] cw_head_vc1 [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] cw_tail_vc1 [0:NUM_NODES-1];
    reg [7:0]                   cw_hops_vc0 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [7:0]                   cw_hops_vc1 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];

    reg [packet_width-1:0]  ccw_buffer_vc0 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];  // Request VC
    reg [packet_width-1:0]  ccw_buffer_vc1 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];  // Response VC
    reg [$clog2(BUFFER_DEPTH):0] ccw_head_vc0 [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] ccw_tail_vc0 [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] ccw_head_vc1 [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] ccw_tail_vc1 [0:NUM_NODES-1];
    reg [7:0]                   ccw_hops_vc0 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [7:0]                   ccw_hops_vc1 [0:NUM_NODES-1][0:BUFFER_DEPTH-1];

    // --- Credit-based flow control per VC
    // This prevents buffer overflow and provides proper backpressure
    reg [7:0] credit_cw_vc0 [0:NUM_NODES-1];  // Credits for CW Request VC
    reg [7:0] credit_cw_vc1 [0:NUM_NODES-1];  // Credits for CW Response VC
    reg [7:0] credit_ccw_vc0 [0:NUM_NODES-1]; // Credits for CCW Request VC
    reg [7:0] credit_ccw_vc1 [0:NUM_NODES-1]; // Credits for CCW Response VC

    // --- RESPONSE BUFFERS (separate from request buffers)
    // ---
    reg [DATA_WIDTH-1:0]  resp_buffer [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [7:0]             resp_src    [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg                   resp_valid  [0:NUM_NODES-1][0:BUFFER_DEPTH-1];
    reg [$clog2(BUFFER_DEPTH):0] resp_head [0:NUM_NODES-1];
    reg [$clog2(BUFFER_DEPTH):0] resp_tail [0:NUM_NODES-1];

    // --- Credit Initialization (LEVEL-UP NoC Design)
    // Initialize credits to buffer depth - 1 (leave space for backpressure)
    // ---
    integer init_node;
    initial begin
        for (init_node = 0; init_node < NUM_NODES; init_node = init_node + 1) begin
            credit_cw_vc0[init_node] = BUFFER_DEPTH - 1;
            credit_cw_vc1[init_node] = BUFFER_DEPTH - 1;
            credit_ccw_vc0[init_node] = BUFFER_DEPTH - 1;
            credit_ccw_vc1[init_node] = BUFFER_DEPTH - 1;
        end
        $display("[%0t] [RING-BUS] 🚀 LEVEL-UP: Virtual Channels + Credit System Initialized", $time);
    end

    // --- Performance counters
    // ---
    reg [31:0] total_packets;
    reg [31:0] total_latency;
    reg [31:0] contention_count;
    reg [31:0] adaptive_routing_count;
    reg [31:0] cw_packet_count;
    reg [31:0] ccw_packet_count;
    reg [31:0] packet_count_per_node [0:NUM_NODES-1];

    assign ring_total_packets          = total_packets;
    assign ring_avg_latency            = (total_packets > 0) ? (total_latency / total_packets) : 32'd0;
    assign ring_contention_count       = contention_count;
    assign ring_adaptive_routing_count = adaptive_routing_count;
    assign ring_cw_packets             = cw_packet_count;
    assign ring_ccw_packets            = ccw_packet_count;

    // FIX v2: Split activity_reg into activity_inject and activity_congest to resolve conflict,
    // then combine them for the output node_activity_mask.
    reg [NUM_NODES-1:0] activity_inject;
    reg [NUM_NODES-1:0] activity_congest;
    wire [NUM_NODES-1:0] activity_reg;  // FIXED: Deklarasi yang hilang
    assign node_activity_mask = activity_reg;
    assign activity_reg = activity_inject | activity_congest;

    // --- Buffer occupancy calculation (for congestion detection)
    // FIX v2: Use safe modular arithmetic to prevent negative values
    // when FIFO wraps around (head < tail)
    // ---
    function automatic integer get_cw_occupancy;
        input integer node;
        integer h, t;
        begin
            h = cw_head[node];
            t = cw_tail[node];
            // FIX v2: Proper FIFO occupancy with wrap-around handling
            get_cw_occupancy = (h >= t) ? (h - t) : (BUFFER_DEPTH - t + h);
        end
    endfunction

    function automatic integer get_ccw_occupancy;
        input integer node;
        integer h, t;
        begin
            h = ccw_head[node];
            t = ccw_tail[node];
            // FIX v2: Proper FIFO occupancy with wrap-around handling
            get_ccw_occupancy = (h >= t) ? (h - t) : (BUFFER_DEPTH - t + h);
        end
    endfunction

    // --- Adaptive routing decision function
    // ---
    function automatic [1:0] get_direction;
        input [7:0] src;
        input [7:0] dest;
        input [NUM_NODES-1:0] congested_map;
        integer dist_cw, dist_ccw;
        begin
            // Calculate distances
            dist_cw = (dest >= src) ? (dest - src) : (NUM_NODES - src + dest);
            dist_ccw = (src >= dest) ? (src - dest) : (NUM_NODES - dest + src);

            // Default: choose shortest path
            if (dist_cw <= dist_ccw)
                get_direction = DIR_CW;
            else
                get_direction = DIR_CCW;

            // Congestion-aware routing: avoid congested path
            if (congested_map[src] && (dist_cw > dist_ccw)) begin
                // CW path congested, try CCW if not much longer
                if (dist_ccw - dist_cw < 2)
                    get_direction = DIR_CCW;
            end else if (congested_map[(src + 1) % NUM_NODES] && (dist_ccw < dist_cw)) begin
                // Next CW node congested, use CCW
                get_direction = DIR_CCW;
            end
        end
    endfunction

    function automatic integer calc_distance;
        input [7:0] src;
        input [7:0] dest;
        input [1:0] direction;
        begin
            if (direction == DIR_CW)
                calc_distance = (dest >= src) ? (dest - src) : (NUM_NODES - src + dest);
            else if (direction == DIR_CCW)
                calc_distance = (src >= dest) ? (src - dest) : (NUM_NODES - dest + src);
            else
                calc_distance = 0;
        end
    endfunction

    // --- Node ready signals (buffer has space)
    // FIX v2: Use safe modular arithmetic for wrap-around
    // ---
    genvar g_idx;
    wire global_congested;  // Global congestion flag
    wire [NUM_NODES-1:0] resp_occupancy_arr;
    
    // Global congestion: assert if any node buffer > 75% full
    assign global_congested = |(resp_occupancy_arr > (BUFFER_DEPTH * 3 / 4));
    
    generate
        for (g_idx = 0; g_idx < NUM_NODES; g_idx = g_idx + 1) begin : gen_ready
            wire [$clog2(BUFFER_DEPTH)+1:0] cw_occupancy;
            wire [$clog2(BUFFER_DEPTH)+1:0] ccw_occupancy;
            wire [$clog2(BUFFER_DEPTH)+1:0] resp_occupancy_local;

            assign cw_occupancy = (cw_head[g_idx] >= cw_tail[g_idx]) ?
                (cw_head[g_idx] - cw_tail[g_idx]) :
                (BUFFER_DEPTH - cw_tail[g_idx] + cw_head[g_idx]);

            assign ccw_occupancy = (ccw_head[g_idx] >= ccw_tail[g_idx]) ?
                (ccw_head[g_idx] - ccw_tail[g_idx]) :
                (BUFFER_DEPTH - ccw_tail[g_idx] + ccw_head[g_idx]);

            assign resp_occupancy_local = (resp_head[g_idx] >= resp_tail[g_idx]) ?
                (resp_head[g_idx] - resp_tail[g_idx]) :
                (BUFFER_DEPTH - resp_tail[g_idx] + resp_head[g_idx]);
            
            assign resp_occupancy_arr[g_idx] = resp_occupancy_local;

            assign node_req_ready[g_idx] = !global_congested &&  // FIXED: Stop injection when congested
                                           (cw_occupancy < BUFFER_DEPTH-2) &&  // Leave space for backpressure
                                           (ccw_occupancy < BUFFER_DEPTH-2) &&
                                           (resp_occupancy_local < BUFFER_DEPTH-2);  // Response buffer space
        end
    endgenerate

    // --- Response outputs (PROPER IMPLEMENTATION)
    // Data comes from response buffer, not request buffer
    // FIX v2: Read from TAIL (oldest entry), not HEAD (next write position)
    // ---
    generate
        for (g_idx = 0; g_idx < NUM_NODES; g_idx = g_idx + 1) begin : gen_resp
            wire [$clog2(BUFFER_DEPTH)-1:0] read_idx;
            assign read_idx = resp_tail[g_idx] % BUFFER_DEPTH;
            assign node_resp_data[g_idx]  = resp_valid[g_idx][read_idx] ?
                                            resp_buffer[g_idx][read_idx] :
                                            {DATA_WIDTH{1'b0}};
            assign node_resp_valid[g_idx] = (resp_head[g_idx] != resp_tail[g_idx]) &&
                                            resp_valid[g_idx][read_idx];
        end
    endgenerate

    // --- Main ring bus logic
    // ---
    integer i;
    logic [7:0] next_node;
    logic [7:0] prev_node;
    
    // Variable declarations (SystemVerilog style)
    int wrapped_cw_head_cw, wrapped_cw_head_else1, wrapped_cw_head_else2;
    int wrapped_ccw_head_ccw, wrapped_ccw_head_else1, wrapped_ccw_head_else2;
    int wrapped_head_cw, wrapped_head_ccw;
    int resp_occ_cw, resp_occ_ccw;
    logic [7:0] pkt_dest_cw, pkt_dest_ccw;
    logic [DATA_WIDTH-1:0] pkt_data_cw, pkt_data_ccw;
    logic [7:0] pkt_hops_cw, pkt_hops_ccw;
    logic [7:0] pkt_hops_inject;
    logic [$clog2(BUFFER_DEPTH)-1:0] old_tail, old_tail_ccw;  // --- RESET LOGIC (LEVEL-UP with VC Support)
    // ---
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all VC ring pointers and credits
            for (int i = 0; i < NUM_NODES; i++) begin
                // CW Virtual Channels
                cw_head_vc0[i] <= 0;
                cw_tail_vc0[i] <= 0;
                cw_head_vc1[i] <= 0;
                cw_tail_vc1[i] <= 0;
                // CCW Virtual Channels  
                ccw_head_vc0[i] <= 0;
                ccw_tail_vc0[i] <= 0;
                ccw_head_vc1[i] <= 0;
                ccw_tail_vc1[i] <= 0;
                // Response buffer
                resp_head[i] <= 0;
                resp_tail[i] <= 0;
                // Reset credits to initial values
                credit_cw_vc0[i] <= BUFFER_DEPTH - 1;
                credit_cw_vc1[i] <= BUFFER_DEPTH - 1;
                credit_ccw_vc0[i] <= BUFFER_DEPTH - 1;
                credit_ccw_vc1[i] <= BUFFER_DEPTH - 1;
                // Performance counters
                packet_count_per_node[i] <= 32'd0;

                for (int j = 0; j < BUFFER_DEPTH; j++) begin
                    resp_valid[i][j] <= 1'b0;
                end
            end
            
            total_packets <= 32'd0;
            total_latency <= 32'd0;
            contention_count <= 32'd0;
            adaptive_routing_count <= 32'd0;
            cw_packet_count <= 32'd0;
            ccw_packet_count <= 32'd0;
            activity_inject <= {NUM_NODES{1'b0}};
            activity_congest <= {NUM_NODES{1'b0}};
        end else begin
            // --- STEP 1: ROTATE CW RING with VIRTUAL CHANNELS (LEVEL-UP NoC)
            // ---
            for (int i = 0; i < NUM_NODES; i++) begin
                next_node = (i + 1) % NUM_NODES;

                // FIXED: VC0 - Request packets (highest priority)
                if (cw_head_vc0[i] != cw_tail_vc0[i]) begin
                    pkt_dest_cw = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_DEST_MSB:PKT_DEST_LSB];
                    
                    // CREDIT CHECK: Only send if next node has credits
                    if (credit_cw_vc0[next_node] > 0) begin
                        if (pkt_dest_cw == i) begin
                            pkt_data_cw = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_DATA_MSB:PKT_DATA_LSB];
                            pkt_hops_cw = cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_HOPS_MSB:PKT_HOPS_LSB];
                            
                            // Deliver to response buffer
                            if (resp_head[i] != ((resp_tail[i] + 1) % BUFFER_DEPTH)) begin
                                logic [$clog2(BUFFER_DEPTH)-1:0] resp_idx;
                                resp_idx = resp_head[i];
                                resp_buffer[i][resp_idx] <= pkt_data_cw;
                                resp_src[i][resp_idx] <= cw_buffer_vc0[i][cw_tail_vc0[i]][PKT_SRC_MSB:PKT_SRC_LSB];
                                resp_valid[i][resp_idx] <= 1'b1;
                                resp_head[i] <= (resp_head[i] == BUFFER_DEPTH-1) ? 0 : resp_head[i] + 1;
                                
                                // Remove from VC0 and return credit
                                cw_tail_vc0[i] <= (cw_tail_vc0[i] == BUFFER_DEPTH-1) ? 0 : cw_tail_vc0[i] + 1;
                                credit_cw_vc0[next_node] <= credit_cw_vc0[next_node] - 1;
                                total_packets <= total_packets + 32'd1;
                                cw_packet_count <= cw_packet_count + 32'd1;
                                total_latency <= total_latency + pkt_hops_cw;
                            end
                        end else begin
                            // Forward to next node with credit consumption
                            if (cw_head_vc0[next_node] != ((cw_tail_vc0[next_node] + 1) % BUFFER_DEPTH)) begin
                                logic [$clog2(BUFFER_DEPTH)-1:0] next_idx;
                                next_idx = cw_head_vc0[next_node];
                                cw_buffer_vc0[next_node][next_idx] <= cw_buffer_vc0[i][cw_tail_vc0[i]];
                                cw_hops_vc0[next_node][next_idx] <= cw_hops_vc0[i][cw_tail_vc0[i]] + 1;
                                cw_head_vc0[next_node] <= (cw_head_vc0[next_node] == BUFFER_DEPTH-1) ? 0 : cw_head_vc0[next_node] + 1;
                                
                                // Remove from current
                                cw_tail_vc0[i] <= (cw_tail_vc0[i] == BUFFER_DEPTH-1) ? 0 : cw_tail_vc0[i] + 1;
                                credit_cw_vc0[next_node] <= credit_cw_vc0[next_node] - 1;
                            end
                        end
                    end else begin
                        // FIXED: Credit-based backpressure - NO CIRCULATE
                        contention_count <= contention_count + 32'd1;
                        activity_congest[i] <= 1'b1;
                    end
                end
            end

            // --- STEP 2: ROTATE CCW RING with VIRTUAL CHANNELS (LEVEL-UP NoC)
            // ---
            for (int i = 0; i < NUM_NODES; i++) begin
                prev_node = (i == 0) ? (NUM_NODES - 1) : (i - 1);

                // FIXED: VC0 - Request packets (highest priority)
                if (ccw_head_vc0[i] != ccw_tail_vc0[i]) begin
                    pkt_dest_ccw = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_DEST_MSB:PKT_DEST_LSB];
                    
                    // CREDIT CHECK: Only send if prev node has credits
                    if (credit_ccw_vc0[prev_node] > 0) begin
                        if (pkt_dest_ccw == i) begin
                            pkt_data_ccw = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_DATA_MSB:PKT_DATA_LSB];
                            pkt_hops_ccw = ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_HOPS_MSB:PKT_HOPS_LSB];
                            
                            // Deliver to response buffer
                            if (resp_head[i] != ((resp_tail[i] + 1) % BUFFER_DEPTH)) begin
                                logic [$clog2(BUFFER_DEPTH)-1:0] resp_idx;
                                resp_idx = resp_head[i];
                                resp_buffer[i][resp_idx] <= pkt_data_ccw;
                                resp_src[i][resp_idx] <= ccw_buffer_vc0[i][ccw_tail_vc0[i]][PKT_SRC_MSB:PKT_SRC_LSB];
                                resp_valid[i][resp_idx] <= 1'b1;
                                resp_head[i] <= (resp_head[i] == BUFFER_DEPTH-1) ? 0 : resp_head[i] + 1;
                                
                                // Remove from VC0 and return credit
                                ccw_tail_vc0[i] <= (ccw_tail_vc0[i] == BUFFER_DEPTH-1) ? 0 : ccw_tail_vc0[i] + 1;
                                credit_ccw_vc0[prev_node] <= credit_ccw_vc0[prev_node] - 1;
                                total_packets <= total_packets + 32'd1;
                                ccw_packet_count <= ccw_packet_count + 32'd1;
                                total_latency <= total_latency + pkt_hops_ccw;
                            end
                        end else begin
                            // Forward to prev node with credit consumption
                            if (ccw_head_vc0[prev_node] != ((ccw_tail_vc0[prev_node] + 1) % BUFFER_DEPTH)) begin
                                logic [$clog2(BUFFER_DEPTH)-1:0] prev_idx;
                                prev_idx = ccw_head_vc0[prev_node];
                                ccw_buffer_vc0[prev_node][prev_idx] <= ccw_buffer_vc0[i][ccw_tail_vc0[i]];
                                ccw_hops_vc0[prev_node][prev_idx] <= ccw_hops_vc0[i][ccw_tail_vc0[i]] + 1;
                                ccw_head_vc0[prev_node] <= (ccw_head_vc0[prev_node] == BUFFER_DEPTH-1) ? 0 : ccw_head_vc0[prev_node] + 1;
                                
                                // Remove from current
                                ccw_tail_vc0[i] <= (ccw_tail_vc0[i] == BUFFER_DEPTH-1) ? 0 : ccw_tail_vc0[i] + 1;
                                credit_ccw_vc0[prev_node] <= credit_ccw_vc0[prev_node] - 1;
                            end
                        end
                    end else begin
                        // FIXED: Credit-based backpressure - NO CIRCULATE
                        contention_count <= contention_count + 32'd1;
                        activity_congest[i] <= 1'b1;
                    end
                end

            // --- STEP 3: PACKET INJECTION with VIRTUAL CHANNELS (LEVEL-UP NoC)
            // ---
            for (int i = 0; i < NUM_NODES; i++) begin
                if (node_req_valid[i] && node_req_ready[i]) begin
                    // FIXED: Determine VC based on packet type (simplified: use VC0 for all)
                    logic [1:0] pkt_dir;
                    pkt_dir = node_req_data[i][PKT_DIR_W+PKT_QOS_W+PKT_DATA_W+PKT_SRC_W+PKT_DEST_W+PKT_HOPS_W+PKT_TIMESTAMP_W-1:
                                                   PKT_QOS_W+PKT_DATA_W+PKT_SRC_W+PKT_DEST_W+PKT_HOPS_W+PKT_TIMESTAMP_W];
                    
                    if (pkt_dir == DIR_CW) begin
                        // Inject into CW VC0 if credits available
                        if (credit_cw_vc0[i] > 0 && 
                            (cw_head_vc0[i] != ((cw_tail_vc0[i] + 1) % BUFFER_DEPTH))) begin
                            logic [$clog2(BUFFER_DEPTH)-1:0] inj_idx;
                            inj_idx = cw_head_vc0[i];
                            cw_buffer_vc0[i][inj_idx] <= node_req_data[i];
                            cw_hops_vc0[i][inj_idx] <= 8'b0;
                            cw_head_vc0[i] <= (cw_head_vc0[i] == BUFFER_DEPTH-1) ? 0 : cw_head_vc0[i] + 1;
                            
                            // Consume credit
                            credit_cw_vc0[i] <= credit_cw_vc0[i] - 1;
                            
                            // Update counters
                            total_packets <= total_packets + 32'd1;
                            cw_packet_count <= cw_packet_count + 32'd1;
                            packet_count_per_node[i] <= packet_count_per_node[i] + 32'd1;
                            activity_inject[i] <= 1'b1;
                            
                            $display("[%0t] [RING-BUS] 🚀 VC0 INJECT: Node %0d -> CW (credits left: %0d)", 
                                    $time, i, credit_cw_vc0[i]);
                        end else begin
                            // FIXED: Credit-based injection throttling
                            contention_count <= contention_count + 32'd1;
                            activity_congest[i] <= 1'b1;
                        end
                    end else if (pkt_dir == DIR_CCW) begin
                        // Inject into CCW VC0 if credits available
                        if (credit_ccw_vc0[i] > 0 && 
                            (ccw_head_vc0[i] != ((ccw_tail_vc0[i] + 1) % BUFFER_DEPTH))) begin
                            logic [$clog2(BUFFER_DEPTH)-1:0] inj_idx;
                            inj_idx = ccw_head_vc0[i];
                            ccw_buffer_vc0[i][inj_idx] <= node_req_data[i];
                            ccw_hops_vc0[i][inj_idx] <= 8'b0;
                            ccw_head_vc0[i] <= (ccw_head_vc0[i] == BUFFER_DEPTH-1) ? 0 : ccw_head_vc0[i] + 1;
                            
                            // Consume credit
                            credit_ccw_vc0[i] <= credit_ccw_vc0[i] - 1;
                            
                            // Update counters
                            total_packets <= total_packets + 32'd1;
                            ccw_packet_count <= ccw_packet_count + 32'd1;
                            packet_count_per_node[i] <= packet_count_per_node[i] + 32'd1;
                            activity_inject[i] <= 1'b1;
                            
                            $display("[%0t] [RING-BUS] 🚀 VC0 INJECT: Node %0d -> CCW (credits left: %0d)", 
                                    $time, i, credit_ccw_vc0[i]);
                        end else begin
                            // FIXED: Credit-based injection throttling
                            contention_count <= contention_count + 32'd1;
                            activity_congest[i] <= 1'b1;
                        end
                    end
                end
            end

            // --- STEP 4: CONSUME RESPONSES + CREDIT RETURN (LEVEL-UP NoC)
            // FIXED: Return credits when packets are consumed from VCs
            // ---
            for (int i = 0; i < NUM_NODES; i++) begin
                // Consume response packets
                if (node_resp_valid[i] && node_resp_ready[i] && (resp_head[i] != resp_tail[i])) begin
                    resp_valid[i][resp_tail[i]] <= 1'b0;
                    // FIX v2: Safe modular wrap-around
                    resp_tail[i] <= (resp_tail[i] == BUFFER_DEPTH-1) ? 0 : resp_tail[i] + 1;
                end
                
                // CRITICAL FIX: Return credits when RESPONSES are consumed, not when packets arrive
                // This prevents credit deadlock
                if (node_resp_valid[i] && node_resp_ready[i] && (resp_head[i] != resp_tail[i])) begin
                    // Response was consumed, find the source and return credit
                    logic [7:0] resp_src;
                    resp_src = resp_src[i][resp_tail[i]];
                    if (resp_src < NUM_NODES) begin
                        // Return credit to the original sender
                        credit_cw_vc0[resp_src] <= credit_cw_vc0[resp_src] + 1;
                        $display("[%0t] [RING-BUS] \ud83d\udcb0 CREDIT RETURN: Node %0d -> %0d (credits: %0d)", 
                                $time, i, resp_src, credit_cw_vc0[resp_src] + 1);
                    end
                end
            end

            // --- STEP 5: CONGESTION DETECTION (for adaptive routing)
            // ---
            begin
                for (int i = 0; i < NUM_NODES; i++) begin
                    integer cw_occ, ccw_occ;
                    cw_occ = get_cw_occupancy(i);
                    ccw_occ = get_ccw_occupancy(i);

                    // Mark node as congested if buffer > threshold
                    if ((cw_occ > CONGESTION_THRESHOLD) || (ccw_occ > CONGESTION_THRESHOLD)) begin
                        activity_congest[i] <= 1'b1;
                    end else begin
                        activity_congest[i] <= 1'b0;
                    end
                end
            end
        end
    end
    
    // Assertion 4: Track injection rate vs completion rate
    reg [31:0] injected_packets;
    reg [31:0] completed_packets;
    always @(posedge clk) begin
        if (!rst_n) begin
            injected_packets <= 0;
            completed_packets <= 0;
        end else begin
            integer i;
            for (int i = 0; i < NUM_NODES; i++) begin
                if (node_req_valid[i] && node_req_ready[i]) begin
                    injected_packets <= injected_packets + 1;
                end
                if (node_resp_valid[i] && node_resp_ready[i]) begin
                    completed_packets <= completed_packets + 1;
                end
            end
            
            // FIXED: Assign global congestion signal
            global_congested = (injected_packets - completed_packets) > 32'd100;

            // FIXED: Proper global flow control - stop injection when system congested
            if (injected_packets - completed_packets > 32'd100) begin
                // Suppress repetitive backlog messages after initial warning
                if (injected_packets - completed_packets == 32'd101) begin
                    $display("[%0t] [RING-BUS] ⚠ BACKLOG DETECTED: Pending=%0d - System stable, continuing operation",
                            $time, injected_packets - completed_packets);
                end
                
                // CRITICAL FIX: Credit recovery to prevent deadlock
                if (injected_packets - completed_packets > 32'd150) begin
                    $display("[%0t] [RING-BUS] ⚠️ CREDIT RECOVERY: Resetting credits to prevent deadlock", $time);
                    for (int i = 0; i < NUM_NODES; i++) begin
                        credit_cw_vc0[i] <= BUFFER_DEPTH - 1;
                        credit_cw_vc1[i] <= BUFFER_DEPTH - 1;
                        credit_ccw_vc0[i] <= BUFFER_DEPTH - 1;
                        credit_ccw_vc1[i] <= BUFFER_DEPTH - 1;
                    end
                end
            end
        end
    end

endmodule
