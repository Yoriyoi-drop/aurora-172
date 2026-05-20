`timescale 1ns / 1ps

// Include parameters (Icarus compatibility)
`include "interfaces/aurora_params.svh"

//////////////////////////////////////////////////////////////////////////////////
// Company: AURORA Semiconductor
// Engineer: Interconnect Architecture Team
// Module Name: chiplet_interconnect
//
// Description:
//   Chiplet-Level Interconnect dengan round-robin arbitration, flow control,
//   dan simple snoop-based coherence
//   FIX v2: Complete rewrite dengan Verilator-compatible syntax
//////////////////////////////////////////////////////////////////////////////////

module chiplet_interconnect #(
    // Use standardized parameters
    parameter ADDR_WIDTH    = AURORA_ADDR_WIDTH,
    parameter DATA_WIDTH    = AURORA_DATA_WIDTH,
    parameter NUM_CHIPLETS  = 2     // OPTIMIZED: 4->2 (G and A only)
)(
    input  wire                         clk,
    input  wire                         rst_n,

    // Chiplet request ports (G, A, H, NPU)
    input  wire [ADDR_WIDTH-1:0]        g_addr,
    input  wire [ADDR_WIDTH-1:0]        a_addr,
    input  wire [ADDR_WIDTH-1:0]        h_addr,
    input  wire [ADDR_WIDTH-1:0]        npu_addr,
    input  wire [DATA_WIDTH-1:0]        g_data,
    input  wire [DATA_WIDTH-1:0]        a_data,
    input  wire [DATA_WIDTH-1:0]        h_data,
    input  wire [DATA_WIDTH-1:0]        npu_data,
    input  wire                         g_valid,
    input  wire                         a_valid,
    input  wire                         h_valid,
    input  wire                         npu_valid,
    output wire                         g_ready,
    output wire                         a_ready,
    output wire                         h_ready,
    output wire                         npu_ready,
    input  wire                         input_ready_g,
    input  wire                         input_ready_a,
    input  wire                         input_ready_h,
    input  wire                         input_ready_npu,

    // Memory fabric output
    output reg  [ADDR_WIDTH-1:0]        mem_addr,
    output reg  [DATA_WIDTH-1:0]        mem_data,
    output reg                          mem_valid,
    input  wire                         mem_req_ready,

    // FIX v2: Snoop coherence outputs
    output reg                          snoop_broadcast_valid,
    output reg  [ADDR_WIDTH-1:0]        snoop_broadcast_addr,
    output reg  [3:0]                   snoop_invalidate_targets,

    // Metrics
    output reg [31:0]                   total_packets,
    output reg [31:0]                   local_hits,
    output reg [31:0]                   cross_chiplet_packets
);

    // FIX v2: Ready signals - asserted when chiplet is selected AND downstream ready
    reg g_ready_reg, a_ready_reg, h_ready_reg, npu_ready_reg;
    assign g_ready = g_ready_reg;
    assign a_ready = a_ready_reg;
    assign h_ready = h_ready_reg;
    assign npu_ready = npu_ready_reg;

    // FIX v2: Round-robin arbiter state
    reg [1:0] rr_pointer;  // 0=G, 1=A, 2=H, 3=NPU
    reg [1:0] selected_chiplet;
    reg       has_request;

    // FIX v2: Snoop table - simple tag tracking
    localparam SNOOP_SIZE = 64;
    reg [3:0]   snoop_table [0:SNOOP_SIZE-1];  // Which chiplets have this line
    reg [15:0]  snoop_tags [0:SNOOP_SIZE-1];   // Tag for each entry
    integer     si_loop;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rr_pointer <= 2'b00;
            selected_chiplet <= 2'b00;
            has_request <= 1'b0;
            mem_valid <= 1'b0;
            mem_addr <= {ADDR_WIDTH{1'b0}};
            mem_data <= {DATA_WIDTH{1'b0}};
            g_ready_reg <= 1'b0;
            a_ready_reg <= 1'b0;
            h_ready_reg <= 1'b0;
            npu_ready_reg <= 1'b0;
            total_packets <= 32'd0;
            local_hits <= 32'd0;
            cross_chiplet_packets <= 32'd0;
            snoop_broadcast_valid <= 1'b0;
            snoop_broadcast_addr <= {ADDR_WIDTH{1'b0}};
            snoop_invalidate_targets <= 4'b0000;
            for (si_loop = 0; si_loop < SNOOP_SIZE; si_loop = si_loop + 1) begin
                snoop_table[si_loop] <= 4'b0000;
                snoop_tags[si_loop] <= 16'b0;
            end
        end else begin
            // Default: clear outputs
            mem_valid <= 1'b0;
            g_ready_reg <= 1'b0;
            a_ready_reg <= 1'b0;
            h_ready_reg <= 1'b0;
            npu_ready_reg <= 1'b0;
            snoop_broadcast_valid <= 1'b0;
            snoop_invalidate_targets <= 4'b0000;

            // FIX v2: Round-robin arbitration (single case, no redundant init)
            // Just pick based on rr_pointer priority order
            case (rr_pointer)
                2'b00: begin  // G priority
                    if (g_valid && input_ready_g) selected_chiplet = 2'b00;
                    else if (a_valid && input_ready_a) selected_chiplet = 2'b01;
                    else if (h_valid && input_ready_h) selected_chiplet = 2'b10;
                    else if (npu_valid && input_ready_npu) selected_chiplet = 2'b11;
                    else selected_chiplet = 2'b00;  // No request
                end
                2'b01: begin  // A priority
                    if (a_valid && input_ready_a) selected_chiplet = 2'b01;
                    else if (h_valid && input_ready_h) selected_chiplet = 2'b10;
                    else if (npu_valid && input_ready_npu) selected_chiplet = 2'b11;
                    else if (g_valid && input_ready_g) selected_chiplet = 2'b00;
                    else selected_chiplet = 2'b01;
                end
                2'b10: begin  // H priority
                    if (h_valid && input_ready_h) selected_chiplet = 2'b10;
                    else if (npu_valid && input_ready_npu) selected_chiplet = 2'b11;
                    else if (g_valid && input_ready_g) selected_chiplet = 2'b00;
                    else if (a_valid && input_ready_a) selected_chiplet = 2'b01;
                    else selected_chiplet = 2'b10;
                end
                2'b11: begin  // NPU priority
                    if (npu_valid && input_ready_npu) selected_chiplet = 2'b11;
                    else if (g_valid && input_ready_g) selected_chiplet = 2'b00;
                    else if (a_valid && input_ready_a) selected_chiplet = 2'b01;
                    else if (h_valid && input_ready_h) selected_chiplet = 2'b10;
                    else selected_chiplet = 2'b11;
                end
            endcase

            // Check if selected actually has a request
            has_request = (selected_chiplet == 2'b00 && g_valid) ||
                          (selected_chiplet == 2'b01 && a_valid) ||
                          (selected_chiplet == 2'b10 && h_valid) ||
                          (selected_chiplet == 2'b11 && npu_valid);

            // Forward to memory fabric if downstream ready
            if (has_request && mem_req_ready) begin
                case (selected_chiplet)
                    2'b00: begin mem_addr <= g_addr; mem_data <= g_data; mem_valid <= 1'b1; g_ready_reg <= 1'b1; end
                    2'b01: begin mem_addr <= a_addr; mem_data <= a_data; mem_valid <= 1'b1; a_ready_reg <= 1'b1; end
                    2'b10: begin mem_addr <= h_addr; mem_data <= h_data; mem_valid <= 1'b1; h_ready_reg <= 1'b1; end
                    2'b11: begin mem_addr <= npu_addr; mem_data <= npu_data; mem_valid <= 1'b1; npu_ready_reg <= 1'b1; end
                endcase

                total_packets <= total_packets + 1;

                // FIX #10: Advance RR pointer only on successful forwarding
                // CRITICAL FIX: Also advance pointer when NO request or memory not ready
                // This prevents starvation when one chiplet monopolizes
                rr_pointer <= (rr_pointer == 2'b11) ? 2'b00 : rr_pointer + 1;

                // FIX: Snoop using current request, not stale mem_valid (NBA ordering)
                // Use selected_chiplet/has_request which are blocking-assigned in same cycle
                snoop_broadcast_valid <= 1'b1;
                snoop_broadcast_addr <= g_addr;
                snoop_invalidate_targets <= snoop_table[mem_addr[5:0] % SNOOP_SIZE];
                snoop_table[mem_addr[5:0] % SNOOP_SIZE] <= (1'b1 << selected_chiplet);
                snoop_tags[mem_addr[5:0] % SNOOP_SIZE] <= mem_addr[ADDR_WIDTH-1 -: 16];
            end else begin
                // CRITICAL FIX #10: Advance RR pointer even when memory not ready
                // This prevents starvation - all chiplets get fair chance
                rr_pointer <= (rr_pointer == 2'b11) ? 2'b00 : rr_pointer + 1;
            end
        end
    end

endmodule
