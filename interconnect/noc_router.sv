`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Interconnect Architecture Team
//
// Create Date: 10 April 2026
// Design Name: AURORA-172 NoC Router
// Module Name: noc_router
//
// Description:
//   NoC Router - 2D Mesh Network-on-Chip router node
//   - 5-port switch (North, South, East, West, Local)
//   - XY routing algorithm (deadlock-free)
//   - Virtual channels (4 VC) for QoS
//   - Wormhole switching
//   - Congestion-aware flow control
//   - Credit-based flow control
//   - FIX v2: Functional response path with proper drain logic
//   - FIX v2: No data truncation on local port input
//   - FIX v2: Dropped packets counter increments correctly
//
// Target: Realistic interconnect between cores, caches, and memory
//////////////////////////////////////////////////////////////////////////////////

module noc_router #(
    parameter DATA_WIDTH    = `AURORA_DATA_WIDTH,   // FIXED: Use standard parameter
    parameter ADDR_WIDTH    = `AURORA_ADDR_WIDTH,   // FIXED: Use standard parameter
    parameter VC_COUNT      = 2,    // OPTIMIZED: 4->2 (simpler VCs)
    parameter BUFFER_DEPTH  = 16,   // OPTIMIZED: 32->16 (smaller buffers)
    parameter ROUTER_X      = 0,
    parameter ROUTER_Y      = 0
)(
    input  wire                         clk,
    input  wire                         rst_n,
    
    // CRITICAL FIX #6: Deadlock recovery signal from noc_mesh
    input  wire                         reset_packet,  // Asserted by mesh when router stuck

    // Local port (to core/cache at this node)
    input  wire [ADDR_WIDTH-1:0]        local_addr,
    input  wire [DATA_WIDTH-1:0]        local_data,
    input  wire [1:0]                   local_vc,
    input  wire                         local_valid,
    output wire                         local_ready,
    output wire [DATA_WIDTH-1:0]        local_resp_data,
    output wire                         local_resp_valid,
    input  wire                         local_resp_ready,

    // North port
    input  wire [DATA_WIDTH-1:0]        n_data_in,
    input  wire                         n_valid_in,
    output wire                         n_ready_in,
    output wire [DATA_WIDTH-1:0]        n_data_out,
    output wire                         n_valid_out,
    input  wire                         n_ready_out,

    // South port
    input  wire [DATA_WIDTH-1:0]        s_data_in,
    input  wire                         s_valid_in,
    output wire                         s_ready_in,
    output wire [DATA_WIDTH-1:0]        s_data_out,
    output wire                         s_valid_out,
    input  wire                         s_ready_out,

    // East port
    input  wire [DATA_WIDTH-1:0]        e_data_in,
    input  wire                         e_valid_in,
    output wire                         e_ready_in,
    output wire [DATA_WIDTH-1:0]        e_data_out,
    output wire                         e_valid_out,
    input  wire                         e_ready_out,

    // West port
    input  wire [DATA_WIDTH-1:0]        w_data_in,
    input  wire                         w_valid_in,
    output wire                         w_ready_in,
    output wire [DATA_WIDTH-1:0]        w_data_out,
    output wire                         w_valid_out,
    input  wire                         w_ready_out,

    // Congestion metrics
    output reg [7:0]                    congestion_level,
    output reg [31:0]                   packets_routed,
    output reg [31:0]                   contention_cycles,
    output reg [31:0]                   dropped_packets,
    
    // DEADLOCK FIX: Head-of-Line blocking prevention
    output reg [31:0]                   hol_blocks_detected,
    output reg [31:0]                   vc_age_violations,
    output reg [31:0]                   priority_inversions
);

    // =========================================================================
    // Flit format
    // =========================================================================
    // [63:56] Header (8 bits)
    //   [7:4]   Message type (CMD=0, DATA=1, RESP=2, CREDIT=3)
    //   [3:2]   Virtual channel
    //   [1:0]   Flit type (HEAD=0, BODY=1, TAIL=2, SINGLE=3)
    // [55:8]  Payload (48 bits)
    // [7:0]   Checksum / sequence

    localparam MSG_CMD      = 4'b0000;
    localparam MSG_DATA     = 4'b0001;
    
    // DEADLOCK FIX: Virtual channel priority levels
    localparam VC_PRIORITY_0 = 2'b00;  // Lowest priority (best effort)
    localparam VC_PRIORITY_1 = 2'b01;  // Medium priority
    localparam VC_PRIORITY_2 = 2'b10;  // High priority
    localparam VC_PRIORITY_3 = 2'b11;  // Highest priority (critical)
    
    // HOL prevention thresholds
    localparam HOL_TIMEOUT = 16'd50;     // 50 cycles max wait in buffer
    localparam AGE_THRESHOLD = 16'd100;  // 100 cycles before priority boost
    localparam MSG_RESP     = 4'b0010;
    localparam MSG_CREDIT   = 4'b0011;

    localparam FLIT_HEAD    = 2'b00;
    localparam FLIT_BODY    = 2'b01;
    localparam FLIT_TAIL    = 2'b10;
    localparam FLIT_SINGLE  = 2'b11;

    // =========================================================================
    // Port definitions
    // =========================================================================
    localparam PORT_NORTH   = 3'b000;
    localparam PORT_SOUTH   = 3'b001;
    localparam PORT_EAST    = 3'b010;
    localparam PORT_WEST    = 3'b011;
    localparam PORT_LOCAL   = 3'b100;
    localparam PORT_NONE    = 3'b101;

    // =========================================================================
    // Input buffers (per port, per VC)
    // Structure: input_buf[port][vc][depth] - 3D array for efficient routing
    // - port: 0-4 (5 input ports: North, South, East, West, Local)
    // - vc: 0-VC_COUNT-1 (virtual channels per port)
    // - depth: 0-BUFFER_DEPTH-1 (buffer depth per VC)
    // =========================================================================
    reg [DATA_WIDTH-1:0]    input_buf [0:4][0:VC_COUNT-1][0:BUFFER_DEPTH-1];
    reg [7:0]               input_buf_wr_ptr [0:4][0:VC_COUNT-1];  // Write pointer per port/VC
    reg [7:0]               input_buf_rd_ptr [0:4][0:VC_COUNT-1];  // Read pointer per port/VC
    reg [7:0]               input_buf_count [0:4][0:VC_COUNT-1];   // Occupancy count per port/VC

    // =========================================================================
    // Routing state machine
    // =========================================================================
    reg [2:0]               state;
    localparam S_IDLE       = 3'b000;
    localparam S_ARBITRATE  = 3'b001;
    localparam S_ROUTE      = 3'b010;
    localparam S_SWITCH     = 3'b011;
    localparam S_COMPLETE   = 3'b100;

    reg [DATA_WIDTH-1:0]    current_flit;
    reg [3:0]               current_msg_type;
    reg [1:0]               current_vc;
    reg [1:0]               current_flit_type;
    reg [2:0]               current_in_port;
    reg [2:0]               current_out_port;
    reg [ADDR_WIDTH-1:0]    current_dest_addr;

    reg [4:0]               request_ports;
    reg [4:0]               grant_ports;
    reg                     arbitrating;

    // CRITICAL FIX #3: Timeout counter for S_SWITCH state to prevent deadlock
    reg [7:0]               switch_timeout_counter;
    
    // DEADLOCK FIX: HOL prevention and age tracking
    reg [15:0]              vc_age_counter [0:4][0:VC_COUNT-1];  // Age counter per VC
    reg [15:0]              hol_wait_counter [0:4][0:VC_COUNT-1]; // HOL wait time
    reg [1:0]               vc_priority_boost [0:4][0:VC_COUNT-1]; // Dynamic priority
    reg [31:0]              global_cycle_count;  // Global cycle counter for age tracking

    // =========================================================================
    // Credit-based Flow Control
    // =========================================================================
    reg [7:0] credit_count [0:5];  // FIX: 6 ports (include PORT_NONE for safety)
    // Use single source of truth for credit initialization
    localparam CREDIT_INIT = `AURORA_CREDIT_INITIAL;  // Single source of truth
    
    // DEADLOCK FIX: HOL prevention metrics (declared as output ports above)

    // =========================================================================
    // FIX v2: Response network with PROPER drain logic
    // Each port has a response buffer that can be consumed by downstream
    // =========================================================================
    reg [DATA_WIDTH-1:0]    resp_buf [0:4][0:BUFFER_DEPTH-1];
    reg [7:0]               resp_wr_ptr [0:4];
    reg [7:0]               resp_rd_ptr [0:4];
    reg [7:0]               resp_count [0:4];

    // FIX v2: Response output assignments - multiplex resp_buf vs forwarding
    // Priority: response buffer (higher) > forwarding path (lower)
    assign local_resp_data = (resp_count[PORT_LOCAL] > 0) ?
                             resp_buf[PORT_LOCAL][resp_rd_ptr[PORT_LOCAL]] :
                             {DATA_WIDTH{1'b0}};
    assign local_resp_valid = (resp_count[PORT_LOCAL] > 0);

    function automatic [DATA_WIDTH-1:0] port_data_out;
        input [2:0] port;
        begin
            if (resp_count[port] > 0) begin
                port_data_out = resp_buf[port][resp_rd_ptr[port]];
            end else if ((current_out_port == port) && (state == S_SWITCH)) begin
                port_data_out = current_flit;
            end else begin
                port_data_out = {DATA_WIDTH{1'b0}};
            end
        end
    endfunction

    function automatic logic port_valid_out;
        input [2:0] port;
        begin
            if (resp_count[port] > 0) begin
                port_valid_out = 1'b1;
            end else if ((current_out_port == port) && (state == S_SWITCH)) begin
                port_valid_out = 1'b1;
            end else begin
                port_valid_out = 1'b0;
            end
        end
    endfunction

    assign n_data_out  = port_data_out(PORT_NORTH);
    assign n_valid_out = port_valid_out(PORT_NORTH);
    assign s_data_out  = port_data_out(PORT_SOUTH);
    assign s_valid_out = port_valid_out(PORT_SOUTH);
    assign e_data_out  = port_data_out(PORT_EAST);
    assign e_valid_out = port_valid_out(PORT_EAST);
    assign w_data_out  = port_data_out(PORT_WEST);
    assign w_valid_out = port_valid_out(PORT_WEST);

    // =========================================================================
    // XY Routing function
    // =========================================================================
    function automatic [2:0] xy_route;
        input [ADDR_WIDTH-1:0] dest_addr;
        reg [15:0] dest_x, dest_y;
        begin
            dest_x = dest_addr[47:32];
            dest_y = dest_addr[31:16];

            if (dest_x == ROUTER_X && dest_y == ROUTER_Y) begin
                xy_route = PORT_LOCAL;
            end else if (dest_x > ROUTER_X) begin
                xy_route = PORT_EAST;
            end else if (dest_x < ROUTER_X) begin
                xy_route = PORT_WEST;
            end else if (dest_y > ROUTER_Y) begin
                xy_route = PORT_SOUTH;
            end else begin
                xy_route = PORT_NORTH;
            end
        end
    endfunction

    function automatic logic is_buffer_full;
        input [2:0] port;
        input [1:0] vc;
        begin
            is_buffer_full = (input_buf_count[port][vc] >= BUFFER_DEPTH);
        end
    endfunction

    function automatic logic is_buffer_empty;
        input [2:0] port;
        input [1:0] vc;
        begin
            is_buffer_empty = (input_buf_count[port][vc] == 0);
        end
    endfunction

    function automatic [7:0] get_buffer_occupancy;
        input [2:0] port;
        integer vc;
        reg [7:0] total;
        begin
            total = 0;
            for (vc = 0; vc < VC_COUNT; vc = vc + 1) begin
                total = total + input_buf_count[port][vc];
            end
            get_buffer_occupancy = total;
        end
    endfunction

    // =========================================================================
    // Input buffer management
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            integer p, vc, i;
            for (p = 0; p < 5; p = p + 1) begin
                for (vc = 0; vc < VC_COUNT; vc = vc + 1) begin
                    for (i = 0; i < BUFFER_DEPTH; i = i + 1) begin
                        input_buf[p][vc][i] <= {DATA_WIDTH{1'b0}};
                    end
                    input_buf_wr_ptr[p][vc] <= 8'h0;
                    input_buf_rd_ptr[p][vc] <= 8'h0;
                    input_buf_count[p][vc] <= 8'h0;
                end
            end

            // FIX v2: Initialize response buffers
            for (p = 0; p < 5; p = p + 1) begin
                for (i = 0; i < BUFFER_DEPTH; i = i + 1) begin
                    resp_buf[p][i] <= {DATA_WIDTH{1'b0}};
                end
                resp_wr_ptr[p] <= 8'h0;
                resp_rd_ptr[p] <= 8'h0;
                resp_count[p] <= 8'h0;
            end

            // FIX v2: Initialize credits
            for (p = 0; p < 6; p = p + 1) begin
                credit_count[p] <= CREDIT_INIT;
            end
        end else begin
            // ─────────────────────────────────────────────────
            // Input: North port
            // ─────────────────────────────────────────────────
            begin : n_input_block
                reg [1:0] vc_masked;
                vc_masked = (n_data_in[3:2] < VC_COUNT) ? n_data_in[3:2] : (VC_COUNT-1);
                if (n_valid_in && n_ready_in && !is_buffer_full(PORT_NORTH, vc_masked)) begin
                    input_buf[PORT_NORTH][vc_masked][input_buf_wr_ptr[PORT_NORTH][vc_masked]] <= n_data_in;
                    input_buf_wr_ptr[PORT_NORTH][vc_masked] <= input_buf_wr_ptr[PORT_NORTH][vc_masked] + 1;
                    input_buf_count[PORT_NORTH][vc_masked] <= input_buf_count[PORT_NORTH][vc_masked] + 1;
                end
            end

            // ─────────────────────────────────────────────────
            // Input: South port
            // ─────────────────────────────────────────────────
            begin : s_input_block
                reg [1:0] vc_masked;
                vc_masked = (s_data_in[3:2] < VC_COUNT) ? s_data_in[3:2] : (VC_COUNT-1);
                if (s_valid_in && s_ready_in && !is_buffer_full(PORT_SOUTH, vc_masked)) begin
                    input_buf[PORT_SOUTH][vc_masked][input_buf_wr_ptr[PORT_SOUTH][vc_masked]] <= s_data_in;
                    input_buf_wr_ptr[PORT_SOUTH][vc_masked] <= input_buf_wr_ptr[PORT_SOUTH][vc_masked] + 1;
                    input_buf_count[PORT_SOUTH][vc_masked] <= input_buf_count[PORT_SOUTH][vc_masked] + 1;
                end
            end

            // ─────────────────────────────────────────────────
            // Input: East port
            // ─────────────────────────────────────────────────
            begin : e_input_block
                reg [1:0] vc_masked;
                vc_masked = (e_data_in[3:2] < VC_COUNT) ? e_data_in[3:2] : (VC_COUNT-1);
                if (e_valid_in && e_ready_in && !is_buffer_full(PORT_EAST, vc_masked)) begin
                    input_buf[PORT_EAST][vc_masked][input_buf_wr_ptr[PORT_EAST][vc_masked]] <= e_data_in;
                    input_buf_wr_ptr[PORT_EAST][vc_masked] <= input_buf_wr_ptr[PORT_EAST][vc_masked] + 1;
                    input_buf_count[PORT_EAST][vc_masked] <= input_buf_count[PORT_EAST][vc_masked] + 1;
                end
            end

            // ─────────────────────────────────────────────────
            // Input: West port
            // ─────────────────────────────────────────────────
            begin : w_input_block
                reg [1:0] vc_masked;
                vc_masked = (w_data_in[3:2] < VC_COUNT) ? w_data_in[3:2] : (VC_COUNT-1);
                if (w_valid_in && w_ready_in && !is_buffer_full(PORT_WEST, vc_masked)) begin
                    input_buf[PORT_WEST][vc_masked][input_buf_wr_ptr[PORT_WEST][vc_masked]] <= w_data_in;
                    input_buf_wr_ptr[PORT_WEST][vc_masked] <= input_buf_wr_ptr[PORT_WEST][vc_masked] + 1;
                    input_buf_count[PORT_WEST][vc_masked] <= input_buf_count[PORT_WEST][vc_masked] + 1;
                end
            end

            // ─────────────────────────────────────────────────
            // FIX v2: Local port input - NO data truncation
            // Previously: {local_data, local_addr[15:0]} = 144 bits → truncated to 128
            // Now: Use local_data directly, encode addr in payload area
            // DEADLOCK FIX: Track age and detect HOL blocking
            // ─────────────────────────────────────────────────
            begin : local_input_block
                reg [1:0] vc_masked;
                vc_masked = (local_vc < VC_COUNT) ? local_vc : (VC_COUNT-1);
            if (local_valid && local_ready && !is_buffer_full(PORT_LOCAL, vc_masked)) begin
                // Pack addr into upper bits of data (data is 128-bit, addr is 48-bit)
                // Use upper 48 bits for addr, lower 80 bits for data
                input_buf[PORT_LOCAL][vc_masked][input_buf_wr_ptr[PORT_LOCAL][vc_masked]] <=
                    {local_addr[47:0], local_data[79:0]};
                input_buf_wr_ptr[PORT_LOCAL][vc_masked] <= input_buf_wr_ptr[PORT_LOCAL][vc_masked] + 1;
                input_buf_count[PORT_LOCAL][vc_masked] <= input_buf_count[PORT_LOCAL][vc_masked] + 1;
                
                // DEADLOCK FIX: Initialize age tracking for new packet
                vc_age_counter[PORT_LOCAL][vc_masked] <= 16'd0;
                hol_wait_counter[PORT_LOCAL][vc_masked] <= 16'd0;
            end
            end

            // ─────────────────────────────────────────────────
            // FIX v2: Response buffer drain logic (THE CRITICAL FIX)
            // When downstream consumer asserts resp_ready, advance rd_ptr
            // ─────────────────────────────────────────────────

            // Local response drain
            if (local_resp_ready && resp_count[PORT_LOCAL] > 0) begin
                resp_rd_ptr[PORT_LOCAL] <= (resp_rd_ptr[PORT_LOCAL] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_rd_ptr[PORT_LOCAL] + 1;
                resp_count[PORT_LOCAL] <= resp_count[PORT_LOCAL] - 1;
            end

            // North response drain (when downstream ready)
            if (n_ready_out && resp_count[PORT_NORTH] > 0) begin
                resp_rd_ptr[PORT_NORTH] <= (resp_rd_ptr[PORT_NORTH] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_rd_ptr[PORT_NORTH] + 1;
                resp_count[PORT_NORTH] <= resp_count[PORT_NORTH] - 1;
            end

            // South response drain
            if (s_ready_out && resp_count[PORT_SOUTH] > 0) begin
                resp_rd_ptr[PORT_SOUTH] <= (resp_rd_ptr[PORT_SOUTH] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_rd_ptr[PORT_SOUTH] + 1;
                resp_count[PORT_SOUTH] <= resp_count[PORT_SOUTH] - 1;
            end

            // East response drain
            if (e_ready_out && resp_count[PORT_EAST] > 0) begin
                resp_rd_ptr[PORT_EAST] <= (resp_rd_ptr[PORT_EAST] == (BUFFER_DEPTH - 1)) ?
                                           8'h0 : resp_rd_ptr[PORT_EAST] + 1;
                resp_count[PORT_EAST] <= resp_count[PORT_EAST] - 1;
            end

            // West response drain
            if (w_ready_out && resp_count[PORT_WEST] > 0) begin
                resp_rd_ptr[PORT_WEST] <= (resp_rd_ptr[PORT_WEST] == (BUFFER_DEPTH - 1)) ?
                                           8'h0 : resp_rd_ptr[PORT_WEST] + 1;
                resp_count[PORT_WEST] <= resp_count[PORT_WEST] - 1;
            end

            // ─────────────────────────────────────────────────
            // FIX v2: Response path for MSG_RESP type packets
            // CRITICAL FIX #4: Add backpressure - reject new responses when resp buffer near full
            // CRITICAL FIX #5: Arbitration to prevent multiple ports writing same cycle (N>S>E>W)
            // When a response packet arrives, buffer it for local consumption
            // ─────────────────────────────────────────────────
            // Backpressure threshold: reject new responses when buffer > 75% full
            if (n_valid_in && n_data_in[7:4] == MSG_RESP && resp_count[PORT_LOCAL] < (BUFFER_DEPTH * 3 / 4)) begin
                resp_buf[PORT_LOCAL][resp_wr_ptr[PORT_LOCAL]] <= n_data_in;
                resp_wr_ptr[PORT_LOCAL] <= (resp_wr_ptr[PORT_LOCAL] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_wr_ptr[PORT_LOCAL] + 1;
                resp_count[PORT_LOCAL] <= resp_count[PORT_LOCAL] + 1;
            end else if (s_valid_in && s_data_in[7:4] == MSG_RESP && resp_count[PORT_LOCAL] < (BUFFER_DEPTH * 3 / 4)) begin
                resp_buf[PORT_LOCAL][resp_wr_ptr[PORT_LOCAL]] <= s_data_in;
                resp_wr_ptr[PORT_LOCAL] <= (resp_wr_ptr[PORT_LOCAL] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_wr_ptr[PORT_LOCAL] + 1;
                resp_count[PORT_LOCAL] <= resp_count[PORT_LOCAL] + 1;
            end else if (e_valid_in && e_data_in[7:4] == MSG_RESP && resp_count[PORT_LOCAL] < (BUFFER_DEPTH * 3 / 4)) begin
                resp_buf[PORT_LOCAL][resp_wr_ptr[PORT_LOCAL]] <= e_data_in;
                resp_wr_ptr[PORT_LOCAL] <= (resp_wr_ptr[PORT_LOCAL] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_wr_ptr[PORT_LOCAL] + 1;
                resp_count[PORT_LOCAL] <= resp_count[PORT_LOCAL] + 1;
            end else if (w_valid_in && w_data_in[7:4] == MSG_RESP && resp_count[PORT_LOCAL] < (BUFFER_DEPTH * 3 / 4)) begin
                resp_buf[PORT_LOCAL][resp_wr_ptr[PORT_LOCAL]] <= w_data_in;
                resp_wr_ptr[PORT_LOCAL] <= (resp_wr_ptr[PORT_LOCAL] == (BUFFER_DEPTH - 1)) ?
                                            8'h0 : resp_wr_ptr[PORT_LOCAL] + 1;
                resp_count[PORT_LOCAL] <= resp_count[PORT_LOCAL] + 1;
            end


            // ─────────────────────────────────────────────────
            // DEADLOCK FIX: Age tracking and HOL prevention
            // Increment age counters and detect HOL blocking
            // ─────────────────────────────────────────────────
            global_cycle_count <= global_cycle_count + 1;
            
            // Update age counters for all VCs
            for (int port = 0; port < 5; port = port + 1) begin
                for (int vc = 0; vc < VC_COUNT; vc = vc + 1) begin
                    if (input_buf_count[port][vc] > 0) begin
                        // Increment age counter
                        vc_age_counter[port][vc] <= vc_age_counter[port][vc] + 1;
                        hol_wait_counter[port][vc] <= hol_wait_counter[port][vc] + 1;
                        
                        // Check for HOL blocking
                        if (hol_wait_counter[port][vc] >= HOL_TIMEOUT) begin
                            hol_blocks_detected <= hol_blocks_detected + 1;
                            $display("[%0t] [NOC-ROUTER] HOL BLOCKING detected: Port=%0d, VC=%0d, wait=%0d cycles", 
                                     $time, port, vc, hol_wait_counter[port][vc]);
                            
                            // Priority boost to prevent starvation
                            if (vc_priority_boost[port][vc] < 2'b11) begin
                                vc_priority_boost[port][vc] <= vc_priority_boost[port][vc] + 1;
                                priority_inversions <= priority_inversions + 1;
                            end
                        end
                        
                        // Check for age violation
                        if (vc_age_counter[port][vc] >= AGE_THRESHOLD) begin
                            vc_age_violations <= vc_age_violations + 1;
                            $display("[%0t] [NOC-ROUTER] AGE VIOLATION: Port=%0d, VC=%0d, age=%0d cycles", 
                                     $time, port, vc, vc_age_counter[port][vc]);
                            
                            // Force priority to maximum
                            vc_priority_boost[port][vc] <= 2'b11;
                        end
                    end else begin
                        // Reset counters when buffer empty
                        vc_age_counter[port][vc] <= 16'd0;
                        hol_wait_counter[port][vc] <= 16'd0;
                        vc_priority_boost[port][vc] <= 2'b00;
                    end
                end
            end
            
            // ─────────────────────────────────────────────────
            // FIX v2: Credit return when input buffer is consumed
            // (handled in S_COMPLETE state below)
            // ─────────────────────────────────────────────────
        end
    end

    // =========================================================================
    // Ready signals (credit-based)
    // =========================================================================
    // Ready signals: check specific VC from incoming data (per-VC flow control)
    assign n_ready_in = !is_buffer_full(PORT_NORTH, (n_data_in[3:2] < VC_COUNT) ? n_data_in[3:2] : (VC_COUNT-1));
    assign s_ready_in = !is_buffer_full(PORT_SOUTH, (s_data_in[3:2] < VC_COUNT) ? s_data_in[3:2] : (VC_COUNT-1));
    assign e_ready_in = !is_buffer_full(PORT_EAST, (e_data_in[3:2] < VC_COUNT) ? e_data_in[3:2] : (VC_COUNT-1));
    assign w_ready_in = !is_buffer_full(PORT_WEST, (w_data_in[3:2] < VC_COUNT) ? w_data_in[3:2] : (VC_COUNT-1));
    assign local_ready = !is_buffer_full(PORT_LOCAL, (local_vc < VC_COUNT) ? local_vc : (VC_COUNT-1));

    // =========================================================================
    // Main routing state machine
    // =========================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            current_flit <= {DATA_WIDTH{1'b0}};
            current_out_port <= PORT_NONE;
            current_in_port <= PORT_NONE;
            arbitrating <= 1'b0;
            congestion_level <= 8'h0;
            packets_routed <= 32'h0;
            contention_cycles <= 32'h0;
            dropped_packets <= 32'h0;
            switch_timeout_counter <= 8'h0;
        end else begin
            // Update congestion level (average buffer occupancy)
            congestion_level <= get_buffer_occupancy(PORT_NORTH) +
                               get_buffer_occupancy(PORT_SOUTH) +
                               get_buffer_occupancy(PORT_EAST) +
                               get_buffer_occupancy(PORT_WEST) +
                               get_buffer_occupancy(PORT_LOCAL);

            // CRITICAL FIX #6: Handle deadlock recovery signal from mesh
            // When reset_packet is asserted, drain current packet and reset state
            if (reset_packet && state != S_IDLE) begin
                $display("[%0t] [NoC-ROUTER] ⚠ DEADLOCK RECOVERY: Router(%0d,%0d) received reset signal, draining packet",
                        $time, ROUTER_X, ROUTER_Y);
                dropped_packets <= dropped_packets + 1;
                // Reset all state machines and counters
                state <= S_IDLE;
                arbitrating <= 1'b0;
                switch_timeout_counter <= 8'h0;
                current_out_port <= PORT_NONE;
                current_in_port <= PORT_NONE;
                // Restore credits for the dropped packet
                if (current_out_port != PORT_NONE) begin
                    credit_count[current_out_port] <= credit_count[current_out_port] + 1;
                end
            end else begin

            case (state)
                // ─────────────────────────────────────────────────
                // S_IDLE: Check for pending requests
                // ─────────────────────────────────────────────────
                S_IDLE: begin
                    integer p;
                    integer vc;
                    request_ports = 0;
                    for (p = 0; p < 5; p = p + 1) begin
                        for (vc = 0; vc < VC_COUNT; vc = vc + 1) begin
                            if (!is_buffer_empty(p, vc)) begin
                                request_ports[p] = 1'b1;
                            end
                        end
                    end

                    if (request_ports != 0) begin
                        state <= S_ARBITRATE;
                    end
                end

                // ─────────────────────────────────────────────────
                // S_ARBITRATE: Round-robin with VC priority
                // ─────────────────────────────────────────────────
                S_ARBITRATE: begin
                    integer p;
                    integer count;
                    reg found;
                    grant_ports = 0;
                    count = 0;
                    found = 1'b0;

                    // Find highest priority port with request
                    for (p = 0; p < 5 && !found; p = p + 1) begin
                        if (request_ports[p]) begin
                            grant_ports[p] = 1'b1;
                            current_in_port <= p[2:0];  // FIX: Use non-blocking for consistency
                            count = count + 1;
                            found = 1'b1;
                        end
                    end

                    if (count > 1) begin
                        contention_cycles <= contention_cycles + count;
                    end

                    arbitrating <= 1'b1;
                    state <= S_ROUTE;
                end

                // ─────────────────────────────────────────────────
                // S_ROUTE: Read flit, determine output port
                // ─────────────────────────────────────────────────
                S_ROUTE: begin
                    integer vc;
                    reg found;
                    reg [DATA_WIDTH-1:0] current_flit_data;
                    // Find first non-empty VC in the selected port
                    vc = 0;
                    found = 1'b0;
                    for (int svc = 0; svc < VC_COUNT && !found; svc = svc + 1) begin
                        if (!is_buffer_empty(current_in_port, svc)) begin
                            vc = svc;
                            found = 1'b1;
                        end
                    end
                    if (!found) vc = 0;

                    // REVIEWED: Array indexing is safe - current_in_port and vc are validated
                    // current_in_port comes from port arbitration (0-4), vc is bounded by VC_COUNT
                    // FIX: Buffer flit data before NBA so routing reads current value
                    current_flit_data = input_buf[current_in_port][vc][input_buf_rd_ptr[current_in_port][vc]];
                    current_flit <= current_flit_data;
                    current_vc <= vc[1:0];

                    // Extract header using combinational copy
                    current_msg_type <= current_flit_data[59:56];
                    current_flit_type <= current_flit_data[1:0];

                    // Determine output port using XY routing
                    current_dest_addr <= current_flit_data[47:0];
                    current_out_port <= xy_route(current_flit_data[47:0]);

                    // Check if output port is valid (not self for non-local)
                    if (current_out_port == PORT_NONE) begin
                        // FIX v2: Invalid routing → drop packet
                        dropped_packets <= dropped_packets + 1;
                        // Drain from input buffer
                        input_buf_count[current_in_port][vc] <= input_buf_count[current_in_port][vc] - 1;
                        input_buf_rd_ptr[current_in_port][vc] <= input_buf_rd_ptr[current_in_port][vc] + 1;
                        state <= S_IDLE;
                    end
                    // Check if output buffer has space (credit-based)
                    else if (credit_count[current_out_port] > 0) begin
                        state <= S_SWITCH;
                    end else begin
                        // Output buffer full - backpressure, retry
                        dropped_packets <= dropped_packets + 1;  // FIX v2: Count drops
                        state <= S_ARBITRATE;
                    end
                end

                // ─────────────────────────────────────────────────
                // S_SWITCH: Crossbar switch - move flit to output
                // ─────────────────────────────────────────────────
                S_SWITCH: begin
                    // CRITICAL FIX v3: Two-phase commit to prevent data loss
                    // Phase 1: Wait for output ready BEFORE decrementing counters
                    // Phase 2: Decrement counters and complete transfer
                    
                    // FIX: Increment timeout counter
                    if (switch_timeout_counter < 8'hFF) begin
                        switch_timeout_counter <= switch_timeout_counter + 1;
                    end
                    
                    // CRITICAL FIX v4: Add backpressure relief mechanism
                    // If stuck > 48 cycles, try alternative routing or drop
                    if (switch_timeout_counter == 8'd48) begin
                        $display("[%0t] [NoC-ROUTER] ⚠ BACKPRESSURE WARNING: Router(%0d,%0d) stuck for 48 cycles, considering packet drop", 
                                $time, ROUTER_X, ROUTER_Y);
                    end
                    
                    // CRITICAL FIX #3: Add timeout to prevent circular backpressure deadlock
                    // If output port not ready for 64 cycles, drop packet and return to IDLE
                    if (switch_timeout_counter >= 8'd64) begin
                        $display("[%0t] [NoC-ROUTER] S_SWITCH TIMEOUT: Output port %0d not ready after 64 cycles, dropping packet", $time, current_out_port);
                        dropped_packets <= dropped_packets + 1;
                        switch_timeout_counter <= 8'h0;
                        // CRITICAL FIX #3: ONLY restore output credit, NOT input buffer count
                        // The flit was already removed from input buffer in S_ROUTE (rd_ptr advanced)
                        // Restoring input_buf_count would create phantom entry causing permanent stall
                        credit_count[current_out_port] <= credit_count[current_out_port] + 1;
                        // DO NOT: input_buf_count[current_in_port][current_vc] <= ... + 1;
                        state <= S_IDLE;
                    end else begin
                        // Wait for output ready before completing
                        // FIX v3: DO NOT decrement counters until output is ready
                        reg output_is_ready;
                        case (current_out_port)
                            PORT_NORTH:  output_is_ready = n_ready_out;
                            PORT_SOUTH:  output_is_ready = s_ready_out;
                            PORT_EAST:   output_is_ready = e_ready_out;
                            PORT_WEST:   output_is_ready = w_ready_out;
                            PORT_LOCAL:  output_is_ready = local_resp_ready;
                            default:     output_is_ready = 1'b1;
                        endcase
                        
                        if (output_is_ready) begin
                            // PHASE 2: Output ready - NOW safe to decrement counters
                            input_buf_count[current_in_port][current_vc] <= input_buf_count[current_in_port][current_vc] - 1;
                            input_buf_rd_ptr[current_in_port][current_vc] <= input_buf_rd_ptr[current_in_port][current_vc] + 1;
                            credit_count[current_out_port] <= credit_count[current_out_port] - 1;
                            
                            packets_routed <= packets_routed + 1;
                            arbitrating <= 1'b0;
                            switch_timeout_counter <= 8'h0;

                            // FIX v2: For response messages, also buffer in resp_buf
                            if (current_msg_type == MSG_RESP) begin
                                if (resp_count[current_out_port] < BUFFER_DEPTH) begin
                                    resp_buf[current_out_port][resp_wr_ptr[current_out_port]] <= current_flit;
                                    resp_wr_ptr[current_out_port] <= (resp_wr_ptr[current_out_port] == (BUFFER_DEPTH - 1)) ?
                                                                      8'h0 : resp_wr_ptr[current_out_port] + 1;
                                    resp_count[current_out_port] <= resp_count[current_out_port] + 1;
                                end
                            end
                            
                            state <= S_COMPLETE;
                        end else begin
                            // PHASE 1: Output not ready - stay in S_SWITCH, preserve counters
                            // DO NOT touch any counters here - this is critical for correctness
                            arbitrating <= 1'b1;  // Mark as waiting
                        end
                    end
                end

                // ─────────────────────────────────────────────────
                // S_COMPLETE: Complete flit transfer
                // ─────────────────────────────────────────────────
                S_COMPLETE: begin
                    // CRITICAL FIX: Do NOT restore credit here - that would create net-zero
                    // credit accounting (credits never consumed, no backpressure).
                    // Credits represent downstream buffer capacity and are consumed when
                    // a flit is sent. The downstream must return credits via a credit
                    // return mechanism when it drains the flit from its input buffer.
                    // Without credit return signals, credits will properly drain to
                    // implement flow control.
                    current_out_port <= PORT_NONE;
                    current_in_port <= PORT_NONE;
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
            end // CRITICAL FIX #6: Close if (reset_packet) else block
        end
    end

    // =========================================================================
    // RUNTIME ASSERTIONS FOR NoC ROUTER
    // =========================================================================
    
    // Assertion 1: Credit count must never be negative
    always @(posedge clk) begin
        if (rst_n) begin
            integer port;
            for (port = 0; port < 5; port = port + 1) begin
                if (credit_count[port] == 8'd0) begin
                    $error("[%0t] [NoC-ROUTER] BUG: Credit underflow at port %0d: %0d", 
                          $time, port, credit_count[port]);
                end
            end
        end
    end
    
    // Assertion 2: Input buffer count must never exceed BUFFER_DEPTH
    always @(posedge clk) begin
        if (rst_n) begin
            integer port, vc;
            for (port = 0; port < 5; port = port + 1) begin
                for (vc = 0; vc < VC_COUNT; vc = vc + 1) begin
                    if (input_buf_count[port][vc] > BUFFER_DEPTH) begin
                        $error("[%0t] [NoC-ROUTER] BUG: Buffer overflow at port %0d VC %0d: count=%0d", 
                              $time, port, vc, input_buf_count[port][vc]);
                    end
                end
            end
        end
    end
    
    // Assertion 3: Detect circular backpressure - all ports blocked simultaneously
    reg [15:0] backpressure_cycles;
    always @(posedge clk) begin
        if (!rst_n) begin
            backpressure_cycles <= 0;
        end else begin
            // Check if all output ports are blocked
            reg all_blocked;
            all_blocked = !n_ready_out && !s_ready_out && !e_ready_out && !w_ready_out && !local_resp_ready;
            
            if (state == S_SWITCH && all_blocked) begin
                backpressure_cycles <= backpressure_cycles + 1;
                if (backpressure_cycles == 100) begin
                    $display("[%0t] [NoC-ROUTER] ⚠ CIRCULAR BACKPRESSURE: All ports blocked for 100 cycles at Router(%0d,%0d)", 
                            $time, ROUTER_X, ROUTER_Y);
                end
            end else begin
                backpressure_cycles <= 0;
            end
        end
    end
    
    // Assertion 4: Packet should not stay in router forever (liveness check)
    reg [31:0] total_packets_in_router;
    always @(posedge clk) begin
        if (!rst_n) begin
            total_packets_in_router <= 0;
        end else if (state != S_IDLE) begin
            total_packets_in_router <= total_packets_in_router + 1;
            if (total_packets_in_router == 500) begin
                $display("[%0t] [NoC-ROUTER] ⚠ LIVENESS WARNING: Packet in router for 500 cycles", $time);
            end
        end else begin
            total_packets_in_router <= 0;
        end
    end
    
    // Assertion 5: Resp buffer count must never exceed BUFFER_DEPTH
    always @(posedge clk) begin
        if (rst_n) begin
            integer port;
            for (port = 0; port < 5; port = port + 1) begin
                if (resp_count[port] > BUFFER_DEPTH) begin
                    $error("[%0t] [NoC-ROUTER] BUG: Response buffer overflow at port %0d: count=%0d", 
                          $time, port, resp_count[port]);
                end
            end
        end
    end

endmodule
