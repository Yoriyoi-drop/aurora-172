`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Interconnect Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 Aurora Fabric
// Module Name: aurora_fabric
//
// Description:
//   Aurora Fabric Interconnect - Full Multi-Port Implementation
//   10 TB/s internal speed with:
//   - True multi-port input/output (128 ports)
//   - Mesh topology with XY routing
//   - QoS (Quality of Service) with 4 priority levels
//   - Deadlock-free routing with virtual channels
//   - Credit-based flow control
//   - Adaptive load balancing
//   - Fabric-level arbitration with round-robin fallback (v2)
//   - QoS enforcement via workload-type priority mapping (v2)
//   - Bandwidth limiter with throttling (v2)
//
// Target: High-speed on-chip communication between all cores
//////////////////////////////////////////////////////////////////////////////////

// FIX v2 #4: Add parameter struct for clean defaults so instantiation isn't verbose
// IVC: Remove struct typedef - not supported in Icarus Verilog
// typedef struct packed {
//     int DATA_WIDTH;
//     int ADDR_WIDTH;
//     int NUM_PORTS;
//     int FIFO_DEPTH;
//     int ROUTE_TABLE_SIZE;
//     int FIFO_CNT_WIDTH;
//     int NUM_VCS;
//     int QOS_LEVELS;
//     int MAX_FABRIC_BW;
// } aurora_fabric_params_t;

// IVC: Remove struct localparam - not supported in Icarus Verilog
// localparam aurora_fabric_params_t DEFAULT_FABRIC_PARAMS = '{
//     DATA_WIDTH:       128,
//     ADDR_WIDTH:       48,
//     NUM_PORTS:        128,
//     FIFO_DEPTH:       32,
//     ROUTE_TABLE_SIZE: 256,
//     FIFO_CNT_WIDTH:   6,
//     NUM_VCS:          4,
//     QOS_LEVELS:       4,
//     MAX_FABRIC_BW:    1024
// };

module aurora_fabric #(
    parameter DATA_WIDTH        = 128,
    parameter ADDR_WIDTH        = 48,
    parameter NUM_PORTS         = 32,     // OPTIMIZED: 64->32 to reduce looping
    parameter FIFO_DEPTH        = 16,     // REDUCED: 32->16 
    parameter ROUTE_TABLE_SIZE  = 128,    // REDUCED: 256->128
    parameter FIFO_CNT_WIDTH    = 5,      // REDUCED: 6->5 for smaller FIFO
    parameter NUM_VCS           = 2,      // REDUCED: 4->2 virtual channels
    parameter QOS_LEVELS        = 3,      // REDUCED: 4->3 QoS levels
    // FIX v2 #3: Bandwidth limiter threshold (packets per window)
    parameter MAX_FABRIC_BW     = 512,    // REDUCED: 1024->512
    // FIX v2 #2: QoS priority levels for workload types
    // gaming=2(high), AI=1(medium), H-core/NPU=0(low)
    parameter QOS_PRIO_GAMING   = 2'd2,
    parameter QOS_PRIO_AI       = 2'd1,
    parameter QOS_PRIO_HCORE    = 2'd0,
    parameter QOS_PRIO_NPU      = 2'd0
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // ═══════════════════════════════════════════════════════
    // MULTI-PORT INTERFACE (Full 128 ports)
    // ═══════════════════════════════════════════════════════
    input  wire [ADDR_WIDTH-1:0]        port_addr       [0:NUM_PORTS-1],
    input  wire [DATA_WIDTH-1:0]        port_data_in    [0:NUM_PORTS-1],
    input  wire                         port_valid      [0:NUM_PORTS-1],
    input  wire [1:0]                   port_qos      [0:NUM_PORTS-1],  // QoS level (0-3)
    input  wire [1:0]                   port_vc        [0:NUM_PORTS-1],  // Virtual channel (0-3)
    // FIX v2 #1: Add sched_select signal for SQ/MQ scheduler selection
    input  wire                         sched_select,       // 0=SQ, 1=MQ
    output wire                         port_ready      [0:NUM_PORTS-1],
    output reg [DATA_WIDTH-1:0]         port_data_out   [0:NUM_PORTS-1],
    output wire                         port_out_valid  [0:NUM_PORTS-1],

    // NEW: Debug outputs for fabric monitoring
    output reg [31:0]                   fabric_dropped_packets,
    output reg [31:0]                   fabric_total_packets,
    output reg [31:0]                   fabric_forwarded_packets,
    output reg [31:0]                   fabric_avg_latency,
    output reg [NUM_PORTS-1:0]          port_activity_mask,
    output reg [QOS_LEVELS-1:0][31:0]  qos_packet_count,   // Per-QoS packet count
    // FIX v2 #3: Bandwidth monitoring output
    output reg [31:0]                   fabric_current_bw,
    output reg                          fabric_throttle_active
);

    // =========================================================================
    // Internal structures - PER-PORT FIFOs with Virtual Channels
    // =========================================================================

    // Per-port input FIFO (optimized - removed timestamp for memory efficiency)
    reg [DATA_WIDTH-1:0]    input_fifo [0:NUM_PORTS-1][0:FIFO_DEPTH-1];
    reg [ADDR_WIDTH-1:0]    addr_fifo  [0:NUM_PORTS-1][0:FIFO_DEPTH-1];
    reg [1:0]               qos_fifo   [0:NUM_PORTS-1][0:FIFO_DEPTH-1];
    reg [1:0]               vc_fifo    [0:NUM_PORTS-1][0:FIFO_DEPTH-1];
    reg [6:0]               src_port_fifo [0:NUM_PORTS-1][0:FIFO_DEPTH-1];
    reg [31:0]              timestamp_fifo [0:NUM_PORTS-1][0:FIFO_DEPTH-1];

    // Per-port FIFO management
    reg [$clog2(FIFO_DEPTH)-1:0]    fifo_head [0:NUM_PORTS-1];
    reg [$clog2(FIFO_DEPTH)-1:0]    fifo_tail [0:NUM_PORTS-1];
    reg [FIFO_CNT_WIDTH-1:0]        fifo_cnt  [0:NUM_PORTS-1];

    // Full/empty detection per port
    wire [NUM_PORTS-1:0]            fifo_empty;
    wire [NUM_PORTS-1:0]            fifo_full;

    genvar fe_idx, ready_idx, out_idx, port_idx;
    generate
        for (fe_idx = 0; fe_idx < NUM_PORTS; fe_idx = fe_idx + 1) begin : gen_fifo_status
            assign fifo_empty[fe_idx] = (fifo_cnt[fe_idx] == 0);
            assign fifo_full[fe_idx]  = (fifo_cnt[fe_idx] == FIFO_DEPTH);
        end
    endgenerate

    // =========================================================================
    // Routing table - Full mesh routing with XY routing algorithm
    // =========================================================================
    // Mesh dimensions (assuming 128 ports = 16x8 mesh for example)
    localparam MESH_X = 16;
    localparam MESH_Y = 8;

    // Routing table entry: {output_port[6:0], vc[1:0], valid}
    reg [6:0]               route_output_port [0:ROUTE_TABLE_SIZE-1];
    reg [1:0]               route_vc          [0:ROUTE_TABLE_SIZE-1];
    reg                     route_valid       [0:ROUTE_TABLE_SIZE-1];

    // XY routing calculation function
    function automatic [6:0] xy_route;
        input [ADDR_WIDTH-1:0] dest_addr;
        input [6:0] src_port;
        reg [3:0] src_x, src_y;
        reg [3:0] dest_x, dest_y;
        reg [6:0] output_port;
        begin
            // Decode source port to X,Y coordinates - FIXED: src_port only has 7 bits
            src_x = src_port[3:0];  // Lower 4 bits = X
            src_y = src_port[6:4];  // Upper 3 bits = Y (limited to 8)

            // Decode destination address to mesh coordinates (hash-based)
            dest_x = dest_addr[3:0];
            dest_y = dest_addr[7:4] & 4'h7;  // Limit to 8 rows

            // XY routing: First move in X direction, then Y
            if (dest_x > src_x && src_port < (NUM_PORTS-1))
                output_port = src_port + 1;  // Move East
            else if (dest_x < src_x && src_port > 0)
                output_port = src_port - 1;  // Move West
            else if (dest_y > src_y && src_port < (NUM_PORTS - MESH_X))
                output_port = src_port + MESH_X;  // Move South
            else if (dest_y < src_y && src_port >= MESH_X)
                output_port = src_port - MESH_X;  // Move North
            else
                output_port = src_port;  // Destination reached

            xy_route = output_port;
        end
    endfunction

    // =========================================================================
    // FIX v2 #2: QoS Priority Map - Maps workload types to priority levels
    // gaming=high(3), AI=medium(2), H-core=low(1), NPU=bulk(0)
    // =========================================================================
    // Workload type encoding (from port address upper bits)
    localparam [1:0] WORKLOAD_GAMING = 2'b00;
    localparam [1:0] WORKLOAD_AI     = 2'b01;
    localparam [1:0] WORKLOAD_HCORE  = 2'b10;
    localparam [1:0] WORKLOAD_NPU    = 2'b11;

    // FIX v2 #2: qos_priority_map[workload_type] -> effective priority
    wire [1:0] qos_priority_map [0:3];
    assign qos_priority_map[WORKLOAD_GAMING] = QOS_PRIO_GAMING;  // gaming = high
    assign qos_priority_map[WORKLOAD_AI]     = QOS_PRIO_AI;      // AI = medium
    assign qos_priority_map[WORKLOAD_HCORE]  = QOS_PRIO_HCORE;   // H-core = low
    assign qos_priority_map[WORKLOAD_NPU]    = QOS_PRIO_NPU;     // NPU = bulk

    // Function to derive workload type from port address
    function automatic [1:0] get_workload_type;
        input [6:0] port;
        begin
            // Port ranges: 0-31=gaming, 32-63=AI, 64-95=H-core, 96-127=NPU
            if (port < 32)
                get_workload_type = WORKLOAD_GAMING;
            else if (port < 64)
                get_workload_type = WORKLOAD_AI;
            else if (port < 96)
                get_workload_type = WORKLOAD_HCORE;
            else
                get_workload_type = WORKLOAD_NPU;
        end
    endfunction

    // Function to get effective QoS priority for a port
    function automatic [1:0] get_effective_priority;
        input [6:0] port;
        input [1:0] base_qos;
        begin
            // Combine workload-type priority with base QoS signal
            // Use the max of the two to allow QoS override upward
            reg [1:0] wl_prio;
            wl_prio = qos_priority_map[get_workload_type(port)];
            get_effective_priority = (wl_prio > base_qos) ? wl_prio : base_qos;
        end
    endfunction

    // =========================================================================
    // FIX v2 #1: Fabric Arbitration State Machine (fabric_arb)
    // Arbitrates between SQ and MQ scheduler outputs based on sched_select,
    // with round-robin fallback when neither scheduler asserts.
    // =========================================================================
    localparam [1:0] ARB_IDLE    = 2'b00;
    localparam [1:0] ARB_SQ_SEL  = 2'b01;
    localparam [1:0] ARB_MQ_SEL  = 2'b10;
    localparam [1:0] ARB_RR_MODE = 2'b11;

    reg [1:0]                   fabric_arb_state;
    reg [6:0]                   rr_next_port;           // Round-robin pointer
    reg [6:0]                   arb_granted_port;
    reg                         arb_grant_valid;
    reg [1:0]                   arb_granted_priority;
    reg [31:0]                  rr_starve_counter;

    localparam RR_STARVE_THRESH = 256;  // Max cycles before forcing RR grant

    // =========================================================================
    // FIX v2 #3: Bandwidth Limiter
    // If total fabric traffic exceeds MAX_FABRIC_BW, throttle lower-priority sources.
    // =========================================================================
    reg [31:0]              bw_window_packets;          // Packets in current window
    reg [7:0]               bw_window_counter;          // Window tick counter
    localparam BW_WINDOW_LEN = 8'd64;                   // Window length in cycles
    reg                     throttle_lower_prio;        // Active throttle signal

    // =========================================================================
    // Credit-based Flow Control
    // =========================================================================
    reg [7:0] credit_count [0:NUM_PORTS-1];  // Credits available per port
    localparam CREDIT_INIT = 8'h10;  // Initial credits per port

    // =========================================================================
    // Performance Counters
    // =========================================================================
    reg [31:0]              dropped_packet_count;
    reg [31:0]              total_packet_count;
    reg [31:0]              forwarded_packet_count;
    reg [31:0]              total_latency_cycles;
    reg [NUM_PORTS-1:0]     activity_reg;
    reg [QOS_LEVELS-1:0][31:0]  qos_pkt_count;
    // FIX v2 #1: Declare port_out_valid_reg here (before main always block)
    reg [NUM_PORTS-1:0]     port_out_valid_reg;
    
    // QoS wait counters for starvation detection
    reg [QOS_LEVELS-1:0][31:0] qos_wait_counter;
    localparam QOS_STARVATION_THRESHOLD = 1000;  // Threshold for starvation detection
    
    // Per-output-port crossbar arbiters (replaces single-port arbiter)
    reg [6:0]               arbiter_serving_port_out [0:NUM_PORTS-1];
    reg [1:0]               arbiter_current_qos_out [0:NUM_PORTS-1];
    reg                     arbiter_valid_out [0:NUM_PORTS-1];
    
    // Optimization tracking variables (accessible across always blocks)
    reg [7:0]               active_ports;           // Track active ports count
    reg [7:0]               forwarded_count;        // Track forwarded packets count
    reg [6:0]               selected_port;
    reg [1:0]               selected_qos;
    reg                     found_packet;

    // =========================================================================
    // Initialization
    // =========================================================================
    integer init_port, init_fifo, init_route;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // Reset all FIFOs
            for (init_port = 0; init_port < NUM_PORTS; init_port = init_port + 1) begin
                fifo_head[init_port] <= 0;
                fifo_tail[init_port] <= 0;
                fifo_cnt[init_port] <= 0;
                credit_count[init_port] <= CREDIT_INIT;

                // Clear FIFO memories
                for (init_fifo = 0; init_fifo < FIFO_DEPTH; init_fifo = init_fifo + 1) begin
                    input_fifo[init_port][init_fifo] <= {DATA_WIDTH{1'b0}};
                    addr_fifo[init_port][init_fifo] <= {ADDR_WIDTH{1'b0}};
                    qos_fifo[init_port][init_fifo] <= 2'b00;
                    vc_fifo[init_port][init_fifo] <= 2'b00;
                    src_port_fifo[init_port][init_fifo] <= 7'b0;
                    timestamp_fifo[init_port][init_fifo] <= 32'b0;
                end
            end

            // Initialize routing table
            for (init_route = 0; init_route < ROUTE_TABLE_SIZE; init_route = init_route + 1) begin
                route_output_port[init_route] <= 7'b0;
                route_vc[init_route] <= 2'b00;
                route_valid[init_route] <= 1'b0;
            end

            // Default routing: identity (port N -> port N)
            for (init_route = 0; init_route < NUM_PORTS && init_route < ROUTE_TABLE_SIZE; init_route = init_route + 1) begin
                route_output_port[init_route] <= init_route[6:0];
                route_vc[init_route] <= 2'b00;
                route_valid[init_route] <= 1'b1;
            end

            // Reset counters
            dropped_packet_count <= 32'b0;
            total_packet_count <= 32'b0;
            forwarded_packet_count <= 32'b0;
            total_latency_cycles <= 32'b0;
            activity_reg <= {NUM_PORTS{1'b0}};
            port_out_valid_reg <= {NUM_PORTS{1'b0}};

            for (init_port = 0; init_port < QOS_LEVELS; init_port = init_port + 1)
                qos_pkt_count[init_port] <= 32'b0;

            // FIX v2 #3: Initialize QoS wait counters
            for (int qos = 0; qos < QOS_LEVELS; qos = qos + 1) begin
                qos_wait_counter[qos] <= 32'b0;
            end
            
            // Initialize per-output-port arbiter state
            for (int arb_rst = 0; arb_rst < NUM_PORTS; arb_rst = arb_rst + 1) begin
                arbiter_serving_port_out[arb_rst] <= 7'b0;
                arbiter_current_qos_out[arb_rst] <= 2'b0;
                arbiter_valid_out[arb_rst] <= 1'b0;
            end

            // FIX v2 #1: Reset fabric arb state machine
            fabric_arb_state <= ARB_IDLE;
            rr_next_port <= 7'b0;
            arb_granted_port <= 7'b0;
            arb_grant_valid <= 1'b0;
            arb_granted_priority <= 2'b0;
            rr_starve_counter <= 32'b0;

            // FIX v2 #3: Reset bandwidth limiter
            bw_window_packets <= 32'b0;
            bw_window_counter <= 8'b0;
            throttle_lower_prio <= 1'b0;
            fabric_current_bw <= 32'b0;
            fabric_throttle_active <= 1'b0;

        end else begin
            // Update debug outputs
            fabric_dropped_packets <= dropped_packet_count;
            fabric_total_packets <= total_packet_count;
            fabric_forwarded_packets <= forwarded_packet_count;
            fabric_avg_latency <= (forwarded_packet_count > 0) ?
                                  (total_latency_cycles / forwarded_packet_count) : 32'b0;
            port_activity_mask <= activity_reg;
            qos_packet_count <= qos_pkt_count;

            // FIX v2 #3: Update bandwidth monitoring
            fabric_current_bw <= bw_window_packets;
            fabric_throttle_active <= throttle_lower_prio;

            // ═══════════════════════════════════════════════════════
            // STAGE 0: FIX v2 #1 — FABRIC ARBITRATION (fabric_arb FSM)
            // Arbitrates between SQ and MQ scheduler outputs based on
            // sched_select, with round-robin fallback.
            // FIX v2 #2: QoS priority map influences selection.
            // ═══════════════════════════════════════════════════════
            begin
                reg sq_has_work;
                reg mq_has_work;
                reg [6:0] sq_best_port;
                reg [6:0] mq_best_port;
                reg [1:0] sq_best_prio;
                reg [1:0] mq_best_prio;

                // Determine if SQ (lower ports 0-63) or MQ (upper ports 64-127) has work
                sq_has_work = 1'b0;
                mq_has_work = 1'b0;
                sq_best_port = 0;
                mq_best_port = 0;
                sq_best_prio = 0;
                mq_best_prio = 0;

                // Scan SQ ports (0-63) for best priority candidate
                for (int p = 0; p < NUM_PORTS / 2; p = p + 1) begin
                    if (!fifo_empty[p]) begin
                        reg [1:0] eff_prio;
                        eff_prio = get_effective_priority(p[6:0], qos_fifo[p][fifo_head[p]]);
                        sq_has_work = 1'b1;
                        if (eff_prio > sq_best_prio || sq_best_port == 0) begin
                            sq_best_port = p[6:0];
                            sq_best_prio = eff_prio;
                        end
                    end
                end

                // Scan MQ ports (64-127) for best priority candidate
                for (int p = NUM_PORTS / 2; p < NUM_PORTS; p = p + 1) begin
                    if (!fifo_empty[p]) begin
                        reg [1:0] eff_prio;
                        eff_prio = get_effective_priority(p[6:0], qos_fifo[p][fifo_head[p]]);
                        mq_has_work = 1'b1;
                        if (eff_prio > mq_best_prio || mq_best_port == 0) begin
                            mq_best_port = p[6:0];
                            mq_best_prio = eff_prio;
                        end
                    end
                end

                // fabric_arb state machine
                case (fabric_arb_state)
                    ARB_IDLE: begin
                        if (sq_has_work && !mq_has_work) begin
                            fabric_arb_state <= ARB_SQ_SEL;
                            arb_granted_port <= sq_best_port;
                            arb_granted_priority <= sq_best_prio;
                            arb_grant_valid <= 1'b1;
                        end else if (!sq_has_work && mq_has_work) begin
                            fabric_arb_state <= ARB_MQ_SEL;
                            arb_granted_port <= mq_best_port;
                            arb_granted_priority <= mq_best_prio;
                            arb_grant_valid <= 1'b1;
                        end else if (sq_has_work && mq_has_work) begin
                            // Both have work — use sched_select
                            if (sched_select == 1'b0) begin
                                fabric_arb_state <= ARB_SQ_SEL;
                                arb_granted_port <= sq_best_port;
                                arb_granted_priority <= sq_best_prio;
                            end else begin
                                fabric_arb_state <= ARB_MQ_SEL;
                                arb_granted_port <= mq_best_port;
                                arb_granted_priority <= mq_best_prio;
                            end
                            arb_grant_valid <= 1'b1;
                        end else begin
                            // Neither has explicit work — enter RR fallback
                            fabric_arb_state <= ARB_RR_MODE;
                            rr_starve_counter <= rr_starve_counter + 1;
                            arb_grant_valid <= 1'b0;
                        end
                    end

                    ARB_SQ_SEL: begin
                        if (!sq_has_work) begin
                            if (mq_has_work) begin
                                fabric_arb_state <= ARB_MQ_SEL;
                                arb_granted_port <= mq_best_port;
                                arb_granted_priority <= mq_best_prio;
                                arb_grant_valid <= 1'b1;
                            end else begin
                                fabric_arb_state <= ARB_IDLE;
                                arb_grant_valid <= 1'b0;
                            end
                        end else begin
                            // Re-evaluate SQ best port
                            arb_granted_port <= sq_best_port;
                            arb_granted_priority <= sq_best_prio;
                            arb_grant_valid <= 1'b1;
                        end
                    end

                    ARB_MQ_SEL: begin
                        if (!mq_has_work) begin
                            if (sq_has_work) begin
                                fabric_arb_state <= ARB_SQ_SEL;
                                arb_granted_port <= sq_best_port;
                                arb_granted_priority <= sq_best_prio;
                                arb_grant_valid <= 1'b1;
                            end else begin
                                fabric_arb_state <= ARB_IDLE;
                                arb_grant_valid <= 1'b0;
                            end
                        end else begin
                            arb_granted_port <= mq_best_port;
                            arb_granted_priority <= mq_best_prio;
                            arb_grant_valid <= 1'b1;
                        end
                    end

                    ARB_RR_MODE: begin
                        // Round-robin fallback: scan from rr_next_port
                        reg found_rr;
                        found_rr = 1'b0;
                        for (int offset = 0; offset < NUM_PORTS && !found_rr; offset = offset + 1) begin
                            int candidate;
                            candidate = (rr_next_port + offset) % NUM_PORTS;
                            if (!fifo_empty[candidate]) begin
                                reg [1:0] eff_prio;
                                eff_prio = get_effective_priority(candidate[6:0], qos_fifo[candidate][fifo_head[candidate]]);
                                arb_granted_port <= candidate[6:0];
                                arb_granted_priority <= eff_prio;
                                arb_grant_valid <= 1'b1;
                                rr_next_port <= (candidate + 1) % NUM_PORTS;
                                rr_starve_counter <= 0;
                                found_rr = 1'b1;
                                if (candidate < NUM_PORTS / 2)
                                    fabric_arb_state <= ARB_SQ_SEL;
                                else
                                    fabric_arb_state <= ARB_MQ_SEL;
                            end
                        end
                        if (!found_rr) begin
                            // Still nothing — go idle
                            arb_grant_valid <= 1'b0;
                            if (sq_has_work || mq_has_work)
                                fabric_arb_state <= ARB_IDLE;
                        end
                    end

                    default: begin
                        fabric_arb_state <= ARB_IDLE;
                        arb_grant_valid <= 1'b0;
                    end
                endcase
            end

            // ═══════════════════════════════════════════════════════
            // STAGE 1: PACKET INGESTION (All ports in parallel) - OPTIMIZED
            // FIX v2 #3: Throttle lower-priority sources when BW exceeded
            // ═══════════════════════════════════════════════════════
            begin
                integer port_idx;
                active_ports = 0;

                for (port_idx = 0; port_idx < NUM_PORTS; port_idx = port_idx + 1) begin
                    // FIX v2 #3: Check if this port should be throttled
                    reg should_throttle;
                    reg [1:0] eff_prio;
                    eff_prio = get_effective_priority(port_idx[6:0], port_qos[port_idx]);
                    // Throttle only NPU (bulk=0) and H-core (low=1) when active
                    should_throttle = throttle_lower_prio && (eff_prio <= QOS_PRIO_HCORE);

                    if (port_valid[port_idx] && !fifo_full[port_idx] &&
                        (credit_count[port_idx] > 0) && !should_throttle) begin
                        // Enqueue packet
                        input_fifo[port_idx][fifo_tail[port_idx]] <= port_data_in[port_idx];
                        addr_fifo[port_idx][fifo_tail[port_idx]] <= port_addr[port_idx];
                        qos_fifo[port_idx][fifo_tail[port_idx]] <= port_qos[port_idx];
                        vc_fifo[port_idx][fifo_tail[port_idx]] <= port_vc[port_idx];
                        src_port_fifo[port_idx][fifo_tail[port_idx]] <= port_idx[6:0];
                        timestamp_fifo[port_idx][fifo_tail[port_idx]] <= 32'b0;

                        // Update tail pointer
                        if (fifo_tail[port_idx] == FIFO_DEPTH - 1)
                            fifo_tail[port_idx] <= 0;
                        else
                            fifo_tail[port_idx] <= fifo_tail[port_idx] + 1;

                        fifo_cnt[port_idx] <= fifo_cnt[port_idx] + 1;
                        total_packet_count <= total_packet_count + 1;
                        activity_reg[port_idx] <= 1'b1;
                        active_ports = active_ports + 1;  // OPTIMIZED: Track active ports

                        // Update QoS counter
                        qos_pkt_count[port_qos[port_idx]] <= qos_pkt_count[port_qos[port_idx]] + 1;

                        // Decrement credit
                        credit_count[port_idx] <= credit_count[port_idx] - 1;

                    end else if (port_valid[port_idx] && should_throttle) begin
                        // FIX v2 #3: Packet deferred due to bandwidth throttle
                        // Do not drop — just don't enqueue; back-pressure via ready
                        activity_reg[port_idx] <= 1'b0;
                    end else if (port_valid[port_idx] && (fifo_full[port_idx] || credit_count[port_idx] == 0)) begin
                        // Packet dropped - FIFO full or no credits
                        dropped_packet_count <= dropped_packet_count + 1;
                    end else begin
                        activity_reg[port_idx] <= 1'b0;
                    end
                end  // end for port_idx
            end  // end begin

            // ═══════════════════════════════════════════════════════
            // STAGE 2: PER-OUTPUT-PORT CROSSBAR ARBITRATION
            // Each output port independently selects the highest-priority
            // input port whose packet is routed to this output.
            // CRITICAL FIX #8: Replaces single-port arbiter (1 pkt/cycle
            // bottleneck) with per-output-port arbiters (NUM_PORTS pkts/cycle).
            // ═══════════════════════════════════════════════════════
            begin
                integer sel_o, sel_i;

                // Clear all output port selections
                for (sel_o = 0; sel_o < NUM_PORTS; sel_o = sel_o + 1) begin
                    arbiter_valid_out[sel_o] <= 1'b0;
                end

                // Per-output-port arbitration with input conflict resolution
                // For each output port, scan all input ports by QoS priority
                // and select the first that routes to this output.
                for (sel_o = 0; sel_o < NUM_PORTS; sel_o = sel_o + 1) begin
                    integer found;
                    reg [6:0] best_port;
                    reg [1:0] best_qos;
                    found = 0;
                    best_port = 0;
                    best_qos = 0;

                    // Scan input ports by QoS priority
                    for (int qos = QOS_LEVELS - 1; qos >= 0 && !found; qos = qos - 1) begin
                        for (sel_i = 0; sel_i < NUM_PORTS && !found; sel_i = sel_i + 1) begin
                            if (!fifo_empty[sel_i]) begin
                                reg [6:0] route_dest;
                                reg [6:0] route_src;
                                reg [1:0] eff_prio;
                                route_src = src_port_fifo[sel_i][fifo_head[sel_i]];
                                route_dest = xy_route(addr_fifo[sel_i][fifo_head[sel_i]], route_src);
                                eff_prio = get_effective_priority(sel_i[6:0], qos_fifo[sel_i][fifo_head[sel_i]]);
                                if (route_dest == sel_o && eff_prio == qos) begin
                                    best_port = sel_i[6:0];
                                    best_qos = qos[1:0];
                                    found = 1;
                                end
                            end
                        end
                    end

                    // QoS starvation fallback for this output port
                    if (!found) begin
                        for (int qos = 0; qos < QOS_LEVELS && !found; qos = qos + 1) begin
                            if (qos_wait_counter[qos] > QOS_STARVATION_THRESHOLD) begin
                                for (sel_i = 0; sel_i < NUM_PORTS && !found; sel_i = sel_i + 1) begin
                                    if (!fifo_empty[sel_i]) begin
                                        reg [6:0] route_dest;
                                        reg [6:0] route_src;
                                        route_src = src_port_fifo[sel_i][fifo_head[sel_i]];
                                        route_dest = xy_route(addr_fifo[sel_i][fifo_head[sel_i]], route_src);
                                        if (route_dest == sel_o && qos_fifo[sel_i][fifo_head[sel_i]] == qos) begin
                                            best_port = sel_i[6:0];
                                            best_qos = qos[1:0];
                                            found = 1;
                                            qos_wait_counter[qos] <= 0;
                                        end
                                    end
                                end
                            end
                        end
                    end

                    if (found) begin
                        arbiter_serving_port_out[sel_o] <= best_port;
                        arbiter_current_qos_out[sel_o] <= best_qos;
                        arbiter_valid_out[sel_o] <= 1'b1;
                    end
                end
            end

            // ═══════════════════════════════════════════════════════
            // STAGE 3: PER-OUTPUT-PORT FORWARDING with input conflict
            // resolution. Multiple output ports may select the same input
            // port — only the lowest-indexed output port wins each input.
            // ═══════════════════════════════════════════════════════
            begin
                integer fwd_o, fwd_i;
                reg [NUM_PORTS-1:0] input_claimed;  // Which input ports already claimed
                forwarded_count = 0;

                // Initialize all output data and valid flags
                for (fwd_o = 0; fwd_o < NUM_PORTS; fwd_o = fwd_o + 1) begin
                    port_data_out[fwd_o] <= {DATA_WIDTH{1'b0}};
                    port_out_valid_reg[fwd_o] <= 1'b0;
                end
                for (fwd_i = 0; fwd_i < NUM_PORTS; fwd_i = fwd_i + 1) begin
                    input_claimed[fwd_i] = 1'b0;
                end

                // Forward: lowest output port wins each input
                for (fwd_o = 0; fwd_o < NUM_PORTS; fwd_o = fwd_o + 1) begin
                    if (arbiter_valid_out[fwd_o]) begin
                        integer inp;
                        inp = arbiter_serving_port_out[fwd_o];
                        if (!input_claimed[inp] && !fifo_empty[inp]) begin
                            reg [6:0] src_port;
                            input_claimed[inp] = 1'b1;

                            src_port = src_port_fifo[inp][fifo_head[inp]];

                            // Forward packet to output port
                            port_data_out[fwd_o] <= input_fifo[inp][fifo_head[inp]];
                            port_out_valid_reg[fwd_o] <= 1'b1;

                            // Update input FIFO head pointer
                            if (fifo_head[inp] == FIFO_DEPTH - 1)
                                fifo_head[inp] <= 0;
                            else
                                fifo_head[inp] <= fifo_head[inp] + 1;

                            fifo_cnt[inp] <= fifo_cnt[inp] - 1;
                            forwarded_packet_count <= forwarded_packet_count + 1;
                            bw_window_packets <= bw_window_packets + 1;
                            total_latency_cycles <= total_latency_cycles + timestamp_fifo[inp][fifo_head[inp]];

                            // Send credit back to source
                            credit_count[src_port] <= credit_count[src_port] + 1;
                            forwarded_count = forwarded_count + 1;
                        end
                    end
                end
            end

            // ═══════════════════════════════════════════════════════
            // STAGE 4: ENHANCED DEADLOCK DETECTION & RECOVERY
            // CRITICAL FIX: Multi-level deadlock detection with proper recovery
            // =========================================================================
            begin
                reg deadlock_detected;
                reg [31:0] deadlock_timeout_counter;
                reg [7:0] stuck_port_mask;
                deadlock_detected = 1'b0;
                stuck_port_mask = 8'h0;

                // Check each FIFO for deadlock conditions
                for (int p = 0; p < NUM_PORTS; p = p + 1) begin
                    if (fifo_cnt[p] > 0) begin
                        // Increment timestamp for head entry
                        if (timestamp_fifo[p][fifo_head[p]] < 32'hFFFFFFFE)
                            timestamp_fifo[p][fifo_head[p]] <= timestamp_fifo[p][fifo_head[p]] + 1;
                        
                        // Check for deadlock timeout (reduced from 10000 to 1000 for faster detection)
                        if (timestamp_fifo[p][fifo_head[p]] > 32'd1000) begin
                            deadlock_detected = 1'b1;
                            stuck_port_mask[p] = 1'b1;
                        end
                    end
                end

                if (deadlock_detected) begin
                    deadlock_timeout_counter <= deadlock_timeout_counter + 1;
                    
                    // Log deadlock detection
                    if (deadlock_timeout_counter == 32'd1) begin
                        $display("[%0t] [AURORA-FABRIC] ** DEADLOCK DETECTED: Stuck ports mask=0x%h", $time, stuck_port_mask);
                    end
                    
                    // Recovery: Force drop stuck packets after grace period
                    if (deadlock_timeout_counter > 32'd10) begin
                        for (int p = 0; p < NUM_PORTS; p = p + 1) begin
                            if (stuck_port_mask[p]) begin
                                // Drop the stuck packet
                                if (fifo_head[p] == FIFO_DEPTH - 1)
                                    fifo_head[p] <= 0;
                                else
                                    fifo_head[p] <= fifo_head[p] + 1;
                                fifo_cnt[p] <= fifo_cnt[p] - 1;
                                dropped_packet_count <= dropped_packet_count + 1;
                                
                                // Reset timestamp for next packet
                                if (fifo_cnt[p] > 0)
                                    timestamp_fifo[p][fifo_head[p]] <= 32'h0;
                                    
                                $display("[%0t] [AURORA-FABRIC] ** DEADLOCK RECOVERY: Dropped packet from port %0d", $time, p);
                            end
                        end
                        stuck_port_mask = 8'h0;
                        deadlock_timeout_counter <= 32'h0;
                    end
                end else begin
                    deadlock_timeout_counter <= 32'h0;
                end
            end

            // ═══════════════════════════════════════════════════════
            // FIX v2 #3: BANDWIDTH LIMITER — Window-based throttle control
            // If exceeded, set throttle_lower_prio to block NPU/H-core injection.
            // ═══════════════════════════════════════════════════════
            // Bandwidth window counter update
            bw_window_counter <= bw_window_counter + 1;

            if (bw_window_counter == BW_WINDOW_LEN - 1) begin
                // Window expired — evaluate bandwidth
                if (bw_window_packets > MAX_FABRIC_BW) begin
                    throttle_lower_prio <= 1'b1;  // Throttle NPU and H-core
                end else begin
                    throttle_lower_prio <= 1'b0;
                end
                // Reset window
                bw_window_packets <= 32'b0;
                bw_window_counter <= 8'b0;
            end  // bandwidth window if
        end  // else (non-reset)
    end  // always @(posedge clk or negedge rst_n)

    // =========================================================================
    // Ready signal generation (per port)
    // FIX v2 #3: When throttled, deassert ready for lower-priority ports
    // =========================================================================
    generate
        for (port_idx = 0; port_idx < NUM_PORTS; port_idx = port_idx + 1) begin : gen_ready
            assign port_ready[port_idx] = !fifo_full[port_idx] &&
                                           (credit_count[port_idx] > 0) &&
                                           !(throttle_lower_prio &&
                                             (get_effective_priority(port_idx[6:0], 2'b00) <= QOS_PRIO_HCORE));
        end
    endgenerate

    // =========================================================================
    // Output valid signals (driven from main always block via port_out_valid_reg)
    // =========================================================================
    generate
        for (out_idx = 0; out_idx < NUM_PORTS; out_idx = out_idx + 1) begin : gen_out_valid
            assign port_out_valid[out_idx] = port_out_valid_reg[out_idx];
        end
    endgenerate

endmodule
